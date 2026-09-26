# Envoy Gateway rollout: sync failures + Gateway never programmed

Date: 2026-09-26
Cluster: `kind-helmsman-hub` / `kind-helmsman-onprem`
Fix commits: `7fde9b8`, `d7b5f2f`

End state: Envoy Gateway v1.3.1 runs on the spoke (`helmsman-onprem`) and
`gateway-infra/helmsman-gateway` is `Programmed=True` at `172.18.0.3`,
NodePort `31641`. Six problems had to be fixed to get there. Each one was
hiding the next.

## Issue 1: `argocd app sync` fails with a DNS timeout

**Symptom**

```
argocd app sync platform-envoy-gateway
{"level":"fatal","msg":"rpc error: code = FailedPrecondition desc = error resolving repo revision:
 rpc error: code = Unavailable desc = dns: A record lookup error: lookup argocd-repo-server on
 10.96.0.10:53: dial udp 10.96.0.10:53: i/o timeout"}
```

**Root cause**

CoreDNS was healthy. New pods on every node, including the one hosting
`argocd-server`, resolved `argocd-repo-server` fine. But the long-running
`argocd-server` pod itself could not:

```
kubectl exec -n argocd deploy/argocd-server --context kind-helmsman-hub -- getent hosts argocd-repo-server
# (no output)
```

**Fix**

```
kubectl rollout restart deploy/argocd-server -n argocd --context kind-helmsman-hub
```

This kills any `argocd-server` port-forward, so restart it afterwards:

```
kubectl port-forward svc/argocd-server -n argocd --context kind-helmsman-hub 9091:443
```

## Issue 2: pushing to git didn't update the Application

**Symptom**

After `96e8908` was pushed, `argocd app get platform-envoy-gateway` still
showed the old `repoURL: https://gateway.envoyproxy.io/helm-chart`.

**Root cause**

`platform-envoy-gateway` (like every `platform-*` Application) was created
with `kubectl apply`. No app-of-apps watches `platform/`, so a push never
reaches the live Application.

**Fix**

Re-apply the manifest after changing it:

```
kubectl apply -f platform/envoy-gateway/argocd-application.yaml --context kind-helmsman-hub
```

## Issue 3: `oci://` repoURL returns 401 from Docker Hub

**Symptom**

```
ComparisonError: failed to resolve revision "v1.3.1": cannot get digest for revision v1.3.1:
HEAD "https://registry-1.docker.io/v2/envoyproxy/manifests/v1.3.1": response status code 401
```

**Root cause**

In Argo CD 3.5, an `oci://` `repoURL` means a raw OCI artifact source, and
`chart:` is ignored. So Argo CD looked for an image called
`envoyproxy:v1.3.1`, which doesn't exist. A Helm chart hosted in an OCI
registry needs the registry path **without** a scheme, plus `chart:`.

**Fix**

[`platform/envoy-gateway/argocd-application.yaml`](../../platform/envoy-gateway/argocd-application.yaml):

```yaml
source:
  repoURL: docker.io/envoyproxy   # was oci://docker.io/envoyproxy
  chart: gateway-helm
  targetRevision: "v1.3.1"
```

## Issue 4: Gateway API kinds missing on the spoke

**Symptom**

`platform-envoy-gateway-infra` sync error:

```
failed to discover server resources for group version gateway.networking.k8s.io/v1:
the server could not find the requested resource
```

**Root cause**

The chart, which ships the Envoy Gateway controller and the Gateway API CRDs,
was being installed on the **hub**
(`server: https://kubernetes.default.svc`). The GatewayClass and Gateway in
`gateway-infra.yaml` are deployed to the **spoke** `helmsman-onprem`.

**Fix**

Point the chart at the spoke, and add the resources finalizer so that
deleting the app also removes what it installed:

```yaml
metadata:
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  destination:
    name: helmsman-onprem          # was server: https://kubernetes.default.svc
    namespace: envoy-gateway-system
```

Then remove the hub install. The Application had been created without the
finalizer, so add it first to make the delete cascade:

```
kubectl patch application platform-envoy-gateway -n argocd --context kind-helmsman-hub \
  --type merge -p '{"metadata":{"finalizers":["resources-finalizer.argocd.argoproj.io"]}}'
kubectl delete application platform-envoy-gateway -n argocd --context kind-helmsman-hub
kubectl apply -f platform/envoy-gateway/argocd-application.yaml --context kind-helmsman-hub
```

Argo CD doesn't prune the chart's CRDs, or the namespace created by
`CreateNamespace=true`, so both stay on the hub. Once you've confirmed no
custom resources use them, remove them:

```
kubectl get crd -o name --context kind-helmsman-hub \
  | grep -E 'gateway.networking.k8s.io|gateway.envoyproxy.io' \
  | xargs kubectl delete --context kind-helmsman-hub
kubectl delete ns envoy-gateway-system --context kind-helmsman-hub
```

## Issue 5: infra app tried to create `Application` objects on the spoke

**Symptom**

`platform-envoy-gateway-infra` listed `Application/argocd/platform-envoy-gateway`
and `Application/argocd/platform-envoy-gateway-infra` as resources to sync to
the spoke, which fails with
`failed to discover server resources for group version argoproj.io/v1alpha1`.

**Root cause**

`directory.exclude` takes a single glob. `"argocd-application.yaml,spoke-application.yaml"`
is read as one literal filename, so nothing matched and nothing was excluded.

**Fix**

[`platform/envoy-gateway/spoke-application.yaml`](../../platform/envoy-gateway/spoke-application.yaml):
wrap the alternatives in braces, and add a retry so the app waits for the
Gateway API CRDs from Issue 4 to exist on the spoke:

```yaml
directory:
  exclude: "{argocd-application.yaml,spoke-application.yaml}"
syncPolicy:
  retry:
    limit: 10
    backoff:
      duration: 15s
      factor: 2
      maxDuration: 3m
```

## Issue 6: Gateway stuck at `Programmed=False`

**Symptom**

```
kubectl get gateway -n gateway-infra --context kind-helmsman-onprem
helmsman-gateway   envoy             False
# Programmed=False AddressNotAssigned: No addresses have been assigned to the Gateway

kubectl get svc -n envoy-gateway-system --context kind-helmsman-onprem
envoy-gateway-infra-helmsman-gateway-104fe5bd   LoadBalancer   10.96.237.25   <pending>   80:31641/TCP
```

**Root cause**

kind has no LoadBalancer controller. Envoy Gateway creates a `LoadBalancer`
service for each Gateway by default, and it never gets an external IP.

**Fix**

[`platform/envoy-gateway/gateway-infra.yaml`](../../platform/envoy-gateway/gateway-infra.yaml):
add an `EnvoyProxy` config that exposes the proxy as a NodePort, and point
the GatewayClass at it:

```yaml
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
  parametersRef:
    group: gateway.envoyproxy.io
    kind: EnvoyProxy
    name: helmsman-proxy
    namespace: gateway-infra
---
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyProxy
metadata:
  name: helmsman-proxy
  namespace: gateway-infra
spec:
  provider:
    type: Kubernetes
    kubernetes:
      envoyService:
        type: NodePort
```

The NodePort override only makes sense on kind. On a cluster with a real
LoadBalancer (or MetalLB / `cloud-provider-kind`), drop it.

## Verification

```
argocd app list | grep envoy
argocd/platform-envoy-gateway        ...  Synced  Healthy
argocd/platform-envoy-gateway-infra  ...  Synced  Healthy

kubectl get gateway -n gateway-infra --context kind-helmsman-onprem
helmsman-gateway   envoy   172.18.0.3   True

docker exec helmsman-onprem-worker curl -s -o /dev/null -w "%{http_code}\n" http://172.18.0.2:31641/
404    # Envoy is answering; no HTTPRoutes attached yet
```

`172.18.0.x:31641` is reachable from inside the kind network but times out
from the WSL shell. To test locally:

```
kubectl --context kind-helmsman-onprem port-forward -n envoy-gateway-system \
  svc/envoy-gateway-infra-helmsman-gateway-104fe5bd 8080:80
curl -i http://localhost:8080/
```

## Open follow-ups

- **`argocd-repo-server` restarts (111 in 27 days).** The liveness probe
  `/healthz?full=true` (5s timeout) times out, and the pod shuts down cleanly
  (exit 0, no OOM). This is probably the same hub network/DNS flakiness as
  Issue 1. Either raise the probe's `timeoutSeconds`/`failureThreshold` or
  investigate kindnet/CoreDNS on the hub.
- **Manage `platform-*` Applications from git.** An app-of-apps over
  `platform/` would remove the manual `kubectl apply` step from Issue 2.
