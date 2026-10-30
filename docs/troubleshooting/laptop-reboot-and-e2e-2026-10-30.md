# Laptop reboot recovery and end-to-end test run

Date: 2026-10-30
Cluster: `kind-helmsman-hub` / `kind-helmsman-onprem`

The recovery itself was clean, and nothing needed hand-fixing. The only failures came from the AgentForge
end-to-end tests, all caused by the **Groq free tier's 8,000 tokens-per-minute limit**.

| Step | Result |
| --- | --- |
| `./scripts/dev-up-gemini.sh` | `BOOTSTRAP COMPLETED SUCCESSFULLY` |
| `./scripts/helmsman-sanity.sh` | 110 passed, 1 failed (a flaky Loki check, now fixed), 12 warnings (restart counts from boot) |
| `tests/run-all.sh` (operator component tests) | 19 / 19 passed |
| AgentForge e2e phases 1–6 (`/app/scripts/test_e2e_phase*.py`) | Phases 1–2 all passed. Phases 3–6 failed on Groq 429s. |

## What the reboot changed, and what dev-up did about it

All five kind nodes came back with network endpoints, and the hub kept host port 8080 (the
[proposal-automation remap](hub-control-plane-reboot-2026-10-24.md#issue-2-host-port-8080-taken-by-another-project)
held). The IPs reshuffled:

| Node | Before | After |
| --- | --- | --- |
| hub-control-plane | 172.18.0.6 | 172.18.0.4 |
| hub-worker | 172.18.0.2 | 172.18.0.2 |
| onprem-control-plane | 172.18.0.3 | 172.18.0.5 |
| onprem-worker | 172.18.0.4 | 172.18.0.6 |

This was the first real reboot since the restart detection, Vault/Keycloak restore and kindnet
changes were added, and all of them worked:

- **Stage 1.** Docker Desktop had already restarted all five nodes. Every one started after
  `~/.helmsman-dev/last-dev-up`, so dev-up treated it as a Docker restart. Before this change it
  would have skipped network and Argo CD recovery.
- **Stage 3–4.** kube-proxy, kindnet and CoreDNS were restarted on both clusters (the kindnet 1-CPU limit
  was already in place), then argocd-redis, argocd-server and the applicationset-controller.
- **Stage 5.** Spoke IP drift `172.18.0.3 → 172.18.0.5` was repaired, and `platform-spoke-promtail`
  re-pointed.
- **Stage 10.5.** All five `secret/agentforge/*` paths were restored from backup. Keycloak's groups, the
  `agentforge-gateway` client and user `subhankar` were recreated. The user got the **same** password
  as before, from `~/.helmsman-dev/keycloak-agentforge-user-password`. All five AgentForge workloads were ready.

## Sanity: restart warnings are from boot, not crash-loops

The 12 "high restarts" warnings all last exited between 02:08 and 02:10 UTC, while the nodes booted. None
restarted in the following 11 minutes.

| Exit | Pods | Cause |
| --- | --- | --- |
| 255 (Unknown) | Kyverno, Envoy Gateway, agentforge-postgres, ESO webhook | killed by the node restart |
| 1 (Error) until ~02:10 | oauth2-proxy, sample-app `adc`, ESO controller | Keycloak and Vault were empty until Stage 10.5 restored them |

## Fixed: flaky Loki `/ready` check

**Symptom**

Sanity failed with `Loki /ready NOT reachable`, while `platform-loki-0` was 2/2 Ready and `/ready`
returned 200 by hand. A `loki-health-check` pod was left behind as Completed. The same thing happened
after the 2026-10-24 reboot.

**Root cause**

`kubectl run --rm -i` can lose the container's output when the attach races a fast container. Loki
also answers "not ready" for a short while after a restart.

**Fix**

`helmsman-sanity.sh` section J tries up to 3 times, each with a fresh pod name, and cleans up any
leftover probe pod.

## AgentForge Phase 7 changes verified

- **The database schema now comes from `files/init.sql`.** The tables are `audit_runs`,
  `document_chunks`, `jobs` and `team_quotas`. The gateway logged no `UndefinedTable` errors, which
  closes the `audit_runs` item in [agentforge-chart-deploy](agentforge-chart-deploy-2026-10-24.md).
- **The `agentforge-ingest` CronJob is admitted by Kyverno, but suspended** (`suspend: true`), so it
  won't run on its `0 2 * * *` schedule. The manual `ingest-now` Job completed earlier, and search
  reports 1,614 chunks indexed.

## AgentForge end-to-end results

The tests ran inside the gateway pod (`python scripts/test_e2e_phaseN.py` against `localhost:8000`):

```
kubectl --context kind-helmsman-onprem -n agentforge exec deploy/agentforge-gateway -- \
  sh -c 'cd /app && python scripts/test_e2e_phase1.py'
```

They make real Groq calls. `confluence_page_creator` is a mock (`is_mock=True`), so Phase 5 publishes
nothing to Confluence.

| Phase | Result | Notes |
| --- | --- | --- |
| 1: health, guardrails, LLM, audit | **15/15** | Postgres, Redis and LLM ok; injection blocked; PII redacted; tokens and cost tracked; audit write |
| 2: agents | **9/9** | PlannerAgent and CodeGenAgent completed; unknown agent → failed; HITL endpoint works |
| 3: pipelines | 10/12 | `plan_only` ok; `sdlc_partial` failed (429) |
| 4: SDK and CLI | 6/10 | SDK agent run and pipeline failed (429); "Expected 4, got 9" agents is a stale expectation in the test |
| 5: full SDLC | 12/15 | all 8 agents registered; `sdlc_full` and `deploy_only` failed (429) |
| 6: IntelliSearch | 10/11 | 1,614 chunks, sessions, answers and follow-ups ok; one run reported no tokens (429) |

### Root cause of the failures: Groq tokens-per-minute limit

```
model_router.invoke_failed  error=Error code: 429 - Rate limit reached for model `openai/gpt-oss-120b`
  … service tier `on_demand` on tokens per minute (TPM): Limit 8000, Used 6978, Requested 1032
```

One `plan_only` run uses about 4,200 tokens, so a 4-agent `sdlc_partial` needs roughly 16,000, which is
twice the per-minute limit. Running phase 3 again on its own, after the quota had reset, failed the same
way: `plan_only` completed (4,194 tokens), then `sdlc_partial` was refused immediately. The model router
retries for only about 7 seconds, but the quota takes up to a minute to free up.

This is not a platform or deployment problem. Fixing it needs one of these, all on the AgentForge team's side:

- The model router honours `Retry-After` / backs off for up to 60 s on a TPM 429.
- A higher Groq tier, or a different `AGENTFORGE_MODEL_BACKEND` for pipeline runs.
- The phase 4 test updated to expect 9 agents.

### Also noted for the AgentForge team

The app reads `AGENTFORGE_HITL_AUTO_APPROVE` (`config/settings.py`), but the chart sets
`HITL_AUTO_APPROVE`, which has no effect. The default `false` (approval required) is what applies, which
is the safe setting, but the chart's value is ignored.
