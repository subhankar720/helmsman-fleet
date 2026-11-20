# Credentials for the local kind platform

No script or manifest in this repo or in `helmsman-operator` holds a credential **value** (WO-1.5a, 20 Nov 2026). There is one known exception, the Vault dev root token; see below.

Every credential comes from one of two places:
- the environment (`export NAME=...`);
- a file in `~/.helmsman-dev/` (`$HELMSMAN_STATE_DIR`), mode 600, holding just the value with no trailing newline.

`dev-up-gemini.sh` checks all of them **before it touches a cluster**. If one is missing, it stops with exit code 2. It names the variable and the file to create, and it changes nothing. `helmsman-sanity.sh` and `scripts/test-onboarding-flow.sh` read the same files.

| Credential | Variable | File in `~/.helmsman-dev/` | Origin | How dev-up uses it |
| --- | --- | --- | --- | --- |
| Argo CD `admin` password | `ARGOCD_PASS` | `argocd-admin-password` | `--reset` reads Argo CD's random `argocd-initial-admin-secret`, saves it here, then deletes that Secret. Change it with `argocd account update-password`, then update the file. | Stage 9 `argocd login`. Not required on `--reset`. |
| Keycloak master-realm admin password | `KEYCLOAK_ADMIN_PASS` | `keycloak-admin-password` | You create it before the first `--reset`. | Creates hub `keycloak/keycloak-admin-credentials`, which Keycloak uses on first start; writes `keycloak-admin-password` into `helmsman-platform-config` in every spoke namespace (Stage 6). |
| Vault dev-mode root token | `VAULT_TOKEN` | `vault-root-token` | Must equal `VAULT_DEV_ROOT_TOKEN_ID` in `platform/vault/deployment.yaml`. | `vault-token` in `helmsman-platform-config` and in `external-secrets/vault-token` for ESO (Stage 6); Vault access in Stage 10.5. |
| Grafana `admin` password | `GRAFANA_ADMIN_PASS` | `grafana-admin-password` | You create it before the first `--reset`. | Hub Secret `monitoring/grafana-admin-credentials` (Stage R3.5 and Stage 6). The chart reads it through `grafana.admin.existingSecret`. Grafana has no persistence, so a new value applies on the next Grafana restart. |
| `helmsman`-realm user `platform-admin` | (none) | `keycloak-platform-admin-password` | You, or a rotation. | Not used by dev-up. The realm import gives the user no password, so set one with the Keycloak admin API when needed. Keycloak has no PVC, so after a Keycloak restart the user has no password until you set it again. |
| AgentForge test users, sample-app OIDC client | (none) | `keycloak-*-password`, `vault-agentforge.json` | Generated at runtime | See [dev-up-and-sanity.md](dev-up-and-sanity.md#state-kept-outside-the-clusters-helmsman-dev-mode-600). |

## Creating a missing file

```bash
mkdir -p ~/.helmsman-dev && chmod 700 ~/.helmsman-dev
python3 -c 'import secrets; print(secrets.token_urlsafe(18), end="")' > ~/.helmsman-dev/keycloak-admin-password
chmod 600 ~/.helmsman-dev/keycloak-admin-password
```

Use URL-safe values (letters, digits, `-` and `_`). Some checks send the Keycloak password as form data without encoding it.

**Changing a credential that is already live is a rotation, not a file edit.** Change it in the service first (the Argo CD API, or the Keycloak admin API `reset-password`), then update the file and every copy:
- the Keycloak admin password also lives in hub `keycloak/keycloak-admin-credentials` and in the spoke's `helmsman-platform-config` in every namespace;
- running dev-up rewrites all of these from the file.

## Known exception: the Vault dev root token

`platform/vault/deployment.yaml` still sets `VAULT_DEV_ROOT_TOKEN_ID` as a literal. Vault runs with `server -dev` and keeps everything in memory, so changing that manifest restarts Vault and wipes all of its data. Moving the token to a Secret and rotating it is WO-1.5b (bootstrap scripts and the encrypted seed file). Until then, the value is public in git, and so is Vault access on the local kind network.

## Secret scanning

Both repos run gitleaks in CI (see `.gitleaks.toml`):
- the full git history with the default rules, where `.gitleaksignore` lists each reviewed finding by fingerprint;
- the working tree with an extra rule for the shell form `${VAR:-value}` on credential-named variables, which the default rules miss.
