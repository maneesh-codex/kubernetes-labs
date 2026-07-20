# Lab 01 — Pods and Deployments

Almost nobody deploys a bare Pod on purpose, but almost everybody has debugged one at 3am. A Pod is the smallest unit Kubernetes schedules, and it is also the most fragile: nothing owns it, nothing recreates it, and a node replacement quietly takes it with it. A Deployment adds the piece that actually matters in production — a control loop that keeps N healthy replicas alive, rolls new versions out gradually, and rolls them back when they misbehave. This lab builds both side by side so the difference stops being an abstraction: you will delete a pod from each and watch exactly one of them come back.

## Objectives

- Create a bare Pod and a Deployment from the same container image, and articulate why only one is production-viable.
- Read a Deployment's `RollingUpdate` strategy and predict how many pods exist mid-rollout.
- Drive a full release cycle: `rollout status`, `set image`, `rollout history`, `rollout undo`.
- Use the downward API to inject pod identity as environment variables with no Kubernetes client library.
- Explain what `minReadySeconds`, `revisionHistoryLimit`, and `progressDeadlineSeconds` protect you from.
- Distinguish a PodDisruptionBudget (voluntary disruption) from `maxUnavailable` (rollout pacing).
- Spread replicas across nodes with `topologySpreadConstraints`.

## Prerequisites

- A running kind cluster named `k8s-labs`, created with `make cluster-up` from the repo root.
- `kubectl` v1.29 or newer on your `PATH`, with its context pointing at `kind-k8s-labs`.
- The demo image `ghcr.io/maneeshm/k8s-labs-demo:1.0.0` available to the cluster. `make cluster-up` builds and side-loads it with `kind load docker-image`; `imagePullPolicy: IfNotPresent` means the node will use that local copy rather than reaching out to a registry.
- Roughly 300m of CPU and 400Mi of memory of headroom in the cluster for the four pods this lab creates.

## Manifests in this lab

| File | What it does |
| --- | --- |
| `00-namespace.yaml` | Creates namespace `lab-01-workloads` and enforces the `restricted` Pod Security Standard on it. |
| `10-pod.yaml` | A bare Pod (`demo-bare`) with no controller — the counter-example. |
| `20-deployment.yaml` | The `demo-web` Deployment: 3 replicas, `RollingUpdate` with `maxSurge: 1` / `maxUnavailable: 0`, downward-API env, topology spread, startup/liveness/readiness probes. |
| `30-service.yaml` | ClusterIP Service fronting the Deployment so `kubectl port-forward` has a stable target. |
| `40-poddisruptionbudget.yaml` | PDB requiring `minAvailable: 2`, so a node drain can evict only one replica at a time. |

## Walkthrough

### 1. Create the namespace and both workloads

```bash
kubectl apply -f 00-namespace.yaml
kubectl apply -f 10-pod.yaml -f 20-deployment.yaml -f 30-service.yaml -f 40-poddisruptionbudget.yaml
kubectl get all -n lab-01-workloads
```

Note what `kubectl get all` shows: the Deployment produced a **ReplicaSet**, and the ReplicaSet produced the pods. That two-level ownership chain is what makes rollbacks possible — each new version gets its own ReplicaSet, and the old one is kept around (scaled to zero) rather than deleted. `demo-bare` appears in the pod list with no owner above it.

### 2. Watch the rollout complete

```bash
kubectl rollout status deployment/demo-web -n lab-01-workloads --timeout=120s
kubectl get pods -n lab-01-workloads -o wide
```

`rollout status` blocks until the Deployment's `.status.updatedReplicas`, `.status.readyReplicas`, and `.spec.replicas` all agree — this is the command to put in CI, not `sleep 30`. Because `minReadySeconds: 10` is set, each pod must hold Ready for ten seconds before it counts, so this takes noticeably longer than pod startup alone.

### 3. Confirm the downward API worked

```bash
kubectl port-forward -n lab-01-workloads svc/demo-web 8080:80 &
sleep 2
curl -s http://localhost:8080/api/info | tee /dev/stderr | grep -o '"pod":"[^"]*"'
kill %1
```

The `pod`, `node`, and `namespace` fields come from `fieldRef` entries, not from any API call the app made. The app has no service account token in use, no client library, and no RBAC — the kubelet wrote those values into the container's environment at start time. This is the cheapest possible way to get identity into an application.

### 4. Scale up and back down

```bash
kubectl scale deployment/demo-web -n lab-01-workloads --replicas=5
kubectl rollout status deployment/demo-web -n lab-01-workloads
kubectl get pods -n lab-01-workloads -l app.kubernetes.io/name=demo-web
kubectl scale deployment/demo-web -n lab-01-workloads --replicas=3
```

Scaling edits `.spec.replicas` on the existing ReplicaSet; it creates no new revision. Confirm that with `kubectl rollout history deployment/demo-web -n lab-01-workloads` — the revision count is unchanged. Only changes to the **pod template** create a revision.

### 5. Perform a rolling update

```bash
kubectl set image deployment/demo-web demo=ghcr.io/maneeshm/k8s-labs-demo:1.0.0 \
  -n lab-01-workloads --record=false
kubectl patch deployment/demo-web -n lab-01-workloads \
  -p '{"spec":{"template":{"spec":{"containers":[{"name":"demo","env":[{"name":"GREETING","value":"v2 rollout"}]}]}}}}'
kubectl rollout status deployment/demo-web -n lab-01-workloads
kubectl get rs -n lab-01-workloads
```

The `set image` call is a no-op here (same tag), which is itself instructive: Kubernetes diffs the pod template, and an identical template produces no rollout. The `patch` that follows genuinely changes the template, so a second ReplicaSet appears. Watch `kubectl get pods -n lab-01-workloads -w` in another terminal during the patch — with `maxSurge: 1` and `maxUnavailable: 0` you will briefly see four pods, never two.

### 6. Inspect and roll back

```bash
kubectl rollout history deployment/demo-web -n lab-01-workloads
kubectl describe deployment/demo-web -n lab-01-workloads | sed -n '/Events/,$p'
kubectl rollout undo deployment/demo-web -n lab-01-workloads
kubectl rollout status deployment/demo-web -n lab-01-workloads
```

`describe` is where you find the real story during an incident: the `Events` block shows `ScalingReplicaSet` lines in order, and the `Conditions` block shows `Progressing`/`Available`. `rollout undo` scales the previous ReplicaSet back up rather than re-pulling or rebuilding anything, which is why rollback is fast — the old pods' spec never left etcd.

### 7. The key lesson: delete a pod of each kind

```bash
kubectl delete pod demo-bare -n lab-01-workloads
kubectl delete pod -n lab-01-workloads -l app.kubernetes.io/name=demo-web \
  --field-selector=status.phase=Running --wait=false
sleep 5
kubectl get pods -n lab-01-workloads
```

`demo-bare` is gone permanently — there is no controller watching for its absence. The `demo-web` pods are already being replaced: the ReplicaSet controller saw `currentReplicas < desiredReplicas` and created new ones, with new names. This is the whole argument against bare pods. A bare pod does not survive a node upgrade, a spot interruption, an eviction, or a fat-fingered `kubectl delete`.

### 8. See the PodDisruptionBudget do its job

```bash
kubectl get pdb -n lab-01-workloads
kubectl get pdb demo-web -n lab-01-workloads \
  -o jsonpath='{.status.currentHealthy}/{.status.desiredHealthy} healthy, {.status.disruptionsAllowed} disruptions allowed{"\n"}'
```

With three healthy replicas and `minAvailable: 2`, `disruptionsAllowed` is 1. Scale to 2 replicas and re-check: it drops to 0, and any `kubectl drain` touching those nodes will block rather than take the service down. That blocking behaviour is the point — it is what turns an unattended node rotation into a safe operation.

## Verification

```bash
kubectl get deployment demo-web -n lab-01-workloads \
  -o jsonpath='{.status.readyReplicas}/{.spec.replicas}{"\n"}'
```

Expected output:

```text
3/3
```

```bash
kubectl get pod demo-bare -n lab-01-workloads --ignore-not-found
```

Expected output after step 7: empty (the pod is not recreated).

```bash
kubectl get endpointslices -n lab-01-workloads -l kubernetes.io/service-name=demo-web \
  -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}{" ready="}{.conditions.ready}{"\n"}{end}'
```

Expected output: three lines, each an in-cluster pod IP with `ready=true`.

```bash
kubectl port-forward -n lab-01-workloads svc/demo-web 8080:80 >/dev/null 2>&1 &
sleep 2 && curl -sf http://localhost:8080/healthz && echo && kill %1
```

Expected output:

```text
{"status":"ok","uptime":"3m12.4s"}
```

```bash
kubectl get pdb demo-web -n lab-01-workloads -o jsonpath='{.status.disruptionsAllowed}{"\n"}'
```

Expected output: `1`.

## Cleanup

```bash
kubectl delete namespace lab-01-workloads --wait=true
```

Deleting the namespace garbage-collects everything inside it: the Deployment, its ReplicaSets, the pods, the Service, and the PDB. If you prefer to remove only the objects this lab created, `kubectl delete -f . -n lab-01-workloads --ignore-not-found` works too.

## What you learned

- A Pod is scheduled once and never rescheduled; a Deployment owns a ReplicaSet which owns pods, and that chain is what provides self-healing.
- Rollbacks are fast because old ReplicaSets are retained at zero replicas — `revisionHistoryLimit` controls how many.
- `maxSurge` / `maxUnavailable` govern rollout pacing, while a PodDisruptionBudget governs voluntary disruptions like drains. They are unrelated knobs that are frequently confused.
- `minReadySeconds` defends against the pod that passes readiness once and then falls over.
- A startup probe suppresses the liveness probe during boot, which is how you support slow-starting apps without weakening liveness detection afterwards.
- The downward API supplies pod, node, and namespace identity for free — no RBAC, no client library, no sidecar.
- Referencing a container port by name (`targetPort: http`) decouples the Service from the port number.
- Editing `.spec.replicas` creates no revision; editing the pod template does.

## Going further / production notes

- **Node lifecycle on EKS.** Managed node groups and Karpenter both drain nodes on rotation, and both respect PDBs. A missing or badly configured PDB is the most common reason a routine AMI upgrade turns into a partial outage — and a PDB with `minAvailable` equal to the replica count is worse, because it blocks the drain forever and stalls the upgrade.
- **Spot interruptions.** On spot-backed node groups you get a two-minute warning, which is a *voluntary* eviction and therefore PDB-aware. `terminationGracePeriodSeconds: 30` plus the demo app's readiness-then-drain shutdown sequence is the pattern to copy; ensure the grace period exceeds your longest in-flight request.
- **Multi-AZ spreading.** In EKS, add a second `topologySpreadConstraint` on `topology.kubernetes.io/zone` with `whenUnsatisfiable: DoNotSchedule`. Zone-level spreading is what actually survives an AZ event; hostname spreading alone does not.
- **`maxUnavailable: 0` costs capacity.** It requires headroom for one extra pod for the duration of the rollout. With Cluster Autoscaler that can mean waiting on a new node mid-rollout; `progressDeadlineSeconds: 600` is what stops that from hanging indefinitely and instead marks the Deployment `Progressing=False`.
- **Never use `:latest`.** `imagePullPolicy: IfNotPresent` with a mutable tag gives you nodes running different code with identical manifests. Pin a semver tag, or better, a digest (`@sha256:...`), which is also what makes `rollout undo` genuinely deterministic.
- **Prefer `kubectl rollout restart` over deleting pods.** It bumps a template annotation, so the change is auditable, respects the rollout strategy, and shows up in `rollout history` — deleting pods by hand does none of those things.
- **Watch the right signals.** Alert on `kube_deployment_status_replicas_unavailable` and on the `Progressing` condition flipping to `False`, not on pod restarts alone. In a GitOps setup (see lab 10), a failed rollout should block the sync rather than silently leave the old ReplicaSet serving.
