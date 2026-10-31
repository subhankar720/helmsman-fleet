# Cloud migration inventory

Last updated: 2026-10-31

This lists what has to change, be decided or be retested when Helmsman moves from the two local kind
clusters to the cloud. The target, from `~/projects/helmsman/tools/oci-a1-grab.sh`, is an **Oracle Cloud
Ampere A1 VM**: **aarch64 / arm64**, Always Free at 2 OCPU / 12 GB, 150 GB boot volume, Ubuntu 22.04.

**Status values:** `open` (not started), `decided` (approach agreed, not done), `done`.

| # | Item | Area | Owner | Status |
| --- | --- | --- | --- | --- |
| 1 | [Image architecture: AgentForge (and two other images) are amd64-only](#1-image-architecture-amd64-only-images) | Build | AgentForge team, Helmsman | open |
| 2 | [Postgres `fsGroup` retest on a real block volume](#2-postgres-fsgroup-retest) | Storage | Helmsman | open |
| 3 | [AgentForge egress rules](#3-agentforge-egress-rules) | Network | Helmsman + AgentForge team | open |
| 4 | [Stable Keycloak issuer / hostname](#4-stable-keycloak-issuer-hostname) | Identity | Helmsman | open |
| 5 | [Vault and Keycloak persistence](#5-vault-and-keycloak-persistence) | Platform | Helmsman | open |
| 6 | [NetworkPolicy-capable CNI and ingress tightening](#6-cni-and-networkpolicy) | Network | Helmsman | open |
| 7 | [Gateway exposure: NodePort to LoadBalancer/ingress, TLS](#7-gateway-exposure-and-tls) | Network | Helmsman | open |
| 8 | [GHCR pull credentials](#8-ghcr-pull-credentials) | Build | Helmsman | open |

Items 1–3 were requested by the AgentForge team. Items 4–8 came out of the same investigation
(see [agentforge-identity-integration.md](agentforge-identity-integration.md)).

## 1. Image architecture: amd64-only images

**Finding (2026-10-31).** Every image deployed on both clusters (41) was checked with
`docker buildx imagetools inspect`. Only three lack an arm64 build, and all three are built by us:

| Image | Platforms | Built by |
| --- | --- | --- |
| `ghcr.io/subhankar720/agentforge` (all tags: `latest`, `5e1c5659…`, `ff226856…`, `216c723f…`) | **linux/amd64** only (plus the `unknown/unknown` attestation manifest) | AgentForge CI (`agentforge-bot`) |
| `ghcr.io/subhankar720/helmsman-app` | **linux/amd64** only | Helmsman |
| `helmsman-operator:dev` | **amd64**, built locally by dev-up Stage 4.5 and never pushed | Helmsman |

Every upstream image already has `linux/arm64`: Kubernetes, kindnet, Argo CD, Keycloak 26.3.3, Vault 1.18,
Envoy Gateway v1.3.1 / Envoy 1.33, Kyverno 1.13.4, ESO 0.10.7, oauth2-proxy 7.7.1, pgvector pg16,
Redis 7, Flower 2.0, Loki, Promtail, Grafana and Prometheus.

**What's needed:**

- **AgentForge CI:** build multi-arch with `docker buildx build --platform linux/amd64,linux/arm64 --push`.
  Check that every Python wheel in `requirements.txt` has an aarch64 build; anything compiled (asyncpg,
  pgvector, tokenizers, numpy) must either have a wheel or build under QEMU.
- **Cosign signing must cover the multi-arch index.** Kyverno's `verify-agentforge-signatures` verifies the
  digest the pod pulls. Sign the index digest (`cosign sign --recursive` signs the index and every
  per-platform manifest), and retest admission on arm64.
- **`helmsman-app` and `helmsman-operator`:** same multi-arch build. The operator also has to be **pushed to
  a registry**, because the cloud has no `kind load docker-image`. Change `imagePullPolicy: Never`, which
  dev-up Stage 4.5 sets.
- **Retest:** on an arm64 node, gateway, worker, migrate Job and ingest CronJob pods start, and the
  [e2e phases](troubleshooting/laptop-reboot-and-e2e-2026-10-30.md#agentforge-end-to-end-results) pass.

## 2. Postgres fsGroup retest

**Finding (2026-10-31).** `agentforge-postgres` runs with `runAsUser: 999`, `runAsNonRoot: true` and
`fsGroup: 999`, and keeps `PGDATA` in a sub-directory, `/var/lib/postgresql/data/pgdata`. On kind, the
volume comes from `rancher.io/local-path` (StorageClass `standard`). That provisioner creates the mount as
`drwxrwxrwx root:root` and **ignores `fsGroup`**:

```
$ kubectl -n agentforge exec agentforge-postgres-0 -- ls -ldn /var/lib/postgresql/data /var/lib/postgresql/data/pgdata
drwxrwxrwx  3   0   0 … /var/lib/postgresql/data          ← local-path, world-writable, fsGroup not applied
drwx------ 19 999 999 … /var/lib/postgresql/data/pgdata   ← created by postgres itself
```

So the kind setup never proves that `fsGroup` works. It passes only because the directory is
world-writable. On OCI, the block-volume CSI driver formats the volume (ext4) as `root:root 0755` and
relies on kubelet applying `fsGroup`.

**Retest on the cloud cluster:**

1. Fresh PVC on the cloud StorageClass: Postgres initialises, `ls -ldn` shows the mount group `999`, and
   `pgdata` is `999:999 0700`.
2. Pod delete/reschedule onto the same volume: the restart is clean, with no `could not change permissions`.
3. Check `fsGroupChangePolicy`. Consider `OnRootMismatch` to avoid a recursive chown on every mount once
   the database is large.
4. The `agentforge-db-migrate` PostSync Job (`runAsUser: 999`, `fsGroup: 999`) still connects. It only uses
   the network, but confirm Kyverno admits it on the cloud cluster.
5. Redis (`agentforge-redis`, 1 Gi PVC): same check if it runs non-root with persistence.

## 3. AgentForge egress rules

**Current state** (`agentforge-allow-egress-external`, applied to **all pods** in `agentforge`). The rule
allows these ports to **any destination**:

| Port | Protocol | Used for (kind) | Cloud action |
| --- | --- | --- | --- |
| 53 | UDP | DNS | keep; also add **TCP 53**, which large responses need |
| 443 | TCP | Groq API, Confluence Cloud (`subhankarp009.atlassian.net`), GHCR | restrict to the needed hosts (below) |
| 30081 | TCP | Keycloak via the **hub NodePort** | replace with the cloud Keycloak endpoint |
| 30082 | TCP | Vault via the **hub NodePort** | ESO talks to Vault, not AgentForge pods; probably **remove** |
| 11434 | TCP | Ollama on `host.docker.internal` (`OLLAMA_BASE_URL`) | remove, or point at the cloud model endpoint |

Plus `agentforge-allow-internal` (all traffic within the namespace) and `agentforge-deny-all`.

**Problems to fix:**

- **"Any destination on 443" means any pod can reach the whole internet.** kindnet only matches IP and CIDR,
  not hostnames. On the cloud, either use a CNI with FQDN policies (Cilium `toFQDNs`, Calico Enterprise),
  or send egress through an HTTP proxy with an allow-list. Required hosts: `api.groq.com`,
  `subhankarp009.atlassian.net`, `ghcr.io` (only the kubelet pulls images; pods don't need it), plus
  OpenRouter or Anthropic if `AGENTFORGE_MODEL_BACKEND` changes (`settings.py` has `openrouter_*` and
  `anthropic_*`).
- **The rule applies to every pod.** Postgres, Redis and Flower don't need internet egress. Scope it to the
  gateway, worker and ingest CronJob pods.
- **Ports 30081 and 30082 are kind artefacts** (hub NodePorts on Docker bridge IPs). They disappear with the
  two-cluster layout.
- The **ingest CronJob** reads Confluence over 443, and the **migrate Job** only needs Postgres
  (in-namespace). Retest both with the tightened policy.

## 4. Stable Keycloak issuer hostname

Keycloak runs `start-dev` without `--hostname`, so the token issuer is whatever URL the token was requested
through. Today that's `http://<hub-worker-ip>:30081/realms/helmsman`, and the IP changes on reboot. A token
fetched through `localhost` is rejected by oauth2-proxy. On the cloud, set
`KC_HOSTNAME=https://<stable DNS name>` and run Keycloak in production mode (`start`, not `start-dev`,
with TLS). Then the issuer is fixed, and AgentForge can pin it. Details:
[identity Q1](agentforge-identity-integration.md#the-exact-issuer-string-and-why-it-isnt-stable).

## 5. Vault and Keycloak persistence

Vault runs `server -dev` (in-memory, root token `root`). Keycloak has no PVC and uses its built-in dev
database. Locally, `dev-up-gemini.sh` Stage 10.5 restores `secret/agentforge/*`, including the Groq key
and Confluence token, plus the Keycloak clients, groups and user, from plaintext backups in
`~/.helmsman-dev/`. That's not acceptable on the cloud:

- **Vault:** persistent storage (integrated Raft on a PVC), real unseal (OCI KMS auto-unseal), and
  Kubernetes auth for ESO instead of the root token.
- **Keycloak:** a Postgres database (a dedicated instance, or a separate database on a managed Postgres).
  Realm, clients and mappers managed as code (realm import, or a Terraform / keycloak-config-cli job), not
  recreated by a script.
- Then retire the `~/.helmsman-dev` backup and restore path.

## 6. CNI and NetworkPolicy

kindnet enforces NetworkPolicy, and the
[negative test](agentforge-identity-integration.md#q2-cni-and-the-networkpolicy-negative-test) passed.
It needed a CPU-limit fix to be reliable, and it has no FQDN rules. On the cloud, choose a CNI with solid
policy support (Cilium recommended, for FQDN egress and Hubble flow visibility). Before AgentForge trusts
`X-Forwarded-Groups`, narrow `agentforge-allow-ingress` to the oauth2-proxy and Envoy pods (it currently
allows whole namespaces).

## 7. Gateway exposure and TLS

kind exposes `helmsman-gateway` through a NodePort `EnvoyProxy` (no LoadBalancer controller), and
oauth2-proxy runs with `--cookie-secure=false` over plain HTTP. On OCI: a LoadBalancer Service (OCI LB, or
a NodePort behind the VM's public IP on a single node), a TLS certificate (cert-manager + Let's Encrypt),
`--cookie-secure=true`, and a public hostname in the oauth2-proxy redirect URL and the Keycloak client
redirect URIs, which are `*` today.

## 8. GHCR pull credentials

`ghcr-pull-secret` currently holds the `gh` CLI's OAuth token (`gho_…`, with `read:packages`), tied to an
interactive `gh` login. GHCR rejects fine-grained PATs. For the cloud, use a dedicated classic PAT or a
GitHub App / machine-user token with `read:packages`. Store it in Vault and sync it with ESO into
`agentforge` and `kyverno` (Kyverno uses it to verify signatures). Alternatively, make the images public if
that's acceptable.
