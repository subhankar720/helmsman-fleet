# AgentForge Helm chart: first deployment

Date: 2026-10-24 (updated 2026-10-25)
Cluster: `kind-helmsman-onprem` (Argo CD on `kind-helmsman-hub`)
Commits: `3238a9b` (chart), `f0480d4`, `4a5ec89`, `e640677`, `57541b5`, `4ffcd4e` (fixes), `25aa17c` (image bump by `agentforge-bot`)

Commit `3238a9b` added the AgentForge Helm chart under `apps/agentforge/` and moved the
`agentforge.helmsman.local` HTTPRoute from the oauth2-proxy manifests into the chart, plus a
ReferenceGrant in `gateway-infra`. Seven issues had to be fixed before everything ran. Two
application-level issues remain for the AgentForge team (see [Open](#open-for-the-agentforge-team)).

**Current state (2026-10-25)**

| Component | State |
| --- | --- |
| `agentforge-gateway`, `-worker`, `-flower`, `-postgres`, `-redis` | Running, Ready, 0 restarts. The image signature verified by Kyverno. |
| ExternalSecret `agentforge-secrets` | Synced from Vault |
| HTTPRoute `agentforge/agentforge` | `/health` and `/health/ready` → 200 (gateway), `/ping` → 200 (oauth2-proxy), `/oauth2/start` → 302 to Keycloak |
| Celery worker | Connected to `agentforge-redis`, `ready` |
| Argo CD `agentforge` | Synced / Healthy |
| `helmsman-sanity.sh` | 117 passed, 0 failed (4 warnings: old restart counts) |

## Issue 1: `argocd app sync` → `dial tcp 127.0.0.1:9091: connection refused`

**Root cause**

The CLI's saved server is a local port-forward, and the laptop reboot killed it. Argo CD itself
was fine.

**Fix**

```
kubectl port-forward svc/argocd-server -n argocd --context kind-helmsman-hub 9091:443
```

## Issue 2: chart re-introduced the `http://http://…` issuer

**Root cause**

`3238a9b` changed oauth2-proxy back to `--oidc-issuer-url=http://$(KEYCLOAK_URL)/realms/helmsman`.
dev-up Stage 6 writes `helmsman-platform-config.keycloak-url` *with* the scheme
(`http://172.18.0.2:30081`) in every spoke namespace, so the issuer would have expanded to
`http://http://…`, and oauth2-proxy fails OIDC discovery and crash-loops. See
[agentforge-restart-resilience-2026-10-03.md](agentforge-restart-resilience-2026-10-03.md#issue-2-oauth2-proxy-issuer-would-become-httphttp).

The same applies to the hand-run snippet that writes `keycloak-url="${HUB_IP}:30081"`. It also
replaces the whole Secret with a single key, which drops the other seven. dev-up Stage 6 and
Stage 10.5 already do that job correctly, so the snippet should not be used.

**Fix**

`f0480d4` restored `--oidc-issuer-url=$(KEYCLOAK_URL)/realms/helmsman`. It was pushed before Argo CD
synced `3238a9b`, so the live pod never broke.

## Issue 3: `agentforge` Application still a plain-directory source

**Root cause**

`apps/agentforge/argocd-application.yaml` had `directory: {exclude: argocd-application.yaml}`.
With a chart in that folder, Argo CD would apply the raw `templates/*.yaml`, `{{ }}` and all,
instead of rendering them.

**Fix (`4a5ec89`)**

```yaml
source:
  path: apps/agentforge
  helm:
    releaseName: agentforge
    valueFiles:
      - values-helmsman-onprem.yaml
```

The Application is kubectl-applied (no app-of-apps), so the change also needed
`kubectl apply -f apps/agentforge/argocd-application.yaml`. `e640677` added
`argocd.argoproj.io/compare-options: ServerSideDiff=true`, because server-defaulted fields on the
StatefulSets, ExternalSecret and HTTPRoute otherwise show as permanent OutOfSync. This is the same
fix as `platform-agentforge-oauth2proxy`.

`helm template agentforge apps/agentforge -f apps/agentforge/values-helmsman-onprem.yaml`, run
through a server-side dry-run on the spoke, accepted every resource except the two Deployments in
Issue 4.

## Issue 4: Kyverno couldn't read the private image

**Symptom**

```
verify-agentforge-signatures: failed to verify image ghcr.io/subhankar720/agentforge:latest:
  GET https://ghcr.io/token?scope=repository:subhankar720/agentforge:pull: DENIED
```

**Root cause**

`verify-agentforge-signatures` checks the cosign signature, which means fetching the image's
manifest and signature from GHCR. The repo is private, and Kyverno had no credentials:
`ghcr-pull-secret` only existed in the `agentforge` namespace, for kubelet.

**Fix (`4a5ec89`)**

- The policy now has `imageRegistryCredentials.secrets: [ghcr-pull-secret]` on its `verifyImages`
  entry. Kyverno reads that Secret from its own namespace.
- dev-up Stage 10.5 copies `ghcr-pull-secret` into `kyverno` from `~/.helmsman-dev/ghcr-pull-secret.json`,
  and sanity section K checks it's there.

After this, Kyverno could authenticate, and the error changed to `MANIFEST_UNKNOWN`: the image
didn't exist yet. `25aa17c` (`agentforge-bot`) then pinned the tag to
`5e1c565905dffbae86d858a52009e99d4fae2a77`, which led to Issue 5.

## Issue 5: GHCR rejects the fine-grained PAT

**Symptom (2026-10-25, after `25aa17c`)**

```
failed to verify image ghcr.io/subhankar720/agentforge:5e1c5659…:
  GET https://ghcr.io/v2/subhankar720/agentforge/manifests/5e1c5659…: DENIED: requested access to the resource is denied
```

**Root cause**

The token in `ghcr-pull-secret` is a **fine-grained** PAT (`github_pat_…`). GHCR exchanges it for a
registry token (HTTP 200), but reading the manifest returns 403. GitHub Packages only accepts
**classic** PATs (`ghp_…`) with the `read:packages` scope. Kubelet would get the same 403 when
pulling, so the pods would sit in `ImagePullBackOff` even if Kyverno let them through.

**Fix (2026-10-25, done with the `gh` CLI)**

GitHub has no API for creating PATs, but `gh`'s own login token (`gho_…`, an OAuth token) is accepted
by GHCR once it has the `read:packages` scope:

1. Add the scope to the existing `gh` login. This needs a one-time browser approval at
   https://github.com/login/device, **including the final Authorize click**:
   ```
   gh auth refresh -h github.com -s read:packages
   gh auth status          # Token scopes: … 'read:packages' …
   ```
2. Recreate the Secret in `agentforge` from that token:
   ```
   kubectl --context kind-helmsman-onprem -n agentforge create secret docker-registry ghcr-pull-secret \
     --docker-server=ghcr.io --docker-username=subhankar720 --docker-password="$(gh auth token)" \
     --dry-run=client -o yaml | kubectl --context kind-helmsman-onprem apply -f -
   ```
3. `./scripts/dev-up-gemini.sh`. Stage 10.5 backs the Secret up to `~/.helmsman-dev/` and copies it into
   `kyverno`.
4. Sync again (`argocd app sync agentforge`). Kyverno read the image and its cosign signature
   (`sha256-965a…​.sig`), the signature matched the policy key, and gateway and worker were admitted.

A classic PAT (`ghp_…` with `read:packages`) works the same way.

**Caveat:** a `gho_` token belongs to the `gh` login. `gh auth logout` or another `gh auth refresh`
issues a new token and the stored one stops working. New pods then fail Kyverno or `ImagePullBackOff`.
Sanity section K now tests the stored token against the deployed image and names the token type,
so this shows up immediately. To fix it, repeat steps 2–3.

## Issue 6: worker crash-loop, `No module named '=gateway'`

**Root cause**

`values.yaml` ran `celery -A=gateway.orchestrator.celery_app worker …`. With the short flag, Celery
keeps the `=`, so it imports a module literally named `=gateway.orchestrator.celery_app`.

**Fix (`57541b5`)**

Use the long form, `--app=gateway.orchestrator.celery_app`. (The liveness probe already used the
space-separated `-A gateway.orchestrator.celery_app`.)

## Issue 7: worker connected to `redis://localhost:6379`

**Root cause**

`config/settings.py` (pydantic settings, no prefix) reads `CELERY_BROKER_URL` and
`CELERY_RESULT_BACKEND`, with `redis://localhost:6379/{0,1}` as defaults. The chart only provided
`REDIS_URL`, which the app uses for quotas and sessions, not Celery.

**Fix (`4ffcd4e`)**

`templates/configmap.yaml` sets both to the chart's own Redis
(`redis://agentforge-redis.<namespace>.svc.cluster.local:6379/0` and `/1`). Changing `envFrom` content
doesn't restart pods, so the worker and gateway needed `kubectl rollout restart`. The worker then
logged `Connected to redis://agentforge-redis…` and `celery@… ready`.

## Open for the AgentForge team

- **`relation "audit_runs" does not exist`.** The gateway's audit code queries `audit_runs`, but
  `templates/configmap-postgres-init.yaml` only creates `agent_runs` and `document_chunks`. The app
  and init schema need aligning, either through migrations or an updated init SQL. The init script
  only runs on an empty data directory, so existing clusters need the table created separately.
- **Groq 404: `The model llama-3.3-70b-versatile does not exist or you do not have access`.** This
  is the app's model selection for `AGENTFORGE_MODEL_BACKEND=cloud_free`.

## Vault keys the chart reads

`templates/external-secret.yaml` reads `llm.groq_api_key`, `db.database_url`,
`db.postgres_password`, `cache.redis_url`, `confluence.{confluence_url,confluence_email,confluence_api_token}`
and `auth.keycloak_client_secret`. ESO syncs all-or-nothing, and `agentforge-postgres` and
`agentforge-flower` read `agentforge-secrets`. So a missing key keeps the database down, even
without the gateway image.

All keys were already in Vault on 2026-10-24. For a fresh `--reset`, dev-up Stage 10.5 now adds any
missing ones without overwriting existing values:

- `db` and `cache` are generated, because they point at the chart's own in-cluster Postgres and Redis
  (`agentforge-postgres.agentforge.svc:5432`, `agentforge-redis.agentforge.svc:6379`).
- `llm` and `confluence` start empty, for the AgentForge team to fill in.

## Script changes

| Script | Change |
| --- | --- |
| `dev-up-gemini.sh` Stage 10.5 | copy `ghcr-pull-secret` to `kyverno`; ensure the chart's Vault keys; force-sync `agentforge-secrets`; report each AgentForge workload, with the Kyverno reason when a Deployment is rejected |
| `helmsman-sanity.sh` section K | the ReferenceGrant; route check moved to `agentforge/agentforge` (was `gateway-infra/agentforge-gateway-route`); the `kyverno` pull secret; **the stored GHCR token can read the deployed image**, with the token type named (flags fine-grained PATs); `agentforge-secrets` Ready; each AgentForge workload ready |

Sanity runs: 2026-10-24, 111 passed and 2 failed (gateway and worker, Issue 5). 2026-10-25, after
Issues 5–7, 117 passed and 0 failed.

## Running `argocd` by hand

The CLI talks to Argo CD through a local port-forward. Keep one running in its own terminal:

```
kubectl port-forward svc/argocd-server -n argocd --context kind-helmsman-hub 9091:443
argocd login localhost:9091 --username admin --password "$(cat ~/.helmsman-dev/argocd-admin-password)" --insecure
argocd app sync agentforge
```

- `another operation is already in progress` means auto-sync is already retrying. Run
  `argocd app terminate-op agentforge`, then sync again.
- dev-up logs the CLI in on its own port-forward (`:9090`), which closes when the script exits. After
  a dev-up run, log in to `:9091` again, or pass `--server localhost:9091 --insecure`.
