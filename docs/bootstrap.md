# Rebuilding the local platform from git

A complete pair of kind clusters can be rebuilt from three things:
1. a clone of `helmsman-fleet`;
2. a clone of `helmsman-operator`, next to it;
3. the **age private key**.

Everything else comes from git:
- the scripts and manifests;
- the encrypted seed `secrets.enc.yaml`, which holds every credential.

WO-1.5b proved this. A build from fresh GitHub clones plus the key, with no manual step, took
13.8 minutes on the WSL2 laptop. It then passed sanity (0 failures), `tests/run-all.sh`, the
AgentForge E2E phases 1–2 and the sample-app login.

What each script does is in [scripts.md](scripts.md). Where each credential comes from is in
[credentials.md](credentials.md).

## Before you start

- **Tools:** `docker`, `kind`, `kubectl`, `argocd`, `age`, `sops`, `python3`, `git`, `make`, `go`,
  `curl`, `jq`, `nc`. `bootstrap.sh` checks for them first.
  - Tested with age v1.2.1 and sops v3.10.2, both in `~/.local/bin`.
- **The age key:** at `~/.helmsman-dev/age.key`, mode 600, or point `SOPS_AGE_KEY_FILE` at it.
  [The age key](#the-age-key) below covers where it is backed up.
- **Memory:** about 7 GB free for one pair.
  - A second pair beside the first also needs different host ports (`HUB_HOST_PORT_ARGOCD`,
    `HUB_HOST_PORT_GRAFANA`), or the first pair stopped.
- **Network:** internet access. Argo CD and dev-up read the fleet repo from GitHub, and the images
  come from public registries and GHCR.
- **Keep the machine awake.** A suspended laptop pauses the clusters mid-build; bootstrap's
  25-minute wait then fails.

## Build

```bash
git clone https://github.com/subhankar720/helmsman-fleet.git
git clone https://github.com/subhankar720/helmsman-operator.git
cd helmsman-fleet
./scripts/bootstrap.sh                       # clusters helmsman-hub / helmsman-onprem
```

- **A pair under other names:** use `CLUSTER_PREFIX=rb- ./scripts/bootstrap.sh`.
- **A separate state folder:** add `HELMSMAN_STATE_DIR=~/.helmsman-rb` (put the age key in it
  first), so the new pair doesn't share `~/.helmsman-dev`.
- **Existing clusters:** bootstrap refuses to run on clusters that already exist. Use
  `--allow-existing` to re-check a pair it built.

Typical timings (attempt 5 of the WO-1.5b test):

| Step | Seconds |
| --- | --- |
| preflight, materialise, operator-tools | 9 |
| dev-up `--bootstrap` (clusters, Argo CD, platform, operator image) | 606 |
| seed-apply | 5 |
| argo-wait (all Applications Synced/Healthy) | 95 |
| seed-verify | 4 |
| sanity | 108 |
| **total** | **827** |

### After the build

The build does not load the AgentForge database. Either:

- **restore it from a snapshot** (about 1 s; no Confluence access needed):
  `python3 -I scripts/snapshot.py restore-db ~/.helmsman-dev/snapshots/<date>/agentforge-db-<time>.pgdump.age`
- **or re-ingest** by running the `agentforge-ingest` CronJob as a Job. This reads Confluence again.

Then check:

```bash
./tests/run-all.sh                                           # about 6 min
kubectl -n agentforge exec deploy/agentforge-gateway -- sh -c 'cd /app && python scripts/test_e2e_phase1.py'
kubectl -n agentforge exec deploy/agentforge-gateway -- sh -c 'cd /app && python scripts/test_e2e_phase2.py'
```

Phase 1 makes one small real LLM call (Groq).

**Known warning on a fresh pair.** Sanity may warn "oauth2-proxy config changed since it last
started (or was never recorded)". dev-up Stage 10.5 ran before oauth2-proxy finished its first
(retried) sync, so the config fingerprint was never recorded. Login works. A plain
`./scripts/dev-up-gemini.sh` run records it.

## What the build depends on: lessons from the rebuild test

A long-lived pair hides gaps that a fresh pair exposes. The WO-1.5b test took five attempts. Each
failure was fixed in git, and then the pair was deleted and rebuilt:

| Gap | Fix now in git |
| --- | --- |
| A dev-up readiness check ended the run (`set -euo pipefail`) when a workload wasn't deployed yet | dev-up tolerates it |
| Kyverno pins each signed image to its digest at admission, which a client-side diff reports as permanent drift | ApplicationSet template: `ServerSideApply=true` and `compare-options: ServerSideDiff=true`, as `agentforge` has |
| `argocd app sync --force` is refused with server-side apply | dev-up syncs without `--force` |
| A first sync ran before ESO's webhook was up, or before Vault had data. The ExternalSecret failed, its workload in the same wave never became healthy, and Argo waited forever. | Vault-backed ExternalSecrets are in `sync-wave: "-1"`, and the Applications have an explicit `retry` |
| The `sample-app` AppDeployment existed only because it was once applied by hand | Argo CD Application `platform-appdeployments` delivers `appdeployments/` |

**Rule of thumb:** anything that exists on the old pair but can't be traced to git or the seed is
a rebuild gap. To find gaps, run a rebuild under another prefix.

### platform-root does not manage itself

`platform/root/argocd-application.yaml` (the app-of-apps) is applied by dev-up `--reset` and
`--bootstrap` (Stage R7) and is not owned by any Application. Changes to its own spec, such as a
new entry in its `include` list, reach a **running** pair only when you apply it:

```bash
kubectl --context kind-helmsman-hub apply -f platform/root/argocd-application.yaml
```

It has prune off and no resources-finalizer, so applying it can add children but never deletes
one.

## The age key

The seed (`secrets.enc.yaml`) and every snapshot are encrypted to the age public key in
`.sops.yaml`. **Without the private key, none of them can be decrypted.** Only the public key is
in git.

### Backup

- **Where it lives:** the key is one line, `~/.helmsman-dev/age.key`, mode 600. It is never
  printed, logged or committed.
  - gitleaks has a rule for it (`age-secret-key` in `.gitleaks-tree.toml`, and in the default
    rules), so an accidental commit fails CI.
- **Keep one copy off this machine,** in a password manager, as a secure note or attachment. The
  owner confirmed that backup on 23 Nov 2026.
- **Test the backup** after storing it. On another machine, or in a temporary directory, decrypt
  the seed's metadata without printing values:

  ```bash
  SOPS_AGE_KEY_FILE=/path/to/restored.key python3 -I scripts/seed.py verify   # needs the clusters
  # or, offline: decrypt to /dev/null; exit 0 means the key works
  SOPS_AGE_KEY_FILE=/path/to/restored.key sops --disable-version-check -d secrets.enc.yaml > /dev/null && echo key-ok
  ```

### Rotation (planned key change)

Do this when someone who had the key leaves, or on a schedule. Tested on a copy of the seed
(WO-1.5b): afterwards only the new key decrypts it.

1. Make a new key next to the old one:
   `age-keygen -o ~/.helmsman-dev/age.key.new && chmod 600 ~/.helmsman-dev/age.key.new`.
   Its public key is the `# public key:` line inside the file.
2. Replace the old public key in `.sops.yaml` with the new one.
3. Re-encrypt the seed's data key to the new recipient, **using the old key** to read it:
   ```bash
   SOPS_AGE_KEY_FILE=~/.helmsman-dev/age.key sops --disable-version-check updatekeys -y secrets.enc.yaml
   mv ~/.helmsman-dev/age.key ~/.helmsman-dev/age.key.old
   mv ~/.helmsman-dev/age.key.new ~/.helmsman-dev/age.key
   python3 -I scripts/seed.py diff             # all "same": the new key reads the seed
   ```
   - Don't use `seed.py build` for this step. It rewrites the seed only when a value changed, so a
     recipient change alone gives "no change: seed not rewritten".
4. **Re-encrypt the snapshots** you want to keep:
   `age -d -i ~/.helmsman-dev/age.key.old FILE.age | age -r NEW_PUBLIC_KEY -o FILE.new.age`.
   Or take new snapshots (`snapshot.py take` uses the recipient in `.sops.yaml`) and delete the
   old ones.
5. Commit `.sops.yaml` and `secrets.enc.yaml`. Back up the new key and test the backup. Then
   destroy `age.key.old` (`shred -u`) and its backup copies.

The old seed versions in git history are still encrypted to the old key. That is fine for a
planned rotation, as long as the old key is destroyed.

### If the key is lost

The seed and the snapshots can no longer be decrypted. The credentials still exist in two places:
- the running clusters;
- `~/.helmsman-dev/` on any machine with a working state dir.

1. On a machine whose `~/.helmsman-dev/` still has every credential file
   ([credentials.md](credentials.md) lists them), make a new key as `~/.helmsman-dev/age.key`
   (Rotation step 1) and put its public key in `.sops.yaml`.
2. Move the unreadable seed aside, so that `build` doesn't try to decrypt it. Then build a new one
   from the state dir:
   ```bash
   mv secrets.enc.yaml /tmp/secrets.enc.yaml.unreadable
   python3 -I scripts/seed.py build            # lists every entry as "added"
   python3 -I scripts/seed.py verify           # with the clusters running
   ```
   Commit, back up the new key, and delete the moved file. (This path was not exercised in
   WO-1.5b.)
3. If no state dir survives, recreate each credential ([credentials.md](credentials.md) lists them
   and how each is rotated), then build as above.
4. Old snapshots are lost. Take new ones.

### If the key is leaked (or may have been)

**Treat every credential in the seed as exposed.** Anyone with the key can decrypt every version
of `secrets.enc.yaml` in git history.

1. Rotate the key (above), and destroy the leaked one.
2. **Rotate every credential in the seed,** one by one, as [credentials.md](credentials.md#rotating-a-credential)
   describes:
   - the Argo CD, Keycloak and Grafana admin passwords;
   - the Vault root token;
   - the AgentForge user passwords;
   - the Keycloak client secrets;
   - the cosign key;
   - the GHCR token and the acme-dns registration;
   - the AgentForge values in Vault (Groq API key, Confluence token, DB password, cookie secret).
3. Then `seed.py build`, commit, and take new snapshots. Delete the old snapshots; they were
   readable with the leaked key.
