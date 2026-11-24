# Credentials for the local kind platform

No script or manifest in `helmsman-fleet` or `helmsman-operator` holds a credential **value**.
That has been true since WO-1.5a. WO-1.5b removed the last exception, the Vault dev root token.

Every credential lives in three layers:

1. **The encrypted seed** `secrets.enc.yaml` (repo root, committed). This is the source of
   truth for a rebuild. It is encrypted with sops to the age public key in `.sops.yaml`; the
   private key is `~/.helmsman-dev/age.key` and is never committed. See [bootstrap.md](bootstrap.md#the-age-key).
2. **The state dir** `~/.helmsman-dev/` (`$HELMSMAN_STATE_DIR`). One mode-600 file per
   credential, holding just the value with no trailing newline. `seed.py materialise` writes it
   from the seed; `seed.py build` writes the seed from it. Scripts read only this layer.
3. **The clusters:** Secrets and Vault, written from the state dir by dev-up and by
   `seed.py apply`.

`dev-up-gemini.sh` checks the state-dir files it needs **before it touches a cluster**. If one is
missing, it stops with exit 2, names the variable and the file, and changes nothing. An
environment variable of the same name overrides the file.

**No credential goes on a command line.** The scripts use stdin, `--from-file=<(…)`, HTTP
headers and request bodies instead. See [scripts.md](scripts.md#common-rules).

## What each credential is for

| Credential | Variable | File in `~/.helmsman-dev/` | Used by |
| --- | --- | --- | --- |
| Argo CD `admin` password | `ARGOCD_PASS` | `argocd-admin-password` | dev-up Stage 9 login, sanity. `--bootstrap` sets Argo CD's password to this value (Stage R4). `--reset` without the file saves Argo CD's random initial one here. |
| Keycloak master-realm admin password | `KEYCLOAK_ADMIN_PASS` | `keycloak-admin-password` | hub `keycloak/keycloak-admin-credentials`, read by Keycloak on first start. Also `helmsman-platform-config` in each spoke namespace, and dev-up Stage 10.5. |
| Vault dev-mode root token | `VAULT_TOKEN` | `vault-root-token` | hub `vault/vault-root-token`, which the Vault Deployment reads at start (`VAULT_DEV_ROOT_TOKEN_ID`); spoke `external-secrets/vault-token` for ESO; `helmsman-platform-config` in each spoke namespace; dev-up, `seed.py`, `snapshot.py`, the sample-app PreSync hook. 32 random characters since WO-1.5b. |
| Grafana `admin` password | `GRAFANA_ADMIN_PASS` | `grafana-admin-password` | hub `monitoring/grafana-admin-credentials`, read through `grafana.admin.existingSecret`. Grafana has no persistence, so a new value applies on the next Grafana restart. |
| AgentForge users' passwords | (none) | `keycloak-agentforge-user-password`, `keycloak-af-platform-user-password`, `keycloak-af-readonly-user-password` | dev-up Stage 10.5 (re)creates the Keycloak users `subhankar`, `af-platform-user` and `af-readonly-user` with these; sanity logs in as `subhankar` |
| `platform-admin` password | (none) | `keycloak-platform-admin-password` | Not used any more. WO-1.5b removed `platform-admin` from the realm import. The file stays in the seed until someone deletes it (`seed.py build` after removing the file). |
| GHCR pull credentials | (none) | `ghcr-pull-secret.json` | `ghcr-pull-secret` in `agentforge` (image pulls) and `kyverno` (signature checks). Needs a classic PAT (`ghp_`) or a `gh` OAuth token (`gho_`) with `read:packages`; GHCR rejects fine-grained PATs. |
| cosign signing key | (none) | `cosign.key` | signing images by hand. CI signs with its own copy (a GitHub Actions secret). Moved out of `helmsman-app/` in WO-1.5b. |
| acme-dns registration | (none) | `acmedns-registration.json` | DNS-01 certificates (a later work order). Created 23 Nov 2026. |
| AgentForge Vault values | (none) | `vault-agentforge.json` (written from the seed) | `secret/agentforge/{auth,cache,confluence,db,llm}`: Groq API key, Confluence token, DB password and URL, Redis URL, oauth2-proxy cookie secret and Keycloak client secret. dev-up Stage 10.5 restores missing paths from this file; `seed.py apply` restores them from the seed. |

**Not in the seed, held by a person:**
- **The GitHub PAT** (`GITHUB_TOKEN`): a fine-grained token for pushing to the fleet repo. Keep
  it in your shell or password manager, and `unset GITHUB_TOKEN` before pushing to other repos.
- **`helmsman-operator.env`**: the operator's local development environment file, moved out of
  the repo in WO-1.5b. It is kept in `~/.helmsman-dev/` and excluded from the seed by name.

Runtime values that need no backup:
- the sample-app OIDC client secret and cookie secret (`secret/apps/sample-app/oidc`): the
  sample-app PreSync hook creates them, and keeps an existing cookie secret;
- each AppDeployment's credentials: the operator creates them.

## The encrypted seed

`secrets.enc.yaml`, version 1:

```yaml
version: 1
files:          # file name in ~/.helmsman-dev -> exact content
  argocd-admin-password: ENC[...]
  ...
vault:          # path under secret/ -> {property: value}
  agentforge/llm: {groq_api_key: ENC[...]}
  ...
sops: {...}     # recipients, MAC, timestamps
```

**Excluded:**
- the age key;
- `dev-up.log` and `last-dev-up`;
- `*.log`, `*.out` and `*.tmp` files;
- the human-held items above;
- `vault-agentforge.json`, which is derived from `vault:`.

**Every other regular file in `~/.helmsman-dev/` goes into the seed on the next `build`.** Keep
scratch or backup copies (`*.bak`, an old token) out of that folder. `build` lists every entry,
so check its output before you commit. Subfolders such as `snapshots/` are skipped.

How to read, change and check it: [scripts.md](scripts.md#scriptsseedpy-the-encrypted-seed).

## Adding a credential

```bash
mkdir -p ~/.helmsman-dev && chmod 700 ~/.helmsman-dev
python3 -c 'import secrets; print(secrets.token_urlsafe(18), end="")' > ~/.helmsman-dev/NEW-NAME
chmod 600 ~/.helmsman-dev/NEW-NAME
python3 -I scripts/seed.py diff && python3 -I scripts/seed.py build   # then commit secrets.enc.yaml
```

Use URL-safe values (letters, digits, `-` and `_`).

## Rotating a credential

**A rotation is not a file edit.** Change the credential in the service first, then update the
file and every copy, then the seed.

| Credential | Rotation |
| --- | --- |
| Argo CD admin | Argo CD API `PUT /api/v1/account/password` (or `argocd account update-password`), then write the file, `seed.py build`, commit |
| Keycloak admin | Keycloak admin API `reset-password` for the master `admin` user. Then write the file, run dev-up (it rewrites `keycloak-admin-credentials` and every `helmsman-platform-config`), `seed.py build`, commit. |
| Grafana admin | write the file, run dev-up (it rewrites the Secret), restart Grafana, `seed.py build`, commit |
| AgentForge users | Keycloak `reset-password` for the user, write the file, `seed.py build`, commit |
| Vault root token | see below |
| AgentForge Vault values | change the value at its source (Groq, Confluence and so on), write it into Vault (`secret/agentforge/...`), then run `seed.py build`. build reads `vault-agentforge.json`, which dev-up refreshes from the live Vault on every run. Commit. Then force-sync the ExternalSecret (below). |

### Vault root token

Vault runs `server -dev`, in memory. **A new token means a restart, and a restart empties
Vault.** The procedure, as done in WO-1.5b Stage 5:

1. **Snapshot first:** `snapshot.py take`.
2. **Write the new token** to `~/.helmsman-dev/vault-root-token` (mode 600, e.g.
   `secrets.token_urlsafe(24)`), then run `seed.py build` and commit.
3. **Update the hub Secret:** `seed.py apply` writes `vault/vault-root-token`, or run dev-up. The
   running Vault ignores it until it restarts.
4. **Restart Vault** by deleting its pod. Don't use `kubectl rollout restart`: that edits the
   Argo-managed Deployment.
   `kubectl --context kind-helmsman-hub -n vault delete pod -l app=vault`
5. **Refill:** run a non-reset `dev-up-gemini.sh`, which rewrites the ESO token and every
   `helmsman-platform-config`, restores `secret/agentforge/*`, and re-runs the sample-app hook.
   Then run `seed.py apply`.
6. **Refresh the ExternalSecrets now** instead of within the hour:
   `kubectl annotate externalsecret NAME -n NS force-sync=$(date +%s) --overwrite` for each.
7. **Check:**
   - `seed.py verify` reports 0 failures;
   - every ExternalSecret is Ready, and sanity has 0 failures;
   - the old token gets 403 on `auth/token/lookup-self`.

Workloads keep running through the empty window (ExternalSecrets use `deletionPolicy: Retain`).
If something is still missing, `snapshot.py restore-vault FILE` refills it.

## Secret scanning

Both repos run gitleaks in CI:
- **the full git history** with the default rules; `.gitleaksignore` lists each reviewed finding
  by fingerprint;
- **the working tree** with `.gitleaks-tree.toml`. It adds two rules:
  - `${VAR:-<value>}` defaults on credential-named variables;
  - `age-secret-key`, so a committed age private key fails CI.

Before showing or committing any script, manifest or doc that may hold credentials, pass it
through a redactor. The `${VAR:-value}` form defeats simple masking.
