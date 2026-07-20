# Lab 08 — Packaging an Application as a Helm Chart

Every lab so far has applied loose YAML with `kubectl apply -f`. That works
until you need the same application in dev, staging and production with three
different replica counts, two different ingress hostnames and one IRSA role
ARN per account — at which point copy-pasted manifests drift, and the drift is
discovered during an incident. Helm solves this by making the manifests a
*function* of a values file: the template is reviewed once, the per-environment
inputs are small and diffable, and `helm upgrade` is transactional with a real
rollback. This lab builds a chart that is genuinely production-shaped rather
than the `helm create` scaffold — schema-validated values, config checksums
that actually roll pods, capability-guarded CRDs, and a chart test that fails
the release if the app is not serving.

## Objectives

- Build a complete chart from scratch: `Chart.yaml`, `values.yaml`, helpers, and eleven templates.
- Write named templates (`_helpers.tpl`) that produce DNS-safe, 63-character-truncated names.
- Understand why `selectorLabels` must be a strict, *immutable* subset of `labels`.
- Use `checksum/config` annotations so a config-only change actually restarts pods.
- Guard optional CRD-backed resources with `.Capabilities.APIVersions.Has`.
- Enforce input correctness with a real `values.schema.json`.
- Ship a `helm.sh/hook: test` pod and gate releases on it.
- Understand Helm's map *coalescing* behaviour and why `{}` does not clear a default.

## Prerequisites

- A running kind cluster (see `kind/` at the repo root).
- `helm` v3.12+ or v4.x on your PATH (`helm version`).
- `kubectl` configured against the cluster.
- The demo image available to the cluster:
  `kind load docker-image ghcr.io/maneeshm/k8s-labs-demo:1.0.0 --name kubernetes-labs`
- Labs 01–03 completed, or at least read — this lab assumes Deployments, Services, ConfigMaps and Secrets are familiar.

## Manifests in this lab

| Path | Kind | Purpose |
| --- | --- | --- |
| `demo-app/Chart.yaml` | Chart metadata | Name, chart version, `appVersion`, maintainers, `kubeVersion` floor. |
| `demo-app/values.yaml` | Values | Fully commented defaults; the chart's primary documentation. |
| `demo-app/values.schema.json` | JSON Schema | Rejects typos and bad types before anything reaches the API server. |
| `demo-app/.helmignore` | Ignore list | Keeps VCS, editor and local-override files out of the packaged `.tgz`. |
| `demo-app/README.md` | Docs | Per-value reference table. |
| `demo-app/templates/_helpers.tpl` | Named templates | `name`, `fullname`, `chart`, `labels`, `selectorLabels`, `serviceAccountName`, `image`. |
| `demo-app/templates/deployment.yaml` | Deployment | Hardened pod spec, downward API, config checksums, conditional `replicas`. |
| `demo-app/templates/service.yaml` | Service | ClusterIP with a **named** `http` port. |
| `demo-app/templates/serviceaccount.yaml` | ServiceAccount | Dedicated identity, token automount disabled. |
| `demo-app/templates/configmap.yaml` | ConfigMap | Rendered from `.Values.config`, consumed via `envFrom`. |
| `demo-app/templates/secret.yaml` | Secret | Rendered from `.Values.secrets` (lab use only). |
| `demo-app/templates/ingress.yaml` | Ingress | With the `apiVersion` capability-check idiom. |
| `demo-app/templates/hpa.yaml` | HorizontalPodAutoscaler | `autoscaling/v2` with scale-up/scale-down `behavior`. |
| `demo-app/templates/pdb.yaml` | PodDisruptionBudget | Voluntary-disruption floor. |
| `demo-app/templates/servicemonitor.yaml` | ServiceMonitor | Double-guarded on the value **and** the CRD's presence. |
| `demo-app/templates/NOTES.txt` | Post-install output | Branches on `service.type` / `ingress.enabled`; warns on single-replica and rendered Secrets. |
| `demo-app/templates/tests/test-connection.yaml` | Pod | `helm test` hook that curls `/healthz`, `/readyz` and `/metrics`. |
| `values-production.yaml` | Values override | EKS-shaped example: IRSA, ALB Ingress, AZ spread, autoscaling. |

## Walkthrough

1. **Lint the chart before rendering anything.** `helm lint` catches malformed
   `Chart.yaml`, missing required fields and values that violate the schema.

   ```bash
   cd labs/08-helm-chart
   helm lint demo-app
   ```

   Expect `1 chart(s) linted, 0 chart(s) failed`. The `[INFO] icon is
   recommended` note is advisory — charts published to a repository should set
   `icon` in `Chart.yaml`, but it has no effect on rendering.

2. **Render the chart locally and read the output.** `helm template` runs the
   whole pipeline without touching the cluster. This is the fastest feedback
   loop in Helm development and the thing to run before every commit.

   ```bash
   helm template demo-app ./demo-app | less
   ```

   Confirm the generated names are `demo-app-*`, the labels include both
   `helm.sh/chart` and the six `app.kubernetes.io/*` keys, and the pod template
   carries the security context.

3. **Prove the schema actually rejects bad input.** This is the payoff for
   writing `values.schema.json`.

   ```bash
   # Wrong type
   helm template demo-app ./demo-app --set replicaCount=two

   # Misspelled key — caught only because additionalProperties is false
   helm template demo-app ./demo-app --set replicaCounts=3

   # Invalid enum value
   helm template demo-app ./demo-app --set service.type=Cluster
   ```

   All three fail with `values don't meet the specifications of the schema`.
   Without the schema, the first would produce invalid YAML, and the second
   would be *silently ignored* — a release that quietly keeps the old replica
   count is far worse than one that fails loudly.

4. **Install into the cluster.**

   ```bash
   helm upgrade --install demo-app ./demo-app \
     --namespace lab-08-helm --create-namespace \
     --wait --timeout 3m
   ```

   `--install` makes this idempotent, so the same command works for the first
   deploy and every subsequent one — which is exactly what a CI pipeline wants.
   `--wait` blocks until pods are Ready, turning a broken image into a failed
   pipeline step instead of a green deploy with a CrashLoopBackOff behind it.

5. **Read the NOTES output and run the chart test.**

   ```bash
   helm status demo-app --namespace lab-08-helm
   helm test demo-app --namespace lab-08-helm --logs
   ```

   The test pod curls `/healthz` and `/readyz` and asserts that
   `demo_app_build_info` appears on `/metrics`. Because it carries the same
   security context as the app, a passing test also proves the namespace's Pod
   Security admission admits a compliant pod.

6. **Demonstrate the config checksum.** This is the single most valuable idiom
   in the chart. Change only a ConfigMap value and watch the pods roll:

   ```bash
   kubectl get pods -n lab-08-helm -l app.kubernetes.io/name=demo-app

   helm upgrade demo-app ./demo-app \
     --namespace lab-08-helm \
     --reuse-values --set config.LOG_LEVEL=debug

   kubectl rollout status deployment/demo-app -n lab-08-helm
   kubectl get pods -n lab-08-helm -l app.kubernetes.io/name=demo-app
   ```

   The pod names changed. Without `checksum/config`, the ConfigMap would have
   been updated in place, the Deployment's pod template would be byte-identical,
   and Kubernetes would correctly conclude there is nothing to do — leaving
   every running pod with the old environment variables indefinitely.

7. **Inspect release history and roll back.**

   ```bash
   helm history demo-app --namespace lab-08-helm
   helm get values demo-app --namespace lab-08-helm
   helm rollback demo-app 1 --namespace lab-08-helm --wait
   helm history demo-app --namespace lab-08-helm
   ```

   Note that a rollback creates a *new* revision rather than deleting one — the
   history is append-only, which is what makes it auditable.

8. **Render the production overrides without applying them.** The values file
   targets EKS (IRSA annotation, ALB Ingress class, AZ topology spread), so it
   is meant to be read rather than installed on kind:

   ```bash
   helm template demo-app ./demo-app \
     -f values-production.yaml \
     --set autoscaling.enabled=true \
     --set ingress.enabled=true \
     --set serviceMonitor.enabled=true \
     | grep -E '^kind:|replicas:|kind: Secret'
   ```

   Two things to verify in the output. First, the Deployment has **no**
   `replicas` field, because `autoscaling.enabled` suppresses it. Second, there
   is **no** Secret: `values-production.yaml` sets `secrets: null`, not
   `secrets: {}`. Helm *coalesces* maps, so an empty map would merge over the
   default and leave the lab's `API_KEY` in place. Only an explicit `null`
   deletes an inherited key — verify with `grep`, never by assumption.

9. **Observe the capability guard.** `serviceMonitor.enabled=true` above did
   *not* produce a ServiceMonitor, because kind has no Prometheus Operator CRDs.
   Force the capability to see the other branch:

   ```bash
   helm template demo-app ./demo-app \
     --set serviceMonitor.enabled=true \
     --api-versions monitoring.coreos.com/v1 \
     | grep -A6 'kind: ServiceMonitor'
   ```

   Guarding on `.Capabilities.APIVersions.Has` means a cluster without the
   operator gets a working release minus its metrics, rather than a hard failure
   with `no matches for kind "ServiceMonitor"`. Lab 09 installs the operator and
   turns this on for real.

10. **Package the chart** as a versioned, distributable artifact:

    ```bash
    helm package demo-app --destination /tmp
    tar -tzf /tmp/demo-app-0.1.0.tgz
    ```

    Confirm `.helmignore` did its job — no `values-local*.yaml`, no `.git`.

## Verification

```bash
# The release is deployed, not failed or pending
helm list --namespace lab-08-helm

# Pods are Running and Ready, and the ReplicaSet is fully rolled out
kubectl get pods,rs -n lab-08-helm -l app.kubernetes.io/name=demo-app

# All expected objects exist
kubectl get deploy,svc,sa,cm,secret,pdb -n lab-08-helm

# The chart test passes
helm test demo-app --namespace lab-08-helm --logs

# Security context landed on the running pod, not just in the template
kubectl get deploy demo-app -n lab-08-helm \
  -o jsonpath='{.spec.template.spec.containers[0].securityContext}' | jq

# The ServiceAccount token is NOT mounted
kubectl get pods -n lab-08-helm -l app.kubernetes.io/name=demo-app \
  -o jsonpath='{.items[0].spec.volumes[*].name}'
# -> should not contain a kube-api-access-* volume

# The app answers through the Service
kubectl port-forward -n lab-08-helm svc/demo-app 8080:8080 &
curl -s localhost:8080/api/info | jq
curl -s localhost:8080/metrics | grep demo_app_build_info
kill %1
```

## Cleanup

```bash
helm uninstall demo-app --namespace lab-08-helm
kubectl delete namespace lab-08-helm
```

`helm uninstall` removes the objects it created but leaves the namespace behind
even when `--create-namespace` created it, so the second command is not
redundant. Add `--keep-history` to the uninstall if you want the release
metadata retained for a later `helm rollback`.

## What you learned

- A chart's real interface is `values.yaml` plus `values.schema.json`; templates are implementation detail.
- `selectorLabels` must exclude anything that changes over the life of the release, because `spec.selector` is immutable — putting `app.kubernetes.io/version` in the selector makes the next upgrade fail permanently.
- `checksum/config` and `checksum/secret` annotations are what make config changes actually take effect.
- `.Capabilities.APIVersions.Has` lets one chart target clusters with and without a given operator.
- `additionalProperties: false` in the schema converts silently-ignored typos into loud failures.
- Helm coalesces maps: `{}` merges, only `null` deletes.
- Omitting `replicas` when an HPA is present prevents Helm and the autoscaler from fighting over the field on every upgrade.
- `helm test` turns "the deploy succeeded" into "the deploy succeeded *and the app serves traffic*".

## Going further — production notes

**Chart distribution on AWS.** Amazon ECR is an OCI registry and Helm 3.8+
speaks OCI natively, so charts belong next to the images they deploy rather than
in a separate `gh-pages` repository:

```bash
aws ecr create-repository --repository-name charts/demo-app --region eu-west-1
aws ecr get-login-password --region eu-west-1 \
  | helm registry login --username AWS --password-stdin \
      111122223333.dkr.ecr.eu-west-1.amazonaws.com
helm push demo-app-0.1.0.tgz oci://111122223333.dkr.ecr.eu-west-1.amazonaws.com/charts
```

One IAM policy then governs both artifacts, ECR lifecycle rules prune old chart
versions, and image scanning findings sit alongside the chart that ships them.

**Secrets belong outside the chart.** The `secrets` value in this chart exists
to demonstrate the template and is unsafe in production: anything rendered from
values lands in the Helm release Secret in the cluster, in CI logs, and in shell
history. On EKS, run External Secrets Operator with an IRSA-annotated
ServiceAccount and let an `ExternalSecret` materialise a Kubernetes Secret from
AWS Secrets Manager or Parameter Store; the chart then references it via
`envFrom` — exactly what `values-production.yaml` does. Sealed Secrets is the
alternative when the constraint is "everything must be in git", but it ties
decryption to a controller keypair that becomes a backup and disaster-recovery
problem of its own.

**IRSA and Pod Identity.** `serviceAccount.annotations` carries
`eks.amazonaws.com/role-arn` for IRSA, where the pod exchanges a projected OIDC
token for AWS credentials. The IAM role's trust policy must pin *both* the
namespace and the ServiceAccount name — a trust policy with `StringLike` on
`system:serviceaccount:*` hands that role to every pod in the cluster. EKS Pod
Identity is the newer mechanism and removes the OIDC provider and per-cluster
trust policy churn; it is worth preferring for new clusters, though it requires
the Pod Identity Agent add-on and does not yet cover every edge case IRSA does.

**Resource limits, honestly.** The lab defaults set both CPU and memory limits
because that is what the `restricted` PSS and most policy engines expect.
In production, `values-production.yaml` deliberately drops the CPU limit: CFS
throttling kicks in at the quota boundary even when the node is completely idle,
which shows up as p99 latency that no amount of scaling fixes. Keep the memory
limit — memory is incompressible, and an unbounded leak takes the node's other
pods with it.

**Testing charts in CI.** `helm lint` and `helm template` are necessary but not
sufficient. Add `helm unittest` for assertions about rendered output (does
`autoscaling.enabled=true` really remove `replicas`?), `kubeconform` with the
real Kubernetes schemas to catch invalid field names that Helm happily renders,
and `conftest`/OPA policies to enforce organisational rules such as "no
`latest` tags" and "every pod sets `runAsNonRoot`". A useful CI matrix renders
the chart against every `--api-versions` combination the fleet actually runs, so
a capability guard cannot silently break on the one cluster without the operator.

**Helm's limits, and where Argo takes over.** Helm's state lives in a Secret in
the cluster, so a `helm upgrade` interrupted midway leaves a `pending-upgrade`
release that blocks the next one until someone runs `helm rollback` by hand.
`--atomic` reduces this but does not eliminate it. Helm also has no continuous
reconciliation: if an operator edits a Deployment by hand, Helm neither notices
nor corrects it until the next upgrade. Lab 10 addresses both by having Argo CD
render this same chart and reconcile it continuously — the chart stays exactly
as written here, but the delivery mechanism gains drift detection, self-heal,
and an audit trail that lives in git rather than in a cluster Secret.

**Chart versioning discipline.** `version` and `appVersion` are independent on
purpose. A template fix bumps `version` only; a new application image bumps
`appVersion` and at least the patch digit of `version`. Publishing a mutated
chart under an existing version is the Helm equivalent of force-pushing a tag —
Argo CD caches by version, so the fleet ends up split between two different
renderings of "0.1.0" with nothing in git to explain the difference.
