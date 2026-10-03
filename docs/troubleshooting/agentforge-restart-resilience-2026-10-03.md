# AgentForge platform: surviving a Docker Desktop restart

Date: 2026-10-03
Cluster: `kind-helmsman-hub` / `kind-helmsman-onprem`
Scripts: [`scripts/dev-up-gemini.sh`](../../scripts/dev-up-gemini.sh) (Stage 3, Stage 10.5),
[`scripts/helmsman-sanity.sh`](../../scripts/helmsman-sanity.sh) (section D.1, section K)

The AgentForge onboarding added these:

- Envoy Gateway v1.3.1 on the spoke, GatewayClass `envoy`, `gateway-infra/helmsman-gateway`
- Keycloak client `agentforge-gateway` with a groups mapper, groups `dev-team` /
  `platform-team` / `readonly`, user `subhankar` in `dev-team`
- oauth2-proxy in `gateway-infra`, which validates Keycloak logins, injects `X-Auth-Request-*`
  headers and proxies to AgentForge
- Vault `secret/agentforge/{auth,llm,db,cache,confluence}`
- Kyverno `verify-agentforge-signatures` on the spoke
- `ghcr-pull-secret` and the `helmsman.dev/managed=true` label on the `agentforge` namespace
- Argo CD Application `agentforge` pointing at `apps/agentforge/`

Half of these would not have survived the next Docker restart.

## What a restart breaks, and what now fixes it

| Item | Before | Now |
| --- | --- | --- |
| Vault `secret/agentforge/*` | Lost. Vault runs `server -dev`, so it's in-memory. | Backed up to `~/.helmsman-dev/vault-agentforge.json` on every dev-up run and restored when missing. Live values win, so data the AgentForge team writes is kept. |
| Keycloak client, groups mapper, groups, user | Lost. No PVC, and the realm import only contains `platform-admin`. | Recreated through the admin API. The client secret comes from the Vault backup, so Keycloak, Vault and oauth2-proxy always agree. |
| `auth.keycloak_url` in Vault | Goes stale when the hub IP changes. | Rewritten to `http://<hub-ip>:30081` on every run. |
| oauth2-proxy issuer | Broke after the first dev-up run: `http://$(KEYCLOAK_URL)` became `http://http://…` once Stage 6 rewrote `helmsman-platform-config`. | Manifest uses `$(KEYCLOAK_URL)/realms/helmsman`. dev-up restarts the proxy whenever its Keycloak URL or credentials change. |
| `ghcr-pull-secret` | Survives a restart, lost on `--reset`. The token isn't in git. | Backed up to `~/.helmsman-dev/ghcr-pull-secret.json` and restored. |
| `agentforge` namespace label | Set by hand. | Owned by the Application (`managedNamespaceMetadata`) and re-applied by dev-up. |
| Envoy Gateway, Kyverno policy, oauth2-proxy manifests | In git. | dev-up recreates any missing Application (they're kubectl-applied) and repairs an unprogrammed Gateway. |
| kindnet NetworkPolicy enforcement | Loses its API watch and drops traffic into `sample-app`. Only the hub was ever reset. | Stage 3 restarts kube-proxy, kindnet and CoreDNS on **both** clusters when kindnet logs `Failed to watch`. |

## Issue 1: Vault and Keycloak forget everything written at runtime

**Root cause**

```
kubectl --context kind-helmsman-hub get deploy vault -n vault -o jsonpath='{.spec.template.spec.containers[0].args}'
["server","-dev"]
kubectl --context kind-helmsman-hub get deploy keycloak -n keycloak -o jsonpath='{.spec.template.spec.containers[0].args}'
["start-dev","--import-realm"]          # no PVC
```

**Fix**

dev-up Stage 10.5 keeps the durable copy in `~/.helmsman-dev/`, with mode 600:

| File | Contents |
| --- | --- |
| `vault-agentforge.json` | all five `secret/agentforge/*` paths |
| `ghcr-pull-secret.json` | the `.dockerconfigjson` for `ghcr-pull-secret` |
| `keycloak-agentforge-user-password` | only written if Stage 10.5 ever has to recreate `subhankar` |

**Your password after a restart**

Keycloak can't export your password. If `subhankar` has to be recreated, dev-up uses the
password in `~/.helmsman-dev/keycloak-agentforge-user-password`. If that file doesn't exist,
it generates a new password, saves it there and prints a warning. To keep your current
password, write it to that file once:

```
echo -n '<your password>' > ~/.helmsman-dev/keycloak-agentforge-user-password
chmod 600 ~/.helmsman-dev/keycloak-agentforge-user-password
```

## Issue 2: oauth2-proxy issuer would become `http://http://…`

**Root cause**

`helmsman-platform-config` in `gateway-infra` had been created by hand as
`keycloak-url=172.18.0.6:30081`, with no scheme. dev-up Stage 6 rewrites that secret in every spoke
namespace as `http://<hub-ip>:30081`, so after the next restart the issuer flag
`--oidc-issuer-url=http://$(KEYCLOAK_URL)/realms/helmsman` would have expanded to a URL starting
`http://http://`.

oauth2-proxy also only reads its environment at start-up, so even a correct new hub IP never
reached the running process.

**Fix**

- [`platform/oauth2-proxy-agentforge/oauth2-proxy.yaml`](../../platform/oauth2-proxy-agentforge/oauth2-proxy.yaml):
  `--oidc-issuer-url=$(KEYCLOAK_URL)/realms/helmsman`
- dev-up stores a fingerprint of the Keycloak URL and the oauth2-proxy Secret in the Deployment
  annotation `helmsman.dev/config-fingerprint`. If the fingerprint has changed, or the Deployment
  isn't Available, it restarts the proxy.

## Issue 3: `agentforge-helmsman-onprem` stuck in ComparisonError

**Root cause**

The `helmsman-apps` ApplicationSet turns every `apps/*` folder into a golden-path-chart app.
`apps/agentforge/` has its own Application and no `values-helmsman-onprem.yaml`, so the generated
duplicate could never render.

**Fix**

[`applicationsets/apps-appset.yaml`](../../applicationsets/apps-appset.yaml):

```yaml
directories:
  - path: "apps/*"
  - path: "apps/agentforge"
    exclude: true
```

## Issue 4: `platform-agentforge-oauth2proxy` permanently OutOfSync

**Root cause**

The server fills in defaults on the ExternalSecret (`conversionStrategy`, `decodingStrategy`, …)
and the HTTPRoute (backendRef `kind`/`weight`). Argo CD's client-side diff reports those as drift.
Syncs succeed, but the app never turns Synced.

**Fix**

Add the annotation `argocd.argoproj.io/compare-options: ServerSideDiff=true` on the Application.

## Issue 5: kindnet silently dropping traffic into `sample-app`

**Symptom**

The sanity check failed with `OIDC sidecar /ping endpoint not reachable through sample-app service`,
even though `sample-app-0` was 3/3 Running and its kubelet probes returned 200. Other pods got no
reply, even when they used the pod IP directly:

```
kubectl --context kind-helmsman-onprem logs -n kube-system -l app=kindnet | grep "Failed to watch"
E1003 11:25:44 reflector.go:200] "Failed to watch" err="failed to list *v1.NetworkPolicy: …
  net/http: TLS handshake timeout"
```

The hub's kindnet was in the same state (22 errors in 10 minutes). That fits last week's
`argocd-server` DNS timeouts and the `argocd-repo-server` liveness-probe restarts.

**Fix**

```
kubectl --context <ctx> -n kube-system rollout restart daemonset/kindnet
```

dev-up Stage 3 now checks both clusters and restarts kube-proxy, kindnet and CoreDNS when any of
these is true: the containers were restarted, CoreDNS isn't running, or kindnet has logged
`Failed to watch` in the last 10 minutes. The sanity script reports kindnet watch health in D.1.

### Issue 5, follow-up: restarting kindnet is only temporary

Within minutes of a restart, kindnet on both clusters logged `Failed to watch` again, and traffic
into `sample-app` was dropped again. The connection from the node to the API server is what keeps
failing (`dial tcp 172.18.0.5:6443: i/o timeout`, and `lookup helmsman-hub-control-plane: i/o
timeout` from Docker's DNS). Meanwhile `dmesg` on the nodes shows
`WSL … Relay ERROR: UtilAcceptVsock: Waiting for abnormally long accept`. So the base flakiness is
the Docker Desktop / WSL network, which none of these scripts can fix.

kindnet makes it much worse because it enforces NetworkPolicy itself. It sends new pod connections
through an nfqueue (`queue 101`) and decides from its own cache of pods and policies. When the
watch drops, that cache goes stale and connections are dropped or held:

```
docker exec helmsman-hub-worker2 cat /proc/net/netfilter/nfnetlink_queue
  101 … 222 …          # 222 packets waiting for a verdict
```

The hub runs the 7 NetworkPolicies from Argo CD's upstream install, and `hub-worker2` hosts
`argocd-redis`, `argocd-dex-server`, Keycloak, Vault and CoreDNS. This is the most likely cause of
the earlier `argocd-server` DNS timeouts and the 111 `argocd-repo-server` liveness-probe restarts.

## Issue 6: sanity probes blocked by Kyverno

**Root cause**

Since Kyverno moved to the spoke, its Enforce policies apply to every namespace labelled
`helmsman.dev/managed=true`. That rejected the sanity script's bare `kubectl run` probe pods in
`sample-app`. The Vault reachability check reported a failure even though Vault answered 200.

**Fix**

The sanity script's `probe_overrides` helper gives the probe pods the labels and security
settings the policies require: `app.kubernetes.io/managed-by=helmsman`, `runAsNonRoot`, limits,
and `allowPrivilegeEscalation: false`.

## Verification

Run on 2026-10-03.

**Simulated restart data loss.** I deleted Vault `auth` + `llm`, the Keycloak `agentforge-gateway`
client and `readonly` group, the namespace label and `ghcr-pull-secret`, then ran Stage 10.5:

```
[OK]    ghcr-pull-secret was missing — restored from ~/.helmsman-dev/ghcr-pull-secret.json
[OK]    secret/agentforge/auth was missing — restored from backup
[OK]    secret/agentforge/llm was missing — restored from backup
[OK]    Keycloak group readonly was missing — created
[OK]    Keycloak client agentforge-gateway was missing — created with the Vault client secret
[OK]    Gateway routes agentforge.helmsman.local → oauth2-proxy (/ping 200)
[OK]    oauth2-proxy redirects to Keycloak at http://172.18.0.6:30081/realms/helmsman
```

**The rebuilt client issues tokens.** I recreated a throwaway user through the same code path
(then deleted it) and logged in with the restored client secret:
`iss=http://172.18.0.6:30081/realms/helmsman azp=agentforge-gateway groups=['dev-team']`.
The first attempt failed with "Account is not fully set up" because Keycloak 26 requires first and
last name. User creation now sets both and marks the email verified.

**Full `./dev-up-gemini.sh` recovery run.** It finished with `BOOTSTRAP COMPLETED SUCCESSFULLY`. All 14
Argo CD apps were Synced/Healthy, and the `agentforge-helmsman-onprem` duplicate was gone.

**`helmsman-sanity.sh` section K.** 33 of 33 checks passed.

## Open items

- **kindnet NetworkPolicy enforcement on a flaky Docker network** (Issue 5 follow-up). This needs a
  decision: disable kindnet's policy enforcement in these kind clusters, or keep it and live with
  intermittent drops between dev-up runs.

- **Hub Kyverno is orphaned.** Commit `02f647f` moved Kyverno to the spoke, but the hub still runs
  the Kyverno controllers and 6 ClusterPolicies, which no Application manages any more.
- **Vault and Keycloak persistence.** Giving Vault file storage and Keycloak a PVC (or a Postgres
  database) would remove the need for the backups. Until then, the `~/.helmsman-dev/` backups are
  the source of truth for runtime state.
