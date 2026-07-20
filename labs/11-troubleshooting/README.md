# Lab 11 — Troubleshooting: a Kubernetes Debugging Runbook

Kubernetes failures are rarely mysterious once you know where to look — but the information is scattered across four or five places (Pod status, container state, events, logs, endpoints), and the symptom is frequently several layers away from the cause. A readiness probe pointing at the wrong port surfaces to your customer as `connection refused` from a Service that looks perfectly healthy. A missing ConfigMap produces a Pod with no logs at all. An OOM kill leaves no trace in the application's own output, because SIGKILL cannot be caught. This lab is a runbook you can actually use during an incident, backed by ten deliberately broken manifests and their corrected counterparts. Break them, diagnose them from the symptom alone, then compare your reasoning to the write-up. The goal is not to memorise ten bugs — it is to internalise the four-command triage loop that identifies almost any of them in under a minute.

## Objectives

- Run a fast, repeatable triage loop: status → events → describe → logs.
- Read a Pod's `phase`, container `state`, `lastState`, and `reason` fields, and know which one answers which question.
- Distinguish failures that look identical from the outside: Pending-for-capacity vs Pending-for-affinity; no-endpoints-from-readiness vs no-endpoints-from-selector.
- Use `kubectl logs --previous`, `kubectl get events --sort-by`, `kubectl get endpoints`, `kubectl debug` (ephemeral containers) and a `netshoot` Pod fluently.
- Diagnose and fix ten realistic production failures.
- Derive an RBAC rule mechanically from a `Forbidden` message.
- Fix a `readOnlyRootFilesystem` conflict *without* weakening the security posture.

## Prerequisites

- A running kind cluster named `k8s-labs` (`make cluster-up` from the repo root).
- The demo image `ghcr.io/maneeshm/k8s-labs-demo:1.0.0` loaded (`make image`); ability to pull `busybox:1.36`, `bitnami/kubectl:1.31` and `nicolaka/netshoot`.
- `kubectl` v1.29+ (ephemeral containers via `kubectl debug` are GA from 1.25).
- Optional but excellent: `stern` for multi-pod log tailing, `kubectl-tree`/`kubectl-neat`, `k9s`.
- Labs 01–07 give useful background, especially 05 (RBAC) and 07 (networking).

## Manifests in this lab

| File | What it does |
| --- | --- |
| `00-namespace.yaml` | Creates `lab-11-troubleshooting`. Note it uses PSS `warn`/`audit` but **not** `enforce` — see the file for why. |
| `broken/01-imagepullbackoff.yaml` | Nonexistent image tag + `imagePullPolicy: Always`. |
| `broken/02-crashloopbackoff.yaml` | Startup validation fails on a missing config file; container exits 1. |
| `broken/03-pending-resources.yaml` | `cpu: 100` and `memory: 64Gi` — the missing-`m` typo. Unschedulable. |
| `broken/04-pending-nodeselector.yaml` | `nodeSelector` + required node affinity matching no node. |
| `broken/05-readiness-wrong-port.yaml` | Readiness probe on `/health/ready:9090`; Pods never Ready; Service has no endpoints. |
| `broken/06-service-selector-typo.yaml` | Service selector uses the wrong label key *and* value; 0 endpoints with healthy Pods. |
| `broken/07-oomkilled.yaml` | Writes 200 MiB into a tmpfs with a 32Mi memory limit. Exit code 137. |
| `broken/08-missing-configmap-secret.yaml` | References three ConfigMaps/Secrets that do not exist. |
| `broken/09-rbac-forbidden.yaml` | ServiceAccount with no Role or RoleBinding; app logs 403s. |
| `broken/10-readonly-rootfs.yaml` | `readOnlyRootFilesystem: true` with no writable volumes; app writes to `/var/run`, `/var/log`. |
| `fixed/NN-*.yaml` | The corrected counterpart of each scenario, same object names so `kubectl apply` is an in-place repair. All are fully restricted-PSS compliant. |

## The triage loop

Four commands, in this order, answer 90% of Kubernetes incidents. Run them before forming any hypothesis.

```bash
NS=lab-11-troubleshooting

# 1. WHAT is wrong? Status, restart count, age.
kubectl -n $NS get pods -o wide

# 2. WHEN and WHY? Events are the control plane narrating its own decisions.
kubectl -n $NS get events --sort-by=.lastTimestamp | tail -30

# 3. DETAIL. The Events block at the bottom of describe is scoped to this Pod.
kubectl -n $NS describe pod <pod>

# 4. WHAT DID THE APP SAY? --previous reads the crashed container, not the new one.
kubectl -n $NS logs <pod> --tail=50
kubectl -n $NS logs <pod> --previous --tail=50
```

> **Events expire.** The default TTL is one hour. If `get events` is empty during a post-mortem, that is not evidence of health — it is evidence you were too late. Ship events to your logging backend (`eventrouter`, the OTel Collector's `k8sobjects` receiver, or Fluent Bit's `kubernetes_events` input) so they survive.

### Triage decision list

Start at the Pod's `STATUS` column and follow the branch.

```text
STATUS?
│
├─ Pending ────────────────► describe pod → the FailedScheduling message
│   ├─ "Insufficient cpu/memory" ............. capacity/requests  → scenario 03
│   ├─ "didn't match Pod's node affinity/selector" ................ scenario 04
│   ├─ "had untolerated taint {...}" ......... missing toleration
│   ├─ "had volume node affinity conflict" ... PV is in another AZ
│   └─ "pod has unbound immediate PersistentVolumeClaims" → check PVC/StorageClass
│
├─ ContainerCreating ──────► describe pod → Events
│   ├─ FailedMount: "configmap X not found" ................. scenario 08
│   ├─ FailedMount: timeout waiting for attach/mount ......... CSI driver / EBS
│   └─ FailedCreatePodSandBox ............................... CNI / IP exhaustion
│
├─ ImagePullBackOff / ErrImagePull ────────────────────────── scenario 01
│   ├─ "manifest unknown" / "not found" ...... bad tag or repo
│   ├─ "unauthorized" / "denied" ............. missing imagePullSecrets / ECR auth
│   └─ "dial tcp ... i/o timeout" ............ egress / NAT / VPC endpoint
│
├─ CreateContainerConfigError ─────────────────────────────── scenario 08
│      (env references a missing ConfigMap/Secret or key)
│
├─ CreateContainerError / RunContainerError
│      (bad command path, bad securityContext, runAsNonRoot with a root image)
│
├─ CrashLoopBackOff ───────► logs --previous  +  lastState.reason
│   ├─ exitCode 1/2 with app output ......................... scenario 02
│   ├─ exitCode 137 + reason OOMKilled ...................... scenario 07
│   ├─ exitCode 143 (SIGTERM) ............... liveness probe killing a slow app
│   └─ exitCode 0, restartPolicy Always ..... a job-shaped workload in a Deployment
│
├─ Running but 0/1 READY ──► describe pod → "Readiness probe failed"
│      → then: get endpoints .............................. scenario 05
│
├─ Running and 1/1 READY, but callers get errors
│   ├─ endpoints EMPTY ...................... Service selector wrong → scenario 06
│   ├─ endpoints PRESENT, connection refused . wrong targetPort / app not listening
│   ├─ DNS resolution fails ................. NetworkPolicy egress (lab 07)
│   └─ app logs show 403 ................... RBAC → scenario 09
│
├─ Error / Completed (unexpectedly) ─────── check restartPolicy and exit code
│
├─ Evicted ────────────────► describe node → MemoryPressure / DiskPressure
│
└─ Terminating (stuck) ────► finalizers, or a preStop hook / SIGTERM handler that hangs
```

### Symptom → cause → command → fix

| Symptom | Likely cause | Diagnose with | Fix |
| --- | --- | --- | --- |
| `ImagePullBackOff`, "manifest unknown" | Bad tag/digest, or image not in the registry | `kubectl describe pod` → Events | Correct the tag; `docker manifest inspect <img>` to confirm. `fixed/01` |
| `ImagePullBackOff`, "unauthorized" | Missing `imagePullSecrets`; ECR token expired; node role lacks `ecr:GetAuthorizationToken` | `kubectl describe pod`; `aws ecr get-login-password` | Add a pull secret or fix the node IAM policy |
| `ImagePullBackOff` on kind only | `imagePullPolicy: Always` with a side-loaded image | `kubectl get pod -o yaml \| grep imagePullPolicy` | `IfNotPresent`; re-run `kind load docker-image` |
| `CrashLoopBackOff`, app logs a fatal error | Bad config/command/args; missing dependency | `kubectl logs --previous` | Fix config; add a `startupProbe`. `fixed/02` |
| `CrashLoopBackOff`, exit 137, no logs | OOMKilled — memory limit too low | `kubectl get pod -o jsonpath='{..lastState.terminated}'` | Raise the limit; size from real data. `fixed/07` |
| `CrashLoopBackOff`, exit 143 | Liveness probe killing a slow-starting app | `describe` → "Liveness probe failed" | Add `startupProbe`; raise `initialDelaySeconds` |
| `Pending`, "Insufficient cpu" | Requests exceed any node's allocatable | `describe pod`; `kubectl describe node` | Fix the units; add a `LimitRange`. `fixed/03` |
| `Pending`, "didn't match node selector" | `nodeSelector`/required affinity matches nothing | `kubectl get nodes --show-labels` | Relax to `preferred`; fix the label. `fixed/04` |
| `Pending`, "untolerated taint" | Node is tainted; Pod has no toleration | `kubectl describe node \| grep Taints` | Add the toleration, or target another pool |
| `CreateContainerConfigError` | Missing ConfigMap/Secret or missing key | `describe pod` → Events (logs are empty!) | Create the object, or `optional: true`. `fixed/08` |
| `ContainerCreating` + FailedMount | Missing ConfigMap volume, or CSI/EBS attach failure | `describe pod`; CSI driver logs | Create the object; check the volume's AZ |
| Pod Running, `0/1 READY` | Readiness probe path/port wrong | `describe pod` → "Readiness probe failed" | Use the **named** port. `fixed/05` |
| Service reachable but 0 endpoints, Pods `1/1` | Service selector does not match Pod labels | `kubectl get endpoints <svc>`; compare labels | Copy the Deployment's `matchLabels`. `fixed/06` |
| Endpoints exist, connection refused | Wrong `targetPort`, or app bound to `127.0.0.1` | `kubectl port-forward` direct to the Pod | Fix `targetPort`; bind `0.0.0.0` |
| App logs `Forbidden` / 403 | ServiceAccount lacks RBAC | `kubectl auth can-i --as=system:serviceaccount:NS:SA ...` | Add Role **and** RoleBinding. `fixed/09` |
| `Read-only file system` / EROFS | `readOnlyRootFilesystem` + an app that writes | `kubectl logs`; `kubectl debug` and `mount` | Mount an emptyDir at each write path. `fixed/10` |
| `Permission denied` on a mounted volume | UID/GID mismatch on the volume | `kubectl debug` → `ls -ln` | Set `fsGroup` |
| DNS resolution fails after a policy change | Default-deny egress with no DNS rule | `nslookup` from the Pod; `get netpol` | Allow UDP **and** TCP 53 to kube-system (lab 07) |
| Pod `Evicted` | Node MemoryPressure / DiskPressure | `describe node`; `kubectl get events` | Set requests; add ephemeral-storage limits |
| Pod stuck `Terminating` | Finalizer, or SIGTERM not handled | `kubectl get pod -o yaml \| grep finalizers` | Remove the finalizer; handle SIGTERM |

### The canonical command set

```bash
NS=lab-11-troubleshooting

# --- Status -----------------------------------------------------------------
kubectl -n $NS get pods -o wide
kubectl -n $NS get pods -o custom-columns=\
'NAME:.metadata.name,STATUS:.status.phase,READY:.status.containerStatuses[*].ready,'\
'RESTARTS:.status.containerStatuses[*].restartCount,'\
'REASON:.status.containerStatuses[*].state.waiting.reason,'\
'LAST:.status.containerStatuses[*].lastState.terminated.reason'

# Everything unhealthy in the whole cluster, one command.
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded

# --- Events -----------------------------------------------------------------
kubectl -n $NS get events --sort-by=.lastTimestamp | tail -40
kubectl -n $NS get events --field-selector type=Warning --sort-by=.lastTimestamp
kubectl -n $NS get events --field-selector involvedObject.name=<pod>
kubectl get events -A --sort-by=.lastTimestamp -w    # live feed

# --- Detail -----------------------------------------------------------------
kubectl -n $NS describe pod <pod>
kubectl -n $NS get pod <pod> -o yaml | less
kubectl -n $NS get pod <pod> -o jsonpath='{.status.containerStatuses[0].lastState}' | jq

# --- Logs -------------------------------------------------------------------
kubectl -n $NS logs <pod>
kubectl -n $NS logs <pod> --previous               # THE crash-loop command
kubectl -n $NS logs <pod> -c <container>           # multi-container pods
kubectl -n $NS logs -l app.kubernetes.io/name=X --all-containers --tail=50 -f
kubectl -n $NS logs <pod> --since=10m --timestamps
# stern is worth installing: stern -n $NS . --since 10m

# --- Networking -------------------------------------------------------------
kubectl -n $NS get svc,endpoints,endpointslices
kubectl -n $NS get endpoints <svc> -o wide         # EMPTY = your answer is here
kubectl -n $NS port-forward pod/<pod> 8080:8080    # bypass the Service entirely
kubectl -n $NS get netpol

# --- Inside the container ---------------------------------------------------
# Ephemeral container: shares the target's network + process namespace. Works on
# distroless images with no shell, and does NOT restart the Pod.
kubectl -n $NS debug -it <pod> --image=nicolaka/netshoot --target=<container>

# A copy of the Pod with a debug container and the command overridden - the way
# to inspect a Pod that is crash-looping too fast to exec into.
kubectl -n $NS debug <pod> -it --copy-to=<pod>-debug --container=<container> \
  --image=busybox:1.36 -- sh

# A throwaway network toolbox pod.
kubectl -n $NS run tmp-shell --rm -it --restart=Never \
  --image=nicolaka/netshoot -- bash
#   inside: dig backend.$NS.svc.cluster.local ; curl -v http://svc:port/ ;
#           nc -zv host port ; ss -tulpn ; traceroute ; tcpdump -i any port 8080

# Debug a NODE (mounts the host filesystem at /host).
kubectl debug node/<node> -it --image=busybox:1.36

# --- Control plane / cluster ------------------------------------------------
kubectl get nodes -o wide
kubectl describe node <node> | sed -n '/Allocated resources/,/Events/p'
kubectl top nodes ; kubectl -n $NS top pods
kubectl -n $NS rollout status deploy/<name>
kubectl -n $NS rollout history deploy/<name>
kubectl -n $NS rollout undo deploy/<name>
kubectl auth can-i --list --as=system:serviceaccount:$NS:<sa> -n $NS
kubectl api-resources --verbs=list -o name   # is the CRD even installed?
```

## Walkthrough

Create the namespace once:

```bash
kubectl apply -f 00-namespace.yaml
export NS=lab-11-troubleshooting
```

Then work each scenario: apply the broken manifest, diagnose it **before** reading the root cause, and apply the fix.

---

### Scenario 01 — ImagePullBackOff

```bash
kubectl apply -f broken/01-imagepullbackoff.yaml
sleep 25
kubectl -n $NS get pods -l app.kubernetes.io/name=broken-01-imagepull
```

**Symptom**

```text
NAME                                  READY   STATUS             RESTARTS   AGE
broken-01-imagepull-6c9f8d4b7-x2klm   0/1     ImagePullBackOff   0          25s
```

**Diagnose**

```bash
POD=$(kubectl -n $NS get pod -l app.kubernetes.io/name=broken-01-imagepull \
  -o jsonpath='{.items[0].metadata.name}')
kubectl -n $NS describe pod "$POD" | tail -15
```

Exact error text:

```text
Events:
  Type     Reason     Age                From               Message
  ----     ------     ----               ----               -------
  Normal   Scheduled  30s                default-scheduler  Successfully assigned ...
  Normal   Pulling    18s (x2 over 30s)  kubelet            Pulling image "ghcr.io/maneeshm/k8s-labs-demo:9.9.9"
  Warning  Failed     17s (x2 over 29s)  kubelet            Failed to pull image "ghcr.io/maneeshm/k8s-labs-demo:9.9.9":
                                                            rpc error: code = NotFound desc = failed to pull and unpack image
                                                            "ghcr.io/maneeshm/k8s-labs-demo:9.9.9": failed to resolve reference:
                                                            ghcr.io/maneeshm/k8s-labs-demo:9.9.9: not found
  Warning  Failed     17s (x2 over 29s)  kubelet            Error: ErrImagePull
  Normal   BackOff    3s  (x2 over 28s)  kubelet            Back-off pulling image "ghcr.io/maneeshm/k8s-labs-demo:9.9.9"
  Warning  Failed     3s  (x2 over 28s)  kubelet            Error: ImagePullBackOff
```

`kubectl logs` here returns `Error from server (BadRequest): container "demo-app" in pod "..." is waiting to start: trying and failing to pull image` — there is no container, so there are no logs. Events are the only source.

**Root cause.** The tag `9.9.9` does not exist (`not found` / `manifest unknown` is the giveaway). Secondarily, `imagePullPolicy: Always` forces a registry round-trip even when a good image is cached — on kind, where images are side-loaded with `kind load docker-image`, that alone breaks a correct deployment.

Read the error text carefully; the three registry failures are distinct:

- `not found` / `manifest unknown` → wrong tag or repo.
- `unauthorized` / `denied` → missing `imagePullSecrets`, or on EKS a node role lacking `ecr:GetAuthorizationToken` / `ecr:BatchGetImage`.
- `dial tcp ... i/o timeout` → network egress: no NAT gateway, no ECR VPC endpoint, or a NetworkPolicy blocking the kubelet's path.

**Fix**

```bash
kubectl apply -f fixed/01-imagepullbackoff.yaml
kubectl -n $NS rollout status deploy/broken-01-imagepull --timeout=120s
```

```diff
-          image: ghcr.io/maneeshm/k8s-labs-demo:9.9.9
-          imagePullPolicy: Always
+          image: ghcr.io/maneeshm/k8s-labs-demo:1.0.0
+          imagePullPolicy: IfNotPresent
```

---

### Scenario 02 — CrashLoopBackOff

```bash
kubectl apply -f broken/02-crashloopbackoff.yaml
sleep 45
kubectl -n $NS get pods -l app.kubernetes.io/name=broken-02-crashloop
```

**Symptom**

```text
NAME                                   READY   STATUS             RESTARTS      AGE
broken-02-crashloop-7d4b9c85f-qz8nv    0/1     CrashLoopBackOff   3 (18s ago)   45s
```

**Diagnose**

```bash
POD=$(kubectl -n $NS get pod -l app.kubernetes.io/name=broken-02-crashloop \
  -o jsonpath='{.items[0].metadata.name}')

kubectl -n $NS logs "$POD"              # often empty or partial
kubectl -n $NS logs "$POD" --previous   # <-- this is the one
```

Exact output from `--previous`:

```text
starting broken-02 v1.0.0
loading configuration from /etc/app/config.yaml
FATAL: open /etc/app/config.yaml: no such file or directory
```

Confirm the exit code:

```bash
kubectl -n $NS get pod "$POD" \
  -o jsonpath='{.status.containerStatuses[0].lastState.terminated}' | jq
```

```json
{
  "containerID": "containerd://...",
  "exitCode": 1,
  "finishedAt": "2026-07-20T09:14:22Z",
  "reason": "Error",
  "startedAt": "2026-07-20T09:14:22Z"
}
```

**Root cause.** The startup script requires `/etc/app/config.yaml`; no ConfigMap was mounted, so it exits 1. `reason: Error` with `exitCode: 1` means the *application* chose to die — contrast with `reason: OOMKilled` in scenario 07, where the kernel chose for it.

Note the backoff: 10s, 20s, 40s, 80s … capped at 5 minutes. A Pod with 200 restarts has been broken for many hours, not many minutes — `RESTARTS` plus `AGE` gives you the timeline.

**Fix**

```bash
kubectl apply -f fixed/02-crashloopbackoff.yaml
kubectl -n $NS rollout status deploy/broken-02-crashloop --timeout=120s
```

The fix adds the ConfigMap and mounts it, and adds a `startupProbe` — the correct mechanism for slow-starting apps, so a long boot is never mistaken for a hang and restarted into a loop of its own.

---

### Scenario 03 — Pending, unsatisfiable resource requests

```bash
kubectl apply -f broken/03-pending-resources.yaml
sleep 10
kubectl -n $NS get pods -l app.kubernetes.io/name=broken-03-pending-resources
```

**Symptom**

```text
NAME                                           READY   STATUS    RESTARTS   AGE
broken-03-pending-resources-5f7c6d9b4-w7htp    0/1     Pending   0          10s
```

**Diagnose**

```bash
POD=$(kubectl -n $NS get pod -l app.kubernetes.io/name=broken-03-pending-resources \
  -o jsonpath='{.items[0].metadata.name}')
kubectl -n $NS describe pod "$POD" | tail -8
```

```text
Events:
  Type     Reason            Age   From               Message
  ----     ------            ----  ----               -------
  Warning  FailedScheduling  12s   default-scheduler  0/3 nodes are available:
           1 node(s) had untolerated taint {node-role.kubernetes.io/control-plane: },
           2 Insufficient cpu, 2 Insufficient memory.
           preemption: 0/3 nodes are available: 1 Preemption is not helpful for scheduling,
           2 No preemption victims found for incoming pod.
```

Then compare demand against supply:

```bash
kubectl -n $NS get pod "$POD" -o jsonpath='{.spec.containers[0].resources}{"\n"}' | jq
kubectl get nodes -o custom-columns=\
'NAME:.metadata.name,CPU:.status.allocatable.cpu,MEM:.status.allocatable.memory'
```

```text
{"limits":{"cpu":"200","memory":"128Gi"},"requests":{"cpu":"100","memory":"64Gi"}}

NAME                      CPU   MEM
k8s-labs-control-plane    8     8039260Ki
k8s-labs-worker           8     8039260Ki
k8s-labs-worker2          8     8039260Ki
```

**Root cause.** `cpu: 100` is **100 cores**, not 100 millicores — the missing `m`. Likewise `64Gi` should be `64Mi`. Kubernetes quantities are unforgiving: `100` and `100m` differ by 1000x and both are perfectly valid YAML, so nothing catches it before the scheduler quietly gives up.

"Preemption is not helpful" confirms it: no combination of evictions would free 100 cores, so this is not a contention problem.

**Fix**

```bash
kubectl apply -f fixed/03-pending-resources.yaml
kubectl -n $NS rollout status deploy/broken-03-pending-resources --timeout=120s
```

```diff
           resources:
             requests:
-              cpu: 100
-              memory: 64Gi
+              cpu: 50m
+              memory: 64Mi
             limits:
-              cpu: 200
-              memory: 128Gi
+              cpu: 200m
+              memory: 128Mi
```

The fix also adds a `LimitRange` with `max: {cpu: 2, memory: 2Gi}`. That converts this entire bug class from a silent Pending into a loud admission-time rejection:

```text
Error from server (Forbidden): error when creating "...": pods "..." is forbidden:
maximum cpu usage per Container is 2, but request is 100.
```

---

### Scenario 04 — Pending, nodeSelector matches no node

```bash
kubectl apply -f broken/04-pending-nodeselector.yaml
sleep 10
kubectl -n $NS get pods -l app.kubernetes.io/name=broken-04-pending-nodeselector
```

**Symptom** — identical to scenario 03: `Pending`. The events are what tell them apart.

**Diagnose**

```bash
POD=$(kubectl -n $NS get pod -l app.kubernetes.io/name=broken-04-pending-nodeselector \
  -o jsonpath='{.items[0].metadata.name}')
kubectl -n $NS describe pod "$POD" | tail -8
```

```text
Events:
  Type     Reason            Age   From               Message
  ----     ------            ----  ----               -------
  Warning  FailedScheduling  14s   default-scheduler  0/3 nodes are available:
           3 node(s) didn't match Pod's node affinity/selector.
           preemption: 0/3 nodes are available: 3 Preemption is not helpful for scheduling.
```

`didn't match Pod's node affinity/selector`, not `Insufficient cpu`. Different cause, same phase.

```bash
kubectl -n $NS get pod "$POD" -o jsonpath='{.spec.nodeSelector}{"\n"}' | jq
kubectl get nodes --show-labels | tr ',' '\n' | grep -E 'instance-type|zone|workload' | sort -u
```

```json
{"node.kubernetes.io/instance-type":"p4d.24xlarge","workload-class":"gpu-training"}
```

and no node carries either label.

**Root cause.** A hard `nodeSelector` plus a `requiredDuringSchedulingIgnoredDuringExecution` node affinity for EKS-specific labels (`instance-type`, `topology.kubernetes.io/zone: eu-west-1a`) that do not exist on a kind cluster. This is exactly how the bug reaches production: the manifest is correct for the cluster it was written against, and wrong everywhere else — dev, DR region, a rebuilt cluster.

Note also the GPU toleration in the broken manifest. Tolerations do **not** attract Pods to nodes; they only permit scheduling onto tainted ones. A toleration will never fix a Pending caused by affinity.

**Fix**

```bash
kubectl apply -f fixed/04-pending-nodeselector.yaml
kubectl -n $NS rollout status deploy/broken-04-pending-nodeselector --timeout=120s
```

The fix drops the `nodeSelector`, converts the hard affinity to `preferredDuringSchedulingIgnoredDuringExecution` (which degrades gracefully), keeps one *satisfiable* required rule (exclude control-plane nodes), removes the pointless toleration, and expresses spreading with a `topologySpreadConstraint` — soft by default, which is almost always what you meant.

---

### Scenario 05 — readiness probe wrong → no endpoints → connection refused

```bash
kubectl apply -f broken/05-readiness-wrong-port.yaml
sleep 30
kubectl -n $NS get pods,svc,endpoints -l app.kubernetes.io/name=broken-05-readiness
```

**Symptom**

```text
NAME                                       READY   STATUS    RESTARTS   AGE
pod/broken-05-readiness-6d8c4f9b7-2mkxp    0/1     Running   0          30s
pod/broken-05-readiness-6d8c4f9b7-lp4qw    0/1     Running   0          30s

NAME                          TYPE        CLUSTER-IP      PORT(S)   AGE
service/broken-05-readiness   ClusterIP   10.96.142.203   80/TCP    30s

NAME                            ENDPOINTS   AGE
endpoints/broken-05-readiness   <none>      30s
```

**`Running` but `0/1`, and `ENDPOINTS: <none>`.** Note the container is not restarting — this is not a crash.

Reproduce what a caller sees:

```bash
kubectl -n $NS run tmp-curl --rm -it --restart=Never --image=busybox:1.36 -- \
  wget -q -O - -T 5 http://broken-05-readiness/
```

```text
wget: can't connect to remote host (10.96.142.203): Connection refused
```

**Diagnose**

```bash
POD=$(kubectl -n $NS get pod -l app.kubernetes.io/name=broken-05-readiness \
  -o jsonpath='{.items[0].metadata.name}')
kubectl -n $NS describe pod "$POD" | tail -8
```

```text
Events:
  Type     Warning  Reason     Age                From     Message
  ----     -------  ------     ----               ----     -------
  Warning  Unhealthy  4s (x6 over 29s)  kubelet  Readiness probe failed: Get
           "http://10.244.2.15:9090/health/ready": dial tcp 10.244.2.15:9090: connect:
           connection refused
```

Prove the app itself is fine by bypassing the Service:

```bash
kubectl -n $NS port-forward "pod/$POD" 18080:8080 >/dev/null 2>&1 &
sleep 2
curl -s localhost:18080/readyz ; echo
curl -s -o /dev/null -w '%{http_code}\n' localhost:18080/health/ready
kill %1
```

```text
{"status":"ready"}
404
```

The app is healthy and serving `/readyz`. The probe is asking the wrong question at the wrong address.

**Root cause.** Two bugs: `path: /health/ready` (a Spring Boot Actuator convention this app never implemented — returns 404, and any non-2xx/3xx is a probe failure) and `port: 9090` (nothing listens there). Because readiness fails, the endpoints controller keeps both Pods out of the EndpointSlice, so the Service has no backends and kube-proxy rejects connections to the ClusterIP.

**This chain — probe → readiness → endpoints → connection refused — is the most valuable thing in this lab.** The symptom is three layers from the cause.

**Fix**

```bash
kubectl apply -f fixed/05-readiness-wrong-port.yaml
kubectl -n $NS rollout status deploy/broken-05-readiness --timeout=120s
kubectl -n $NS get endpoints broken-05-readiness
```

```diff
           readinessProbe:
             httpGet:
-              path: /health/ready
-              port: 9090
+              path: /readyz
+              port: http
```

Using the **named** port (`http`) rather than a number means the probe can never drift from the container port. Make it a review rule and this bug class disappears.

---

### Scenario 06 — Service selector typo → 0 endpoints

```bash
kubectl apply -f broken/06-service-selector-typo.yaml
sleep 25
kubectl -n $NS get pods,endpoints -l app.kubernetes.io/name=broken-06-selector
```

**Symptom**

```text
NAME                                      READY   STATUS    RESTARTS   AGE
pod/broken-06-selector-84f7d9c6b-8xvzt    1/1     Running   0          25s
pod/broken-06-selector-84f7d9c6b-nr2ws    1/1     Running   0          25s

NAME                           ENDPOINTS   AGE
endpoints/broken-06-selector   <none>      25s
```

**Pods are `1/1 READY` and endpoints are still empty.** That single difference from scenario 05 is the whole diagnosis:

- `READY 0/1` + no endpoints → readiness probe (scenario 05)
- `READY 1/1` + no endpoints → Service selector (this one)

**Diagnose**

```bash
kubectl -n $NS get svc broken-06-selector -o jsonpath='{.spec.selector}{"\n"}' | jq
kubectl -n $NS get pods -l app.kubernetes.io/name=broken-06-selector \
  -o jsonpath='{.items[0].metadata.labels}{"\n"}' | jq

# Definitive test: query with the Service's own selector.
kubectl -n $NS get pods -l 'app=broken-06-selector,app.kubernetes.io/instance=lab-eleven'
```

```json
{"app":"broken-06-selector","app.kubernetes.io/instance":"lab-eleven"}

{"app.kubernetes.io/component":"backend","app.kubernetes.io/instance":"lab-11",
 "app.kubernetes.io/managed-by":"kubectl","app.kubernetes.io/name":"broken-06-selector",
 "app.kubernetes.io/part-of":"kubernetes-labs","app.kubernetes.io/version":"1.0.0",
 "pod-template-hash":"84f7d9c6b"}
```

```text
No resources found in lab-11-troubleshooting namespace.
```

`describe svc` shows it plainly too:

```bash
kubectl -n $NS describe svc broken-06-selector | grep -E 'Selector|Endpoints'
```

```text
Selector:          app=broken-06-selector,app.kubernetes.io/instance=lab-eleven
Endpoints:         <none>
```

**Root cause.** Two independent bugs: the selector uses the key `app` while the Pods carry `app.kubernetes.io/name`, and the instance value is `lab-eleven` instead of `lab-11`. Selector labels are AND-ed, so either alone is fatal. Kubernetes never warns about this — a Service whose selector matches nothing is a perfectly valid object.

**Fix**

```bash
kubectl apply -f fixed/06-service-selector-typo.yaml
kubectl -n $NS get endpoints broken-06-selector
```

```diff
   selector:
-    app: broken-06-selector
-    app.kubernetes.io/instance: lab-eleven
+    app.kubernetes.io/name: broken-06-selector
+    app.kubernetes.io/instance: lab-11
```

Habit worth adopting: copy the Deployment's `spec.selector.matchLabels` verbatim into the Service's `spec.selector`. They answer the same question and should never be authored independently.

---

### Scenario 07 — OOMKilled

```bash
kubectl apply -f broken/07-oomkilled.yaml
sleep 60
kubectl -n $NS get pods -l app.kubernetes.io/name=broken-07-oomkilled
```

**Symptom**

```text
NAME                                   READY   STATUS             RESTARTS      AGE
broken-07-oomkilled-5b9d7f8c4-jt6wq    0/1     CrashLoopBackOff   3 (22s ago)   60s
```

Looks exactly like scenario 02 from the outside. The logs are what differ:

```bash
POD=$(kubectl -n $NS get pod -l app.kubernetes.io/name=broken-07-oomkilled \
  -o jsonpath='{.items[0].metadata.name}')
kubectl -n $NS logs "$POD" --previous
```

```text
allocating 200MiB into a tmpfs with a 32Mi memory limit
```

…and then nothing. No error, no stack trace, no shutdown message. **That silence is the signal.** SIGKILL cannot be caught, so the process never gets a chance to say anything about its own death.

**Diagnose**

```bash
kubectl -n $NS get pod "$POD" \
  -o jsonpath='{.status.containerStatuses[0].lastState.terminated}' | jq
```

```json
{
  "containerID": "containerd://8f2a...",
  "exitCode": 137,
  "finishedAt": "2026-07-20T09:22:41Z",
  "reason": "OOMKilled",
  "startedAt": "2026-07-20T09:22:38Z"
}
```

```bash
kubectl -n $NS describe pod "$POD" | grep -A3 'Last State'
```

```text
    Last State:     Terminated
      Reason:       OOMKilled
      Exit Code:    137
      Started:      Mon, 20 Jul 2026 09:22:38 +0000
      Finished:     Mon, 20 Jul 2026 09:22:41 +0000
```

**Root cause.** A 32Mi memory limit against a workload that allocates 200 MiB. Exit code 137 = 128 + 9 (SIGKILL) is the fingerprint. Note it is driven by the **limit**, not the request — and that pages in a `medium: Memory` emptyDir (tmpfs) are charged to the container's memory cgroup, which is why writing a file can OOM a process.

Distinguish two different OOMs:

- **Container OOM** (this one): `lastState.reason: OOMKilled`, only this container dies, it restarts.
- **Node OOM / eviction**: Pod phase `Failed` with `reason: Evicted`, message `The node was low on resource: memory`. Multiple Pods die at once. Check `kubectl describe node` for `MemoryPressure`. Setting honest **requests** is what prevents this.

**Fix**

```bash
kubectl apply -f fixed/07-oomkilled.yaml
kubectl -n $NS rollout status deploy/broken-07-oomkilled --timeout=120s
```

```diff
           resources:
             requests:
-              memory: 32Mi
+              memory: 128Mi
             limits:
-              memory: 32Mi
+              memory: 256Mi
```

Do not guess the numbers. Measure `container_memory_working_set_bytes` over a week; set requests near p90 and limits near 2x p99. Alert on `working_set / limit > 0.9` *before* the kill, and on `kube_pod_container_status_last_terminated_reason{reason="OOMKilled"}` after — that second alert is how you find OOM kills that a successful restart hid from everyone.

For the JVM use `-XX:MaxRAMPercentage=75` rather than a fixed `-Xmx`; for Go, `GOMEMLIMIT`. Both make the runtime aware of the cgroup limit instead of the host's memory.

---

### Scenario 08 — missing ConfigMap/Secret → CreateContainerConfigError

```bash
kubectl apply -f broken/08-missing-configmap-secret.yaml
sleep 20
kubectl -n $NS get pods -l app.kubernetes.io/name=broken-08-missing-config
```

**Symptom**

```text
NAME                                        READY   STATUS                       RESTARTS   AGE
broken-08-missing-config-79c8d5f64-vk9tp    0/1     CreateContainerConfigError   0          20s
```

**Diagnose**

```bash
POD=$(kubectl -n $NS get pod -l app.kubernetes.io/name=broken-08-missing-config \
  -o jsonpath='{.items[0].metadata.name}')
kubectl -n $NS logs "$POD"
```

```text
Error from server (BadRequest): container "demo-app" in pod "broken-08-..." is waiting
to start: CreateContainerConfigError
```

**No logs, because no container was ever created.** Go to events:

```bash
kubectl -n $NS describe pod "$POD" | tail -12
```

```text
Events:
  Type     Reason       Age                From               Message
  ----     ------       ----               ----               -------
  Normal   Scheduled    22s                default-scheduler  Successfully assigned ...
  Warning  FailedMount  6s (x7 over 22s)   kubelet            MountVolume.SetUp failed for
                        volume "extra-config" : configmap "demo-app-extra-config" not found
  Normal   Pulled       5s (x3 over 20s)   kubelet            Container image ... already present
  Warning  Failed       5s (x3 over 20s)   kubelet            Error: configmap "demo-app-settings" not found
```

Confirm:

```bash
kubectl -n $NS get configmaps,secrets
```

```text
NAME                         DATA   AGE
configmap/kube-root-ca.crt   1      12m
```

**Root cause.** Three references to objects that do not exist: `demo-app-settings` (via `envFrom`), `demo-app-credentials` (via `secretKeyRef`), and `demo-app-extra-config` (via a volume). Note the two distinct statuses they produce — env references give `CreateContainerConfigError`, volume references give `ContainerCreating` + `FailedMount`. The status field reports whichever the kubelet hits first.

A missing **key** inside an existing Secret fails identically but with a different message: `couldn't find key api-key in Secret lab-11-troubleshooting/demo-app-credentials`. Read the message, not just the status.

**Fix**

```bash
kubectl apply -f fixed/08-missing-configmap-secret.yaml
kubectl -n $NS rollout status deploy/broken-08-missing-config --timeout=120s
```

The fix creates all three objects and marks the genuinely optional volume `optional: true`. Use `optional` sparingly — on something the app actually requires it converts a clear `CreateContainerConfigError` into a confusing runtime bug hundreds of lines later.

---

### Scenario 09 — RBAC forbidden

```bash
kubectl apply -f broken/09-rbac-forbidden.yaml
sleep 30
kubectl -n $NS get pods -l app.kubernetes.io/name=broken-09-rbac
```

**Symptom**

```text
NAME                              READY   STATUS    RESTARTS   AGE
broken-09-rbac-7f4c8b9d5-mn2rt    1/1     Running   0          30s
```

**Everything looks perfect.** Running, Ready, zero restarts. Nothing in `get pods`, `describe pod`, or the events will ever hint at the problem, because from Kubernetes' point of view there is no problem — the container is doing exactly what it was told, and being denied.

**Diagnose** — go straight to the logs:

```bash
kubectl -n $NS logs -l app.kubernetes.io/name=broken-09-rbac --tail=10
```

```text
watcher starting; will list pods every 15s
Error from server (Forbidden): pods is forbidden: User
"system:serviceaccount:lab-11-troubleshooting:broken-09-watcher" cannot list resource
"pods" in API group "" in the namespace "lab-11-troubleshooting"
list failed (see error above)
```

Confirm from outside, without needing the credential:

```bash
kubectl auth can-i list pods \
  --as=system:serviceaccount:$NS:broken-09-watcher -n $NS
# no

kubectl auth can-i --list \
  --as=system:serviceaccount:$NS:broken-09-watcher -n $NS
# only selfsubjectreviews and the system:discovery non-resource URLs

kubectl -n $NS get rolebindings,roles
# No resources found.
```

**Root cause.** The ServiceAccount exists and authentication succeeds — the request gets as far as the authorizer and is then denied, because no Role or RoleBinding grants anything. "The ServiceAccount exists" and "the ServiceAccount can do something" are completely unrelated statements.

**Deriving the fix mechanically** — the `Forbidden` message contains exactly the five fields you need:

| Message fragment | Becomes |
| --- | --- |
| `cannot list` | `verbs: ["list"]` |
| `resource "pods"` | `resources: ["pods"]` |
| `in API group ""` | `apiGroups: [""]` (empty = core) |
| `in the namespace "lab-11-troubleshooting"` | a `Role` there, not a `ClusterRole` |
| `User "system:serviceaccount:..."` | the RoleBinding subject |

**Fix**

```bash
kubectl apply -f fixed/09-rbac-forbidden.yaml
kubectl -n $NS rollout restart deploy/broken-09-rbac
kubectl -n $NS rollout status deploy/broken-09-rbac --timeout=120s
sleep 20
kubectl -n $NS logs -l app.kubernetes.io/name=broken-09-rbac --tail=5
```

Expected: a list of `pod/...` names instead of the 403.

The commonest half-fix is creating the Role and forgetting the RoleBinding — a Role with no binding grants nothing at all. Also note `get`, `list` and `watch` are granted together: any client using an informer needs all three, and granting only `list` produces an identical-looking failure a few seconds later on the watch call.

---

### Scenario 10 — readOnlyRootFilesystem vs an app that writes

```bash
kubectl apply -f broken/10-readonly-rootfs.yaml
sleep 30
kubectl -n $NS get pods -l app.kubernetes.io/name=broken-10-readonly-fs
```

**Symptom**

```text
NAME                                     READY   STATUS             RESTARTS      AGE
broken-10-readonly-fs-6b4d8c7f9-hs4nv    0/1     CrashLoopBackOff   2 (15s ago)   30s
```

**Diagnose**

```bash
POD=$(kubectl -n $NS get pod -l app.kubernetes.io/name=broken-10-readonly-fs \
  -o jsonpath='{.items[0].metadata.name}')
kubectl -n $NS logs "$POD" --previous
```

```text
starting; writing pidfile and opening log
/bin/sh: can't create /var/run/app.pid: Read-only file system
mkdir: can't create directory '/var/log/app': Read-only file system
/bin/sh: can't create /var/log/app/app.log: Read-only file system
```

Inspect from inside with an ephemeral container — it shares the target's namespaces, so you see exactly what the app sees, and it works even on a distroless image with no shell:

```bash
kubectl -n $NS debug -it "$POD" --image=busybox:1.36 \
  --target=app -- sh -c 'mount | grep -E " / |/var|/tmp"'
```

```text
overlay on / type overlay (ro,relatime,...)
```

`ro` on `/` is the confirmation.

**Root cause.** `readOnlyRootFilesystem: true` with no writable volume mounted at any of the paths the process writes to. This is the flag most likely to break a working application, because so many programs write pid files, logs, caches, or TLS temp files without documenting it.

**The fix is never to set the flag to `false`.** That is how a hardening standard erodes, one exception at a time. Find what the process writes and mount an emptyDir there.

```bash
kubectl apply -f fixed/10-readonly-rootfs.yaml
kubectl -n $NS rollout status deploy/broken-10-readonly-fs --timeout=120s
```

```diff
           volumeMounts:
+            - name: var-run
+              mountPath: /var/run
+            - name: var-log
+              mountPath: /var/log/app
+            - name: tmp
+              mountPath: /tmp
       volumes:
+        - name: var-run
+          emptyDir: {medium: Memory, sizeLimit: 4Mi}
+        - name: var-log
+          emptyDir: {sizeLimit: 128Mi}     # node disk, not RAM - logs grow
+        - name: tmp
+          emptyDir: {medium: Memory, sizeLimit: 16Mi}
```

Choosing the medium matters, and ties back to scenario 07: `medium: Memory` is tmpfs, which is charged to the container's **memory limit** — a tmpfs log directory that fills up gets your container OOMKilled. Use node-disk emptyDir for anything that grows, and pair it with `ephemeral-storage` requests/limits so a runaway writer cannot fill the node and trigger DiskPressure evictions for every other Pod on it.

A related failure worth recognising: if a mounted volume is root-owned and the process runs as UID 65532, you get `Permission denied` (EACCES) rather than `Read-only file system` (EROFS) — different error, same class, fixed with `fsGroup`.

---

### Bonus: prove the fixes are genuinely hardened

Every manifest under `fixed/` is fully restricted-PSS compliant, so you can turn enforcement on and watch them all survive:

```bash
kubectl label ns $NS pod-security.kubernetes.io/enforce=restricted --overwrite
kubectl -n $NS rollout restart deploy --all
kubectl -n $NS get pods
# All Running/Ready. Now try a broken one:
kubectl apply -f broken/10-readonly-rootfs.yaml
kubectl -n $NS rollout status deploy/broken-10-readonly-fs --timeout=60s
# Reset when done:
kubectl label ns $NS pod-security.kubernetes.io/enforce- --overwrite
```

## Verification

```bash
export NS=lab-11-troubleshooting

# Apply every fix and confirm the whole namespace converges.
kubectl apply -f fixed/
for d in $(kubectl -n $NS get deploy -o name); do
  kubectl -n $NS rollout status "$d" --timeout=180s
done

# 1. Nothing is unhealthy.
kubectl -n $NS get pods --field-selector=status.phase!=Running -o name | wc -l
# expected: 0

# 2. Every Pod is Ready.
kubectl -n $NS get pods \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[0].ready}{"\n"}{end}' \
  | grep -c false
# expected: 0

# 3. Both Services now have endpoints.
kubectl -n $NS get endpoints broken-05-readiness broken-06-selector \
  -o jsonpath='{range .items[*]}{.metadata.name}={.subsets[0].addresses[0].ip}{"\n"}{end}'
# expected: two lines, each with a real Pod IP

# 4. No container has been OOMKilled since the fix.
kubectl -n $NS get pods -o json \
  | jq -r '.items[].status.containerStatuses[]?.lastState.terminated.reason // empty' \
  | grep -c OOMKilled
# expected: 0

# 5. The RBAC scenario can now list Pods.
kubectl auth can-i list pods --as=system:serviceaccount:$NS:broken-09-watcher -n $NS
# expected: yes

# 6. The read-only-rootfs Pod really did write its files.
POD=$(kubectl -n $NS get pod -l app.kubernetes.io/name=broken-10-readonly-fs \
  -o jsonpath='{.items[0].metadata.name}')
kubectl -n $NS exec "$POD" -- cat /var/log/app/app.log
# expected: a timestamped "started" line

# 7. readOnlyRootFilesystem is still TRUE everywhere (we did not weaken it).
kubectl -n $NS get deploy -o json \
  | jq -r '.items[].spec.template.spec.containers[]
           | select(.securityContext.readOnlyRootFilesystem != true) | .name'
# expected: (empty)

# 8. No Warning events in the last few minutes.
kubectl -n $NS get events --field-selector type=Warning \
  --sort-by=.lastTimestamp | tail -5
# expected: only historical warnings from the broken phase, none recent
```

## Cleanup

```bash
kubectl delete -f fixed/ --ignore-not-found
kubectl delete -f broken/ --ignore-not-found
kubectl delete -f 00-namespace.yaml --ignore-not-found

# Stray debug pods from the walkthrough.
kubectl -n lab-11-troubleshooting delete pod tmp-curl tmp-shell --ignore-not-found

kubectl get ns lab-11-troubleshooting
# expected: Error from server (NotFound): namespaces "lab-11-troubleshooting" not found
```

## What you learned

- The triage loop — `get pods` → `get events --sort-by` → `describe` → `logs --previous` — identifies almost any failure in under a minute, before you have formed a hypothesis.
- Events are the control plane narrating its own decisions, and they expire after an hour. Ship them somewhere durable.
- `kubectl logs` reads the *current* container; a crash-looping Pod needs `--previous`, and an unstarted container has no logs at all.
- `lastState.terminated` carries the evidence that logs cannot: `exitCode` and `reason`. 137 = OOMKilled, 143 = SIGTERM, 1/2 = the app chose to die.
- Two Pending Pods can have unrelated causes — read the `FailedScheduling` message, not the phase.
- Empty endpoints have two causes, separated by one column: `0/1 READY` means the readiness probe, `1/1 READY` means the Service selector.
- Reference probe ports by **name**, and copy the Deployment's `matchLabels` into the Service selector. Those two habits eliminate scenarios 05 and 06 permanently.
- Kubernetes quantities are 1000x unforgiving: `100` vs `100m`, `64Gi` vs `64Mi`. A `LimitRange` turns that typo into an immediate admission error rather than a silent Pending.
- A `Forbidden` message contains exactly the five fields needed to write the missing RBAC rule. A Role without a RoleBinding grants nothing.
- `readOnlyRootFilesystem` conflicts are fixed with emptyDir mounts, never by disabling the flag — and tmpfs volumes count against the memory limit.
- `kubectl debug --target=<container>` shares the target's namespaces and works on distroless images; `--copy-to` lets you inspect a Pod that crashes too fast to exec into.

## Going further / production notes

- **Make the runbook executable.** Everything above should be a script your on-call runs in one command. `k8s-triage`-style wrappers, `kubectl-debug` plugins, or a simple `make triage NS=x` target that dumps status, events, describes and logs for every unhealthy Pod into a tarball. During an incident nobody remembers the jsonpath for `lastState`.
- **Alert on the signals, not the symptoms.** The highest-value alerts map one-to-one onto the scenarios here: `kube_pod_container_status_waiting_reason{reason=~"ImagePullBackOff|CrashLoopBackOff|CreateContainerConfigError"}`, `kube_pod_container_status_last_terminated_reason{reason="OOMKilled"}`, `kube_pod_status_phase{phase="Pending"} > 5m`, `kube_endpoint_address_available == 0` for any Service with a Deployment behind it, and `kube_poddisruptionbudget_status_expected_pods - kube_poddisruptionbudget_status_current_healthy`. kube-state-metrics gives you all of these for free.
- **On EKS specifically.** Enable the control-plane audit log to CloudWatch and learn one Logs Insights query: `filter responseStatus.code = 403 | stats count() by user.username` finds every under-privileged workload in the cluster in about ten seconds. Container Insights gives you `pod_memory_utilization_over_pod_limit`, which is the leading indicator for scenario 07. For scenario 01, remember ECR auth failures usually mean the node role lost `ecr:GetAuthorizationToken` or there is no ECR VPC endpoint in a private subnet.
- **Node-level failures this lab does not cover.** `NotReady` nodes (check `kubectl describe node` conditions, then the kubelet journal via `kubectl debug node/`), disk pressure from image sprawl (`crictl images`, and set `--image-gc-high-threshold`), PID exhaustion, and the EKS-specific one: **VPC CNI IP exhaustion**, which surfaces as `FailedCreatePodSandBox: failed to assign an IP address to container`. That last one has nothing to do with your manifest and everything to do with subnet sizing — enable prefix delegation or add a secondary CIDR.
- **Ephemeral containers are the modern answer** to "I can't debug this, there's no shell in the image". Do not compromise your image hygiene by shipping busybox in production containers; ship distroless and use `kubectl debug --target`. Ensure your admission policies allow the debug image, and audit `create pods/ephemeralcontainers` in RBAC — it is effectively arbitrary code execution inside another workload's namespaces, and should be a privileged grant.
- **Prevent, don't just diagnose.** Most of these ten never reach a cluster if you gate them in CI: `kubeconform --strict` for schema, `kube-linter`/`polaris` for missing probes and resources, `conftest`/OPA for organisational rules ("every Deployment has a PDB", "no `:latest` tags", "probes must use named ports"), and Pod Security Standards or a `ValidatingAdmissionPolicy` at admission time. Scenarios 03, 05, 06 and 10 are all statically detectable.
- **Practice deliberately.** This `broken/` directory is a small chaos-engineering exercise. Extend it: delete a random Pod mid-request and watch whether your PDB and readiness gates hold; drain a node; corrupt a ConfigMap; expire a certificate. Tools like `chaos-mesh` or `litmus` automate it. The point is that the first time you see `CreateContainerConfigError` should not be at 3am.
