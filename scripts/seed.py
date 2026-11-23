#!/usr/bin/env python3
"""Encrypted seed for the local kind platform (WO-1.5b).

The seed `secrets.enc.yaml` (repo root) is a sops file encrypted to the age public key in
`.sops.yaml`. Key names are readable; every value is encrypted. Decrypting needs the age
private key (default ~/.helmsman-dev/age.key, or SOPS_AGE_KEY_FILE). Plaintext never touches
the disk: sops reads and writes through pipes, and this script keeps values in memory.

Seed layout (version 1):
  files:   name -> exact content of ~/.helmsman-dev/<name> (mode 600). Every credential file
           except the age key itself and the AgentForge Vault backup (generated from `vault`).
  vault:   "<path under secret/>" -> {property: value}, e.g. "agentforge/llm": {...}

Commands (nothing is ever printed except names, yes/no, lengths and counts):
  build        state dir -> seed (re-encrypts the whole file). Shows which entries changed.
  diff         seed vs state dir, per entry: same | differs | missing-in-state | missing-in-seed
  materialise  seed -> state dir. Writes missing files; --force also rewrites differing ones.
  apply        seed -> Vault (fill missing paths/properties; --overwrite replaces them) and the
               cluster Secrets that come only from the seed (see SECRETS below).
  verify       every Vault path/property the platform references, every seed-made cluster
               Secret and every state file: present yes/no, equals seed yes/no. Exit 1 on any no.

Credentials never go on a command line: the Vault token is sent on stdin to `kubectl exec -i`
(read by `read -r` in the container shell), payloads follow on stdin, and Secrets are sent to
`kubectl apply -f -` as JSON on stdin.

Settings (environment): HUB_CTX, SPOKE_CTX (default kind-<CLUSTER_PREFIX>hub /
kind-<CLUSTER_PREFIX>onprem with CLUSTER_PREFIX default "helmsman-"), HELMSMAN_STATE_DIR
(~/.helmsman-dev), HELMSMAN_SEED (<repo>/secrets.enc.yaml), SOPS_AGE_KEY_FILE.
"""
import argparse
import base64
import hashlib
import json
import os
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PREFIX = os.environ.get("CLUSTER_PREFIX", "helmsman-")
HUB_CTX = os.environ.get("HUB_CTX", "kind-%shub" % PREFIX)
SPOKE_CTX = os.environ.get("SPOKE_CTX", "kind-%sonprem" % PREFIX)
STATE = os.path.expanduser(os.environ.get("HELMSMAN_STATE_DIR", "~/.helmsman-dev"))
SEED = os.environ.get("HELMSMAN_SEED", os.path.join(REPO, "secrets.enc.yaml"))
AGE_KEY = os.path.expanduser(os.environ.get("SOPS_AGE_KEY_FILE", os.path.join(STATE, "age.key")))
SOPS = ["sops", "--disable-version-check"]
SEED_VERSION = 1

# State files that are not credentials, or that the seed represents another way.
NOT_IN_SEED = {"age.key", "dev-up.log", "last-dev-up", "vault-agentforge.json"}
# Human-held credentials: kept only as local files, never in the committed seed (the bootstrap
# does not need them, and they are worth more than the platform's own credentials).
HUMAN_HELD = {"helmsman-operator.env"}   # personal GitHub token (WO-1.5b Gate 1 decision)
NOT_IN_SEED |= HUMAN_HELD
VAULT_BACKUP = "vault-agentforge.json"      # written by materialise from the `vault` section
AF_PREFIX = "agentforge/"
# Properties whose value depends on the environment (dev-up rewrites them); verify checks
# presence only, apply never overwrites them.
ENV_DERIVED = {("agentforge/auth", "keycloak_url")}


# Cluster Secrets built only from seed values: (context, namespace, name, type, {key: value}).
# helmsman-platform-config is not here: it also carries non-secret settings that dev-up derives
# (URLs, cluster name), so dev-up Stage 6 keeps writing it from the materialised state files.
def secrets_spec(seed):
    f = seed.get("files", {})
    out = []
    if "vault-root-token" in f:
        out.append((SPOKE_CTX, "external-secrets", "vault-token", "Opaque",
                    {"token": f["vault-root-token"]}))
    if "keycloak-admin-password" in f:
        out.append((HUB_CTX, "keycloak", "keycloak-admin-credentials", "Opaque",
                    {"admin-user": "admin", "admin-password": f["keycloak-admin-password"],
                     "username": "admin", "password": f["keycloak-admin-password"]}))
    if "grafana-admin-password" in f:
        out.append((HUB_CTX, "monitoring", "grafana-admin-credentials", "Opaque",
                    {"admin-user": "admin", "admin-password": f["grafana-admin-password"]}))
    if "ghcr-pull-secret.json" in f:
        for ns in ("agentforge", "kyverno"):
            out.append((SPOKE_CTX, ns, "ghcr-pull-secret", "kubernetes.io/dockerconfigjson",
                        {".dockerconfigjson": f["ghcr-pull-secret.json"]}))
    return out


# ---------------------------------------------------------------- helpers
def die(msg, code=2):
    print("ERROR: " + msg, file=sys.stderr)
    sys.exit(code)


def h4(v):
    return hashlib.sha256(v.encode() if isinstance(v, str) else v).hexdigest()[:4]


def run(cmd, stdin=None, env=None):
    return subprocess.run(cmd, input=stdin, capture_output=True, text=True,
                          env=dict(os.environ, **(env or {})))


def sops_decrypt():
    if not os.path.isfile(SEED):
        die("seed not found: %s" % SEED)
    if not os.path.isfile(AGE_KEY):
        die("age private key not found: %s (set SOPS_AGE_KEY_FILE)" % AGE_KEY)
    r = run(SOPS + ["decrypt", "--output-type", "json", SEED], env={"SOPS_AGE_KEY_FILE": AGE_KEY})
    if r.returncode != 0:
        die("sops decrypt failed (rc=%d): %s" % (r.returncode, r.stderr.strip().splitlines()[-1:]))
    d = json.loads(r.stdout)
    if d.get("version") != SEED_VERSION:
        die("seed version %r, expected %d" % (d.get("version"), SEED_VERSION))
    return d


def sops_encrypt(plain):
    # .sops.yaml next to the seed supplies the age recipient; input arrives on stdin.
    r = run(SOPS + ["encrypt", "--input-type", "json", "--output-type", "yaml",
                    "--filename-override", SEED], stdin=json.dumps(plain, sort_keys=True))
    if r.returncode != 0:
        die("sops encrypt failed (rc=%d): %s" % (r.returncode, r.stderr.strip()))
    return r.stdout


def read_state():
    files, vault = {}, {}
    if not os.path.isdir(STATE):
        die("state dir not found: %s" % STATE)
    for n in sorted(os.listdir(STATE)):
        p = os.path.join(STATE, n)
        if n in NOT_IN_SEED or n.startswith(".") or n.endswith(".tmp") or not os.path.isfile(p):
            continue
        with open(p) as fh:
            files[n] = fh.read()
    bp = os.path.join(STATE, VAULT_BACKUP)
    if os.path.isfile(bp):
        with open(bp) as fh:
            for k, v in json.load(fh).items():
                vault[AF_PREFIX + k] = v
    return {"version": SEED_VERSION, "files": files, "vault": vault}


def write_private(path, content):
    tmp = path + ".tmp"
    with open(os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as fh:
        fh.write(content)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def vault_backup_content(seed):
    af = {k[len(AF_PREFIX):]: v for k, v in seed.get("vault", {}).items() if k.startswith(AF_PREFIX)}
    return json.dumps(af, indent=1, sort_keys=True) if af else None


# ---------------------------------------------------------------- vault access
class Vault:
    def __init__(self, token):
        self.token = token
        r = run(["kubectl", "--context", HUB_CTX, "-n", "vault", "get", "pods", "-l", "app=vault",
                 "--field-selector=status.phase=Running", "-o", "jsonpath={.items[0].metadata.name}"])
        self.pod = r.stdout.strip()
        if r.returncode != 0 or not self.pod:
            die("no running Vault pod on %s" % HUB_CTX)

    def _exec(self, vault_args, payload=""):
        # The token is the first stdin line; `read -r` consumes exactly that line. kubectl exec -i
        # does not pass end-of-input to the container, so the payload is cut with `head -c <bytes>`
        # (the vault command then sees EOF), and commands without payload get /dev/null.
        n = len(payload.encode())
        tail = ('head -c %d | vault "$@"' % n) if n else 'exec vault "$@" </dev/null'
        script = 'read -r VAULT_TOKEN; export VAULT_TOKEN VAULT_ADDR=http://127.0.0.1:8200; ' + tail
        return run(["kubectl", "--context", HUB_CTX, "-n", "vault", "exec", "-i", self.pod, "--",
                    "sh", "-c", script, "sh"] + vault_args, stdin=self.token + "\n" + payload)

    def token_ok(self):
        return self._exec(["token", "lookup", "-format=json"]).returncode == 0

    def get(self, path):
        r = self._exec(["kv", "get", "-format=json", "secret/" + path])
        if r.returncode != 0:
            return None
        return json.loads(r.stdout)["data"]["data"]

    def put(self, path, data):
        return self._exec(["kv", "put", "secret/" + path, "-"], json.dumps(data)).returncode == 0

    def list_all(self, base=""):
        r = self._exec(["kv", "list", "-format=json", "secret/" + base])
        if r.returncode != 0:
            return []
        out = []
        for k in json.loads(r.stdout):
            out += self.list_all(base + k) if k.endswith("/") else [base + k]
        return out


# ---------------------------------------------------------------- k8s access
def kget(ctx, kind, ns=None, name=None):
    cmd = ["kubectl", "--context", ctx, "get", kind] + (["-n", ns, name] if name else ["-A"]) + ["-o", "json"]
    r = run(cmd)
    if r.returncode != 0:
        return None
    return json.loads(r.stdout)


def referenced_vault_props():
    """Every (path, property) the platform reads from Vault, from three sources:
    live ExternalSecrets on the spoke (rendered from git by Argo CD), the operator's
    secret/apps/<appdeployment>/oidc paths, and the seed's own paths (checked separately)."""
    refs = {}
    es = kget(SPOKE_CTX, "externalsecrets.external-secrets.io") or {"items": []}
    for e in es["items"]:
        who = "%s/%s" % (e["metadata"]["namespace"], e["metadata"]["name"])
        for d in e["spec"].get("data", []):
            r = d.get("remoteRef", {})
            if r.get("key"):
                refs.setdefault((r["key"], r.get("property")), set()).add("ExternalSecret " + who)
        for d in e["spec"].get("dataFrom", []):
            k = d.get("extract", {}).get("key")
            if k:
                refs.setdefault((k, None), set()).add("ExternalSecret(dataFrom) " + who)
    ads = kget(SPOKE_CTX, "appdeployments.platform.helmsman.dev") or {"items": []}
    for a in ads["items"]:
        refs.setdefault(("apps/%s/oidc" % a["metadata"]["name"], None), set()).add(
            "operator (AppDeployment %s/%s)" % (a["metadata"]["namespace"], a["metadata"]["name"]))
    return refs


# ---------------------------------------------------------------- commands
def cmd_build(a):
    new = read_state()
    old = None
    if os.path.isfile(SEED) and os.path.isfile(AGE_KEY):
        old = sops_decrypt()
    def flat(s):
        out = {("files", k): v for k, v in s.get("files", {}).items()}
        out.update({("vault", k): json.dumps(v, sort_keys=True) for k, v in s.get("vault", {}).items()})
        return out
    fn, fo = flat(new), flat(old or {})
    for k in sorted(set(fn) | set(fo)):
        state = ("added" if k not in fo else "removed" if k not in fn else
                 "same" if fn[k] == fo[k] else "changed")
        extra = ""
        if k in fn and k[0] == "vault":
            extra = " props=" + ",".join(sorted(new["vault"][k[1]]))
        print("%-8s %-6s %s len=%d%s" % (state, k[0], k[1], len(fn.get(k, fo.get(k, ""))), extra))
    if a.dry_run:
        print("dry run: seed not written")
        return 0
    if old is not None and fn == fo:
        print("no change: seed not rewritten")
        return 0
    enc = sops_encrypt(new)
    with open(SEED + ".tmp", "w") as fh:
        fh.write(enc)
    os.replace(SEED + ".tmp", SEED)
    print("seed written: %s (%d bytes, %d files, %d vault paths)" %
          (SEED, len(enc), len(new["files"]), len(new["vault"])))
    return 0


def cmd_diff(a):
    seed, state = sops_decrypt(), read_state()
    bad = 0
    for sec in ("files", "vault"):
        for k in sorted(set(seed.get(sec, {})) | set(state[sec])):
            s, t = seed.get(sec, {}).get(k), state[sec].get(k)
            if sec == "vault" and s is not None and t is not None:
                s = {p: v for p, v in s.items() if (k, p) not in ENV_DERIVED}
                t = {p: v for p, v in t.items() if (k, p) not in ENV_DERIVED}
            r = ("missing-in-state" if t is None else "missing-in-seed" if s is None else
                 "same" if s == t else "differs")
            bad += r != "same"
            print("%-16s %-5s %s" % (r, sec, k))
    return 1 if bad else 0


def cmd_materialise(a):
    seed = sops_decrypt()
    os.makedirs(STATE, mode=0o700, exist_ok=True)
    want = dict(seed.get("files", {}))
    vb = vault_backup_content(seed)
    if vb is not None:
        want[VAULT_BACKUP] = vb
    for n, v in sorted(want.items()):
        p = os.path.join(STATE, n)
        cur = open(p).read() if os.path.isfile(p) else None
        if n == VAULT_BACKUP and cur is not None:
            same = json.loads(cur) == json.loads(v)
        else:
            same = cur == v
        if cur is not None and same:
            os.chmod(p, 0o600)
            print("same     %s" % n)
        elif cur is None or a.force:
            write_private(p, v)
            print("%-8s %s (mode 600, len=%d)" % ("written" if cur is None else "replaced", n, len(v)))
        else:
            print("differs  %s (kept; use --force to replace with the seed value)" % n)
    return 0


def cmd_apply(a):
    seed = sops_decrypt()
    tok = seed.get("files", {}).get("vault-root-token")
    if not tok:
        die("seed has no files.vault-root-token")
    v = Vault(tok)
    if not v.token_ok():
        die("Vault refused the seed's root token (is Vault running with it?)", 1)
    failed = 0
    for path, want in sorted(seed.get("vault", {}).items()):
        live = v.get(path)
        if live is None:
            data, action = dict(want), "written (was missing)"
        elif a.overwrite:
            data = dict(want)
            for p in want:
                if (path, p) in ENV_DERIVED and p in live:
                    data[p] = live[p]
            data.update({p: x for p, x in live.items() if p not in want})
            action = "overwritten"
        else:
            data = dict(live)
            added = [p for p in want if p not in live]
            data.update({p: want[p] for p in added})
            action = ("filled " + ",".join(added)) if added else None
        if action is None or data == live:
            print("vault    %-28s present, unchanged" % path)
            continue
        ok = v.put(path, data)
        failed += not ok
        print("vault    %-28s %s" % (path, action if ok else "WRITE FAILED"))
    for ctx, ns, name, typ, data in secrets_spec(seed):
        nsr =run(["kubectl", "--context", ctx, "get", "namespace", ns])
        if nsr.returncode != 0:
            run(["kubectl", "--context", ctx, "create", "namespace", ns])
        obj = {"apiVersion": "v1", "kind": "Secret", "type": typ,
               "metadata": {"name": name, "namespace": ns,
                            "labels": {"app.kubernetes.io/managed-by": "helmsman-seed"}},
               "data": {k: base64.b64encode(x.encode()).decode() for k, x in data.items()}}
        r = run(["kubectl", "--context", ctx, "apply", "--server-side", "--force-conflicts",
                 "--field-manager=helmsman-seed", "-f", "-"], stdin=json.dumps(obj))
        failed += r.returncode != 0
        print("secret   %s %s/%s %s" % (ctx, ns, name, "applied" if r.returncode == 0 else
                                         "APPLY FAILED: " + r.stderr.strip().splitlines()[-1]))
    return 1 if failed else 0


def cmd_verify(a):
    seed = sops_decrypt()
    files, svault = seed.get("files", {}), seed.get("vault", {})
    rows, bad = [], 0

    def row(area, name, present, equal, note=""):
        nonlocal bad
        ok = present and equal in (True, None)
        bad += not ok
        rows.append("%-4s %-7s %-55s present=%-3s equals-seed=%-3s %s" % (
            "ok" if ok else "FAIL", area, name, "yes" if present else "no",
            {True: "yes", False: "no", None: "n/a"}[equal], note))

    # state files
    for n, val in sorted(files.items()):
        p = os.path.join(STATE, n)
        present = os.path.isfile(p)
        mode_ok = present and (os.stat(p).st_mode & 0o777) == 0o600
        row("file", n, present, (open(p).read() == val) if present else None,
            "" if mode_ok or not present else "MODE NOT 600")
        bad += present and not mode_ok

    # Vault
    tok = files.get("vault-root-token")
    v = Vault(tok) if tok else None
    tok_ok = bool(v and v.token_ok())
    row("vault", "token from seed authenticates", tok_ok, None)
    if tok_ok:
        refs = referenced_vault_props()
        for path, props in svault.items():
            for p in props:
                refs.setdefault((path, p), set()).add("seed")
        cache = {}
        for (path, prop) in sorted(refs, key=lambda x: (x[0], x[1] or "")):
            if path not in cache:
                cache[path] = v.get(path)
            live = cache[path]
            want = svault.get(path, {}).get(prop) if prop else None
            if prop is None:
                present, equal = live is not None, None
            else:
                present = live is not None and prop in live
                if (path, prop) in ENV_DERIVED or want is None or not present:
                    equal = None
                else:
                    equal = live[prop] == want
            row("vault", "secret/%s%s" % (path, (" ." + prop) if prop else " (path)"), present,
                equal, "used by: " + "; ".join(sorted(refs[(path, prop)])))
        extra = sorted(set(v.list_all()) - {p for p, _ in refs})
        for p in extra:
            rows.append("info vault   secret/%s exists in Vault but nothing above references it" % p)

    # cluster Secrets made from the seed
    for ctx, ns, name, typ, data in secrets_spec(seed):
        s = kget(ctx, "secret", ns, name)
        if s is None:
            row("secret", "%s %s/%s" % (ctx, ns, name), False, None)
            continue
        live = {k: base64.b64decode(x).decode() for k, x in (s.get("data") or {}).items()}
        for k, want in sorted(data.items()):
            row("secret", "%s %s/%s .%s" % (ctx, ns, name, k), k in live,
                (live[k] == want) if k in live else None)
    print("\n".join(rows))
    print("verify: %d checks, %d failed" % (len(rows) - sum(r.startswith("info") for r in rows), bad))
    return 1 if bad else 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build"); b.add_argument("--dry-run", action="store_true")
    sub.add_parser("diff")
    m = sub.add_parser("materialise"); m.add_argument("--force", action="store_true")
    p = sub.add_parser("apply"); p.add_argument("--overwrite", action="store_true")
    sub.add_parser("verify")
    a = ap.parse_args()
    print("seed=%s hub=%s spoke=%s state=%s" % (os.path.relpath(SEED), HUB_CTX, SPOKE_CTX,
                                                  STATE.replace(os.path.expanduser("~"), "~")))
    return {"build": cmd_build, "diff": cmd_diff, "materialise": cmd_materialise,
            "apply": cmd_apply, "verify": cmd_verify}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
