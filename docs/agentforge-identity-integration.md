# AgentForge identity integration: answers for the AgentForge team

Date: 2026-10-31
Cluster: `kind-helmsman-onprem` (AgentForge, oauth2-proxy, Envoy Gateway), `kind-helmsman-hub` (Keycloak, Vault)
Platform commits: `02ae6b5` (oauth2-proxy flags), then the [follow-up round](#follow-up-round-2026-10-31-labels-api-route-users-teams-timeouts-sanity)
(`--api-route`, `--upstream-timeout`, team groups, test users, route timeout). The `agentforge-cli` Keycloak
client, groups and users are created by `dev-up-gemini.sh` Stage 10.5 and checked by `helmsman-sanity.sh` section K.

Every answer below was **tested on the live clusters**, not inferred from documentation. The header
behaviour came from a throwaway copy of oauth2-proxy (same image, same flags and secrets) pointed at an
HTTP echo server, plus a throwaway Keycloak user in three groups. Both were removed afterwards.

> **The most important finding.** `X-Auth-Request-Groups` is **not safe to trust**. In reverse-proxy
> mode, oauth2-proxy never sets `X-Auth-Request-*` on the request it forwards to AgentForge. Those
> headers are response headers for nginx `auth_request`. So a client-supplied
> `X-Auth-Request-Groups: admins` reaches AgentForge **untouched**, even on unauthenticated paths.
> AgentForge must read **`X-Forwarded-Groups`** (and the other `X-Forwarded-*` identity headers)
> instead. oauth2-proxy overwrites or strips those itself. See [Q4](#q4-header-format-ordering-and-a-dedicated-team-claim).

## Summary

| # | Question | Answer |
| --- | --- | --- |
| 1 | `--skip-jwt-bearer-tokens` + `agentforge-cli` client | **Done.** Bearer tokens from `agentforge-cli` get 200 through the gateway. Missing or tampered tokens get **401 on `/v1/*`** (`--api-route`, follow-up round) and 302 elsewhere. |
| 1 | Exact issuer | `http://172.18.0.2:30081/realms/helmsman` today. It is **not stable**: the IP changes on reboot, and tokens requested through any other URL are rejected. |
| 1 | Test token for `subhankar` | Password grant on `agentforge-cli`, requested from inside the cluster (see below) |
| 2 | CNI / NetworkPolicy negative test | **kindnet**, which enforces NetworkPolicy. The negative test ran: `default` and `sample-app` are blocked, and 4 namespaces can still reach the gateway directly. |
| 3 | `--pass-access-token` | **Not needed. Turned off** (`02ae6b5`). Nothing in AgentForge reads it. |
| 4 | Multi-group header | Comma-separated, no spaces, full group paths since the follow-up round: `X-Forwarded-Groups: /teams/dev-team,/readonly`. **Order is not stable** (not alphabetical either). |
| 4 | Dedicated team claim | **Option A implemented** (follow-up round): exactly one `/teams/<name>` group per user. |
| 6 | Vault backups include Groq key and Confluence token? | **Yes.** dev-up Stage 10.5 re-seeds them automatically from `~/.helmsman-dev/vault-agentforge.json`. |

## Q1: bearer tokens, the `agentforge-cli` client, the issuer, and a test token

### What changed

oauth2-proxy (`platform/oauth2-proxy-agentforge/oauth2-proxy.yaml`):

```yaml
- --pass-access-token=false       # was true; unused by AgentForge
- --pass-user-headers=true        # unchanged: the X-Forwarded-* identity headers
- --skip-jwt-bearer-tokens=true   # new
```

With `--skip-jwt-bearer-tokens`, a request carrying `Authorization: Bearer <access token>` skips the cookie
login flow. oauth2-proxy verifies the JWT against the OIDC issuer's JWKS and checks that its `aud` includes
`agentforge-gateway` (oauth2-proxy's `--client-id`). It then forwards the request with the same
`X-Forwarded-*` headers a browser session would get.

Keycloak client **`agentforge-cli`** (realm `helmsman`):

| Setting | Value | Why |
| --- | --- | --- |
| Client type | public (no secret) | CLI/SDK can't keep a secret |
| Standard flow | off | no browser redirect flow |
| Direct access grants | **on** | password grant for CLI/SDK and tests |
| Mapper `groups` | `oidc-group-membership-mapper`, claim `groups`, `full.path=false`, in ID, access and userinfo tokens | same as `agentforge-gateway` |
| Mapper `audience-agentforge-gateway` | `oidc-audience-mapper`, included client audience `agentforge-gateway`, access and ID tokens | oauth2-proxy rejects tokens whose `aud` lacks its client-id |

Keycloak has no PVC, so the client would vanish on restart. dev-up Stage 10.5 now recreates it, and its
mappers, whenever they're missing. This was tested by deleting the client and running the stage. Sanity
section K fails if it's missing or incomplete.

A decoded token (throwaway user in all three groups):

```json
{
  "iss": "http://172.18.0.2:30081/realms/helmsman",
  "aud": ["agentforge-gateway", "account"],
  "azp": "agentforge-cli",
  "groups": ["dev-team", "platform-team", "readonly"],
  "preferred_username": "af-hdr-test",
  "email": "af-hdr-test@helmsman.dev"
}
```

Access-token lifetime is **300 s**. The CLI/SDK has to refresh (`grant_type=refresh_token`) or re-request.

### The exact issuer string, and why it isn't stable

```
http://<hub-worker-ip>:30081/realms/helmsman        # today: http://172.18.0.2:30081/realms/helmsman
```

- Keycloak runs `start-dev` with no `--hostname`, so it writes **whatever host the token was requested
  through** into `iss`.
- oauth2-proxy's issuer comes from `helmsman-platform-config.keycloak-url`, which dev-up Stage 6 sets to
  `http://<hub-worker-ip>:30081`.
- A token requested via a port-forward has `iss: http://localhost:18081/realms/helmsman`. It was
  **rejected**: `oidc: id token issued by a different provider`.
- The hub worker IP changes when Docker reassigns addresses after a reboot. It was `172.18.0.6` and is now
  `172.18.0.2`. dev-up re-points oauth2-proxy, but tokens and any issuer hard-coded in AgentForge become invalid.

**Recommendation before AgentForge depends on the issuer:** give Keycloak a fixed hostname
(`KC_HOSTNAME`, for example `http://keycloak.helmsman.local:30081`), resolvable from the spoke and from the
laptop. Then the issuer is the same however a token is obtained. It's also on the
[cloud-migration inventory](cloud-migration-inventory.md). Until then, AgentForge should take the issuer
from configuration (`KEYCLOAK_URL` + `/realms/helmsman`) and never hard-code it.

### Fetching a test token for `subhankar`

The password lives in `~/.helmsman-dev/keycloak-agentforge-user-password`. dev-up reuses it if it ever
has to recreate the user. The token **must** be requested through the same URL oauth2-proxy uses.
`172.18.x.x` isn't reachable from WSL, so request it from a pod:

```bash
HUB_IP=$(docker inspect helmsman-hub-worker --format='{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
SVC=$(kubectl --context kind-helmsman-onprem -n envoy-gateway-system get svc \
  -l gateway.envoyproxy.io/owning-gateway-name=helmsman-gateway -o jsonpath='{.items[0].metadata.name}')

kubectl --context kind-helmsman-onprem -n default run --rm -i --restart=Never tok-test \
  --image=curlimages/curl:latest \
  --env="PW=$(cat ~/.helmsman-dev/keycloak-agentforge-user-password)" \
  --env="K=http://$HUB_IP:30081" --env="G=http://$SVC.envoy-gateway-system" -- sh -c '
T=$(curl -s -X POST $K/realms/helmsman/protocol/openid-connect/token \
      -d grant_type=password -d client_id=agentforge-cli -d username=subhankar \
      --data-urlencode "password=$PW" -d scope=openid \
    | sed -n "s/.*\"access_token\":\"\([^\"]*\)\".*/\1/p")
curl -s -H "Host: agentforge.helmsman.local" -H "Authorization: Bearer $T" $G/v1/agents'
```

Results on 2026-10-31:

| Request | Result |
| --- | --- |
| `subhankar` bearer → `/v1/agents` | **200** (agent list returned) |
| no credentials | 302 → Keycloak login |
| tampered token | 302 |
| token issued via `localhost:18081` | 302 (wrong issuer) |

For API clients, a missing or bad token returns **302 to the login page**, not 401. Adding
`--api-route=^/v1/` to oauth2-proxy would return 401 for those paths. I haven't changed this; say if you want it.

## Q2: CNI and the NetworkPolicy negative test

**CNI:** kindnet (`docker.io/kindest/kindnetd:v20250512-df8de77b`) on both clusters. It **does enforce
NetworkPolicy**: it sends new pod connections to an nfqueue and decides allow/deny in userspace. It can only
match on IP, namespace and pod selector; there are no FQDN rules. On 2026-10-03 it was found CPU-starved at
kind's default 100m limit, which made enforcement go stale. It now has a 1-CPU limit, enforced by dev-up
Stage 3 ([details](troubleshooting/agentforge-restart-resilience-2026-10-03.md)).

**Negative test (2026-10-31).** A pod in each namespace ran
`curl http://agentforge-gateway.agentforge.svc.cluster.local:8000/health`:

| Source namespace | Result | Policy that decides it |
| --- | --- | --- |
| `default` | **blocked** (timeout) | `agentforge-deny-all` |
| `sample-app` | **blocked** (timeout) | `agentforge-deny-all` |
| `gateway-infra` | 200 | `agentforge-allow-ingress` (whole namespace) |
| `envoy-gateway-system` | 200 | `agentforge-allow-ingress` (whole namespace) |
| `monitoring` | 200 | `agentforge-allow-prometheus` (whole namespace, port 8000) |
| `agentforge` | 200 | `agentforge-allow-internal` (all pods in the namespace) |

And the case that matters for header trust: a pod in `gateway-infra` called the gateway **directly**
(skipping oauth2-proxy) with `X-Forwarded-Groups: admins`, and got **200**. Today that's harmless, because
the app ignores identity headers (`gateway/api/routes/agents.py`: `team_id = "dev-team"  # Phase 3: from JWT
auth middleware`). Once AgentForge trusts `X-Forwarded-Groups`, **any pod in those four namespaces could
impersonate any group.**

**Recommendations, needed before trusting headers:**

1. Narrow `agentforge-allow-ingress` from the whole `gateway-infra` namespace to the oauth2-proxy pods:
   `namespaceSelector: gateway-infra` **and** `podSelector: app.kubernetes.io/name=agentforge-oauth2-proxy`.
2. Narrow `envoy-gateway-system` access to the Envoy proxy pods, which carry the
   `gateway.envoyproxy.io/owning-gateway-name=helmsman-gateway` label. Envoy reaches the gateway directly only for `/health`
   and `/metrics`. Also strip identity headers on that route, for example with a Gateway API
   `RequestHeaderModifier` `remove: [X-Forwarded-User, X-Forwarded-Email, X-Forwarded-Groups,
   X-Forwarded-Preferred-Username, X-Auth-Request-User, X-Auth-Request-Email, X-Auth-Request-Groups]`.
3. Restrict `agentforge-allow-prometheus` to the Prometheus pods and the metrics port/path. Note that
   Prometheus runs on the **hub**, so this rule currently admits nothing useful.
4. `agentforge-allow-internal` lets the worker, Flower, Postgres and Redis call the gateway. If only the
   worker needs to, narrow it.

These belong in the AgentForge chart (`templates/networkpolicies.yaml`). They're not applied yet because
they change your chart's behaviour.

Also, `/metrics` is routed **Envoy → gateway directly** by the HTTPRoute, so it's reachable without login
at `agentforge.helmsman.local/metrics`. Decide whether that's intended.

## Q3: does AgentForge need `--pass-access-token=true`?

**No, and it's now off** (`--pass-access-token=false`, `02ae6b5`). With it on, every upstream request
carried `X-Forwarded-Access-Token: <JWT>` (seen in the echo test). Nothing in `/app/gateway` reads it.
Turn it back on only if AgentForge decides to verify JWTs itself, for example to read custom claims; see
Q4 option C.

Bearer requests still pass the client's own `Authorization: Bearer <JWT>` header through to the upstream.
oauth2-proxy doesn't remove it. If AgentForge shouldn't see raw tokens, strip `Authorization` in the
HTTPRoute (`RequestHeaderModifier`), or set oauth2-proxy `--pass-authorization-header=false` and check
that it removes the incoming header.

## Q4: header format, ordering, and a dedicated team claim

### What AgentForge receives (echo test, oauth2-proxy v7.7.1, current flags)

Request with a valid bearer token for a user in three groups:

```
X-Forwarded-User:               d51d4403-c2aa-481a-b4c4-3c8e83b2b915     ← Keycloak user ID (sub), not the username
X-Forwarded-Email:              af-hdr-test@helmsman.dev
X-Forwarded-Preferred-Username: af-hdr-test
X-Forwarded-Groups:             dev-team,platform-team,readonly
X-Forwarded-Access-Token:       <JWT>                                      ← gone now (--pass-access-token=false)
Authorization:                  Bearer <JWT>                               ← the client's own header, passed through
```

The same request plus forged headers `X-Auth-Request-Groups: admins`, `X-Forwarded-Groups: admins` and
`X-Auth-Request-User: mallory`:

| Header | Value AgentForge received |
| --- | --- |
| `X-Forwarded-Groups` | `dev-team,platform-team,readonly`: **forgery overwritten** |
| `X-Auth-Request-Groups` | `admins`: **forgery passed through** |
| `X-Auth-Request-User` | `mallory`: **forgery passed through** |

`/health` (a skip-auth route, no login) with the same forged headers:

| Header | Value AgentForge received |
| --- | --- |
| `X-Forwarded-Groups` | absent: oauth2-proxy **stripped** it |
| `X-Auth-Request-Groups`, `-User` | `admins`, `mallory`: passed through |

**So: trust `X-Forwarded-*`, never `X-Auth-Request-*`.** If AgentForge was planning to read
`X-Auth-Request-Groups`, that has to change. Defence in depth: strip `X-Auth-Request-*` at Envoy
(Q2 recommendation 2), so the trap can't be fallen into later.

### Format and ordering

- One header, **comma-separated with no spaces**: `X-Forwarded-Groups: dev-team,platform-team,readonly`.
  Split on `,` and trim.
- ~~Group names are the Keycloak group names (`full.path=false`).~~ **Since the follow-up round the mappers
  use `full.path=true`**, so entries are full paths: `/teams/dev-team`, `/readonly`.
- **Order isn't something to rely on.** In the first test the token happened to list three flat groups
  alphabetically. In the follow-up round, `af-readonly-user` (added to `/teams/dev-team`, then `/readonly`)
  got `/teams/dev-team,/readonly`: **not** alphabetical. Treat the header as an unordered set. **"Team = first
  group" breaks.**

### A dedicated team claim

**Keycloak:** yes. Give the user an attribute `team` (for example `dev-team`) and add an
`oidc-usermodel-attribute-mapper` (`user.attribute=team`, `claim.name=team`, access and ID tokens) to both
`agentforge-gateway` and `agentforge-cli`. Every token then carries `"team": "dev-team"`.

**Getting it to AgentForge:** oauth2-proxy's standard flags only forward user, email, groups and preferred
username, so a custom claim needs one of these:

| Option | How | Trade-off |
| --- | --- | --- |
| **A. Team groups under a parent** (no oauth2-proxy change) | Keycloak groups `/teams/dev-team`, `/teams/platform-team`; set `full.path=true` on the groups mapper | Header becomes `/teams/dev-team,/readonly,…`. AgentForge takes the entry starting with `/teams/` and rejects users with zero or several. Simplest. |
| **B. oauth2-proxy alpha config** | Switch to `--alpha-config` with `injectRequestHeaders: [{name: X-Forwarded-Team, values: [{claim: team}]}]` | A clean dedicated header, but the oauth2-proxy config moves to the alpha format |
| **C. App verifies the JWT** | `--pass-access-token=true` again; AgentForge validates the token (JWKS from the issuer) and reads `team` | Most flexible, but AgentForge has to do JWT verification and depends on a stable issuer (Q1) |

Recommendation: **A** for now, because it needs no proxy change and gives one unambiguous team per user.
Move to **B** if more claims are needed. **A is now implemented**; see the
[follow-up round](#4-team-groups-option-a-implemented).

## Q6: Vault dev-mode backups and re-seeding

**Do the backups include the Groq key and the Confluence token? Yes.**
`~/.helmsman-dev/vault-agentforge.json` (mode 600) holds all five paths. On 2026-10-31 these keys were set:

| Path | Keys |
| --- | --- |
| `secret/agentforge/auth` | `cookie_secret`, `keycloak_client_id`, `keycloak_client_secret`, `keycloak_realm`, `keycloak_url` |
| `secret/agentforge/llm` | **`groq_api_key`** |
| `secret/agentforge/confluence` | `confluence_url`, `confluence_email`, **`confluence_api_token`** |
| `secret/agentforge/db` | `database_url`, `postgres_password` |
| `secret/agentforge/cache` | `redis_url` |

**Who re-seeds them after a Vault restart? `dev-up-gemini.sh` Stage 10.5, automatically.** It runs as part
of the normal "after a restart, run dev-up" routine. On 2026-10-30, after a laptop reboot, it logged:

```
[OK] secret/agentforge/llm was missing — restored from backup
[OK] secret/agentforge/confluence was missing — restored from backup
```

How it behaves, and the gaps to know about:

- **Live Vault wins.** dev-up rewrites the backup from Vault on every run, so a key the AgentForge team
  writes into Vault is kept, *after the next dev-up run*.
- **Gap:** if someone updates a key in Vault and Vault restarts **before** dev-up runs again, the update is
  lost and dev-up restores the older backup. After changing a secret, run dev-up once, or write it into the
  backup as well.
- **Between a Vault restart and the dev-up run,** ESO can't refresh, but it keeps the existing Kubernetes
  Secrets, so running pods keep working.
- The backup is **plaintext on the laptop** (mode 600, `~/.helmsman-dev/`). Fine for local dev; not for
  shared or cloud environments. The proper fix is Vault with persistent storage (on the cloud-migration inventory).

## Follow-up round (2026-10-31): labels, api-route, users, teams, timeouts, sanity

The AgentForge team's second set of questions. Everything was tested live. Timeouts and headers were
measured with a throwaway namespace `af-stream-test` (a slow/SSE test server, two copies of oauth2-proxy
v7.7.1 with the production flags, test HTTPRoutes on `helmsman-gateway`), deleted afterwards.

### 1. Pod labels for the narrowed NetworkPolicy

Use these; don't use `pod-template-hash` or the hashed Envoy Deployment name, which change.

| Source | Namespace (`kubernetes.io/metadata.name`) | Pod labels to select | Needs to reach |
| --- | --- | --- | --- |
| oauth2-proxy | `gateway-infra` | `app.kubernetes.io/name: agentforge-oauth2-proxy` | gateway `:8000`, all paths |
| Envoy proxy (data plane) | `envoy-gateway-system` | `app.kubernetes.io/name: envoy`, `app.kubernetes.io/component: proxy`, `gateway.envoyproxy.io/owning-gateway-name: helmsman-gateway`, `gateway.envoyproxy.io/owning-gateway-namespace: gateway-infra` | gateway `:8000`, only for `/health` and `/metrics` (HTTPRoute rule 1) |
| Envoy Gateway controller | `envoy-gateway-system` | `control-plane: envoy-gateway` | **nothing**: it never talks to AgentForge; leave it out |

Narrowed rule (both selectors in **one** `from` entry, so they're ANDed):

```yaml
ingress:
  - from:
      - namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: gateway-infra}}
        podSelector:       {matchLabels: {app.kubernetes.io/name: agentforge-oauth2-proxy}}
      - namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: envoy-gateway-system}}
        podSelector:
          matchLabels:
            app.kubernetes.io/name: envoy
            gateway.envoyproxy.io/owning-gateway-name: helmsman-gateway
    ports: [{port: 8000, protocol: TCP}]
```

Things to know when writing it:

- **NetworkPolicies add up.** Narrowing `agentforge-allow-ingress` isn't enough while
  `agentforge-allow-prometheus` admits the whole `monitoring` namespace on 8000. On the spoke, `monitoring`
  holds **only Promtail** (`app.kubernetes.io/name=promtail`), which ships logs and never scrapes :8000.
  Prometheus runs on the hub and can't reach spoke pod IPs. That policy currently admits nothing useful;
  delete it or scope it to a future spoke Prometheus.
- `agentforge-allow-internal` still lets every `agentforge` pod (worker, Flower, Postgres, Redis) call the
  gateway. Narrow it if only the worker needs to.
- NetworkPolicy can't filter by path. Envoy is allowed on :8000; the HTTPRoute decides that only `/health`
  and `/metrics` go there directly. Stripping identity headers on that rule (Q2 recommendation 2) still
  applies.

### 2. `--api-route=^/v1/` (done)

Added to `platform/oauth2-proxy-agentforge/oauth2-proxy.yaml`. Every AgentForge API route is under `/v1/`
(`agents`, `pipelines`, `jobs`, `search`). Results through the real gateway:

| Request | Before | Now |
| --- | --- | --- |
| `GET /v1/agents`, no token | 302 → Keycloak login | **401** |
| `GET /v1/agents`, invalid/expired bearer | 302 | **401** |
| `GET /v1/agents`, valid bearer | 200 | 200 |
| `GET /` (browser), no session | 302 | 302 (login still works) |

`helmsman-sanity.sh` section K now checks the 401.

### 3. Test users and their exact groups

Created in Keycloak, recreated by `dev-up-gemini.sh` Stage 10.5 after a Keycloak restart (variable
`AF_KC_USERS`), checked by sanity. Passwords are generated once and kept in `~/.helmsman-dev/` (mode 600).

| User | Groups | `X-Forwarded-Groups` received (echo test) | Password file |
| --- | --- | --- | --- |
| `subhankar` | `/teams/dev-team` | `/teams/dev-team` | `keycloak-agentforge-user-password` |
| `af-platform-user` | `/teams/platform-team` | `/teams/platform-team` | `keycloak-af-platform-user-password` |
| `af-readonly-user` | `/teams/dev-team`, `/readonly` | `/teams/dev-team,/readonly` | `keycloak-af-readonly-user-password` |

The other identity headers for each user: `X-Forwarded-Preferred-Username` = the username,
`X-Forwarded-Email` = `<username>@helmsman.dev`, `X-Forwarded-User` = the Keycloak user ID (`sub`).
A forged `X-Forwarded-Groups: /teams/admins` sent with each request was **overwritten**. All three users
get 200 on `GET /v1/agents` through the gateway with an `agentforge-cli` bearer token. Fetch a token the same
way as for subhankar ([above](#fetching-a-test-token-for-subhankar)), with the other username and password file.

The readonly user is in a team **and** `/readonly`, so AgentForge can test "member of dev-team, but may not
run agents" (an AgentForge decision; Helmsman only supplies the groups).

### 4. Team groups (option A, implemented)

Keycloak now has:

```
/readonly
/teams
  /teams/dev-team        ← was the top-level dev-team (moved; members kept)
  /teams/platform-team   ← was the top-level platform-team (moved)
```

Both `agentforge-gateway` and `agentforge-cli` groups mappers now use **`full.path=true`**, so tokens and
`X-Forwarded-Groups` carry full paths. No other Keycloak client uses a groups mapper, so nothing else
changed. dev-up does the migration idempotently: it moves an old flat group under `/teams` if it finds
one, creates missing groups otherwise, and re-aligns a mapper whose config has drifted.

**Rule for AgentForge:** split `X-Forwarded-Groups` on `,`. Team = the **single** entry starting with
`/teams/`, minus the prefix (`dev-team`). Reject the request (403) if there are zero or several. Roles are
other top-level entries (`/readonly`). Never use position.

Why A, not B or C: it needs no oauth2-proxy change and no JWT verification in the app, and it gives one
unambiguous team per user. A new team is one Keycloak group under `/teams` (add it to `AF_KC_GROUPS` in dev-up
so it survives a restart).

### 5. Long runs and SSE: timeouts and buffering

**Measured (before the fix):**

| Path | 10 s | 20 s | 40 s | 70 s | 310 s | SSE (event every 1 s / 10 s) |
| --- | --- | --- | --- | --- | --- | --- |
| Envoy → server (route default) | 200 | **504 at 15 s** | 504 at 15 s | 504 at 15 s | 504 at 15 s | events on time; **stream cut at 15 s** |
| Envoy (route `timeouts.request: 360s`) → server | n/a | 200 | 200 | 200 | **200** | all events; cut at 360 s |
| Envoy (360 s) → oauth2-proxy (default) → server | n/a | 200 | **502 at 30 s** | 502 at 30 s | 502 at 30 s | all events; cut at 360 s |
| Envoy (360 s) → oauth2-proxy `--upstream-timeout=6m` → server | n/a | n/a | 200 | n/a | **200** | n/a |

So there were **two limits**, and both blocked anything longer than 15 s, including today's synchronous
`POST /v1/agents/{id}/run` and `POST /v1/pipelines/run` (they wait for the whole run before replying):

1. **Envoy Gateway's default route timeout: 15 s**, applied to the whole request **including a stream**.
   Fixed in the chart: `httproute.timeouts.request: 360s` on the authenticated rule
   (`apps/agentforge/values.yaml`, `templates/httproute.yaml`).
2. **oauth2-proxy `--upstream-timeout`, default 30 s.** It's the time to wait for the response to *start*,
   so a stream that sends headers at once isn't affected, but a silent 5-minute run is. Fixed:
   `--upstream-timeout=6m`.

**Buffering: none.** Every SSE event arrived at the second it was sent, both directly and through oauth2-proxy
(Go's reverse proxy flushes `text/event-stream` immediately; Envoy streams by default). No change was needed.

**What AgentForge should know:**

- Runs up to **6 minutes** now work as plain synchronous requests. Past that they get a 504.
- **An SSE stream is capped at 360 s in total**, even while events flow, because Gateway API's
  `timeouts.request` covers the whole exchange. For longer streams, raise `httproute.timeouts.request`
  (and `--upstream-timeout` if the first byte can be late), or reconnect with `Last-Event-ID`.
- Send an SSE comment (`: keepalive`) every 15–30 s anyway. It helps clients and any future proxies or load
  balancers (for example an OCI or AWS load balancer's idle timeout, which is often 60 s).
- Send `Cache-Control: no-cache` on SSE responses. If you ever add response compression, exclude
  `text/event-stream`.
- For long work, the async pattern (start job → 202 + job ID → poll `GET /v1/jobs/{id}` or stream it) avoids
  all of this. `store_job` already exists in `pipelines.py`.

### 6. Do the post-restart sanity checks call AgentForge agents?

**Not agents, no.** Before this round, section K checked routing up to oauth2-proxy (`/ping` 200, login
redirect to the current Keycloak) and that the pods were Ready, but never made an authenticated request to
the AgentForge app. It now does that, without running an agent:

| Check (section K) | What it proves |
| --- | --- |
| `GET /v1/agents`, no token → **401** | `--api-route` is active |
| Password-grant token for `subhankar` via `agentforge-cli` | Keycloak, the realm, the client and the user survived the restart |
| `GET /v1/agents` with that bearer → **200** | Envoy → oauth2-proxy (token validation against the current issuer) → AgentForge gateway → app, end to end |
| Groups `/teams/dev-team`, `/teams/platform-team`, `/readonly`; each test user's exact groups; both mappers `full.path=true` | The team model survived the restart |

`GET /v1/agents` is a static list: **no LLM call, no Groq quota used.** Running a real agent is
deliberately **not** in sanity. It takes minutes, spends Groq tokens, and the free tier's 8,000 tokens/minute
limit made phases 3–6 fail with 429s on 2026-10-30, which would make sanity flaky for reasons that aren't
platform faults. The agent-level e2e (`scripts/test_e2e_phase*.py` inside the gateway pod) stays a separate,
manual step after a restart
([how it was run](troubleshooting/laptop-reboot-and-e2e-2026-10-30.md#agentforge-end-to-end-results)).

## Related changes this session

- `agentforge-cli` is recreated by dev-up and checked by sanity.
- `oauth2-proxy.yaml` comments explain which identity headers can be trusted.
- [`cloud-migration-inventory.md`](cloud-migration-inventory.md) and
  [`25-agentforge-chart.md`](25-agentforge-chart.md) were created with the items you asked for.
