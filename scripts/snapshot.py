#!/usr/bin/env python3
"""Encrypted snapshots of the state that git and the seed cannot recreate (WO-1.5b Stage 2).

  snapshot.py take   [--only NAME,...]   write ~/.helmsman-dev/snapshots/<UTC-date>/<name>-<HHMMSSZ>.<ext>.age
  snapshot.py check  [DIR]               decrypt each file in memory; print size, sha256/16 and counts
  snapshot.py restore-db FILE            pg_restore an AgentForge DB snapshot into the spoke Postgres
  snapshot.py restore-vault FILE [--overwrite]
                                         write every path of a vault-kv snapshot back into Vault
                                         (default: only paths that are missing; token from the state dir)

Snapshots (each encrypted to the age PUBLIC key from .sops.yaml; files mode 600, dir mode 700):
  agentforge-db   pg_dump -Fc of the AgentForge database (streamed: kubectl exec | age > file)
  keycloak-realm  the `helmsman` realm: partial export (clients, groups, roles) with the real
                  client secrets put back, plus users with their groups and realm roles
                  (no password hashes: user passwords live in the seed)
  vault-kv        every path under secret/ with its current data and version
  argo-apps       Applications, ApplicationSets and AppProjects as JSON

Plaintext never reaches the disk: data is piped to `age -r <recipient>` or held in memory. The
Vault token and the Keycloak admin password are read from the state dir and sent over HTTP
through a port-forward (header or form body), never on a command line. Nothing prints content.

Settings: CLUSTER_PREFIX / HUB_CTX / SPOKE_CTX, HELMSMAN_STATE_DIR, SOPS_AGE_KEY_FILE (check only).
"""
import argparse
import datetime
import hashlib
import json
import os
import re
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from helmsman_lib import HUB_CTX, SPOKE_CTX, STATE, PortForward, Vault, die, http  # noqa: E402

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SNAPROOT = os.path.join(STATE, "snapshots")
AGE_KEY = os.path.expanduser(os.environ.get("SOPS_AGE_KEY_FILE", os.path.join(STATE, "age.key")))
AF_NS, AF_PG_POD = "agentforge", "agentforge-postgres-0"
REALM = "helmsman"


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


def keycloak_realm():
    with PortForward(HUB_CTX, "keycloak", "svc/keycloak", 80) as pf:
        def get(url, method="GET"):
            st, j = http(method, url, headers={"Authorization": "Bearer " + tok})
            if st != 200:
                die("Keycloak %s %s -> HTTP %d" % (method, url.split("/admin/")[-1], st))
            return j
        st, j = http("POST", pf.base + "/realms/master/protocol/openid-connect/token",
                     form={"grant_type": "password", "client_id": "admin-cli", "username": "admin",
                           "password": state_file("keycloak-admin-password")})
        if st != 200:
            die("Keycloak admin login -> HTTP %d" % st)
        tok = j["access_token"]
        adm = pf.base + "/admin/realms/" + REALM
        realm = get(adm + "/partial-export?exportClients=true&exportGroupsAndRoles=true", "POST")
        restored = 0
        for c in realm.get("clients", []):
            if not c.get("publicClient") and c.get("clientAuthenticatorType") == "client-secret" \
                    and not c.get("bearerOnly"):
                sec = get(adm + "/clients/%s/client-secret" % c["id"])
                if sec and sec.get("value"):
                    c["secret"] = sec["value"]
                    restored += 1
        users = get(adm + "/users?briefRepresentation=false&max=10000")
        for u in users:
            u["groups"] = [g["path"] for g in get(adm + "/users/%s/groups" % u["id"])]
            u["realmRoles"] = [r["name"] for r in get(adm + "/users/%s/role-mappings/realm" % u["id"])]
        realm["users"] = users
        realm["_snapshot"] = {"client_secrets_restored": restored, "user_credentials": "not exported (see seed)"}
        return json.dumps(realm, sort_keys=True).encode()


def vault_kv():
    with Vault(state_file("vault-root-token")) as v:
        if not v.token_ok():
            die("Vault refused the root token from the state dir")
        out = {}
        for p in v.list_all():
            d = v.get_full(p)
            out[p] = {"data": d["data"], "version": d["metadata"]["version"]}
    if not out:
        die("Vault returned no paths")
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


def cmd_restore_vault(a):
    snap = json.loads(decrypt(a.file))
    with Vault(state_file("vault-root-token")) as v:
        if not v.token_ok():
            die("Vault refused the root token from the state dir")
        bad = 0
        for path in sorted(snap):
            live = v.get(path)
            if live is not None and not a.overwrite:
                print("kept     secret/%s (present; --overwrite replaces it)" % path)
                continue
            ok = v.put(path, snap[path]["data"])
            bad += not ok
            print("%-8s secret/%s (%d properties)" % ("written" if ok else "FAILED", path, len(snap[path]["data"])))
    return 1 if bad else 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    t = sub.add_parser("take"); t.add_argument("--only")
    c = sub.add_parser("check"); c.add_argument("dir", nargs="?")
    r = sub.add_parser("restore-db"); r.add_argument("file")
    rv = sub.add_parser("restore-vault"); rv.add_argument("file"); rv.add_argument("--overwrite", action="store_true")
    a = ap.parse_args()
    print("hub=%s spoke=%s snapshots=%s" % (HUB_CTX, SPOKE_CTX, SNAPROOT.replace(os.path.expanduser("~"), "~")))
    return {"take": cmd_take, "check": cmd_check, "restore-db": cmd_restore_db,
            "restore-vault": cmd_restore_vault}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
