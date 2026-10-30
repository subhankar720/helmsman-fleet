# dev-up-gemini.sh and helmsman-sanity.sh

Two scripts keep the local kind platform (`kind-helmsman-hub` + `kind-helmsman-onprem`) working
across Docker Desktop and laptop restarts:

| Script | Role |
| --- | --- |
| `dev-up-gemini.sh` | **Fixes.** Recovery by default; `--reset` rebuilds both clusters. |
| `helmsman-sanity.sh` | **Reports only.** Never restarts, patches or syncs anything. Every failure names the dev-up stage that fixes it. |

Run sanity at the start of a session or after any restart. If it reports failures, run dev-up,
then sanity again.

dev-up logs the `argocd` CLI in on its own port-forward (`:9090`), which closes when the script
exits. To use the CLI afterwards, see
[Running argocd by hand](troubleshooting/agentforge-chart-deploy-2026-10-24.md#running-argocd-by-hand).

## Where the scripts live

`dev-up-gemini.sh` exists in two places, and the copies must stay identical:

- `helmsman-fleet/scripts/dev-up-gemini.sh`
- `helmsman-operator/dev-up-gemini.sh`

Each copy finds both repos on its own (`FLEET_DIR`, `OPERATOR_DIR`, both overridable), so it works
when run from either repo or from any other directory. On 2026-10-03 the two had drifted. The fleet
copy was newer, but the operator copy had fixes the fleet copy lacked, so they were merged into one
script rather than one replacing the other.

`helmsman-sanity.sh` lives only in `helmsman-fleet/scripts/`.

## State kept outside the clusters (`~/.helmsman-dev/`, mode 600)

Vault runs `server -dev` (in-memory) and Keycloak has no PVC, so anything written to them at
runtime is lost on restart. dev-up backs it up here on every run and restores it when missing.

| File | Contents | Written by |
| --- | --- | --- |
| `argocd-admin-password` | Argo CD admin password (was `/tmp/helmsman-argocd-pass`, lost on reboot; migrated automatically) | `--reset`, or by hand |
| `vault-agentforge.json` | `secret/agentforge/{auth,llm,db,cache,confluence}`. Live Vault wins; the backup only fills gaps. | Stage 10.5 |
| `ghcr-pull-secret.json` | `.dockerconfigjson` for `ghcr-pull-secret`. Must be a classic PAT (`ghp_`) or a `gh` OAuth token (`gho_`) with `read:packages`; GHCR rejects fine-grained PATs. Currently a `gho_` token, which `gh auth logout` or `gh auth refresh` replaces. | Stage 10.5, from the Secret in `agentforge` |
| `keycloak-agentforge-user-password` | Password used if Keycloak user `subhankar` has to be recreated. Generated if missing. | you, or Stage 10.5 |
| `last-dev-up` | Time of the last successful run. A node started after it counts as restarted. | Stage 11 |

## dev-up stages

### `--reset` only

| Stage | What it does |
| --- | --- |
| R1–R2 | Delete and recreate both kind clusters from `clusters/*.yaml` |
| R3 | Install Argo CD (server-side apply), repo-server timeout, NodePort 30080, save the admin password |
| R3.5, R6.5 | Pre-seed Keycloak admin credentials (hub) and the Vault token for ESO (spoke) |
| R4–R6 | Port-forward and login, register the fleet repo and the spoke cluster |
| R7 | Apply every kubectl-managed Application: `platform/*/argocd-application.yaml`, Kyverno policies, `platform/envoy-gateway/spoke-application.yaml`, `apps/*/argocd-application.yaml`, observability, ApplicationSet |

### Every run

| Stage | What it does | Why |
| --- | --- | --- |
| 1 | Start stopped nodes. Reconnect a node that lost its `kind` network endpoint. Stop with the owner's name if another container holds a node's host port. Count nodes that Docker started after the last successful run as restarted. | [hub-control-plane-reboot](troubleshooting/hub-control-plane-reboot-2026-10-24.md) |
| 2 | Discover hub and spoke IPs; check both API servers | |
| 3 | Set kindnet limits to 1 CPU / 256Mi on both clusters. Restart kube-proxy, kindnet and CoreDNS on each cluster after a restart, when CoreDNS is down, or when kindnet logs `Failed to watch`. | [kindnet CPU starvation](troubleshooting/agentforge-restart-resilience-2026-10-03.md#issue-5-root-cause-kindnet-cpu-starved-by-kinds-default-100m-limit) |
| 4 | Restart argocd-redis, argocd-server and the applicationset-controller after a restart | |
| 4.5 | Build `helmsman-operator:dev`, load it into the spoke, apply manifests, `imagePullPolicy: Never`, restart and wait | Runs after Stage 3, so the spoke network is up |
| 5 | Re-point the Argo CD spoke cluster Secret and any stale Applications when the spoke IP drifts | |
| 6 | Rewrite `helmsman-platform-config` (8 keys, `keycloak-url=http://<hub-ip>:30081`) in every spoke namespace; ensure `vault-token` | oauth2-proxy and sample-app read this |
| 7 | Wait for the ESO CRDs, then point ClusterSecretStore `vault-backend` at the hub IP | On `--reset` the CRDs arrive late |
| 7.5 | Re-apply `platform-spoke-promtail` with the current IPs | [Loki/Grafana](troubleshooting/loki-and-grafana-access-2026-09-14.md) |
| 8 | Label **app** namespaces `helmsman.dev/managed=true`; **remove** the label from platform namespaces (`PLATFORM_NAMESPACES_RE`) | Kyverno app policies blocked operator and Promtail pods |
| 9 | Argo CD CLI login, showing the actual error and the reset commands on failure | |
| 10 | Sync platform apps, wait for Keycloak, re-apply the ClusterSecretStore if needed, clean stale PreSync hooks, sync sample-app, restart sample-app on a stale OIDC issuer | |
| 10.5 | AgentForge state, see below | [restart resilience](troubleshooting/agentforge-restart-resilience-2026-10-03.md), [chart deploy](troubleshooting/agentforge-chart-deploy-2026-10-24.md) |
| 11 | Health summary; prints `BOOTSTRAP COMPLETED SUCCESSFULLY` or `SANITY CHECK COMPLETED WITH WARNINGS`; records `last-dev-up` on success | |

### Stage 10.5 in detail

Results print line by line as each check runs (the stage streams its output, so it doesn't sit
silent for minutes).

1. Re-create any missing kubectl-managed Application from fleet `main`: Envoy Gateway, gateway-infra,
   oauth2-proxy, Kyverno policies, agentforge. Existing ones are left alone.
2. `agentforge` namespace label. `ghcr-pull-secret` backed up, or restored if missing, and copied
   into `kyverno` for image signature checks.
3. Vault `secret/agentforge/*`: restore missing paths from backup; keep `auth.keycloak_url` on the
   current hub IP; add any keys the AgentForge chart reads that are missing (`db`/`cache` generated,
   `llm`/`confluence` empty); write the backup.
4. Keycloak (via port-forward on 18081): groups `dev-team`, `platform-team`, `readonly`; client
   `agentforge-gateway` with the groups mapper and the **Vault** client secret; user `subhankar`
   (first/last name and verified email, otherwise logins fail with "Account is not fully set up")
   in `dev-team`.
5. Force-sync oauth2-proxy's ExternalSecret. Restart oauth2-proxy when the fingerprint of its
   Keycloak URL and credentials (annotation `helmsman.dev/config-fingerprint`) changes.
6. Kyverno `verify-agentforge-signatures` Ready, otherwise hard-refresh the policies app.
   `helmsman-gateway` Programmed, otherwise refresh the apps and restart Envoy Gateway.
7. End to end, retried 3 times: `agentforge.helmsman.local/ping` → 200, `/oauth2/start` → 302 to
   the current Keycloak.
8. AgentForge workloads: force-sync `agentforge-secrets`; report each Postgres, Redis, Flower,
   gateway and worker, with Kyverno's reason when a Deployment is rejected.

## Sanity sections

| Section | Checks |
| --- | --- |
| A, B | Docker reachable; nodes running, recently restarted, lost `kind` endpoint, host port taken by another container |
| C | Hub node IPs in etcd match Docker |
| D, D.1 | ClusterIP/DNS from Argo CD pods; spoke ClusterIP; kindnet CPU limit and API-watch health on both clusters |
| E | Argo CD components |
| F, F.1, F.2 | Spoke IP drift; `helmsman-platform-config`, sample-app OIDC/ExternalSecret, Keycloak and Vault reachable from the spoke; Promtail IPs and hostNetwork |
| G, H | Argo CD login; cluster and every Application's sync/health |
| I | Every spoke pod |
| J | Loki, Grafana datasource, live log shipping |
| K | Applications exist; Envoy Gateway, GatewayClass, Gateway (NodePort); ReferenceGrant and `agentforge/agentforge` HTTPRoute; `gateway-infra` Keycloak URL; GHCR token can read the deployed image; oauth2-proxy Secret, availability and config fingerprint; e2e gateway → oauth2-proxy → Keycloak; Vault paths and keys; Keycloak client, mapper, secret identical in Keycloak/Vault/K8s, groups, user; Kyverno policy; platform namespaces unlabelled; workloads blocked by Kyverno (only if still short of pods); `agentforge` namespace label and pull secrets (`agentforge`, `kyverno`); `agentforge-secrets` and workloads; backups present |

Probe pods in `helmsman.dev/managed` namespaces are created with `probe_overrides` (managed-by label,
non-root, limits, no privilege escalation), so Kyverno doesn't reject the checks themselves.

## Incident history

| Date | Write-up | Main fixes |
| --- | --- | --- |
| 2026-09-14 | [loki-and-grafana-access](troubleshooting/loki-and-grafana-access-2026-09-14.md) | Loki `emptyDir`, Promtail IP sync (Stage 7.5) |
| 2026-09-26 | [envoy-gateway-rollout](troubleshooting/envoy-gateway-rollout-2026-09-26.md) | OCI Helm `repoURL`, Envoy Gateway on spoke, exclude glob, NodePort `EnvoyProxy` |
| 2026-10-03 | [agentforge-restart-resilience](troubleshooting/agentforge-restart-resilience-2026-10-03.md) | Vault/Keycloak backup and restore, oauth2-proxy issuer, ApplicationSet exclude, ServerSideDiff, kindnet CPU, Kyverno-safe probes |
| 2026-10-24 | [hub-control-plane-reboot](troubleshooting/hub-control-plane-reboot-2026-10-24.md) | lost `kind` endpoint, host port 8080 conflict, Kyverno on platform namespaces, restart detection |
| 2026-10-30 | [laptop-reboot-and-e2e](troubleshooting/laptop-reboot-and-e2e-2026-10-30.md) | clean reboot recovery; Loki check retries; AgentForge e2e blocked by Groq 8k TPM limit |
| 2026-10-24/25 | [agentforge-chart-deploy](troubleshooting/agentforge-chart-deploy-2026-10-24.md) | Helm source, issuer regression, Kyverno GHCR credentials, chart Vault keys, `gh` OAuth pull token, Celery `--app` flag and broker URLs |

## Open items

- **AgentForge application issues** (team-owned): multi-agent pipelines fail on Groq's 8,000
  tokens-per-minute limit (the router needs to back off on 429), and the chart's `HITL_AUTO_APPROVE`
  is ignored (the app reads `AGENTFORGE_HITL_AUTO_APPROVE`). The `audit_runs` table is fixed by Phase 7. See
  [agentforge-chart-deploy](troubleshooting/agentforge-chart-deploy-2026-10-24.md#open-for-the-agentforge-team).
- **Hub Kyverno is orphaned.** The controllers and 6 ClusterPolicies still run on the hub with no
  Application managing them.
- **Vault and Keycloak have no persistence.** The `~/.helmsman-dev/` backups are the source of truth
  until Vault gets storage and Keycloak gets a PVC or Postgres.
- **`helmsman-operator/dev-up-gemini.sh` isn't committed.** It matches the fleet copy, but that repo
  has unrelated uncommitted changes.
