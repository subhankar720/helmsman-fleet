# 25b: AgentForge Helm chart (as deployed)

Last updated: 2026-11-18 (renamed from `25-agentforge-chart.md`; the architect side has its own document 25)
Chart: `apps/agentforge/` (`Chart.yaml` name `agentforge`, version `0.1.0`, appVersion `0.5.0`)
Argo CD Application: `agentforge` (`apps/agentforge/argocd-application.yaml`, kubectl-applied), Helm source
with `values-helmsman-onprem.yaml`, `ServerSideDiff=true`, auto-sync with prune and self-heal
Destination: spoke `helmsman-onprem`, namespace `agentforge` (labelled `helmsman.dev/managed=true`, so the
Kyverno app policies apply)
Image: `ghcr.io/subhankar720/agentforge:ff226856c372bec922a5491c97cfa60f644d01f3`, bumped by `agentforge-bot`
and cosign-verified by Kyverno `verify-agentforge-signatures`

## Resources

`helm template agentforge apps/agentforge -n agentforge -f apps/agentforge/values-helmsman-onprem.yaml`
renders 22 objects:

| Kind | Name | Purpose |
| --- | --- | --- |
| Deployment | `agentforge-gateway` | FastAPI gateway, port 8000. Readiness probe `/health` (doesn't trigger LLM calls). Pod template carries `checksum/config`, so a ConfigMap change rolls it. |
| Deployment | `agentforge-worker` | Celery worker, `celery --app=gateway.orchestrator.celery_app worker --queues=sdlc,default --concurrency=2`. Also carries `checksum/config`. |
| Deployment | `agentforge-flower` | Celery UI (`mher/flower:2.0`), port 5555 |
| StatefulSet | `agentforge-postgres` | `pgvector/pgvector:pg16`, 5 Gi PVC, `runAsUser/fsGroup 999` |
| StatefulSet | `agentforge-redis` | `redis:7-alpine`, 1 Gi PVC; Celery broker (`/0`) and results (`/1`) |
| **Job (Argo CD Sync hook, wave 1)** | **`agentforge-db-migrate`** | re-applies `files/init.sql` on every sync, after Postgres and before the app ([below](#migration-job-agentforge-db-migrate)) |
| **CronJob** | **`agentforge-ingest`** | re-indexes Confluence into `document_chunks` ([below](#ingest-cronjob-agentforge-ingest)) |
| ConfigMap | `agentforge-config` | non-secret env (model backend, env, log level, auth, HITL, Ollama URL, Confluence space/ancestor, **`CELERY_BROKER_URL` / `CELERY_RESULT_BACKEND`**) |
| ConfigMap | `agentforge-postgres-init` | `init.sql` from `files/init.sql`, mounted at `/docker-entrypoint-initdb.d` and by the migrate Job |
| ConfigMap | `agentforge-grafana-dashboard` | dashboard JSON |
| ExternalSecret | `agentforge-secrets` | from Vault `secret/agentforge/*` via ClusterSecretStore `vault-backend` |
| Service | `agentforge-gateway` (8000), `-postgres` (5432), `-redis` (6379), `-flower` (5555) | |
| ServiceAccount | `agentforge` | |
| HTTPRoute | `agentforge` | host `agentforge.helmsman.local` on `gateway-infra/helmsman-gateway`; authenticated rule has `timeouts.request: 360s` (`httproute.timeouts`; the Envoy Gateway default is 15 s) |
| NetworkPolicy ×5 | `agentforge-deny-all`, `-allow-internal`, `-allow-ingress` (in `networkpolicies-narrowed.yaml`), `-allow-egress-external`, `-allow-egress-dns` | see [Network](#network) |

`serviceMonitor.enabled: false` on the spoke, because Prometheus runs on the hub.

## Migration Job: `agentforge-db-migrate`

**Why it exists.** Postgres runs `/docker-entrypoint-initdb.d/*.sql` **only when its data directory is
empty**. The 2026-10-24 deployment hit exactly that: the app queried `audit_runs`, but the original init
SQL had created `agent_runs` and `document_chunks`, and an existing volume never re-ran it. Phase 7
(`6d2ad79`) moved the schema into `files/init.sql` and added this Job, so schema changes reach existing
databases.

| Field | Value |
| --- | --- |
| Enabled by | `migrations.enabled: true` (`values.yaml`) |
| Argo CD hook | `argocd.argoproj.io/hook: Sync`, `sync-wave: "1"` (since PWP-1 item 1.2; was PostSync). Wave 0 = Postgres, Redis and all non-workload objects; wave 1 = this Job; wave 2 = gateway, worker, Flower, ingest CronJob. Runs on **every sync operation** of `agentforge`. |
| Hook delete policy | `BeforeHookCreation`: the previous run's Job is deleted when the next sync creates a new one |
| `ttlSecondsAfterFinished` | `600`, so a finished Job disappears after 10 minutes. Not finding it in `kubectl get jobs` is normal. |
| `backoffLimit` / `restartPolicy` | `6` / `OnFailure` |
| Image | `{{ .Values.postgres.image }}` (`pgvector/pgvector:pg16`, used for `psql`; no app image needed) |
| Security | `runAsNonRoot`, `runAsUser: 999`, `fsGroup: 999`, chart container security context (Kyverno-compliant) |
| Resources | requests `50m / 64Mi`, limits `200m / 128Mi` |
| Env | `PGHOST=agentforge-postgres`, `PGUSER` and `PGDATABASE` from values, `PGPASSWORD` from `agentforge-secrets/POSTGRES_PASSWORD` |
| Command | `until pg_isready -q; do sleep 2; done; psql -v ON_ERROR_STOP=1 -f /sql/init.sql` |
| SQL source | ConfigMap `agentforge-postgres-init`, mounted read-only at `/sql` |

**The SQL must be idempotent.** `init.sql` uses `CREATE EXTENSION/TABLE … IF NOT EXISTS` and
`ON CONFLICT DO NOTHING`, because it runs on every sync. It creates `uuid-ossp`, `vector`, and the tables
`audit_runs`, `document_chunks`, `jobs` and `team_quotas`. Destructive changes (drop or rename a column,
change a type) can't be expressed safely this way. They'd need a real migration tool (Alembic) and a
versioned approach.

**Verified 2026-10-31.** The last `agentforge` sync reported `Job agentforge-db-migrate PostSync Succeeded
(Reached expected number of succeeded pods)`, and the database has `audit_runs, document_chunks, jobs,
team_quotas`. The gateway logs no more `UndefinedTable` errors.

**Operations:**

```bash
# see the hook result of the last sync
argocd app get agentforge --server localhost:9091 --insecure | grep -i migrate
# re-run the migration without changing git: any sync re-runs the hook
argocd app sync agentforge --server localhost:9091 --insecure
# watch it (within 10 min of the sync, before the TTL removes it)
kubectl --context kind-helmsman-onprem -n agentforge logs -f job/agentforge-db-migrate
# confirm the schema
kubectl --context kind-helmsman-onprem -n agentforge exec agentforge-postgres-0 -- \
  psql -U agentforge -d agentforge -c '\dt'
```

If the Job fails, the **sync fails** and wave 2 is not applied: the gateway, worker and Flower keep their
previous spec and pods (proven on a synthetic chart in WO-P1.B). Argo CD retries the failed sync on its own
(5 times observed) before giving up. See [schema handoff](agentforge-schema-handoff.md) for verification and rollback.

## Ingest CronJob: `agentforge-ingest`

Re-indexes the Confluence knowledge base into Postgres (`document_chunks`, pgvector) for IntelliSearch. It's
idempotent: chunk ids are content hashes, so duplicates are skipped.

| Field | Value |
| --- | --- |
| Enabled by | `ingest.enabled: true` |
| Schedule | `ingest.schedule: "0 2 * * *"` (02:00 daily; CronJob timezone is the controller's, UTC) |
| **Suspended** | **`ingest.suspend: true`, so it never runs on schedule.** Runs are on demand. Set `suspend: false` for nightly re-indexing. |
| `concurrencyPolicy` | `Forbid` |
| History | 2 successful, 2 failed |
| Job `backoffLimit` / `activeDeadlineSeconds` | `1` / `1800` (30 min) |
| Image | the AgentForge app image (same tag as gateway and worker, so it's signature-verified) |
| Command | `python scripts/ingest_confluence.py` |
| Env | `envFrom` `agentforge-config` (Confluence space key and ancestor id) + `agentforge-secrets` (Confluence URL, email, API token, database URL) |
| Security | chart pod and container security contexts (non-root, no privilege escalation), Kyverno-compliant |
| Resources | requests `100m / 128Mi`, limits `500m / 512Mi` |
| Network | needs egress 443 to Confluence Cloud (allowed by `agentforge-allow-egress-external`, which selects `app.kubernetes.io/name=agentforge-ingest`) and Postgres in-namespace |

**Verified 2026-10-31.** Argo CD reports `CronJob is Suspended`. A manual run, `ingest-now`, completed
earlier (`1/1`, 41 s), and search reports **1,614 chunks** indexed.

**Verified 2026-11-18 (WO-P1.C, after egress was narrowed).** A manual run reached Confluence: 50 pages,
`Inserted: 1605 | Skipped: 5 | Failed: 0` in 35 s; search then reported 1,638 chunks. The CronJob stayed suspended.

**Operations:**

```bash
# run an ingest now
kubectl --context kind-helmsman-onprem -n agentforge create job --from=cronjob/agentforge-ingest ingest-$(date +%s)
kubectl --context kind-helmsman-onprem -n agentforge logs -f job/<name>
# turn on nightly runs: set ingest.suspend: false in apps/agentforge/values*.yaml and push
```

Ingest makes Confluence API calls, and possibly embedding calls, on every run. It isn't affected by the
Groq tokens-per-minute limit unless embeddings go through Groq.

## Configuration and secrets

`agentforge-secrets` (ExternalSecret → Vault):

| Env var | Vault key |
| --- | --- |
| `GROQ_API_KEY` | `agentforge/llm.groq_api_key` |
| `DATABASE_URL` (`postgresql+asyncpg://agentforge:…@agentforge-postgres…:5432/agentforge`) | `agentforge/db.database_url` |
| `POSTGRES_PASSWORD` | `agentforge/db.postgres_password` |
| `REDIS_URL` | `agentforge/cache.redis_url` |
| `CONFLUENCE_URL`, `CONFLUENCE_EMAIL`, `CONFLUENCE_API_TOKEN` | `agentforge/confluence.*` |
| `KEYCLOAK_CLIENT_SECRET` | `agentforge/auth.keycloak_client_secret` |

ESO syncs all-or-nothing, so a missing key blocks Postgres, Flower and every pod. Vault is in-memory;
`dev-up-gemini.sh` Stage 10.5 restores these paths from `~/.helmsman-dev/vault-agentforge.json` and adds any
missing keys ([identity Q6](agentforge-identity-integration.md#q6-vault-dev-mode-backups-and-re-seeding)).

HITL: the ConfigMap key is `AGENTFORGE_HITL_AUTO_APPROVE` (since `6d2ad79`), which is what the app reads
(`config/settings.py`); `config.hitlAutoApprove: "false"` means approval required. Verified in git, the live
ConfigMap and the gateway and worker environment on 2026-11-18. (An earlier version of this doc described a
mismatch with a bare `HITL_AUTO_APPROVE` key; that was wrong, the key has been correct since `6d2ad79`.)

## Routing

| Path on `agentforge.helmsman.local` | Backend | Auth |
| --- | --- | --- |
| `/health` (exact) | `agentforge-gateway:8000` directly | **none** |
| `/` (everything else, **including `/metrics`** since 2026-11-18) | `gateway-infra/agentforge-oauth2-proxy:4180` (ReferenceGrant `agentforge-to-oauth2-proxy`) → gateway | Keycloak browser login, or `Authorization: Bearer` (`agentforge-cli`). Unauthenticated `/metrics` → 302 to the login; see [metrics plan](agentforge-metrics-plan.md) |

Both rules remove nine client-supplied identity headers by name (`X-Forwarded-User/-Preferred-Username/-Email/-Groups`,
`X-Auth-Request-User/-Email/-Groups/-Preferred-Username/-Access-Token`): on `/health` since `a406ad6` (2026-11-06), on `/`
(before oauth2-proxy) since WO-P1.C. `X-Forwarded-For/-Host/-Proto/-Uri` and `Authorization` are kept.

`/health/ready` was removed from the unauthenticated route in `47aeb2c`. oauth2-proxy passes identity
upstream as `X-Forwarded-User/-Email/-Groups/-Preferred-Username` (it overwrites client copies).
**`X-Auth-Request-*` is never set upstream**; client copies used to pass through to the gateway and are now
removed at the edge on every path. The app must still never read them. See
[agentforge-identity-integration.md](agentforge-identity-integration.md).

## Network

| Policy | Effect |
| --- | --- |
| `agentforge-deny-all` | default deny, ingress and egress, all pods |
| `agentforge-allow-internal` | all traffic between pods in `agentforge` |
| `agentforge-allow-ingress` | gateway:8000 **only** from pods labelled `app.kubernetes.io/name=agentforge-oauth2-proxy` in `gateway-infra`, and the `helmsman-gateway` Envoy proxy pods in `envoy-gateway-system` (narrowed 2026-11-01, `cd616d1`) |
| `agentforge-allow-egress-external` | gateway, worker, ingest → any destination on 53/UDP+TCP and 443/TCP (Groq, Confluence; no FQDN rules exist) |
| `agentforge-allow-egress-dns` | Flower and the migration Job → kube-dns pods in `kube-system`, 53/UDP+TCP only (they reach Redis/Postgres by Service name) |

Postgres and Redis have no egress outside the namespace (no egress policy selects them). Ports 30081, 30082
(Keycloak/Vault NodePorts) and 11434 (Ollama) were removed on 2026-11-18 (WO-P1.C, PWP-1 1.5c): no
AgentForge pod uses them. In-namespace traffic is allowed by `agentforge-allow-internal`, not by the egress policies.

`agentforge-allow-prometheus` was removed on 2026-11-01: the spoke's `monitoring` namespace holds only Promtail,
which never scrapes :8000.

The negative test on 2026-10-31 showed `default` and `sample-app` blocked, and four namespaces reachable.
After narrowing (2026-11-01), AgentForge's `scripts/test_forged_headers.sh` shows `default`, `gateway-infra`,
`envoy-gateway-system` and `monitoring` all **blocked**. The remaining tightening (internal traffic, egress) is in
[identity Q2](agentforge-identity-integration.md#q2-cni-and-the-networkpolicy-negative-test) and
[cloud inventory #3](cloud-migration-inventory.md#3-agentforge-egress-rules).

## History

| Date | Change | Write-up |
| --- | --- | --- |
| 2026-10-24 | Chart added; Helm source; Kyverno GHCR credentials; issuer regression fixed | [agentforge-chart-deploy](troubleshooting/agentforge-chart-deploy-2026-10-24.md) |
| 2026-10-25 | gh OAuth pull token; worker `--app` flag; Celery broker URLs; `--skip-provider-button` | same |
| 2026-10-26 | Gateway readiness probe → `/health` (`d7df8b1`); `/health/ready` no longer unauthenticated; anchored skip routes (`47aeb2c`); **Phase 7: `init.sql`, PostSync migrate Job, ingest CronJob** (`6d2ad79`) | this doc |
| 2026-10-31 | Bearer tokens (`--skip-jwt-bearer-tokens`), `--pass-access-token=false`, `agentforge-cli` client | [identity](agentforge-identity-integration.md) |
| 2026-11-05 | PWP-1 1.2: migration Job PostSync → Sync hook in wave 1; Postgres/Redis wave 0; gateway/worker/Flower/ingest wave 2 (WO-P1.B) | [schema handoff](agentforge-schema-handoff.md) |
| 2026-11-06 | PWP-1 1.1: nine identity headers stripped on the direct `/health`,`/metrics` rule (`a406ad6`, WO-P1.B) | this doc |
| 2026-11-18 | PWP-1 1.5: `checksum/config` on gateway and worker; egress per workload class (`76a5a4c`). 1.7: `/metrics` needs a login (`8ee290a`). Header strip on the authenticated `/` rule (`d40944c`). WO-P1.C | [metrics plan](agentforge-metrics-plan.md) |
