# AgentForge metrics: exposure decision and scrape-path plan

PWP-1 item 1.7. Status: **plan only — nothing below is built.** Owner: Helmsman platform.

## Decision (architect chat, applied in WO-P1.C)

`/metrics` is **not** reachable without a login. The HTTPRoute's no-login rule straight to
the gateway now matches `/health` only, and oauth2-proxy no longer has a
`--skip-auth-route` for `/metrics`. An unauthenticated `/metrics` through the edge is a login
redirect (302); with a valid token it reaches the gateway (404 today: AgentForge does not
serve metrics yet). AgentForge metrics will carry per-team figures, so they must not be
public. A scraper reads them **inside the cluster**, straight from the gateway pod, never
through the edge.

## Target design (spoke side)

```
spoke: agentforge-gateway pod :8000/metrics
         ^  in-cluster scrape (NetworkPolicy source: the scraper only)
spoke: Prometheus in agent mode (namespace monitoring)
         |  remote_write over HTTP
         v
hub:   Prometheus (platform-prometheus-stack) with the remote-write receiver on
         -> Grafana on the hub (dashboards already live there)
```

1. **Scraper:** Prometheus in **agent mode** on the spoke (`PrometheusAgent` from
   prometheus-operator, or the plain `--enable-feature=agent` binary). Agent mode keeps no
   local TSDB for queries, only a short write-ahead log, so it stays small on kind.
   Expected labels for the NetworkPolicy: namespace `monitoring`,
   `app.kubernetes.io/name=prometheus-agent` (to be confirmed when it is built; never a
   hash label).
2. **What it scrapes:** the gateway pods directly (pod or endpoints discovery on
   `agentforge-gateway`, port 8000, path `/metrics`), not the Service through Envoy.
   The worker is added only if AgentForge exposes metrics there.
3. **Ingress rule on the gateway:** one more source in `agentforge-allow-ingress`, written
   as **one** `from` item holding both a `namespaceSelector` (`kubernetes.io/metadata.name:
   monitoring`) and a `podSelector` (the agent's labels), TCP 8000 only. Two separate items
   would be OR-ed and admit every pod in `monitoring` (the same trap as item 1.1). The
   ingress probe (`tests/component/agentforge-ingress-probe.sh`) gets a case: a pod in
   `monitoring` without the agent's labels stays BLOCKED.
4. **Egress for the agent:** `monitoring` has no NetworkPolicy today. If one is added, the
   agent needs DNS, TCP 8000 to the gateway pods and TCP to the hub's remote-write NodePort.
5. **Hub side:** enable the receiver on the hub Prometheus
   (`prometheus.prometheusSpec.enableRemoteWriteReceiver: true` in the
   `platform-prometheus-stack` values) and expose `/api/v1/write` to the spoke the way Loki
   is exposed today (a NodePort Service, as `loki-nodeport` 3100:30031). On kind the spoke
   reaches the hub at the hub node IP, which changes on Docker/WSL restarts: dev-up's Loki
   IP sync (Stage 7.5) needs a twin for the remote-write URL.
6. **`serviceMonitor.enabled` stays `false`** in the AgentForge chart until the agent
   exists. The ServiceMonitor CRD is not installed on the spoke; a PodMonitor or
   ServiceMonitor is created only together with the agent.

## Prerequisites

- AgentForge serves `/metrics` on the gateway (and says which metrics, with which labels;
  per-team label cardinality must stay bounded).
- Memory headroom on the laptop: the hub Prometheus already holds about 0.4 GiB; an agent
  adds roughly 100–200 MiB (estimate, not measured).
- A decision on authentication of the write path (see open questions).

## Open questions

1. **Auth on remote write:** the receiver has no auth of its own. Options: accept it on a
   local kind network; put basic auth or mTLS in front (Envoy or a sidecar); or use the
   hub's Envoy with a token. Cloud environments need something better than an open NodePort.
2. **Retention:** the hub Prometheus keeps 24 h. Is that enough for AgentForge's dashboards,
   or does it need longer retention or a separate store?
3. **Cloud:** in the cloud plan (docs 27–31) does each environment keep a spoke-to-hub write,
   or does each spoke get its own Prometheus? The NetworkPolicy shape above works either way.
4. **Worker metrics:** Celery workers usually expose metrics through Flower or an exporter.
   Does AgentForge want worker metrics, and from which component?
5. **Who owns the dashboard:** the existing `agentforge-grafana-dashboard` ConfigMap in the
   chart; does AgentForge update it when it adds metrics?

## Rollback of the decision

`git revert` of the WO-P1.C commit that changed the HTTPRoute and oauth2-proxy restores the
unauthenticated `/metrics` route. Do not do this once AgentForge serves per-team metrics.
