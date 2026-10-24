# Hub control-plane won't start after a laptop reboot

Date: 2026-10-24
Cluster: `kind-helmsman-hub` / `kind-helmsman-onprem`
Scripts: [`scripts/dev-up-gemini.sh`](../../scripts/dev-up-gemini.sh) (Stage 1, Stage 8),
[`scripts/helmsman-sanity.sh`](../../scripts/helmsman-sanity.sh) (section B, section K)

**Symptom**

```
── Stage 1: Kind Container Health ──
[WARN]  helmsman-hub-control-plane is stopped — starting...
...
── Stage 2: IP Discovery ──
[ERROR] Hub API server not responding
```

Two Docker Desktop problems kept the hub control-plane down. Once it was up, a third problem
(an old dev-up bug, harmless until Kyverno moved to the spoke) was blocking platform pods.

## Issue 1: the container lost its endpoint on the `kind` network

**Root cause**

After the reboot the other four kind nodes started first and took the low IPs. The hub
control-plane's old address, `172.18.0.4`, now belongs to `helmsman-onprem-worker`. Docker Desktop
also dropped the container's endpoint on the network: `HostConfig.NetworkMode` was still `kind`, but
`NetworkSettings.Networks` was `{}`. kind's entrypoint then refuses to boot:

```
docker logs helmsman-hub-control-plane
INFO: detected IPv4 address:
INFO: detected old IPv4 address: 172.18.0.4
ERROR: have an old IPv4 address but no current IPv4 address (!)
```

**Fix**

```
docker network connect kind helmsman-hub-control-plane
docker start helmsman-hub-control-plane
```

The node came up with `172.18.0.6`, and kind's entrypoint rewrote the old IP in the API server
and etcd configs. A failed `docker start` rolls the `network connect` back, so reconnect right
before every start attempt.

## Issue 2: host port 8080 taken by another project

**Root cause**

The hub control-plane publishes `0.0.0.0:8080 → 30080` (Argo CD NodePort). The
`proposal-automation` Compose project's frontend also publishes `8080`, and its restart policy is
`unless-stopped`, so after a reboot whichever container starts first wins:

```
Error response from daemon: … Bind for 0.0.0.0:8080 failed: port is already allocated
```

**Fix**

`FRONTEND_PORT=8088` added to
`C:\Users\sonal\Downloads\proposal-automation-production\proposal-automation\.env` (its compose
file already maps `${FRONTEND_PORT:-8080}:80`). Only the frontend container was recreated, and
proposal-automation is now at `http://localhost:8088`. Moving the hub's port instead would mean
recreating the cluster.

## Issue 3: Kyverno blocking platform pods

**Symptom**

dev-up Stage 4.5 reported `Operator rollout not complete`. The new ReplicaSet never got a pod:

```
FailedCreate  admission webhook "validate.kyverno.svc-fail" denied the request:
  require-helmsman-labels: Pods must have label app.kubernetes.io/managed-by: helmsman
```

The Promtail DaemonSet in `monitoring` had been blocked the same way.

**Root cause**

dev-up Stage 8 labelled *every* non-system spoke namespace `helmsman.dev/managed=true`, platform
ones included (`helmsman-operator-system`, `envoy-gateway-system`, `gateway-infra`, `monitoring`).
That label opts a namespace into the Kyverno application policies (managed-by label, non-root,
limits, signed images). It did nothing while Kyverno ran on the hub. Since `02f647f` moved Kyverno
to the spoke, it rejects any recreated platform pod that doesn't meet those app rules. Promtail
runs as root on hostNetwork, and the operator and Envoy Gateway pods don't carry the app label.

**Fix**

- Stage 8 skips `PLATFORM_NAMESPACES_RE` and **removes** the label from those namespaces. App
  namespaces (`sample-app`, `agentforge`, and any new ones the operator creates) are still labelled.
- After the label was removed, the operator needed `kubectl rollout restart`, because its
  ReplicaSet had backed off and gone past its progress deadline. Promtail recovered on its own.
- The sanity script fails if a platform namespace carries the label, or if a ReplicaSet/DaemonSet/
  StatefulSet is still short of pods because of a Kyverno denial.

## Also fixed: dev-up skipped recovery after a real reboot

Docker Desktop restarts kind nodes itself (restart policy), so on a normal reboot all five are
already running by the time dev-up runs. Stage 1 then decided nothing had restarted and skipped
the Stage 3 network recovery and the Stage 4 Argo CD restarts.

dev-up now records `~/.helmsman-dev/last-dev-up` after a successful run. Any node started after
that timestamp counts as restarted. Stage 1 also stops with a clear error, naming the container
holding the port, instead of failing a stage later with "Hub API server not responding".

## Verification

- `./dev-up-gemini.sh` after the reboot: `BOOTSTRAP COMPLETED SUCCESSFULLY`. Stage 10.5 restored all
  five `secret/agentforge/*` paths from backup, recreated the Keycloak client, groups and user,
  restarted oauth2-proxy onto the new hub IP (`172.18.0.2`), and the gateway → oauth2-proxy →
  Keycloak check passed. This was the first real-restart test of the AgentForge recovery.
- Operator rolled out (`helmsman-operator-controller-manager-77c575c78-*` Ready). Promtail is 2/2,
  and Loki `/ready` returns 200.
- Keycloak user `subhankar` had to be recreated. No password file existed, so dev-up generated one
  and saved it in `~/.helmsman-dev/keycloak-agentforge-user-password`.
