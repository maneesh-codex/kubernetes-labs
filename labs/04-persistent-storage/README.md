# Lab 04 — Persistent Storage

Stateless workloads are the easy half of Kubernetes. The moment data has to outlive a pod, a different set of rules applies: volumes are zonal, `ReadWriteOnce` does not mean what most people assume, a rolling update on a shared volume deadlocks, and a non-root container will fail to write to its own PersistentVolume unless you set `fsGroup`. This lab builds the storage stack from the bottom up — StorageClass, PVC, then a Deployment with a shared volume and two StatefulSets with per-pod volumes — and spends most of its time on the lifecycle question that actually causes incidents: what gets deleted, and what quietly does not.

## Objectives

- Explain the StorageClass → PVC → PV chain and who owns each object.
- Justify `volumeBindingMode: WaitForFirstConsumer` in terms of a concrete failure it prevents.
- Distinguish `ReadWriteOnce` (one *node*) from `ReadWriteOncePod` (one *pod*), and know when you need `ReadWriteMany`.
- Set `fsGroup` correctly so a non-root container can write to a freshly provisioned volume.
- Contrast a Deployment sharing one PVC with a StatefulSet's `volumeClaimTemplates`.
- Observe stable network identity, ordered creation and reverse-ordered termination.
- Prove that deleting pods, and even deleting the StatefulSet, does not delete PVCs — and control that with `persistentVolumeClaimRetentionPolicy`.
- Run a real database with a correct `securityContext`, and reason honestly about the one place `readOnlyRootFilesystem` must be relaxed.

## Prerequisites

- A running kind cluster named `k8s-labs` from `make cluster-up`. kind ships the rancher local-path provisioner as the default `standard` StorageClass; this lab declares its own class rather than relying on that default.
- `kubectl` v1.29+ (needed for `ReadWriteOncePod` GA and stable `persistentVolumeClaimRetentionPolicy`).
- Images pullable or side-loaded: `ghcr.io/maneeshm/k8s-labs-demo:1.0.0`, `postgres:16-alpine`, `busybox:1.36`.
- About 2 CPU and 2Gi of memory of headroom — the postgres StatefulSet requests 250m/512Mi per replica across three replicas.
- Roughly 10Gi of free disk on the kind node for the seven volumes this lab provisions.

## Manifests in this lab

| File | What it does |
| --- | --- |
| `00-namespace.yaml` | Creates namespace `lab-04-storage` under the `restricted` Pod Security Standard. |
| `10-storageclass.yaml` | `lab-local-path` StorageClass with `WaitForFirstConsumer` and `reclaimPolicy: Delete`. |
| `20-pvc.yaml` | Standalone 1Gi `ReadWriteOnce` PVC, `demo-shared-data`. |
| `30-deployment-pvc.yaml` | Single-replica Deployment mounting that PVC, with `strategy: Recreate` and an init container that appends to a history log. |
| `40-secret-postgres.yaml` | `POSTGRES_DB` / `POSTGRES_USER` / `POSTGRES_PASSWORD`. |
| `50-service-postgres.yaml` | Headless governing Service `postgres` plus a readiness-respecting `postgres-client` ClusterIP. |
| `51-statefulset-postgres.yaml` | 3-replica postgres StatefulSet with `volumeClaimTemplates`, `pg_isready` exec probes, and the documented `readOnlyRootFilesystem: false` exception. |
| `60-service-demo.yaml` | Headless governing Service for the demo StatefulSet. |
| `61-statefulset-demo.yaml` | 3-replica demo-app StatefulSet with per-ordinal PVCs, keeping `readOnlyRootFilesystem: true`. |

## Walkthrough

### 1. Create the StorageClass and watch the PVC stay Pending

```bash
kubectl apply -f 00-namespace.yaml
kubectl apply -f 10-storageclass.yaml
kubectl apply -f 20-pvc.yaml -n lab-04-storage
kubectl get pvc,sc -n lab-04-storage
```

The PVC sits in `Pending` with the event `waiting for first consumer to be created before binding`. That is `volumeBindingMode: WaitForFirstConsumer` working as designed, not a failure. With `Immediate` binding the provisioner would create a volume *now*, pinned to some node or zone, and the scheduler would then have to place the pod there — which is how you get a pod stuck Pending forever because its volume is in the wrong availability zone.

### 2. Bind it by creating a consumer

```bash
kubectl apply -f 30-deployment-pvc.yaml -n lab-04-storage
kubectl rollout status deployment/demo-pvc -n lab-04-storage --timeout=120s
kubectl get pvc,pv -n lab-04-storage
```

The PVC is now `Bound` and a PersistentVolume exists. Note the ownership split: the PVC is namespaced and belongs to the app team, the PV is cluster-scoped and belongs to the platform. Note also `RECLAIM POLICY: Delete` on the PV — inherited from the StorageClass, and the reason deleting this PVC destroys the data.

### 3. Prove the volume survives the pod

```bash
POD=$(kubectl get pod -n lab-04-storage -l app.kubernetes.io/name=demo-pvc -o jsonpath='{.items[0].metadata.name}')
kubectl logs -n lab-04-storage "$POD" -c record-start
kubectl delete pod -n lab-04-storage "$POD"
kubectl rollout status deployment/demo-pvc -n lab-04-storage --timeout=120s
NEWPOD=$(kubectl get pod -n lab-04-storage -l app.kubernetes.io/name=demo-pvc -o jsonpath='{.items[0].metadata.name}')
kubectl logs -n lab-04-storage "$NEWPOD" -c record-start
```

The first log shows one line. The second shows *two* — a different pod name, appended to the same file on the same volume. The pod was disposable; the data was not. That the init container both appends and `cat`s the file is what makes this visible without a shell in the main container (the demo image is built `FROM scratch`).

While you are here, note `strategy: Recreate` in the manifest. A `RollingUpdate` on a `ReadWriteOnce` volume deadlocks: the new pod cannot mount until the old pod releases, and the old pod is not terminated until the new one is ready.

### 4. Bring up postgres and watch ordered creation

In one terminal:

```bash
kubectl get pods -n lab-04-storage -l app.kubernetes.io/name=postgres -w
```

In another:

```bash
kubectl apply -f 40-secret-postgres.yaml -f 50-service-postgres.yaml -f 51-statefulset-postgres.yaml -n lab-04-storage
kubectl rollout status statefulset/postgres -n lab-04-storage --timeout=300s
```

Watch the ordering: `postgres-0` is created, reaches Running *and Ready*, and only then is `postgres-1` created. That is `podManagementPolicy: OrderedReady`. A Deployment would have created all three simultaneously. The first boot is slow because each replica runs `initdb` — which is exactly why the manifest has a startup probe with `failureThreshold: 30`. Without it, the liveness probe would kill the pod mid-`initdb`.

### 5. Confirm one PVC per ordinal

```bash
kubectl get pvc -n lab-04-storage
```

You now have `pgdata-postgres-0`, `-1`, `-2` — the `volumeClaimTemplates` name plus the StatefulSet name plus the ordinal. This is the core difference from a Deployment: three replicas, three independent volumes, permanently associated with their ordinal.

Be clear about what these three pods are, though: **three independent databases**, not a replicated cluster. Nothing here configures streaming replication or failover. The StatefulSet gives identity and ordering; making postgres actually highly available is an operator's job (CloudNativePG, Patroni).

### 6. Verify stable network identity

```bash
kubectl run psql-probe -n lab-04-storage --rm -it --restart=Never \
  --image=postgres:16-alpine \
  --env=PGPASSWORD=lab04-demo-password-not-a-real-credential \
  --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":70,"runAsGroup":70,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"psql-probe","image":"postgres:16-alpine","env":[{"name":"PGPASSWORD","value":"lab04-demo-password-not-a-real-credential"}],"command":["sh","-c","for i in 0 1 2; do echo -n \"postgres-$i: \"; psql -h postgres-$i.postgres -U demo -d demo -tAc \"select inet_server_addr()\"; done"],"securityContext":{"allowPrivilegeEscalation":false,"readOnlyRootFilesystem":false,"capabilities":{"drop":["ALL"]}}}]}}'
```

Each `postgres-N.postgres` name resolves to a distinct pod. Those DNS names are stable across rescheduling and IP changes — which is what lets a replica be configured to stream from a named primary with no service discovery machinery at all.

### 7. Write data, delete the pod, confirm it survived

```bash
kubectl exec -n lab-04-storage postgres-0 -- \
  psql -U demo -d demo -c "create table if not exists notes(id serial primary key, body text); insert into notes(body) values ('written before the pod was deleted');"
kubectl exec -n lab-04-storage postgres-0 -- psql -U demo -d demo -tAc "select count(*) from notes;"
kubectl delete pod postgres-0 -n lab-04-storage
kubectl wait --for=condition=ready pod/postgres-0 -n lab-04-storage --timeout=180s
kubectl exec -n lab-04-storage postgres-0 -- psql -U demo -d demo -tAc "select body from notes;"
```

The row is still there. The replacement pod re-attached `pgdata-postgres-0` — same name, same volume, same data. Run the same `select` against `postgres-1` and the table does not exist, which drives home that these are separate databases with separate volumes.

### 8. Watch reverse-ordered termination on scale-down

```bash
kubectl scale statefulset/postgres -n lab-04-storage --replicas=1
kubectl get pods -n lab-04-storage -l app.kubernetes.io/name=postgres -w
```

Termination runs highest-ordinal-first: `postgres-2`, then `postgres-1`. For a real clustered database that ordering matters enormously — you want to remove followers before the primary, and ordinal 0 is conventionally the primary.

Now the important part:

```bash
kubectl get pvc -n lab-04-storage
```

`pgdata-postgres-1` and `pgdata-postgres-2` are **still there**, still `Bound`. `persistentVolumeClaimRetentionPolicy.whenScaled: Retain` kept them, so scaling back up reattaches the original data. This is the safe default and also a genuine billing surprise on EBS — orphaned volumes cost money indefinitely. Set `whenScaled: Delete` only for caches and scratch tiers.

Scale back up and confirm the data returned:

```bash
kubectl scale statefulset/postgres -n lab-04-storage --replicas=3
kubectl rollout status statefulset/postgres -n lab-04-storage --timeout=300s
```

### 9. Bring up the demo StatefulSet and see per-ordinal identity

```bash
kubectl apply -f 60-service-demo.yaml -f 61-statefulset-demo.yaml -n lab-04-storage
kubectl rollout status statefulset/demo-sts -n lab-04-storage --timeout=180s
for i in 0 1 2; do echo "== demo-sts-$i =="; kubectl logs -n lab-04-storage "demo-sts-$i" -c record-identity; done
```

Each pod's log names only itself. Delete `demo-sts-1`, wait for it to return, and re-read its log — it now has two lines on the same volume, while `demo-sts-0` and `-2` are untouched.

Note that this StatefulSet keeps `readOnlyRootFilesystem: true` while writing to `/data`. A mounted volume is a separate filesystem; the read-only root applies to the image layers. Those two settings are orthogonal, and the postgres exception in this lab is about the *image*, not about its data.

### 10. Orphan the pods, then delete the StatefulSet

```bash
kubectl delete statefulset demo-sts -n lab-04-storage --cascade=orphan
kubectl get pods,statefulset -n lab-04-storage -l app.kubernetes.io/name=demo-sts
```

The StatefulSet is gone; the pods are still running, now unowned. `--cascade=orphan` is the escape hatch for changing an immutable StatefulSet field (`serviceName`, `selector`, `volumeClaimTemplates`) without downtime: orphan the pods, recreate the StatefulSet with the new spec, and it adopts the existing pods by label.

Now recreate and delete properly:

```bash
kubectl apply -f 61-statefulset-demo.yaml -n lab-04-storage
kubectl delete statefulset demo-sts -n lab-04-storage
kubectl get pvc -n lab-04-storage -l app.kubernetes.io/name=demo-sts
```

The StatefulSet and its pods are gone. **The three PVCs remain.** With `whenDeleted: Retain` this is by design — deleting a workload should never silently destroy its data. It is also why storage costs creep: nothing garbage-collects these but you.

## Verification

```bash
kubectl get storageclass lab-local-path -o jsonpath='{.volumeBindingMode}{"\n"}'
```

Expected output:

```text
WaitForFirstConsumer
```

```bash
kubectl get pvc -n lab-04-storage -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,CAPACITY:.status.capacity.storage
```

Expected output (after step 9): `demo-shared-data`, `pgdata-postgres-0/1/2`, and `data-demo-sts-0/1/2`, all `Bound`.

```bash
kubectl get statefulset postgres -n lab-04-storage \
  -o jsonpath='{.status.readyReplicas}/{.spec.replicas}{"\n"}'
```

Expected output:

```text
3/3
```

```bash
kubectl exec -n lab-04-storage postgres-0 -- pg_isready -U demo -d demo
```

Expected output:

```text
/var/run/postgresql:5432 - accepting connections
```

```bash
kubectl exec -n lab-04-storage postgres-0 -- id
```

Expected output:

```text
uid=70(postgres) gid=70(postgres) groups=70(postgres)
```

```bash
kubectl get statefulset postgres -n lab-04-storage \
  -o jsonpath='{.spec.persistentVolumeClaimRetentionPolicy}{"\n"}'
```

Expected output:

```text
{"whenDeleted":"Retain","whenScaled":"Retain"}
```

```bash
kubectl logs -n lab-04-storage demo-sts-0 -c record-identity | grep -c 'pod=demo-sts-0'
```

Expected output: `1` on first boot, incrementing by one for each time you delete and recreate that pod.

## Cleanup

```bash
kubectl delete namespace lab-04-storage --wait=true
kubectl delete storageclass lab-local-path --ignore-not-found
kubectl get pv | grep lab-04-storage || echo "no orphaned PVs"
```

Deleting the namespace removes the PVCs, and because `reclaimPolicy: Delete` the PVs and their backing directories go with them. With `reclaimPolicy: Retain` — which is what you should use in production — the PVs would survive in `Released` state and need explicit removal. The final `grep` is the habit worth building: always confirm no orphaned volumes are left billing you.

## What you learned

- A StorageClass is a named provisioning policy; a PVC is a request; a PV is the result. The PVC is namespaced and app-owned, the PV is cluster-scoped and platform-owned.
- `WaitForFirstConsumer` defers provisioning until a pod is scheduled, so the volume lands in the right zone or on the right node. `Immediate` binding is the classic cause of a permanently `Pending` pod in a multi-AZ cluster.
- `ReadWriteOnce` means one *node*, not one pod — two pods on the same node can both mount it. `ReadWriteOncePod` is the exclusive one.
- `fsGroup` is what makes a freshly provisioned volume writable by a non-root container; without it you get `EACCES` and a CrashLoopBackOff. `fsGroupChangePolicy: OnRootMismatch` avoids a slow recursive chown on large volumes.
- A Deployment on a RWO volume must use `strategy: Recreate`, because a rolling update deadlocks on the volume.
- `volumeClaimTemplates` gives each StatefulSet ordinal its own PVC, permanently bound to that ordinal. The replacement for `postgres-0` always gets `pgdata-postgres-0`.
- Headless governing Services provide stable per-pod DNS (`postgres-0.postgres`); `publishNotReadyAddresses: true` lets peers find each other before any of them is ready.
- `OrderedReady` creates pods in ascending ordinal order and terminates them in descending order.
- Deleting pods does not delete PVCs. Deleting the StatefulSet does not delete PVCs either, unless `persistentVolumeClaimRetentionPolicy` says so.
- `--cascade=orphan` lets you replace a StatefulSet's immutable fields without dropping the pods.
- `readOnlyRootFilesystem` and volume writability are orthogonal; the postgres exception is about what the *image* writes, not about its data.

## Going further / production notes

- **EBS CSI driver and gp3.** On EKS, install the `aws-ebs-csi-driver` as a managed add-on and give it an IRSA role. Default to `gp3` over `gp2` — it is cheaper per GiB and decouples IOPS and throughput from volume size, so you no longer have to over-provision a 500Gi disk just to get 1,500 IOPS. Set `type: gp3`, `iops`, `throughput`, and `encrypted: "true"` with a `kmsKeyId` in the StorageClass `parameters`.
- **Always encrypt.** Set `encrypted: "true"` in the StorageClass parameters, and enable EBS encryption-by-default at the account level so an unencrypted volume cannot be created by accident. Encryption cannot be added to an existing volume in place — it requires a snapshot-and-restore, which is a migration you do not want to discover you need.
- **`WaitForFirstConsumer` is mandatory on EBS.** EBS volumes are zonal and cannot cross an AZ boundary. With `Immediate` binding the provisioner picks a zone before the scheduler picks a node, and the two disagree roughly two-thirds of the time in a three-AZ cluster. Pair it with `allowedTopologies` if you need to constrain provisioning further.
- **Topology-aware scheduling for StatefulSets.** Because each ordinal's volume is pinned to one AZ, that ordinal can only ever run in that AZ. Losing an AZ takes those replicas down until you restore from a snapshot. Spread ordinals across zones with `topologySpreadConstraints` on `topology.kubernetes.io/zone` and treat AZ loss as a data-recovery event, not a rescheduling one.
- **Turn on `allowVolumeExpansion: true`.** With it, growing a full disk is `kubectl patch pvc ... -p '{"spec":{"resources":{"requests":{"storage":"100Gi"}}}}'` and an online filesystem resize. Without it, the same situation is a snapshot, a new volume, and downtime. Note EBS enforces a cooldown between modifications of the same volume, and volumes can only grow.
- **`reclaimPolicy: Retain` for anything you would miss.** `Delete` means `kubectl delete pvc` destroys the data immediately with no undo. `Retain` leaves the PV in `Released` state requiring a deliberate human action. The operational cost is that you must reclaim PVs by hand; that is the correct trade for a database.
- **`persistentVolumeClaimRetentionPolicy` is a cost control as much as a safety one.** `whenScaled: Retain` on an autoscaled StatefulSet accumulates orphaned gp3 volumes every time it scales in. Audit unattached EBS volumes on a schedule — it is one of the most common sources of unexplained EKS spend.
- **Snapshots, not just replication.** Install the external-snapshotter and use `VolumeSnapshot` / `VolumeSnapshotClass` for point-in-time copies. Replication protects against node and AZ failure; it faithfully replicates a `DROP TABLE`. For postgres specifically, prefer a logical backup to S3 (CloudNativePG's `barmanObjectStore`, or `pgBackRest`) so you get PITR rather than just crash-consistent block snapshots.
- **Use an operator for databases.** CloudNativePG or Zalando/Patroni handle failover, replication, connection routing, backups, and major-version upgrades. A hand-rolled StatefulSet gives you identity and ordering and nothing else — every hard part of running a database is still yours. Or, honestly, run it on RDS/Aurora and keep the stateful complexity out of your cluster entirely.
- **EFS for `ReadWriteMany`.** EBS cannot be shared across nodes. If multiple pods on different nodes must write the same volume, that is the `aws-efs-csi-driver` with an access point per claim. Expect NFS latency characteristics and price it carefully — EFS is substantially more expensive per GiB than gp3.
