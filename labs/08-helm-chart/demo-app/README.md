# demo-app

A production-shaped Helm chart for the `kubernetes-labs` demo application.

The chart renders a hardened Deployment (non-root, read-only root filesystem,
all capabilities dropped, `RuntimeDefault` seccomp), a Service with a **named**
`http` port, a dedicated ServiceAccount with token automounting disabled, and
optional Ingress, HorizontalPodAutoscaler, PodDisruptionBudget, ConfigMap,
Secret and Prometheus ServiceMonitor objects.

| Field | Value |
| --- | --- |
| Chart version | `0.1.0` |
| App version | `1.0.0` |
| Chart type | `application` |
| Minimum Kubernetes | `1.25` |

## Installing

```bash
# From the lab directory
helm upgrade --install demo-app ./demo-app \
  --namespace lab-08-helm --create-namespace \
  --wait --timeout 3m

# With the production example overrides
helm upgrade --install demo-app ./demo-app \
  --namespace demo-prod --create-namespace \
  -f ../values-production.yaml
```

## Uninstalling

```bash
helm uninstall demo-app --namespace lab-08-helm
```

Helm does not delete the namespace it created with `--create-namespace`, nor
any PersistentVolumeClaims. Remove those explicitly if you want a clean slate.

## Values

### Workload

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `replicaCount` | int | `2` | Deployment replicas. **Ignored when `autoscaling.enabled` is true** — the template omits `replicas` entirely so Helm and the HPA do not fight over the field. |
| `revisionHistoryLimit` | int | `5` | ReplicaSets retained for `helm rollback` / `kubectl rollout undo`. |
| `terminationGracePeriodSeconds` | int | `30` | Shutdown grace period. Must exceed the readiness probe period plus endpoint propagation delay or in-flight requests are dropped during a rollout. |

### Image

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `image.repository` | string | `ghcr.io/maneeshm/k8s-labs-demo` | Image repository, no tag. |
| `image.tag` | string | `"1.0.0"` | Image tag. Falls back to `.Chart.AppVersion` when empty. |
| `image.pullPolicy` | string | `IfNotPresent` | `IfNotPresent` lets a `kind load docker-image` sideloaded image be used without a registry round trip. Use `Always` in production, or deploy by digest. |
| `imagePullSecrets` | list | `[]` | Pull secrets for a private registry, e.g. `[{name: ghcr-credentials}]`. The Secret must already exist in the namespace. |

### Naming

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `nameOverride` | string | `""` | Overrides the chart-name portion of generated names. |
| `fullnameOverride` | string | `""` | Replaces the generated name entirely. Breaks release-name scoping — two releases in one namespace will collide. |

### ServiceAccount

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `serviceAccount.create` | bool | `true` | Create a dedicated ServiceAccount. Strongly preferred over `default`, which is shared by every pod in the namespace. |
| `serviceAccount.annotations` | object | `{}` | SA annotations. On EKS this is where IRSA lives: `eks.amazonaws.com/role-arn`. |
| `serviceAccount.name` | string | `""` | Name to use; generated from the fullname template when empty. |
| `serviceAccount.automount` | bool | `false` | Mount the SA token into pods. This app never calls the Kubernetes API, so the token is pure attack surface. |

### Security

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `podSecurityContext.runAsNonRoot` | bool | `true` | Required by the `restricted` Pod Security Standard. |
| `podSecurityContext.runAsUser` | int | `65532` | The `nonroot` UID in distroless / Chainguard base images. |
| `podSecurityContext.runAsGroup` | int | `65532` | Primary group. |
| `podSecurityContext.fsGroup` | int | `65532` | Group applied to mounted volume ownership. |
| `podSecurityContext.seccompProfile.type` | string | `RuntimeDefault` | Applies the container runtime's default syscall filter. |
| `securityContext.allowPrivilegeEscalation` | bool | `false` | Blocks `setuid` binaries from gaining privileges. |
| `securityContext.readOnlyRootFilesystem` | bool | `true` | Turns "attacker got RCE" into "attacker got RCE and cannot write a payload to disk". Use `extraVolumes` for scratch space rather than relaxing this. |
| `securityContext.capabilities.drop` | list | `[ALL]` | Drops every Linux capability. |

### Service and Ingress

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `service.type` | string | `ClusterIP` | `ClusterIP` for anything behind an Ingress. `LoadBalancer` on EKS provisions a real NLB and a real monthly bill. |
| `service.port` | int | `8080` | Service port. `targetPort` is always the container's named `http` port, so this may differ freely. |
| `ingress.enabled` | bool | `false` | Create an Ingress. |
| `ingress.className` | string | `nginx` | IngressClass. `nginx` for kind, `alb` for the AWS Load Balancer Controller. |
| `ingress.annotations` | object | `{}` | Controller-specific config (ALB scheme, ACM certificate ARN, health check path). |
| `ingress.hosts` | list | `[{host: demo-app.local, paths: [{path: /, pathType: Prefix}]}]` | Host and path rules. |
| `ingress.tls` | list | `[]` | TLS blocks. Each needs a `kubernetes.io/tls` Secret in the namespace, usually from cert-manager. Leave empty when TLS terminates at an ALB. |

### Resources and scaling

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `resources.requests.cpu` | string | `50m` | Drives scheduling and is the denominator for HPA CPU utilisation. |
| `resources.requests.memory` | string | `64Mi` | Memory request. |
| `resources.limits.cpu` | string | `200m` | CPU ceiling. Consider removing in production — CFS throttling adds tail latency even on an idle node. |
| `resources.limits.memory` | string | `128Mi` | Memory ceiling. Always set this: memory is incompressible, so one leaking pod can OOM a whole node. |
| `autoscaling.enabled` | bool | `false` | Create a HorizontalPodAutoscaler. |
| `autoscaling.minReplicas` | int | `2` | Floor. |
| `autoscaling.maxReplicas` | int | `10` | Ceiling. |
| `autoscaling.targetCPUUtilizationPercentage` | int | `80` | Percentage of the CPU **request**, not the limit. With a `50m` request, 80% triggers at `40m`. |
| `autoscaling.targetMemoryUtilizationPercentage` | int/null | `80` | Set `null` to drop the memory metric. Memory rarely falls when replicas are added, so CPU-only is safer for most stateless services. |
| `pdb.enabled` | bool | `true` | Create a PodDisruptionBudget. |
| `pdb.minAvailable` | int/string | `1` | Pods that must stay up during a drain. Must be **below** the replica count or drains block forever. |

### Scheduling

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `nodeSelector` | object | `{}` | Node label constraints. |
| `tolerations` | list | `[]` | Tolerations for tainted nodes (spot, GPU). |
| `affinity` | object | `{}` | Affinity rules. Prefer `topologySpreadConstraints` for the common spread case. |
| `topologySpreadConstraints` | list | one `kubernetes.io/hostname` constraint, `ScheduleAnyway` | Spread replicas. The chart injects the selector labels automatically. On multi-AZ EKS add a `topology.kubernetes.io/zone` constraint with `DoNotSchedule`. |

### Configuration

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `env` | list | `[{name: GREETING, value: "Hello from Helm"}]` | Literal env vars. `POD_NAME`, `NODE_NAME`, `POD_NAMESPACE` and `PORT` are always injected by the template. |
| `envFrom` | list | `[]` | Extra `envFrom` sources, e.g. a Secret produced by External Secrets Operator. |
| `config` | object | `{LOG_LEVEL: info, ...}` | Rendered into a ConfigMap, consumed via `envFrom`. Keys become env var names, so use `SHOUTY_SNAKE`. |
| `secrets` | object/null | `{API_KEY: "lab-only-not-a-real-secret"}` | Rendered into a Secret. **Lab use only.** Set to `null` — not `{}` — to disable; Helm coalesces maps, so an empty map leaves inherited keys in place. |

### Probes

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `livenessProbe.enabled` | bool | `true` | "Is this process wedged?" Failure restarts the container, so it must **never** check downstream dependencies — a database blip would restart every pod at once. |
| `livenessProbe.path` | string | `/healthz` | Liveness endpoint. |
| `livenessProbe.initialDelaySeconds` | int | `5` | Delay before the first check. |
| `livenessProbe.periodSeconds` | int | `10` | Check interval. |
| `livenessProbe.timeoutSeconds` | int | `2` | Per-check timeout. |
| `livenessProbe.failureThreshold` | int | `3` | Consecutive failures before restart. |
| `livenessProbe.successThreshold` | int | `1` | Must be `1` for liveness; the API server rejects anything else. |
| `readinessProbe.enabled` | bool | `true` | "Should this pod receive traffic?" Failure only removes the pod from Service endpoints, which is cheap and reversible — so this one *may* check dependencies. |
| `readinessProbe.path` | string | `/readyz` | Readiness endpoint. |
| `readinessProbe.initialDelaySeconds` | int | `3` | Delay before the first check. |
| `readinessProbe.periodSeconds` | int | `5` | Check interval. |
| `readinessProbe.timeoutSeconds` | int | `2` | Per-check timeout. |
| `readinessProbe.failureThreshold` | int | `3` | Consecutive failures before removal from endpoints. |
| `readinessProbe.successThreshold` | int | `1` | Consecutive successes before the pod is Ready again. |

### Observability

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `serviceMonitor.enabled` | bool | `false` | Create a Prometheus Operator ServiceMonitor. The template *also* checks that `monitoring.coreos.com/v1` exists, so enabling this without the operator fails soft instead of erroring. |
| `serviceMonitor.interval` | string | `15s` | Scrape interval. Every halving doubles active-series ingest cost on Amazon Managed Prometheus. |
| `serviceMonitor.scrapeTimeout` | string | `10s` | Must be less than `interval`. |
| `serviceMonitor.path` | string | `/metrics` | Metrics path. |
| `serviceMonitor.labels` | object | `{release: kube-prometheus-stack}` | Labels the Prometheus `serviceMonitorSelector` matches on. See lab 09 for why this is the number one reason targets do not appear. |

### Volumes

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `extraVolumes` | list | `[]` | Extra pod volumes. Usually an `emptyDir` for scratch space, which lets `readOnlyRootFilesystem` stay `true`. |
| `extraVolumeMounts` | list | `[]` | Matching container mounts. |

## Values schema

`values.schema.json` is a real JSON Schema and Helm enforces it on `install`,
`upgrade`, `lint` and `template`. A typo like `replicaCount: "two"` or an
invalid `service.type` fails immediately with a readable error instead of
producing a broken Deployment. `additionalProperties` is `false` at the top
level, so a misspelled key such as `replicaCounts` is rejected rather than
silently ignored — which is the single most valuable thing a chart schema does.

## Chart tests

`helm test` runs a `curlimages/curl` pod that checks `/healthz`, `/readyz` and
asserts `demo_app_build_info` is present on `/metrics`. The test pod carries the
same security context and resource constraints as the app, so it also verifies
the namespace's Pod Security admission actually admits a compliant pod.

```bash
helm test demo-app --namespace lab-08-helm --logs
```

## Templates

| Template | Rendered when |
| --- | --- |
| `deployment.yaml` | always |
| `service.yaml` | always |
| `serviceaccount.yaml` | `serviceAccount.create` |
| `configmap.yaml` | `config` is non-empty |
| `secret.yaml` | `secrets` is non-empty |
| `ingress.yaml` | `ingress.enabled` |
| `hpa.yaml` | `autoscaling.enabled` |
| `pdb.yaml` | `pdb.enabled` |
| `servicemonitor.yaml` | `serviceMonitor.enabled` **and** the `monitoring.coreos.com/v1` API exists |
| `tests/test-connection.yaml` | `helm test` only (`helm.sh/hook: test`) |
