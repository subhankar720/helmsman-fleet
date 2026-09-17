# Loki CrashLoopBackOff + Grafana unreachable on :30030

Date: 2026-09-14 (updated 2026-09-16 – 2026-09-17)
Cluster: `kind-helmsman-hub` / `kind-helmsman-onprem`

## Issue 1: `platform-loki-0` stuck in `CrashLoopBackOff`

**Symptom**

```
kubectl get pods -n monitoring --context kind-helmsman-hub
platform-loki-0   1/2   CrashLoopBackOff   5 (95s ago)   4m56s
```

Logs (`kubectl logs platform-loki-0 -n monitoring -c loki`):

```
mkdir /var/loki: read-only file system
error initialising module: ruler-storage
```

**Root cause**

[`platform/observability/loki-application.yaml`](../../platform/observability/loki-application.yaml)
sets `singleBinary.persistence.enabled: false` to avoid needing a PVC for local
dev. The `grafana/loki` chart (v6.21.0) does **not** fall back to an
`emptyDir` when persistence is disabled — it just omits any volume mount at
`/var/loki` entirely. Loki's containers run with
`securityContext.readOnlyRootFilesystem: true`, so on startup it tried to
`mkdir /var/loki` on the container's read-only root filesystem, which failed
the `ruler-storage` module and crashed the process on every restart.

**Fix**

Added an explicit `emptyDir` volume mounted at `/var/loki` via
`extraVolumes` / `extraVolumeMounts` in the Helm values:

```yaml
singleBinary:
  persistence:
    enabled: false
  extraVolumes:
    - name: storage
      emptyDir: {}
  extraVolumeMounts:
    - name: storage
      mountPath: /var/loki
```

After applying and forcing an Argo CD refresh, `platform-loki-0` went to
`2/2 Running` and `/ready` returns `ready`.

Data in this `emptyDir` does not survive pod rescheduling — fine for local
dev, but if persistent log retention is ever needed, switch to
`singleBinary.persistence.enabled: true` with a `storageClass` instead.

## Issue 2: `curl` commands against Loki/Grafana failing

Two unrelated problems surfaced in the commands that were run:

1. **`kubectl run loki-check --rm ...`** — `--rm` requires an attached,
   foreground run. Used with `--restart=Never` alone it errors out before
   curl ever executes:
   ```
   error: --rm should only be used for attached containers
   ```
   The reported `Loki exit: 1` was this `kubectl run` invocation failing, not
   Loki itself.

2. **`curl http://localhost:30030/api/health`** — two mistakes stacked:
   - Port `30030` is **Grafana's** NodePort (`platform-prometheus-stack-grafana`,
     `80:30030/TCP`), not Loki's. Loki's ClusterIP service is `platform-loki`
     on port `3100` (release-name-prefixed — there's no plain `loki` service).
   - Even for Grafana, `localhost:30030` was never reachable: the kind
     cluster ([`clusters/hub-cluster.yaml`](../../clusters/hub-cluster.yaml))
     only mapped container port `30080` → host `8080`. Port `30030` had no
     `extraPortMappings` entry, so nothing on the host machine could reach it
     — `curl` correctly got connection refused.

**Fix**

- Verified Loki directly with the correct in-cluster DNS name:
  ```bash
  curl -sf http://platform-loki.monitoring.svc.cluster.local:3100/ready
  # -> ready
  ```
- Added a host port mapping for Grafana to
  [`clusters/hub-cluster.yaml`](../../clusters/hub-cluster.yaml) so future
  cluster (re)creations expose it without a port-forward:
  ```yaml
  extraPortMappings:
    - containerPort: 30080
      hostPort: 8080
      protocol: TCP
    - containerPort: 30030
      hostPort: 30030
      protocol: TCP
  ```
- For the **current, already-running** cluster (kind config changes only
  apply at cluster creation), used a temporary port-forward to confirm
  Grafana itself is healthy:
  ```bash
  kubectl port-forward svc/platform-prometheus-stack-grafana -n monitoring \
    --context kind-helmsman-hub 30030:80
  curl -sf http://localhost:30030/api/health
  # -> {"database":"ok","version":"11.3.0",...}
  ```

## Issue 3: cross-cluster Loki check flaky (`loki-spoke-check` intermittently fails)

**Symptom**

From the onprem spoke cluster, hitting the hub's Loki NodePort intermittently
failed:

```bash
kubectl run loki-spoke-check --image=curlimages/curl:latest --restart=Never --rm -it \
  --context kind-helmsman-onprem -- curl -sf "http://${HUB_IP}:30031/ready"
# pod default/loki-spoke-check terminated (Error)
```

but re-running the same command sometimes succeeded.

**Root cause**

[`platform/observability/loki-nodeport.yaml`](../../platform/observability/loki-nodeport.yaml)
exposes Loki cross-cluster via a NodePort service selecting on
`app.kubernetes.io/name: loki` alone. That label is shared by **all** Loki
chart pods, including the two `loki-canary` pods — which only listen on port
`3500` (`http-metrics`), not `3100`. So the service's endpoint list ended up
with 3 addresses on port 3100, only one of which (`platform-loki-0`) actually
had anything listening:

```
kubectl get endpoints loki-nodeport -n monitoring
loki-nodeport   10.244.1.8:3100,10.244.2.13:3100,10.244.2.19:3100
```

`kube-proxy` round-robins across all three, so roughly 2 out of every 3
requests landed on a canary pod with nothing bound to `:3100` and failed
with a connection error — a ~33% success rate, which read as "flaky."

(Separately, `$HUB_IP` in the example was `172.18.0.2`, which is actually
`helmsman-hub-worker`, not the control-plane — but NodePorts are exposed on
every cluster node, so this wasn't itself a problem; it was ruled out by
testing directly against the control-plane IP.)

**Fix**

Narrowed the service selector to match only the actual Loki server pod:

```yaml
selector:
  app.kubernetes.io/name: loki
  app.kubernetes.io/component: single-binary
```

After `kubectl apply`, `loki-nodeport`'s endpoint list dropped to the single
correct address, and 5/5 repeated cross-cluster checks against
`http://${HUB_IP}:30031/ready` succeeded.

## Issue 4: `sample-app` pod not restarting after a ConfigMap change

**Symptom**

Pushed a new `configmap-fluentbit.yaml` template (adding a Loki `[OUTPUT]`
block) and a new `apps/sample-app/values-helmsman-onprem.yaml`, synced Argo
CD, confirmed the ConfigMap content updated — but `sample-app-0` kept its
original `AGE`/`RESTARTS`, never picking up the new config.

**Root cause**

Two stacked issues:

1. Argo CD's cached comparison was pinned to the commit before the push
   (`status.sync.revisions` still showed the old SHA); it hadn't polled git
   yet. A `kubectl annotate application ... argocd.argoproj.io/refresh=hard`
   forced it to see the new commit as `OutOfSync`.
2. Even after a successful sync, Kubernetes has no reason to restart a
   StatefulSet's pods just because a ConfigMap they mount changed — only
   changes to the **pod template** trigger a rollout, and
   [`golden-path-chart/templates/statefulset.yaml`](../../golden-path-chart/templates/statefulset.yaml)
   had no annotation tying the pod template to the ConfigMap's content.

**Fix**

Added the standard Helm "config checksum" annotation so the pod template
hash changes whenever the rendered ConfigMap changes:

```yaml
annotations:
  checksum/fluent-bit-config: {{ include (print $.Template.BasePath "/configmap-fluentbit.yaml") . | sha256sum }}
```

After this, syncing rolled `sample-app-0` immediately and the new Fluent Bit
container logged `configured, hostname=...` for the new output.

## Issue 5: cross-cluster log shipping — pods can't reach another cluster's node IP at all

**Symptom**

Even with the ConfigMap/NetworkPolicy/rollout issues above fixed, Fluent Bit
inside `sample-app-0` (onprem/spoke cluster) still couldn't reach Loki's
NodePort on the hub cluster:

```
[error] [upstream] connection #44 to tcp://172.18.0.2:30031 timed out after 10 seconds
[error] [output:loki:loki.0] no upstream connections available
```

**Root cause**

This is a fundamentally different failure mode than Issues 1–3: **pods on
the spoke cluster cannot reach the hub cluster's node IPs over the shared
`kind` Docker bridge network at all** — only a node's own network namespace
can. Proven by comparing:

```bash
# from the node's own netns (docker exec) — works every time
docker exec helmsman-onprem-worker curl -m5 http://172.18.0.2:30081/   # 200 OK

# from a pod's netns (kubectl exec) — always times out, zero conntrack entries
kubectl exec sample-app-0 -c app -- wget --timeout=5 http://172.18.0.2:30081/
```

Both an "allowed" port (Keycloak, `30081`) and a "blocked" port (Loki,
`30031`) failed identically, and the packets never even created a conntrack
entry on the destination node — ruling out both NetworkPolicy and Loki-
specific causes. Adding an egress `NetworkPolicy` rule for Loki's port
([`golden-path-chart/templates/networkpolicy.yaml`](../../golden-path-chart/templates/networkpolicy.yaml))
was still the right defense-in-depth fix (the default-deny policy had no
allow-list entry for Loki at all), but it did **not** fix the underlying
connectivity gap.

**Fix**

Routing/masquerading between a spoke cluster's pod network and another kind
cluster's node IPs isn't a supported path. Instead of fixing pod-to-node
routing, log shipping was redesigned to run from the **node** network
namespace: a `Promtail` DaemonSet was deployed on the spoke cluster
([`platform/observability/spoke/promtail-application.yaml`](../../platform/observability/spoke/promtail-application.yaml))
with:

```yaml
hostNetwork: true
dnsPolicy: ClusterFirstWithHostNet
```

`hostNetwork: true` puts Promtail's containers directly in the node's
network namespace — the same namespace that `docker exec` proved *can*
reach the hub's Docker bridge IP — instead of the pod network namespace,
which can't. Fluent Bit's direct-to-Loki output in `sample-app` was reverted
back to `stdout` (removed from `configmap-fluentbit.yaml`); Promtail now
tails container log files from the node's filesystem and pushes them to
Loki itself. Verified end-to-end: `curl .../loki/api/v1/label/job/values`
from the hub lists `sample-app/sample-app`, confirming logs are arriving
from the spoke cluster.

## Issue 6: `platform-spoke-promtail`'s Loki URL going stale, and `argocd app sync` failing

**Symptom**

`argocd app sync platform-spoke-promtail` failed with:

```
{"level":"fatal","msg":"Failed to establish connection to localhost:9091: ... connect: connection refused"}
```

and separately, editing `promtail-application.yaml` in git and pushing
didn't change the running DaemonSet's behavior.

**Root cause**

Two unrelated problems:

1. **CLI auth**: the `argocd` CLI's `localhost:9091` context had no active
   port-forward behind it, and its cached login token had expired. The
   `argocd-initial-admin-secret` had already been deleted (both `dev-up-
   gemini.sh` and `dev-up.sh` delete it right after first use, per Argo CD's
   own recommended practice) and the password file dev-up saves it to
   (`/tmp/helmsman-argocd-pass` in `dev-up-gemini.sh`,
   `$HOME/.helmsman-dev/argocd-admin-password` per `helmsman-sanity.sh`'s
   lookup — these two paths don't even agree) wasn't present. Worked around
   it by driving Argo CD via `kubectl annotate
   application ... argocd.argoproj.io/refresh=hard` instead of the CLI,
   which needs no separate auth.
2. **The real gap**: `platform/observability/*.yaml` (including
   `promtail-application.yaml`) are `Application` manifests applied directly
   with `kubectl apply` — there's no app-of-apps watching that path and
   re-applying it from git. So editing the file and pushing never touches
   the live `Application` object; a `kubectl apply -f
   platform/observability/spoke/promtail-application.yaml` was required
   before a refresh/sync would see the change.

**Fix — the IP-freshness problem specifically**

`promtail-application.yaml` hardcodes `${HUB_IP}` (the hub Docker container's
bridge IP, e.g. `172.18.0.2`) into `config.clients[0].url`, and
`${SPOKE_IP}` into `spec.destination.server` — both of which are reassigned
by Docker on every Docker Desktop restart (this is the same class of drift
`dev-up-gemini.sh` already handles for the Argo CD cluster Secret and the
`vault-backend` `ClusterSecretStore`). Since this `Application` is applied
directly rather than synced from git, a stale IP baked into it will not
self-heal — it needs to be re-applied with the current IP on every recovery
run. Addressed by:

- **`scripts/dev-up-gemini.sh`**: added **Stage 7.5: Promtail Loki IP Sync**,
  which re-applies `platform-spoke-promtail` with the freshly-discovered
  `$HUB_IP`/`$SPOKE_IP` (from Stage 2) baked in, then forces a hard refresh —
  mirroring the existing Stage 5 (spoke cluster Secret) / Stage 7
  (`ClusterSecretStore`) pattern. Also fixed **Stage R7** (`--reset` mode):
  it only applied `platform/*/argocd-application.yaml`, a naming convention
  `platform/observability/` doesn't follow at all (`loki-application.yaml`,
  `loki-nodeport.yaml`, `kube-prometheus-stack-application.yaml`, and
  `spoke/promtail-application.yaml` a directory deeper) — so on a full
  `--reset`, the entire observability stack was silently never deployed.
  Now everything under `platform/observability/` is applied explicitly.
- **`scripts/helmsman-sanity.sh`**: added **F.2 Promtail (Spoke) Loki IP
  Drift Check** — read-only checks that `clients.url` and
  `destination.server` on the live `platform-spoke-promtail` Application
  match the current `$HUB_IP`/`$SPOKE_IP`, and that the DaemonSet still has
  `hostNetwork: true` (a `selfHeal` sync or manual edit could silently drop
  it).

## To pick up the new port mapping without a manual port-forward

`scripts/dev-up-gemini.sh --reset` deletes and recreates the hub cluster
straight from `clusters/hub-cluster.yaml`:

```bash
kind delete cluster --name helmsman-hub
kind create cluster --config clusters/hub-cluster.yaml
```

so after a `--reset` run, `http://localhost:30030` will reach Grafana
directly, the same way `http://localhost:8080` already works for Argo CD.
Note `--reset` also tears down and re-bootstraps everything (Argo CD, all
Applications), not just the port mapping — if only the port mapping is
needed, deleting/recreating just the kind cluster and re-running the rest of
`dev-up` manually is faster.
