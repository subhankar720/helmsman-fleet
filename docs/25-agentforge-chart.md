# 25: AgentForge Helm chart (as deployed)

Last updated: 2026-10-31
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
| Deployment | `agentforge-gateway` | FastAPI gateway, port 8000. Readiness probe `/health` (doesn't trigger LLM calls). |
| Deployment | `agentforge-worker` | Celery worker, `celery --app=gateway.orchestrator.celery_app worker --queues=sdlc,default --concurrency=2` |
| Deployment | `agentforge-flower` | Celery UI (`mher/flower:2.0`), port 5555 |
| StatefulSet | `agentforge-postgres` | `pgvector/pgvector:pg16`, 5 Gi PVC, `runAsUser/fsGroup 999` |
| StatefulSet | `agentforge-redis` | `redis:7-alpine`, 1 Gi PVC; Celery broker (`/0`) and results (`/1`) |
| **Job (Argo CD PostSync hook)** | **`agentforge-db-migrate`** | re-applies `files/init.sql` after every sync ([below](#postsync-migration-job-agentforge-db-migrate)) |
| **CronJob** | **`agentforge-ingest`** | re-indexes Confluence into `document_chunks` ([below](#ingest-cronjob-agentforge-ingest)) |
| ConfigMap | `agentforge-config` | non-secret env (model backend, env, log level, auth, HITL, Ollama URL, Confluence space/ancestor, **`CELERY_BROKER_URL` / `CELERY_RESULT_BACKEND`**) |
| ConfigMap | `agentforge-postgres-init` | `init.sql` from `files/init.sql`, mounted at `/docker-entrypoint-initdb.d` and by the migrate Job |
| ConfigMap | `agentforge-grafana-dashboard` | dashboard JSON |
| ExternalSecret | `agentforge-secrets` | from Vault `secret/agentforge/*` via ClusterSecretStore `vault-backend` |
| Service | `agentforge-gateway` (8000), `-postgres` (5432), `-redis` (6379), `-flower` (5555) | |
| ServiceAccount | `agentforge` | |
| HTTPRoute | `agentforge` | host `agentforge.helmsman.local` on `gateway-infra/helmsman-gateway` |
| NetworkPolicy ×5 | `agentforge-deny-all`, `-allow-internal`, `-allow-ingress`, `-allow-prometheus`, `-allow-egress-external` | see [Network](#network) |

`serviceMonitor.enabled: false` on the spoke, because Prometheus runs on the hub.

## PostSync migration Job: `agentforge-db-migrate`

**Why it exists.** Postgres runs `/docker-entrypoint-initdb.d/*.sql` **only when its data directory is
empty**. The 2026-10-24 deployment hit exactly that: the app queried `audit_runs`, but the original init
SQL had created `agent_runs` and `document_chunks`, and an existing volume never re-ran it. Phase 7
(`6d2ad79`) moved the schema into `files/init.sql` and added this Job, so schema changes reach existing
databases.

| Field | Value |
| --- | --- |
| Enabled by | `migrations.enabled: true` (`values.yaml`) |
| Argo CD hook | `argocd.argoproj.io/hook: PostSync`. Runs **after every successful sync** of `agentforge`. |
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
# re-run the migration without changing git: any sync re-runs the PostSync hook
argocd app sync agentforge --server localhost:9091 --insecure
# watch it (within 10 min of the sync, before the TTL removes it)
kubectl --context kind-helmsman-onprem -n agentforge logs -f job/agentforge-db-migrate
# confirm the schema
kubectl --context kind-helmsman-onprem -n agentforge exec agentforge-postgres-0 -- \
  psql -U agentforge -d agentforge -c '\dt'
```

If the Job fails, the **sync still shows Succeeded** for the main resources, but the hook shows Failed, and
the app may run against an old schema. Check `argocd app get agentforge` after schema changes.

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
| Network | needs egress 443 to Confluence Cloud (allowed by `agentforge-allow-egress-external`) and Postgres in-namespace |

**Verified 2026-10-31.** Argo CD reports `CronJob is Suspended`. A manual run, `ingest-now`, completed
earlier (`1/1`, 41 s), and search reports **1,614 chunks** indexed.

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

Known config mismatch: the chart sets `HITL_AUTO_APPROVE`, but the app reads
`AGENTFORGE_HITL_AUTO_APPROVE`. So the default `false` (approval required) always applies.

## Routing

| Path on `agentforge.helmsman.local` | Backend | Auth |
| --- | --- | --- |
| `/health`, `/metrics` (exact) | `agentforge-gateway:8000` directly | **none**. `/metrics` is publicly reachable. |
| `/` (everything else) | `gateway-infra/agentforge-oauth2-proxy:4180` (ReferenceGrant `agentforge-to-oauth2-proxy`) → gateway | Keycloak browser login, or `Authorization: Bearer` (`agentforge-cli`) |

`/health/ready` was removed from the unauthenticated route in `47aeb2c`. oauth2-proxy passes identity
upstream as `X-Forwarded-User/-Email/-Groups/-Preferred-Username`; **`X-Auth-Request-*` is not set
upstream and is forgeable**. See [agentforge-identity-integration.md](agentforge-identity-integration.md).

## Network

| Policy | Effect |
| --- | --- |
| `agentforge-deny-all` | default deny, ingress and egress, all pods |
| `agentforge-allow-internal` | all traffic between pods in `agentforge` |
| `agentforge-allow-ingress` | gateway:8000 from **all pods** in `gateway-infra` and `envoy-gateway-system` |
| `agentforge-allow-prometheus` | gateway:8000 from **all pods** in `monitoring` |
| `agentforge-allow-egress-external` | all pods → **any** destination on 53/UDP, 443, 30081, 30082, 11434 |

The negative test on 2026-10-31 showed `default` and `sample-app` blocked, and the four allowed
namespaces reachable. The recommended tightening is in
[identity Q2](agentforge-identity-integration.md#q2-cni-and-the-networkpolicy-negative-test) and
[cloud inventory #3](cloud-migration-inventory.md#3-agentforge-egress-rules).

## History

| Date | Change | Write-up |
| --- | --- | --- |
| 2026-10-24 | Chart added; Helm source; Kyverno GHCR credentials; issuer regression fixed | [agentforge-chart-deploy](troubleshooting/agentforge-chart-deploy-2026-10-24.md) |
| 2026-10-25 | gh OAuth pull token; worker `--app` flag; Celery broker URLs; `--skip-provider-button` | same |
| 2026-10-26 | Gateway readiness probe → `/health` (`d7df8b1`); `/health/ready` no longer unauthenticated; anchored skip routes (`47aeb2c`); **Phase 7: `init.sql`, PostSync migrate Job, ingest CronJob** (`6d2ad79`) | this doc |
| 2026-10-31 | Bearer tokens (`--skip-jwt-bearer-tokens`), `--pass-access-token=false`, `agentforge-cli` client | [identity](agentforge-identity-integration.md) |
