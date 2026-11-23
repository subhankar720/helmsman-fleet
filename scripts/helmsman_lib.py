"""Shared helpers for seed.py and snapshot.py (WO-1.5b). Standard library only.

Credentials never go on a command line: Vault and Keycloak are reached through
`kubectl port-forward` on 127.0.0.1 and spoken to over HTTP, with tokens in request headers
and passwords in request bodies.
"""
import json
import os
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

PREFIX = os.environ.get("CLUSTER_PREFIX", "helmsman-")
HUB_CTX = os.environ.get("HUB_CTX", "kind-%shub" % PREFIX)
SPOKE_CTX = os.environ.get("SPOKE_CTX", "kind-%sonprem" % PREFIX)
STATE = os.path.expanduser(os.environ.get("HELMSMAN_STATE_DIR", "~/.helmsman-dev"))


def die(msg, code=2):
    print("ERROR: " + msg, file=sys.stderr)
    sys.exit(code)


class PortForward:
    """kubectl port-forward to a free local port; use as a context manager."""

    def __init__(self, ctx, ns, target, remote):
        s = socket.socket()
        s.bind(("127.0.0.1", 0))
        self.port = s.getsockname()[1]
        s.close()
        self.p = subprocess.Popen(["kubectl", "--context", ctx, "-n", ns, "port-forward", target,
                                   "%d:%d" % (self.port, remote)],
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(75):
            try:
                socket.create_connection(("127.0.0.1", self.port), 0.2).close()
                return
            except OSError:
                if self.p.poll() is not None:
                    break
                time.sleep(0.2)
        self.close()
        die("port-forward to %s %s/%s did not come up" % (ctx, ns, target))

    @property
    def base(self):
        return "http://127.0.0.1:%d" % self.port

    def close(self):
        if self.p.poll() is None:
            self.p.terminate()
            self.p.wait()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()


def http(method, url, headers=None, form=None, body=None, timeout=60):
    """Returns (status, parsed JSON or None). HTTP errors are returned, not raised."""
    data, h = None, {"Accept": "application/json"}
    h.update(headers or {})
    if form is not None:
        data = urllib.parse.urlencode(form).encode()
        h["Content-Type"] = "application/x-www-form-urlencoded"
    elif body is not None:
        data = json.dumps(body).encode()
        h["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=h, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, json.loads(raw) if raw else None
        except ValueError:
            return e.code, None


class Vault:
    """KV v2 at secret/ over the HTTP API through a port-forward to the hub Vault service."""

    def __init__(self, token, ctx=None):
        self.token = token
        self.pf = PortForward(ctx or HUB_CTX, "vault", "svc/vault", 8200)

    def close(self):
        self.pf.close()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()

    def _req(self, method, path, body=None):
        return http(method, self.pf.base + "/v1/" + path, headers={"X-Vault-Token": self.token}, body=body)

    def token_ok(self):
        return self._req("GET", "auth/token/lookup-self")[0] == 200

    def get(self, path):
        """Current data of secret/<path>, or None if absent."""
        s, j = self._req("GET", "secret/data/" + path)
        return j["data"]["data"] if s == 200 and j and j.get("data") else None

    def get_full(self, path):
        s, j = self._req("GET", "secret/data/" + path)
        return j["data"] if s == 200 and j and j.get("data") else None

    def put(self, path, data):
        return self._req("POST", "secret/data/" + path, {"data": data})[0] in (200, 204)

    def list_all(self, base=""):
        s, j = self._req("LIST", "secret/metadata/" + base)
        if s != 200 or not j:
            return []
        out = []
        for k in j["data"]["keys"]:
            out += self.list_all(base + k) if k.endswith("/") else [base + k]
        return out
