# Helmsman Fleet Repository

GitOps source of truth for the Helmsman Internal Developer Platform.

## Structure
- `golden-path-chart/` — shared Helm chart deployed for every application
- `apps/` — per-app values files (one folder per app)
- `applicationsets/` — Argo CD ApplicationSet definitions driving multi-cluster fan-out
- `platform/` — platform components (Argo CD Applications, Kyverno policies, Envoy Gateway, oauth2-proxy, …)
- `scripts/` — `dev-up-gemini.sh` (bootstrap/recovery) and `helmsman-sanity.sh` (read-only health report)
- `docs/` — [dev-up and sanity reference](docs/dev-up-and-sanity.md) and [troubleshooting write-ups](docs/troubleshooting/)
