# Helmsman Fleet Repository

GitOps source of truth for the Helmsman Internal Developer Platform.

## Structure
- `golden-path-chart/` — shared Helm chart deployed for every application
- `apps/` — per-app values files (one folder per app)
- `applicationsets/` — Argo CD ApplicationSet definitions driving multi-cluster fan-out
