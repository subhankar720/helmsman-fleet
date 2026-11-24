# Scripts: what each one does and when to use it

This page covers every script in `scripts/` and `tests/`. The rebuild procedure is in
[bootstrap.md](bootstrap.md), where credentials come from is in [credentials.md](credentials.md),
and dev-up's stages and sanity's sections are in [dev-up-and-sanity.md](dev-up-and-sanity.md).

| I want to… | Run |
| --- | --- |
| Check the platform after a restart or before work | `scripts/helmsman-sanity.sh` |
| Repair it (IP drift, empty Vault, stale config) | `scripts/dev-up-gemini.sh` |
| Build a new pair of clusters from git | `scripts/bootstrap.sh` |
| Save a changed credential into the encrypted seed | `scripts/seed.py diff`, then `scripts/seed.py build` |
| Put the credential files on a new machine | `scripts/seed.py materialise` |
| Check every credential the platform reads | `scripts/seed.py verify` |
| Back up the state git can't recreate (DB, realm, Vault, Argo) | `scripts/snapshot.py take` |
| Restore the AgentForge DB or Vault from a backup | `scripts/snapshot.py restore-db FILE` / `restore-vault FILE` |
| Run the component tests | `tests/run-all.sh` |

## Common rules

- **No credential ever goes on a command line.** Process arguments are visible to every user on
  the machine (`ps`, `/proc/*/cmdline`). The scripts send values over stdin, `--from-file=<(…)`,
  HTTP headers and request bodies instead. A watcher sampled every process's arguments during the
  WO-1.5b rebuilds and found no credential in 224,735 samples. Keep new code to the same rule.
- **Nothing prints a value.** The scripts print names, `present`/`equals` yes or no, lengths,
  counts and short hashes (`sha4` = the first 4 hex characters of the SHA-256).
- **Plaintext never touches the disk** in `seed.py` and `snapshot.py`. sops and age read and
  write through pipes. The only plaintext copies are the mode-600 files in `~/.helmsman-dev/`.
- **Cluster names are a setting.** All scripts follow `CLUSTER_PREFIX` (default `helmsman-`),
  giving clusters `<prefix>hub` / `<prefix>onprem` and contexts `kind-<prefix>hub` /
  `kind-<prefix>onprem`. Use this to build a second pair beside the first, for example
  `CLUSTER_PREFIX=rb-`.

### Settings (environment variables)

| Variable | Default | Read by |
| --- | --- | --- |
| `CLUSTER_PREFIX` | `helmsman-` | all |
| `HUB_CLUSTER_NAME`, `SPOKE_CLUSTER_NAME` | `<prefix>hub`, `<prefix>onprem` | dev-up, sanity, bootstrap |
| `HUB_CTX`, `SPOKE_CTX` | `kind-<hub name>`, `kind-<spoke name>` | seed.py, snapshot.py, bootstrap |
| `HELMSMAN_STATE_DIR` | `~/.helmsman-dev` | all |
| `SOPS_AGE_KEY_FILE` | `$HELMSMAN_STATE_DIR/age.key` | seed.py, snapshot.py `check`/`restore-*`, bootstrap |
| `HELMSMAN_SEED` | `<fleet repo>/secrets.enc.yaml` | seed.py |
| `ARGO_SPOKE_NAME` | `helmsman-onprem` | dev-up: the spoke's name **inside Argo CD**. It stays `helmsman-onprem` with any prefix, because Applications name it as their destination. |
| `HUB_HOST_PORT_ARGOCD`, `HUB_HOST_PORT_GRAFANA` | `8080`, `30030` | dev-up (`--reset`/`--bootstrap`): host ports of the hub's kind config. Change them to run two pairs at once. |
| `ARGOCD_VERSION` | `v3.5.2` | dev-up: Argo CD install manifest (pinned; it used to follow the moving `stable` branch) |
| `FLEET_DIR`, `OPERATOR_DIR` | found from the script's location | dev-up, bootstrap |
| `ARGO_MIN_APPS`, `ARGO_WAIT_SECONDS` | `16`, `1500` | bootstrap `argo-wait` |

`scripts/dev-up-gemini.sh --print-config` prints the settings it resolved, then exits without
touching anything.

## `scripts/bootstrap.sh`: build a pair from git

Builds a working pair from a clean checkout of `helmsman-fleet` and `helmsman-operator` side by
side, plus the age private key. Nothing else is needed. See [bootstrap.md](bootstrap.md).

```bash
./scripts/bootstrap.sh                          # helmsman-hub / helmsman-onprem
CLUSTER_PREFIX=rb- ./scripts/bootstrap.sh       # a second pair: rb-hub / rb-onprem
./scripts/bootstrap.sh --allow-existing         # re-run on clusters that already exist
```

| Step | What it does |
| --- | --- |
| `preflight` | Tools present; the age key exists and is mode 600; the seed and operator checkout exist; Docker is running. **Refuses if the clusters already exist** unless `--allow-existing`. |
| `materialise` | `seed.py materialise`: writes the credential files into the state dir. Files already there are kept. |
| `operator-tools` | `make kustomize` in the operator checkout, if `bin/kustomize` is missing |
| `dev-up` | `dev-up-gemini.sh --bootstrap`: create the clusters, Argo CD, spoke registration, platform Applications, the operator image and platform state |
| `seed-apply` | `seed.py apply`: seed → Vault (fills only what is missing) and the Secrets that come only from the seed |
| `argo-wait` | every Argo CD Application Synced and Healthy, and at least `ARGO_MIN_APPS` of them |
| `seed-verify` | `seed.py verify` |
| `sanity` | `helmsman-sanity.sh` (0 failures required) |

- **Logging:** each step writes one line (start, seconds, exit code) to
  `$HELMSMAN_STATE_DIR/bootstrap.log`. The full output goes to
  `$HELMSMAN_STATE_DIR/bootstrap-<UTC time>.out` (mode 600).
- **Safe to repeat:** it never deletes anything, so running it again repairs or re-checks.
- **Exit codes:** it stops at the first failed step, with exit 1 and the name of that step.

## `scripts/seed.py`: the encrypted seed

`secrets.enc.yaml` (repo root) holds every credential the platform needs, encrypted with sops to
the age public key in `.sops.yaml`. Key names are readable; values are not. The layout and the
list of what is and isn't in it are in [credentials.md](credentials.md#the-encrypted-seed).

| Command | Use it when | What it does |
| --- | --- | --- |
| `seed.py diff` | before `build`, or to see if your machine and the seed disagree | per entry: `same`, `differs`, `missing-in-state` or `missing-in-seed` |
| `seed.py build [--dry-run]` | you changed or added a credential file | re-encrypts the whole seed from the state dir and lists what changed (with lengths). **Commit `secrets.enc.yaml` afterwards.** |
| `seed.py materialise [--force]` | new machine, or a file was lost | writes the seed's files into the state dir (mode 600). It keeps existing files; `--force` rewrites the ones that differ. |
| `seed.py apply [--overwrite]` | Vault was emptied, or a seed-made Secret is missing | fills `secret/agentforge/*` in Vault (`--overwrite` replaces existing values) and server-side applies the Secrets listed below |
| `seed.py verify` | after a rebuild, a rotation or a restore | checks every Vault path and property that an ExternalSecret, an AppDeployment or the seed refers to, plus every seed-made Secret and state file: present? equals the seed? **Exit 1 on any "no".** |

Secrets that `apply` makes from the seed (field manager `helmsman-seed`):

| Cluster | Secret | From |
| --- | --- | --- |
| hub | `vault/vault-root-token` | `vault-root-token`, read by the Vault Deployment at start |
| spoke | `external-secrets/vault-token` | `vault-root-token`, used by ESO |
| hub | `keycloak/keycloak-admin-credentials` | `keycloak-admin-password` |
| hub | `monitoring/grafana-admin-credentials` | `grafana-admin-password` |
| spoke | `agentforge/ghcr-pull-secret`, `kyverno/ghcr-pull-secret` | `ghcr-pull-secret.json` |

**Not in the seed:**
- the age key itself;
- `dev-up.log`, `last-dev-up`, and `*.log`, `*.out`, `*.tmp` files;
- `vault-agentforge.json`, which `materialise` writes from the seed's `vault` section;
- human-held items: the GitHub PAT, and `helmsman-operator.env`. These stay with the person who owns them.

`keycloak_url` in `secret/agentforge/auth` is rewritten by dev-up to the current hub IP, so
`verify` checks that it is present but not that it equals the seed.

## `scripts/snapshot.py`: encrypted backups of runtime state

Saves the state that neither git nor the seed can recreate. Each file is encrypted to the age
public key in `.sops.yaml`, so taking a snapshot needs no private key, but `check` and the
restores do. Files go to `~/.helmsman-dev/snapshots/<UTC date>/<name>-<HHMMSSZ>.<ext>.age`
(files mode 600, directory mode 700).

| Snapshot | Contents |
| --- | --- |
| `agentforge-db` | `pg_dump -Fc` of the AgentForge database (ingested Confluence chunks, audit runs, quotas) |
| `keycloak-realm` | the `helmsman` realm: clients with their real secrets, groups, roles, and users with their groups and roles. Password hashes are excluded; passwords are in the seed. |
| `vault-kv` | every path under `secret/`, with data and version |
| `argo-apps` | Applications, ApplicationSets and AppProjects as JSON |

| Command | Use it when |
| --- | --- |
| `snapshot.py take [--only agentforge-db,vault-kv]` | before anything risky: a rotation, a rebuild test, a Vault or Keycloak restart |
| `snapshot.py check [DIR]` | to prove a snapshot can be decrypted and read: prints size, hash and counts (tables, clients, paths), never content |
| `snapshot.py restore-db FILE` | the AgentForge DB was lost or a fresh pair needs data without re-ingesting: `pg_restore --clean --if-exists` into the spoke Postgres. On a fresh pair it takes about 1 s; the alternative is the ingest CronJob, which re-reads Confluence. |
| `snapshot.py restore-vault FILE [--overwrite]` | Vault lost data that the seed and dev-up don't hold (for example `secret/apps/*`). The default writes only missing paths; `--overwrite` replaces them all. |

Snapshots hold credentials (Vault data, Keycloak client secrets). **Never commit or share them.**
Keep them under `~/.helmsman-dev/`.

## `scripts/helmsman_lib.py`

Shared code for `seed.py` and `snapshot.py`, standard library only:
- cluster contexts and the state dir from the settings above;
- `PortForward`: `kubectl port-forward` on a free local port, as a context manager;
- `http()`: JSON over HTTP; errors are returned, not raised;
- `Vault`: KV v2 at `secret/` through a port-forward, with the token in the `X-Vault-Token` header.

Use it rather than calling `vault` or `curl` with a token argument. In Vault's CPU-limited pod
the `vault` CLI also takes about 4 s to start.

## `scripts/dev-up-gemini.sh`: repair, reset, bootstrap

Two copies that must stay byte-identical: this one and `helmsman-operator/dev-up-gemini.sh`.
The stages are in [dev-up-and-sanity.md](dev-up-and-sanity.md#dev-up-stages).

| Mode | Use it when |
| --- | --- |
| (no flag) | after any restart, or whenever sanity reports a failure. It never deletes. |
| `--bootstrap` | called by `bootstrap.sh`: creates the named clusters if they are missing, then installs everything. It never deletes, and it refuses to be combined with `--reset`. |
| `--reset` | deletes and rebuilds the named clusters. **Destructive**, and almost never needed now that `--bootstrap` exists. |
| `--print-config` | to see which names, ports and paths it would use |

What changed in WO-1.5b:
- **Names and ports are settings**, from the table above.
- **No credential on a command line:**
  - Secrets are created with `--from-file=<key>=<(printf …)`;
  - the Argo CD login uses the session API, with the token in `ARGOCD_AUTH_TOKEN`;
  - the Vault token goes to pods on stdin.
- **New `ensure_vault_root_secret`:** writes the hub Secret `vault/vault-root-token` and reads it back.
- **`--bootstrap` sets the Argo CD admin password** to the seed's value (Stage R4).
- **Fixes the rebuild test found:**
  - a Stage 10.5 check no longer ends the run when a workload isn't deployed yet;
  - Stage 10 syncs sample-app without `--force`, which Argo rejects with server-side apply.

## `scripts/helmsman-sanity.sh`: report only

It never changes anything, but takes the same name settings as dev-up. WO-1.5b changes:
- names come from `CLUSTER_PREFIX`;
- passwords and tokens go over stdin and request bodies, not arguments;
- `ARGOCD_PASS_FILE` follows `HELMSMAN_STATE_DIR`.

It exits 0 with warnings and 1 on a failure; `--strict` fails on warnings too.

## `scripts/test-onboarding-flow.sh`

The end-to-end onboarding flow test. It **writes to the clusters**, so run it deliberately.
WO-1.5b changed only its names (from the prefix) and its credential handling (tokens and
passwords in headers and bodies).

## `tests/run-all.sh` and `tests/component/`

`tests/run-all.sh` runs the component tests in order and exits non-zero if any fails.
Contexts come from `tests/lib/wait.sh`, which follows `CLUSTER_PREFIX`.
On a fresh pair it takes about 6 minutes.

| Test | Checks |
| --- | --- |
| `operator-rbac.sh` | the operator may bind exactly the predefined ClusterRoles, nothing broader |
| `accessgrant.sh` | AccessGrant lifecycle: Pending → Active → Expired; the RoleBinding is created and removed |
| `agentforge-ingress-probe.sh` | the AgentForge gateway accepts traffic only from the two sources its NetworkPolicy allows (oauth2-proxy, the Envoy proxies); pods with forged labels are refused |
| `appdeployment-lifecycle.sh --variant A` / `--variant B` | an AppDeployment copied from the live `sample-app` one creates its Keycloak client, Vault credentials, ExternalSecret and StatefulSet, then everything is removed when the AppDeployment (A) or its namespace (B) is deleted. `sample-app` itself must be unchanged. |

The lifecycle test needs the `sample-app` AppDeployment. Argo CD delivers it from
`appdeployments/` through the Application `platform-appdeployments`.
