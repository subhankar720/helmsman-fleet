# AgentForge Helm chart: first deployment

Date: 2026-10-24 (updated 2026-10-25)
Cluster: `kind-helmsman-onprem` (Argo CD on `kind-helmsman-hub`)
Commits: `3238a9b` (chart), `f0480d4`, `4a5ec89`, `e640677` (fixes), `25aa17c` (image bump by `agentforge-bot`)

Commit `3238a9b` added the AgentForge Helm chart under `apps/agentforge/` and moved the
`agentforge.helmsman.local` HTTPRoute from the oauth2-proxy manifests into the chart, plus a
ReferenceGrant in `gateway-infra`. Four issues had to be fixed before it would deploy. A fifth
(GHCR credentials) is still open.

**Current state (2026-10-25)**

| Component | State |
| --- | --- |
| `agentforge-postgres`, `agentforge-redis`, `agentforge-flower` | Running |
| ExternalSecret `agentforge-secrets` | Synced from Vault |
| HTTPRoute `agentforge/agentforge` | Accepted, ResolvedRefs. `/ping` → 200 (oauth2-proxy), `/oauth2/start` → 302 to Keycloak |
| `agentforge-gateway`, `agentforge-worker` | Blocked by Kyverno: image can't be read ([Issue 5](#issue-5-ghcr-rejects-the-fine-grained-pat-open)) |
| `/health` | 500 until the gateway pods exist |

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

## Issue 5: GHCR rejects the fine-grained PAT (open)

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

**Fix (manual: the token can't be created from here)**

1. On GitHub, go to Settings → Developer settings → Personal access tokens → **Tokens (classic)**,
   and create one with `read:packages`.
2. Recreate the Secret in `agentforge`:
   ```
   kubectl --context kind-helmsman-onprem -n agentforge delete secret ghcr-pull-secret
   kubectl --context kind-helmsman-onprem -n agentforge create secret docker-registry ghcr-pull-secret \
     --docker-server=ghcr.io --docker-username=subhankar720 --docker-password=<classic PAT>
   ```
3. Run `./dev-up-gemini.sh`. Stage 10.5 backs the new Secret up to `~/.helmsman-dev/` and copies it
   into `kyverno`.
4. Kyverno then verifies the signature. This only passes if CI signed the image with the key in
   `platform/kyverno/policies/verify-agentforge-signatures.yaml`.

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
| `helmsman-sanity.sh` section K | the ReferenceGrant; route check moved to `agentforge/agentforge` (was `gateway-infra/agentforge-gateway-route`); the `kyverno` pull secret; `agentforge-secrets` Ready; each AgentForge workload ready |

Final sanity run on 2026-10-24: 111 passed, 2 failed (`agentforge-gateway` and `agentforge-worker`,
the image issue above), 5 warnings (old restart counts and the resulting `agentforge` OutOfSync).
