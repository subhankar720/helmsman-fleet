# AgentForge schema handoff — `init.sql` from the AgentForge repo to the cluster

PWP-1 item 1.3. How a database schema change travels from AgentForge to the running Postgres on the
spoke, who does each step, how success is checked and reported, and how to roll back.

| | |
|---|---|
| **Source of truth** | `infra/sql/init.sql` in `github.com/subhankar720/agentforge` (branch `main`) |
| **Copy deployed** | `apps/agentforge/files/init.sql` in this repo (`helmsman-fleet`) |
| **How it is applied** | ConfigMap `agentforge-postgres-init` (from `files/init.sql`) → Job `agentforge-db-migrate` (`psql -v ON_ERROR_STOP=1 -f /sql/init.sql`), an Argo CD hook of Application `agentforge` |
| **When it runs** | Only when Argo CD performs a **sync operation** of `agentforge`, i.e. after a commit that changes the rendered chart. A refresh with nothing to sync does not run it. |
| **Owner of the copy** | The Helmsman platform side (whoever operates `helmsman-fleet`; today the Helmsman chat via Claude Code). AgentForge owns the SQL. |
| **Interim** | Manual copy until AgentForge CI opens the PR automatically (a later work order). |

## Rules for the SQL (AgentForge's side)

1. **Idempotent.** The whole file is re-applied on every sync: `CREATE … IF NOT EXISTS`,
   `ALTER TABLE … ADD COLUMN IF NOT EXISTS`, `INSERT … ON CONFLICT DO NOTHING`. A statement that fails on
   the second run fails every later sync.
2. **Additive only** (new tables, new nullable columns, new indexes). `DROP`, `RENAME` and type changes
   need a separate, explicitly agreed plan: `git revert` of the copy does **not** undo SQL that has
   already run (see Rollback).
3. **Code that needs a new column ships after the column exists.** Until PWP-1 item 1.2 lands, the
   migration runs *after* new pods roll (PostSync), so the schema change must be merged and verified
   *before* the code change. Once 1.2 is done, both can ship in one commit (this document is updated then).

## Procedure

### 1. AgentForge asks
AgentForge sends (chat or issue): the AgentForge commit SHA that changed `infra/sql/init.sql`, a one-line
summary of the change, and whether any application change depends on it.

### 2. Copy (Helmsman)
```bash
cd ~/projects/agentforge && git fetch origin                 # read-only: never edit the AgentForge repo
cd ~/projects/helmsman/helmsman-fleet && git pull --ff-only
git -C ~/projects/agentforge show <sha>:infra/sql/init.sql > apps/agentforge/files/init.sql
git diff --stat                                    # only apps/agentforge/files/init.sql
git diff apps/agentforge/files/init.sql            # read it: idempotent? additive only?
git -C ~/projects/agentforge show <sha>:infra/sql/init.sql | sha256sum; sha256sum apps/agentforge/files/init.sql   # must match
```
Stop and send it back to AgentForge if the diff contains a non-idempotent or destructive statement.

### 3. Preview what Argo CD will change
```bash
helm template agentforge apps/agentforge -n agentforge -f apps/agentforge/values-helmsman-onprem.yaml > /tmp/after.yaml
git stash && helm template agentforge apps/agentforge -n agentforge -f apps/agentforge/values-helmsman-onprem.yaml > /tmp/before.yaml && git stash pop
diff /tmp/before.yaml /tmp/after.yaml   # expect: only ConfigMap agentforge-postgres-init data, nothing else
```

### 4. Commit and push (the push is the deployment)
```bash
git add apps/agentforge/files/init.sql
git commit -m "chore(agentforge): sync init.sql from agentforge@<short-sha> — <summary>"
git push origin main
```
Argo CD polls the repo (about every 3 minutes) and syncs automatically (prune + self-heal).

### 5. Verify — within 10 minutes (the Job is deleted 600 s after it finishes)
```bash
H=--context=kind-helmsman-hub; S=--context=kind-helmsman-onprem
# a) Argo synced the new commit and the hook succeeded
kubectl $H -n argocd get application agentforge \
  -o jsonpath='{.status.sync.revision} {.status.sync.status} {.status.health.status} {.status.operationState.phase}{"\n"}'
kubectl $H -n argocd get application agentforge -o json | python3 -c 'import json,sys
o=json.load(sys.stdin)["status"]["operationState"]
print(o["phase"], o["startedAt"], o["finishedAt"])
[print(" ", r["kind"], r["name"], r.get("hookPhase"), r.get("message","")) for r in o["syncResult"]["resources"] if r["kind"]=="Job"]'
# b) the Job completed — save its log NOW
kubectl $S -n agentforge get job agentforge-db-migrate \
  -o jsonpath='start={.status.startTime} done={.status.completionTime} succeeded={.status.succeeded} failed={.status.failed}{"\n"}'
kubectl $S -n agentforge logs job/agentforge-db-migrate > migrate-$(date -u +%Y%m%dT%H%MZ).log
grep -E 'ERROR|FATAL' migrate-*.log || echo "no errors"
# c) the change is in the database (read-only; credentials come from the pod's own environment)
kubectl $S -n agentforge exec agentforge-postgres-0 -- sh -c \
  'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "\d <table>"'
# d) the app is still healthy
kubectl $S -n agentforge get pods
```
Success = revision is the new commit, `Synced Healthy Succeeded`, Job `succeeded=1` with no `ERROR` lines,
the object exists in `\d`, all pods Ready.

If the Job fails: the Job retries its pod up to `backoffLimit: 6`, then the hook and the sync operation are
marked Failed. No sync `retry` policy is configured on `agentforge`, so do not expect Argo CD to re-run the
same commit by itself (not yet observed on this app). Capture `kubectl logs` immediately and go to Rollback.

### 6. Report back to AgentForge
One message:
```
schema handoff: agentforge@<sha> → helmsman-fleet@<sha>
Argo operation: <phase> <startedAt>–<finishedAt>; Job agentforge-db-migrate: succeeded=<n> (<start>–<done>)
migration log: no ERROR lines (attached / excerpt)
verified in DB: <\d output line(s) for the new object>
pods: all Ready
```

## Rollback

- **The copy:** `git revert <commit>` and push; Argo CD syncs the previous `init.sql` and the Job re-runs it.
- **The database:** reverting the copy does **not** undo SQL that already ran (`CREATE … IF NOT EXISTS`
  just skips on the next run). A new nullable column is harmless to old code, so the usual answer is to
  leave it. If an object must go, AgentForge supplies the reverse SQL and it is applied as a new, reviewed
  change through this same procedure — never by hand with `psql`.
- **The app:** if pods are unhealthy after a schema push, revert first, then investigate (`git revert`,
  push, check `Synced Healthy`).

## Record of runs

| Date | AgentForge SHA | Fleet SHA | Change | Result |
|---|---|---|---|---|
| 2026-11-05 | `ac01b80` (unchanged) | see WO-P1.B outcome | Dry run: comment-only change to the copy (WO-P1.B) | see WO-P1.B outcome |
