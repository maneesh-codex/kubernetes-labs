# Lab 06 — Autoscaling (HPA, VPA, PDB, and the node layer)

Autoscaling is where capacity planning stops being a spreadsheet and becomes a control loop. Get it right and traffic spikes are a non-event; get it wrong and you find out at 2am that your HPA has been pinned at `maxReplicas` for six hours, or that it scaled down mid-deploy, or that it never scaled at all because metrics-server was quietly broken and nobody alerted on `ScalingActive=False`. This lab builds the whole stack deliberately: a Deployment whose resource *requests* are chosen so the HPA arithmetic is legible, an `autoscaling/v2` HorizontalPodAutoscaler with CPU and memory metrics plus an explicit `behavior` block, a PodDisruptionBudget that does not deadlock against the HPA's floor, a VerticalPodAutoscaler configured so it cannot fight the HPA, and a load generator to drive it all. Then it connects the Pod layer to the node layer, because an HPA that creates Pods no node can fit has not scaled anything — it has just created Pending Pods.

## Objectives

- Install metrics-server on kind (including the `--kubelet-insecure-tls` workaround) and verify the metrics pipeline end to end.
- Understand precisely how the HPA computes desired replicas, and why the CPU **request** — not the limit — is the denominator.
- Write an `autoscaling/v2` HPA with multiple metrics and reason about how they combine.
- Use a `behavior` block to make scale-up aggressive and scale-down conservative, and observe the stabilization window in action.
- Pair an HPA with a PodDisruptionBudget without creating an undrainable node.
- Configure a VerticalPodAutoscaler so it complements rather than fights the HPA.
- Explain how HPA and the Cluster Autoscaler / Karpenter interact through unschedulable Pending Pods.

## Prerequisites

- A running kind cluster named `k8s-labs` (`make cluster-up` from the repo root). Two or more worker nodes make the scaling behaviour much more interesting.
- The demo image `ghcr.io/maneeshm/k8s-labs-demo:1.0.0` loaded (`make image`), plus the ability to pull `busybox:1.36`.
- `kubectl` v1.29+. `watch` is handy but `kubectl get -w` works fine without it.
- metrics-server (step 1 below installs it if `make cluster-up` has not).
- Optional: the VPA CRDs, if you want to run `optional/60-vpa.yaml`. See the header of that file.

## Manifests in this lab

| File | What it does |
| --- | --- |
| `00-namespace.yaml` | Creates `lab-06-autoscaling` with the restricted Pod Security Standard enforced. |
| `10-deployment.yaml` | The scaling target. Requests `cpu: 100m` / limits `cpu: 500m` — deliberately different from the repo default, with the reasoning inline. |
| `20-service.yaml` | ClusterIP Service the load generator targets. |
| `30-hpa.yaml` | `autoscaling/v2` HPA: CPU 60% + memory 75%, `minReplicas: 2`, `maxReplicas: 10`, and a full `behavior` block. |
| `40-pdb.yaml` | `maxUnavailable: 25%` PDB with `unhealthyPodEvictionPolicy: AlwaysAllow`. |
| `50-load-generator.yaml` | busybox Deployment (starts at `replicas: 0`) that hammers `/burn?seconds=30`. |
| `optional/60-vpa.yaml` | VerticalPodAutoscaler in `updateMode: "Off"`, restricted to memory so it cannot fight the HPA. **Requires the VPA CRDs; excluded from CI schema validation.** |

## Walkthrough

### 1. Install and verify metrics-server

The HPA does not scrape anything itself. It reads `metrics.k8s.io`, which is an aggregated API served by metrics-server, which in turn scrapes each kubelet's `/metrics/resource` endpoint. No metrics-server, no HPA — and the failure is quiet.

`make cluster-up` may already have installed it. Check first:

```bash
kubectl -n kube-system get deploy metrics-server 2>/dev/null \
  || echo "not installed"
```

If it is not installed:

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
```

On kind this will **not** become ready. kubelets in kind serve their metrics endpoint with a self-signed certificate that is not signed by the cluster CA, so metrics-server refuses the connection. Patch it:

```bash
kubectl -n kube-system patch deployment metrics-server --type=json -p='[
  {"op":"add","path":"/spec/template/spec/containers/0/args/-",
   "value":"--kubelet-insecure-tls"}
]'

kubectl -n kube-system rollout status deploy/metrics-server --timeout=180s
```

> `--kubelet-insecure-tls` disables verification of the kubelet's serving certificate. It is acceptable in a throwaway kind cluster and **not** acceptable in production. The correct production fix is to run the kubelet with `--rotate-server-certificates=true` and have the CSR approver sign the serving certs — which is exactly what EKS-managed nodes already do, which is why you never pass this flag on EKS.

Verify the whole pipeline, not just the Pod:

```bash
kubectl get apiservices v1beta1.metrics.k8s.io
kubectl top nodes
kubectl top pods -A | head
```

Observe: the APIService reports `True (Passed)`. If `kubectl top nodes` says `error: Metrics API not available`, wait ~30s for the first scrape window; if it persists, check `kubectl -n kube-system logs deploy/metrics-server`.

### 2. Deploy the workload

```bash
kubectl apply -f 00-namespace.yaml
kubectl apply -f 10-deployment.yaml -f 20-service.yaml -f 40-pdb.yaml
kubectl -n lab-06-autoscaling rollout status deploy/demo-app --timeout=180s

kubectl -n lab-06-autoscaling get pods -o wide
kubectl -n lab-06-autoscaling get pdb demo-app
```

Observe: 2 Pods, ideally on different nodes thanks to the `topologySpreadConstraints`. The PDB reports `ALLOWED DISRUPTIONS: 1`.

Wait for metrics to appear for these Pods before continuing — the HPA cannot act on data that does not exist yet:

```bash
kubectl -n lab-06-autoscaling top pods
```

Observe: roughly `1m` CPU and `10-15Mi` memory per Pod. That is your idle baseline; against a 100m request that is ~1% utilisation.

### 3. Create the HPA and read it before any load

```bash
kubectl apply -f 30-hpa.yaml

kubectl -n lab-06-autoscaling get hpa demo-app
kubectl -n lab-06-autoscaling describe hpa demo-app
```

Observe in `get`: `TARGETS` shows something like `15%/75%, 1%/60%` (memory first, then CPU — the order follows the `metrics` array). If either shows `<unknown>`, metrics-server is not delivering yet.

Observe in `describe`, the Conditions block — this is the part people skip and then debug for an hour:

```text
Conditions:
  Type            Status  Reason              Message
  AbleToScale     True    ReadyForNewScale    recommended size matches current size
  ScalingActive   True    ValidMetricFound    the HPA was able to successfully
                                              calculate a replica count from cpu
                                              resource utilization (percentage of request)
  ScalingLimited  False   DesiredWithinRange  the desired count is within the
                                              acceptable range
```

`ScalingActive: False` with reason `FailedGetResourceMetric` is the metrics-server-is-broken signature. `ScalingLimited: True` with reason `TooManyReplicas` means you are pinned at `maxReplicas` and are silently under-provisioned — alert on that condition in production.

### 4. Watch the HPA while you apply load

Open three terminals.

Terminal 1 — the HPA:

```bash
kubectl -n lab-06-autoscaling get hpa demo-app -w
```

Terminal 2 — the Pods:

```bash
kubectl -n lab-06-autoscaling get pods -w
```

Terminal 3 — drive load:

```bash
kubectl apply -f 50-load-generator.yaml
kubectl -n lab-06-autoscaling scale deploy/load-generator --replicas=4
kubectl -n lab-06-autoscaling logs -l app.kubernetes.io/name=load-generator --tail=5 -f
```

Observe, over roughly the next two minutes:

- Within ~15–30s the HPA's CPU column climbs past 60% and keeps going — `/burn` pins a full core, so you will see values in the hundreds of percent (e.g. `480%/60%`).
- `REPLICAS` jumps. The `behavior` block permits `max(100% of current, 4 Pods)` per 30s, so 2 → 6 → 10 rather than a slow crawl. It stops at 10 because that is `maxReplicas`.
- `describe hpa` now shows `ScalingLimited: True, Reason: TooManyReplicas`.
- New Pods spend a few seconds `ContainerCreating` → `Running` → `Ready`. Only Ready Pods count toward the utilisation average; the HPA also ignores Pods that are still starting up, so it does not mistake a cold Pod's 0% CPU for spare capacity.

Check the events, which narrate every decision:

```bash
kubectl -n lab-06-autoscaling describe hpa demo-app | tail -20
```

Observe lines like `SuccessfulRescale  New size: 6; reason: cpu resource utilization (percentage of request) above target`.

If your kind cluster is small, some Pods may go `Pending` with `FailedScheduling: 0/2 nodes are available: Insufficient cpu`. **This is the single most important thing in the lab** — it is exactly the signal the Cluster Autoscaler or Karpenter watches for. See the notes section below.

### 5. Stop the load and watch the stabilization window

```bash
kubectl -n lab-06-autoscaling scale deploy/load-generator --replicas=0
date
```

Keep terminal 1 open and watch the clock.

Observe:

- CPU utilisation drops back to ~1% within ~30 seconds.
- `REPLICAS` **does not move.** It sits at 10 for a full five minutes.
- Roughly 300 seconds after load stopped, replicas begin stepping down — and even then only by `min(50%, 2 Pods)` per minute, so you will see something like 10 → 8 → 6 → 4 → 2 over four more minutes.
- It stops at 2, the `minReplicas` floor, never lower.

That five-minute pause is `scaleDown.stabilizationWindowSeconds: 300`. The HPA keeps the *highest* recommendation from the trailing window, so a brief dip cannot tear down capacity you are about to need again. Compare with `scaleUp.stabilizationWindowSeconds: 0`: up is instant, down is patient. Deliberate asymmetry — the cost of being wrong in each direction is not the same.

To feel the difference, temporarily shrink the window and repeat:

```bash
kubectl -n lab-06-autoscaling patch hpa demo-app --type=merge \
  -p '{"spec":{"behavior":{"scaleDown":{"stabilizationWindowSeconds":30}}}}'
# ...drive load, stop it, watch it collapse within ~30-60s...
kubectl apply -f 30-hpa.yaml   # restore
```

### 6. Prove that the *request* is the denominator

```bash
# Halve the request without touching anything else.
kubectl -n lab-06-autoscaling set resources deploy/demo-app \
  --requests=cpu=50m --containers=demo-app
kubectl -n lab-06-autoscaling rollout status deploy/demo-app

kubectl -n lab-06-autoscaling get hpa demo-app
```

Observe: with identical real CPU consumption, the reported utilisation percentage roughly **doubles**, and the HPA becomes correspondingly twitchier. Nothing about the workload changed — only the number you divided by. This is why "just lower the requests to fit more Pods on a node" is never a free action when an HPA is in play.

Restore it:

```bash
kubectl apply -f 10-deployment.yaml
```

### 7. Exercise the PodDisruptionBudget

```bash
kubectl -n lab-06-autoscaling get pdb demo-app -o wide

NODE=$(kubectl -n lab-06-autoscaling get pod \
  -l app.kubernetes.io/name=demo-app \
  -o jsonpath='{.items[0].spec.nodeName}')

kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data --dry-run=server
```

Observe: the dry run lists the Pods that would be evicted. With `maxUnavailable: 25%` and 2 replicas, exactly one may go at a time; the drain would evict, wait for the replacement to become Ready, then continue. Had you written `minAvailable: 2` against `minReplicas: 2`, `ALLOWED DISRUPTIONS` would read `0` and this drain would hang forever — the classic PDB/HPA deadlock.

(Skip the real drain on a two-node kind cluster, or `kubectl uncordon "$NODE"` afterwards.)

### 8. Optional — the VerticalPodAutoscaler

Only if you installed the VPA CRDs (see the header of `optional/60-vpa.yaml`):

```bash
kubectl apply -f optional/60-vpa.yaml

# The recommender needs 5-15 minutes of history before it says anything useful.
kubectl -n lab-06-autoscaling describe vpa demo-app
```

Observe the `Recommendation` block: `target`, `lowerBound`, `upperBound` and `uncappedTarget` per container. Because `updateMode: "Off"`, nothing is applied — it is advice, which you then commit to Git. Note that `controlledResources: ["memory"]` means the recommender will not touch CPU, keeping it out of the HPA's way entirely.

## Verification

```bash
# 1. The metrics pipeline is healthy.
kubectl get apiservices v1beta1.metrics.k8s.io \
  -o jsonpath='{.status.conditions[?(@.type=="Available")].status}{"\n"}'
# expected: True

# 2. The HPA can actually compute a recommendation.
kubectl -n lab-06-autoscaling get hpa demo-app \
  -o jsonpath='{.status.conditions[?(@.type=="ScalingActive")].status}{"\n"}'
# expected: True

# 3. Both metrics are configured and reporting.
kubectl -n lab-06-autoscaling get hpa demo-app \
  -o jsonpath='{range .status.currentMetrics[*]}{.resource.name}={.resource.current.averageUtilization}%{"\n"}{end}'
# expected: two lines, e.g. "cpu=1%" and "memory=18%"

# 4. Bounds are what we asked for.
kubectl -n lab-06-autoscaling get hpa demo-app \
  -o jsonpath='min={.spec.minReplicas} max={.spec.maxReplicas}{"\n"}'
# expected: min=2 max=10

# 5. The behavior block survived the apply (it is easy to lose in a merge).
kubectl -n lab-06-autoscaling get hpa demo-app \
  -o jsonpath='up={.spec.behavior.scaleUp.stabilizationWindowSeconds} down={.spec.behavior.scaleDown.stabilizationWindowSeconds}{"\n"}'
# expected: up=0 down=300

# 6. The request that the HPA divides by.
kubectl -n lab-06-autoscaling get deploy demo-app \
  -o jsonpath='{.spec.template.spec.containers[0].resources.requests.cpu}{"\n"}'
# expected: 100m

# 7. The PDB permits at least one eviction (no drain deadlock).
kubectl -n lab-06-autoscaling get pdb demo-app \
  -o jsonpath='{.status.disruptionsAllowed}{"\n"}'
# expected: 1  (with 2 healthy replicas)

# 8. End-to-end scale test, scripted.
kubectl -n lab-06-autoscaling scale deploy/load-generator --replicas=4
sleep 120
kubectl -n lab-06-autoscaling get deploy demo-app \
  -o jsonpath='{.spec.replicas}{"\n"}'
# expected: > 2  (typically 6-10)
kubectl -n lab-06-autoscaling scale deploy/load-generator --replicas=0
```

## Cleanup

```bash
# VPA first, if you applied it (its CRD is cluster-scoped but the CR is not).
kubectl delete -f optional/60-vpa.yaml --ignore-not-found

# Stop load before anything else, so the HPA is not mid-flight.
kubectl -n lab-06-autoscaling scale deploy/load-generator --replicas=0 \
  --ignore-not-found

kubectl delete -f 00-namespace.yaml --ignore-not-found

# metrics-server is shared infrastructure - only remove it if you installed it
# for this lab and no other lab needs it (lab 09 does).
# kubectl delete -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

kubectl get ns lab-06-autoscaling
# expected: Error from server (NotFound)
```

## What you learned

- The HPA's formula is `ceil(currentReplicas * currentMetric / targetMetric)`, with a ±10% tolerance band to damp jitter, and it takes the **maximum** desired count across all configured metrics.
- For `type: Utilization`, the denominator is the container's **request**. The limit is invisible to the HPA — but a tight CPU limit throttles the workload and therefore *hides* demand from it.
- `metrics.k8s.io` is an aggregated API served by metrics-server; on kind it needs `--kubelet-insecure-tls`, and when it breaks the HPA fails silently unless you watch the `ScalingActive` condition.
- `behavior` lets you make scale-up immediate and scale-down patient. The scale-down stabilization window keeps the highest recommendation over its lookback period, which is what prevents flapping.
- Scaling on memory rarely does what people hope, because adding replicas does not shrink the memory an existing Pod already holds.
- `minReplicas: 1` is an availability trap; `minAvailable` on a PDB set equal to `minReplicas` is a drain deadlock; `unhealthyPodEvictionPolicy: AlwaysAllow` stops a crash-looping app from blocking node maintenance.
- VPA and HPA must not both control CPU. Split them by resource, or give the HPA a custom/external metric so it never reads a request value.
- Once an HPA owns `.spec.replicas`, your manifests must stop asserting it.
- A Pending Pod is not an autoscaling failure — it is the handoff point from Pod-level to node-level autoscaling.

## Cluster autoscaler notes — where Pods meet nodes

The HPA creates Pods. It has no idea whether a node exists to run them. When it creates more than the cluster can fit, those Pods sit `Pending` with `FailedScheduling: Insufficient cpu`, and that unschedulable state is the *only* signal the node-level autoscalers act on. HPA and node autoscaling are coupled through the scheduler, not through any direct API — which is why "my HPA scaled to 20 and half of them are Pending" is a node-layer problem, always.

### Cluster Autoscaler (CA)

The classic answer, and still the right one for many EKS clusters. CA watches for unschedulable Pods, runs a simulated scheduling pass against each node group's template, picks a group whose template *would* fit the Pod, and increments the ASG's desired capacity.

- **It scales node groups, not nodes.** Every node in a group must be interchangeable, because CA reasons about one representative template per group.
- **ASG tagging is mandatory** for auto-discovery (`--node-group-auto-discovery=asg:tag=...`):
  - `k8s.io/cluster-autoscaler/enabled` = `true`
  - `k8s.io/cluster-autoscaler/<cluster-name>` = `owned`
  - For groups that can scale from zero, CA cannot inspect a running node, so you must advertise capacity via tags: `k8s.io/cluster-autoscaler/node-template/label/<key>`, `.../node-template/taint/<key>`, and `.../node-template/resources/<resource>`. Forgetting these is the number-one reason scale-from-zero silently does nothing.
- **Version pinning:** CA's minor version must match the cluster's (CA 1.31 for EKS 1.31). It is not forward or backward compatible.
- **`--balance-similar-node-groups=true`** spreads capacity evenly across node groups that CA judges equivalent — in practice, one group per AZ. Without it, CA will happily put every new node in a single AZ, which is how you end up with an "HA" service that is single-AZ, and with cross-AZ data transfer charges. Pair it with `--balancing-ignore-label` for labels that differ cosmetically between groups (e.g. `topology.ebs.csi.aws.com/zone`).
- **Expander strategies** (`--expander=`) decide *which* eligible group grows:
  - `random` — default, no intelligence.
  - `most-pods` — fits the most pending Pods with one node; good for batch.
  - `least-waste` — smallest leftover CPU/memory after scheduling; the sensible general default.
  - `price` — cheapest option (needs cloud pricing support).
  - `priority` — you supply a ConfigMap ranking groups by regex; the practical choice for "spot first, on-demand as fallback".
  - They can be chained (`--expander=priority,least-waste`) and evaluated in order as tie-breakers.
- **Scale-down** removes a node when its utilisation is below `--scale-down-utilization-threshold` (default 0.5) for `--scale-down-unneeded-time` (default 10m) *and* every Pod on it can be rescheduled elsewhere. Things that block it, and which you will debug repeatedly: PDBs with no allowed disruptions, Pods with local storage (`--skip-nodes-with-local-storage`, default true), kube-system Pods without a PDB (`--skip-nodes-with-system-pods`, default true), and bare Pods with no controller. The annotation `cluster-autoscaler.kubernetes.io/safe-to-evict: "false"` pins a Pod — and therefore its node — in place; audit for it when nodes refuse to drain.

### Karpenter

The newer, and generally better, answer on EKS. Karpenter skips ASGs entirely and calls the EC2 Fleet API directly, provisioning a right-sized instance for the specific pending Pods it sees.

- **`NodePool`** declares what Karpenter may provision: instance-type/capacity-type/architecture/zone requirements, taints and labels, limits (`limits.cpu`, `limits.memory`) as a hard budget, `disruption.consolidationPolicy` (`WhenEmptyOrUnderutilized` / `WhenEmpty`), `disruption.consolidateAfter`, `expireAfter` for forced node rotation, and `disruption.budgets` to rate-limit churn (e.g. `nodes: "10%"`, or a schedule-based budget that blocks consolidation during business hours).
- **`EC2NodeClass`** is the AWS-specific half: AMI family/selector, subnet and security-group selector terms, IAM role or instance profile, block device mappings, `metadataOptions` (set `httpPutResponseHopLimit: 1` — see lab 07), and user data.
- **Consolidation** is the headline feature: Karpenter continuously looks for nodes it can delete or *replace with something cheaper*, including swapping three half-empty large instances for one right-sized one. CA can only delete underutilised nodes; it cannot replace them with a different shape. Pin critical workloads with `karpenter.sh/do-not-disrupt: "true"` on the Pod when consolidation churn is unacceptable.
- **Practical advantages:** no node-group sprawl (one NodePool can span dozens of instance types, which also makes Spot far more reliable because the allocation pool is wide), bin-packing informed by actual Pod requests, faster provisioning (typically under a minute vs. several for ASG), and native Spot interruption handling via SQS.
- **Migration reality check:** Karpenter itself must run somewhere — a small managed node group or Fargate profile — and it needs an IAM role via IRSA/Pod Identity plus the `KarpenterNodeRole` mapped in Access Entries (or `aws-auth`) so its nodes can join. Running CA and Karpenter simultaneously on the same capacity is a known way to get duplicate scale-ups; scope them to disjoint node sets during migration.

### Overprovisioning: buying back the node-provisioning latency

Even Karpenter takes ~40–60 seconds to get a node Ready. If your traffic ramps faster than that, HPA + node autoscaling is structurally too slow, and no tuning fixes it. The standard trick is to keep a reservation of *cheap, evictable* capacity:

```yaml
# A PriorityClass with a NEGATIVE value, below the global default of 0.
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: overprovisioning
value: -10
globalDefault: false
description: "Placeholder pods that are preempted the moment real work arrives."
```

Then run a Deployment of `registry.k8s.io/pause` Pods using that PriorityClass, with resource requests sized to one "unit" of your real workload. They consume schedulable capacity — so the node autoscaler keeps that capacity warm — but the instant a real Pod (priority 0 or above) needs room, the scheduler preempts a pause Pod and the real Pod binds immediately to an already-running node. The pause Pods then go Pending, which triggers the node autoscaler to replenish the buffer in the background. You are trading a fixed monthly cost for bounded scale-up latency, and you can scale the buffer itself on a schedule (a CronJob, or `cluster-proportional-autoscaler` sizing it against cluster size).

### The full chain, in order

1. Traffic rises → container CPU rises.
2. metrics-server scrapes kubelets (~15s cadence).
3. HPA control loop (default `--horizontal-pod-autoscaler-sync-period=15s`) reads `metrics.k8s.io`, applies its formula plus the ±10% tolerance and the `behavior` policies, and patches `.spec.replicas`.
4. The Deployment controller creates Pods; the scheduler places what it can.
5. Anything that does not fit goes `Pending` with `FailedScheduling`.
6. CA or Karpenter observes the unschedulable Pods and provisions nodes.
7. Nodes register, Pods bind, containers start, readiness passes, the Service endpoint list grows, traffic distributes.

End to end that is typically 60–180 seconds. **Alert on every stage**: `ScalingActive=False` (broken metrics), `ScalingLimited=True` with `TooManyReplicas` (pinned at max), Pods Pending longer than ~2 minutes (node layer stuck), and `disruptionsAllowed=0` on any PDB (drains will hang). Those four alerts catch nearly every autoscaling incident before a human notices the symptom.

## Going further / production notes

- **KEDA** (`keda.sh`) is the pragmatic answer for event-driven scaling on EKS. Its `ScaledObject` generates an HPA under the hood but adds 60+ scalers — SQS queue depth, Kafka consumer lag, CloudWatch metrics, cron schedules — plus genuine scale-to-zero, which a plain HPA cannot do (`minReplicas: 0` requires the `HPAScaleToZero` feature gate). Scaling on queue depth is leading rather than lagging, and it is almost always a better signal than CPU.
- **prometheus-adapter** lets an HPA scale on any Prometheus series via `custom.metrics.k8s.io` — e.g. the `demo_app_http_requests_total` counter this app already exposes, turned into requests-per-second per Pod. That is the natural follow-on from lab 09.
- **Startup time dominates responsiveness.** An HPA cannot outrun a 90-second JVM boot. Track `Pod created → Ready` as a first-class SLI and invest there before tuning HPA parameters; also set `initialReadinessDelay`/`cpuInitializationPeriod` awareness in mind — the HPA discounts Pods that are still initializing, so slow starters distort the average.
- **Cost.** Right-sizing requests is the highest-leverage cost lever on EKS, and VPA in `updateMode: "Off"` is the cheapest way to find the numbers. Feed its recommendations into Git rather than letting it evict Pods. Pair with Kubecost/OpenCost for per-namespace attribution, and remember that on EKS you pay for *nodes*, so the metric that matters is node-level bin-packing efficiency, not Pod count.
- **Spot + autoscaling** works well with Karpenter (wide instance-type pools, SQS interruption handling, `karpenter.sh/capacity-type` requirements) provided your workloads tolerate a 2-minute eviction notice. Enforce PDBs, keep `terminationGracePeriodSeconds` under 120, and make sure readiness flips false on SIGTERM — the demo app in this repo does exactly that, sleeping 5s after marking itself unready so load balancers deregister before it stops serving.
- **In-place Pod resize** (KEP-1287, beta in 1.33) will eventually let VPA change requests without restarting Pods, which removes the main objection to running it in `Auto`. Worth tracking; not worth depending on yet.
- **AWS specifics that bite:** the VPC CNI's per-instance ENI/IP limits cap Pods per node independently of CPU and memory, so bin-packing can fail for reasons no resource request explains (enable prefix delegation to raise the ceiling); EC2 API throttling during large scale-ups; and ASG cooldowns interfering with CA's own timing (set them to 0 and let CA manage cadence).
