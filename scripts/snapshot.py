#!/usr/bin/env python3
"""Encrypted snapshots of the state that git and the seed cannot recreate (WO-1.5b Stage 2).

  snapshot.py take   [--only NAME,...]   write ~/.helmsman-dev/snapshots/<UTC-date>/<name>-<HHMMSSZ>.<ext>.age
  snapshot.py check  [DIR]               decrypt each file in memory; print size, sha256/16 and counts
  snapshot.py restore-db FILE            pg_restore an AgentForge DB snapshot into the spoke Postgres

Snapshots (each encrypted to the age PUBLIC key from .sops.yaml; files mode 600, dir mode 700):
  agentforge-db   pg_dump -Fc of the AgentForge database (streamed: kubectl exec | age > file)
  keycloak-realm  the `helmsman` realm: partial export (clients, groups, roles) with the real
                  client secrets put back, plus users with their groups and realm roles
                  (no password hashes: user passwords live in the seed)
  vault-kv        every path under secret/ with its current data and version
  argo-apps       Applications, ApplicationSets and AppProjects as JSON

Plaintext never reaches the disk: data is piped to `age -r <recipient>` or held in memory. The
Vault token and the Keycloak admin password are read from the state dir and sent on stdin or in
an HTTP body, never on a command line. Nothing here prints content.

Settings: CLUSTER_PREFIX / HUB_CTX / SPOKE_CTX, HELMSMAN_STATE_DIR, SOPS_AGE_KEY_FILE (check only).
"""
import argparse
import datetime
import hashlib
import json
import os
import re
import socket
import subprocess
import sys
import time
import urllib.parse
import urllib.request

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PREFIX = os.environ.get("CLUSTER_PREFIX", "helmsman-")
HUB_CTX = os.environ.get("HUB_CTX", "kind-%shub" % PREFIX)
SPOKE_CTX = os.environ.get("SPOKE_CTX", "kind-%sonprem" % PREFIX)
STATE = os.path.expanduser(os.environ.get("HELMSMAN_STATE_DIR", "~/.helmsman-dev"))
SNAPROOT = os.path.join(STATE, "snapshots")
AGE_KEY = os.path.expanduser(os.environ.get("SOPS_AGE_KEY_FILE", os.path.join(STATE, "age.key")))
AF_NS, AF_PG_POD = "agentforge", "agentforge-postgres-0"
REALM = "helmsman"


def die(msg, code=2):
    print("ERROR: " + msg, file=sys.stderr)
    sys.exit(code)


def recipient():
    with open(os.path.join(REPO, ".sops.yaml")) as fh:
        m = re.search(r"\bage:\s*(age1[0-9a-z]+)", fh.read())
    if not m:
        die(".sops.yaml has no age recipient")
    return m.group(1)


def state_file(name):
    p = os.path.join(STATE, name)
    if not os.path.isfile(p):
        die("missing %s (run seed.py materialise)" % p)
    with open(p) as fh:
        return fh.read().strip()


def run(cmd, stdin=None):
    return subprocess.run(cmd, input=stdin, capture_output=True)


def open_private(path):
    return os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "wb")


def encrypt_bytes(data, path):
    with open_private(path) as out:
        r = subprocess.run(["age", "-r", recipient()], input=data, stdout=out, stderr=subprocess.PIPE)
    if r.returncode != 0:
        os.unlink(path)
        die("age failed: %s" % r.stderr.decode().strip())


def h16(b):
    return hashlib.sha256(b).hexdigest()[:16]


# ------------------------------------------------------------------ sources
def snap_db(path):
    """kubectl exec pg_dump -Fc | age -r R > path, streamed; local socket auth inside the pod."""
    dump = subprocess.Popen(["kubectl", "--context", SPOKE_CTX, "-n", AF_NS, "exec", AF_PG_POD, "--",
                             "sh", "-c", 'exec pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc'],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    with open_private(path) as out:
        enc = subprocess.run(["age", "-r", recipient()], stdin=dump.stdout, stdout=out, stderr=subprocess.PIPE)
    dump.stdout.close()
    err = dump.stderr.read().decode().strip()
    if dump.wait() != 0 or enc.returncode != 0:
        os.unlink(path)
        die("pg_dump/age failed: %s %s" % (err, enc.stderr.decode().strip()))


class PortForward:
    def __init__(self, ctx, ns, target, remote):
        s = socket.socket(); s.bind(("127.0.0.1", 0)); self.port = s.getsockname()[1]; s.close()
        self.p = subprocess.Popen(["kubectl", "--context", ctx, "-n", ns, "port-forward", target,
                                   "%d:%d" % (self.port, remote)], stdout=subprocess.DEVNULL,
                                  stderr=subprocess.DEVNULL)
        for _ in range(50):
            try:
                socket.create_connection(("127.0.0.1", self.port), 0.2).close(); return
            except OSError:
                time.sleep(0.2)
        self.close(); die("port-forward to %s/%s did not come up" % (ns, target))

    def close(self):
        self.p.terminate(); self.p.wait()


def http(method, url, token=None, form=None, body=None):
    data, headers = None, {"Accept": "application/json"}
    if form is not None:
        data = urllib.parse.urlencode(form).encode()
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    elif body is not None:
        data = json.dumps(body).encode(); headers["Content-Type"] = "application/json"
    if token:
        headers["Authorization"] = "Bearer " + token
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read() or b"null")


def keycloak_realm():
    pf = PortForward(HUB_CTX, "keycloak", "svc/keycloak", 80)
    try:
        base = "http://127.0.0.1:%d" % pf.port
        tok = http("POST", base + "/realms/master/protocol/openid-connect/token",
                   form={"grant_type": "password", "client_id": "admin-cli", "username": "admin",
                         "password": state_file("keycloak-admin-password")})["access_token"]
        adm = base + "/admin/realms/" + REALM
        realm = http("POST", adm + "/partial-export?exportClients=true&exportGroupsAndRoles=true", tok)
        restored = 0
        for c in realm.get("clients", []):
            if not c.get("publicClient") and c.get("clientAuthenticatorType") == "client-secret" \
                    and not c.get("bearerOnly"):
                s = http("GET", adm + "/clients/%s/client-secret" % c["id"], tok)
                if s and s.get("value"):
                    c["secret"] = s["value"]; restored += 1
        users = http("GET", adm + "/users?briefRepresentation=false&max=10000", tok)
        for u in users:
            u["groups"] = [g["path"] for g in http("GET", adm + "/users/%s/groups" % u["id"], tok)]
            u["realmRoles"] = [r["name"] for r in http("GET", adm + "/users/%s/role-mappings/realm" % u["id"], tok)]
        realm["users"] = users
        realm["_snapshot"] = {"client_secrets_restored": restored, "user_credentials": "not exported (see seed)"}
        return json.dumps(realm, sort_keys=True).encode()
    finally:
        pf.close()


def vault_kv():
    pod = run(["kubectl", "--context", HUB_CTX, "-n", "vault", "get", "pods", "-l", "app=vault",
               "--field-selector=status.phase=Running", "-o", "jsonpath={.items[0].metadata.name}"]).stdout.decode().strip()
    if not pod:
        die("no running Vault pod")
    tok = state_file("vault-root-token")
    script = 'read -r VAULT_TOKEN; export VAULT_TOKEN VAULT_ADDR=http://127.0.0.1:8200; exec vault "$@" </dev/null'
    def v(*args):
        r = run(["kubectl", "--context", HUB_CTX, "-n", "vault", "exec", "-i", pod, "--", "sh", "-c",
                 script, "sh"] + list(args), stdin=(tok + "\n").encode())
        return json.loads(r.stdout) if r.returncode == 0 else None
    out = {}
    def walk(base):
        for k in v("kv", "list", "-format=json", "secret/" + base) or []:
            if k.endswith("/"):
                walk(base + k)
            else:
                d = v("kv", "get", "-format=json", "secret/" + base + k)
                out[base + k] = {"data": d["data"]["data"], "version": d["data"]["metadata"]["version"]}
    walk("")
    if not out:
        die("Vault returned no paths (token refused?)")
    return json.dumps(out, sort_keys=True).encode()


def argo_apps():
    r = run(["kubectl", "--context", HUB_CTX, "-n", "argocd", "get",
             "applications.argoproj.io,applicationsets.argoproj.io,appprojects.argoproj.io", "-o", "json"])
    if r.returncode != 0:
        die("kubectl get applications failed")
    return r.stdout


SOURCES = {  # name -> (extension, producer: path -> None  |  () -> bytes)
    "agentforge-db": ("pgdump", snap_db),
    "keycloak-realm": ("json", keycloak_realm),
    "vault-kv": ("json", vault_kv),
    "argo-apps": ("json", argo_apps),
}


def cmd_take(a):
    now = datetime.datetime.now(datetime.timezone.utc)
    d = os.path.join(SNAPROOT, now.strftime("%Y-%m-%d"))
    os.makedirs(d, mode=0o700, exist_ok=True)
    os.chmod(SNAPROOT, 0o700); os.chmod(d, 0o700)
    names = a.only.split(",") if a.only else list(SOURCES)
    for n in names:
        ext, fn = SOURCES[n]
        path = os.path.join(d, "%s-%s.%s.age" % (n, now.strftime("%H%M%SZ"), ext))
        t0 = time.time()
        if n == "agentforge-db":
            fn(path)
        else:
            encrypt_bytes(fn(), path)
        print("wrote %s  mode=%o  size=%d  (%.1fs)" % (path.replace(os.path.expanduser("~"), "~"),
              os.stat(path).st_mode & 0o777, os.path.getsize(path), time.time() - t0))
    return 0


def pod_stdin(data, shell_cmd):
    """Feed bytes to a command in the AgentForge Postgres pod. The data never touches the pod's
    disk. Two kubectl exec -i traps are handled: `head -c <bytes>` gives the command a clean EOF,
    and `cat >/dev/null` drains whatever the command leaves unread (pg_restore --list stops after
    the table of contents); otherwise kubectl blocks forever sending bytes nobody reads."""
    return run(["kubectl", "--context", SPOKE_CTX, "-n", AF_NS, "exec", "-i", AF_PG_POD, "--", "sh", "-c",
                "head -c %d | { %s; rc=$?; cat >/dev/null; exit $rc; }" % (len(data), shell_cmd)], stdin=data)


def decrypt(path):
    r = run(["age", "-d", "-i", AGE_KEY, path])
    if r.returncode != 0:
        die("age -d failed for %s" % path)
    return r.stdout


def cmd_check(a):
    d = a.dir or max((os.path.join(SNAPROOT, x) for x in os.listdir(SNAPROOT)), key=os.path.getmtime)
    bad = 0
    for f in sorted(os.listdir(d)):
        p = os.path.join(d, f)
        mode = os.stat(p).st_mode & 0o777
        if not f.endswith(".age"):
            print("PLAINTEXT? %s" % f); bad += 1; continue
        head = open(p, "rb").read(22)
        pt = decrypt(p)
        info = ""
        if ".pgdump." in f:
            r = pod_stdin(pt, "pg_restore --list")
            toc = [l for l in r.stdout.decode().splitlines() if l and not l.startswith(";")]
            kinds = {}
            for l in toc:
                m = re.match(r"\d+; \d+ \d+ (TABLE DATA|SEQUENCE SET|[A-Z]+(?: [A-Z]+)*) ", l)
                k = m.group(1) if m else "?"
                kinds[k] = kinds.get(k, 0) + 1
            info = "pg_restore --list rc=%d entries=%d %s" % (r.returncode, len(toc),
                   " ".join("%s=%d" % kv for kv in sorted(kinds.items()) if kv[0] in ("TABLE", "TABLE DATA", "INDEX", "EXTENSION", "SEQUENCE")))
        elif f.startswith("keycloak-realm"):
            j = json.loads(pt)
            info = "realm=%s clients=%d (secrets restored %d) users=%d groups=%d roles=%d" % (
                j.get("realm"), len(j.get("clients", [])), j["_snapshot"]["client_secrets_restored"],
                len(j.get("users", [])), len(j.get("groups", [])), len(j.get("roles", {}).get("realm", [])))
        elif f.startswith("vault-kv"):
            j = json.loads(pt)
            info = "paths=%d properties=%d [%s]" % (len(j), sum(len(x["data"]) for x in j.values()), ", ".join(sorted(j)))
        elif f.startswith("argo-apps"):
            j = json.loads(pt)
            kinds = {}
            for i in j["items"]:
                kinds[i["kind"]] = kinds.get(i["kind"], 0) + 1
            info = " ".join("%s=%d" % kv for kv in sorted(kinds.items()))
        print("%s mode=%o enc=%d age-header=%s plain=%d sha256/16=%s | %s" % (
            f, mode, os.path.getsize(p), head.startswith(b"age-encryption.org/v1"), len(pt), h16(pt), info))
        bad += mode != 0o600
    print("check: %s" % ("OK" if not bad else "%d problems" % bad))
    return 1 if bad else 0


def cmd_restore_db(a):
    pt = decrypt(a.file)
    r = pod_stdin(pt, 'pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --clean --if-exists --no-owner')
    print("pg_restore rc=%d (stderr lines=%d)" % (r.returncode, len(r.stderr.splitlines())))
    return r.returncode


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    t = sub.add_parser("take"); t.add_argument("--only")
    c = sub.add_parser("check"); c.add_argument("dir", nargs="?")
    r = sub.add_parser("restore-db"); r.add_argument("file")
    a = ap.parse_args()
    print("hub=%s spoke=%s snapshots=%s" % (HUB_CTX, SPOKE_CTX, SNAPROOT.replace(os.path.expanduser("~"), "~")))
    return {"take": cmd_take, "check": cmd_check, "restore-db": cmd_restore_db}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
