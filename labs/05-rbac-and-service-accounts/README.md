# Lab 05 — RBAC and Service Accounts

Every Pod in a Kubernetes cluster authenticates to the API server as *someone*. If you never say who, it is the namespace's `default` ServiceAccount — an identity shared by every other workload in that namespace, which makes "who did this?" unanswerable and least privilege impossible. Nearly every real container-escape-to-cluster-compromise story has the same middle chapter: an application was breached, the attacker read a ServiceAccount token off the filesystem, and that token turned out to be bound to something far broader than the app ever needed. This lab builds the defensive version of that story — a dedicated ServiceAccount per workload, a narrow namespaced Role, a cluster-scoped grant only where the resource genuinely is cluster-scoped, aggregated ClusterRoles for composable platform permissions, and short-lived audience-bound projected tokens instead of immortal Secrets. You will then verify all of it with `kubectl auth can-i`, from your laptop *and* from inside a Pod, because the only RBAC policy that counts is the one the API server actually enforces.

## Objectives

- Create a dedicated ServiceAccount per workload and set `automountServiceAccountToken` explicitly on both the ServiceAccount and the Pod.
- Write a namespaced `Role` + `RoleBinding` granting read access to Pods, ConfigMaps and Deployments, including a `resourceNames`-pinned write rule.
- Write a `ClusterRole` + `ClusterRoleBinding` for genuinely cluster-scoped resources (Nodes, non-resource URLs) and understand why that is the *only* good reason to use one.
- Bind a ClusterRole with a namespaced RoleBinding to reuse upstream roles like `view` without granting them cluster-wide.
- Build an aggregated ClusterRole with `aggregationRule`, and contribute rules to the built-in `view` role via the `rbac.authorization.k8s.io/aggregate-to-view` label.
- Mount a projected, audience-scoped, expiring ServiceAccount token and articulate the four ways it beats a legacy Secret token.
- Interrogate effective permissions with `kubectl auth can-i --as=...`, `kubectl auth can-i --list`, and from inside a Pod carrying the real token.
- Map all of it onto EKS: IRSA, EKS Pod Identity, `aws-auth` vs Access Entries.

## Prerequisites

- A running kind cluster named `k8s-labs` (`make cluster-up` from the repo root).
- `kubectl` v1.29+ on your PATH; `kubectl auth can-i --list` needs a reasonably modern client.
- The demo image `ghcr.io/maneeshm/k8s-labs-demo:1.0.0` loaded into the cluster (`make image`), plus network access to pull `bitnami/kubectl:1.31`.
- Cluster-admin on the kind cluster — you need it to *create* RBAC objects. (Kubernetes forbids privilege escalation: you may only grant permissions you already hold, unless you hold the `escalate` verb.)
- Labs 01–03 are helpful context but not required.

## Manifests in this lab

| File | What it does |
| --- | --- |
| `00-namespace.yaml` | Creates `lab-05-rbac` with the restricted Pod Security Standard enforced. |
| `10-serviceaccount.yaml` | Three ServiceAccounts: `demo-app` (workload), `kubectl-debug` (in-cluster tooling), `no-perms` (control identity with automount disabled). |
| `20-role-and-rolebinding.yaml` | Namespaced `Role` (read pods/configmaps/deployments, get pod logs, patch one named ConfigMap) plus the `RoleBinding` that activates it. |
| `30-clusterrole-and-binding.yaml` | `ClusterRole` for nodes + `nonResourceURLs`, its `ClusterRoleBinding`, and a `RoleBinding` that scopes the built-in `view` ClusterRole to this namespace only. |
| `40-aggregated-clusterrole.yaml` | An aggregated `ClusterRole` (`lab-05-platform-view`), two contributor roles it unions in, a role that extends the built-in `view`, and a binding. |
| `50-configmap.yaml` | `demo-app-config` — the object the `resourceNames` rule pins to. |
| `60-deployment.yaml` | The demo app running as the `demo-app` SA with a projected, audience-bound, 1-hour token. |
| `70-service.yaml` | ClusterIP Service in front of the demo app. |
| `80-kubectl-debug-pod.yaml` | Two `bitnami/kubectl:1.31` Pods (`kubectl-debug`, `kubectl-noperms`) for testing permissions from inside the cluster. Runs as UID 1001 — see the comment in the file. |

## Walkthrough

### 1. Create the namespace and the identities

```bash
kubectl apply -f 00-namespace.yaml
kubectl apply -f 10-serviceaccount.yaml

kubectl -n lab-05-rbac get serviceaccounts
kubectl -n lab-05-rbac get sa demo-app -o yaml | grep -A2 automount
```

Observe: three ServiceAccounts plus the `default` one you never asked for. Note there is **no** `secrets:` list on any of them — since Kubernetes 1.24 ServiceAccounts no longer get an auto-generated, never-expiring Secret token. If you see one on an older cluster, treat it as technical debt.

### 2. Confirm the SAs currently have nothing

```bash
kubectl auth can-i list pods \
  --as=system:serviceaccount:lab-05-rbac:demo-app \
  -n lab-05-rbac

kubectl auth can-i --list \
  --as=system:serviceaccount:lab-05-rbac:demo-app \
  -n lab-05-rbac
```

Observe: the first command prints `no`. The second prints only the handful of rules every authenticated identity gets — `selfsubjectaccessreviews`, `selfsubjectrulesreviews`, and the `/healthz`-style non-resource URLs from `system:discovery`. That baseline is your "zero permissions" reference point.

### 3. Grant the namespaced Role, then re-check

```bash
kubectl apply -f 20-role-and-rolebinding.yaml

kubectl -n lab-05-rbac describe role pod-configmap-reader
kubectl -n lab-05-rbac describe rolebinding demo-app-pod-configmap-reader

kubectl auth can-i list pods \
  --as=system:serviceaccount:lab-05-rbac:demo-app -n lab-05-rbac
kubectl auth can-i get pods/log \
  --as=system:serviceaccount:lab-05-rbac:demo-app -n lab-05-rbac
kubectl auth can-i delete pods \
  --as=system:serviceaccount:lab-05-rbac:demo-app -n lab-05-rbac
kubectl auth can-i list secrets \
  --as=system:serviceaccount:lab-05-rbac:demo-app -n lab-05-rbac
```

Observe: `yes`, `yes`, `no`, `no`. RBAC is purely additive and whitelist-only — there is no `deny` rule, so the *absence* of a grant is the denial. That also means you can never "subtract" a permission later; you remove the binding that granted it.

### 4. Watch the namespace boundary hold

```bash
# Same verb, same resource, different namespace.
kubectl auth can-i list pods \
  --as=system:serviceaccount:lab-05-rbac:demo-app -n kube-system

# And at cluster scope (all namespaces).
kubectl auth can-i list pods \
  --as=system:serviceaccount:lab-05-rbac:demo-app --all-namespaces
```

Observe: both `no`. A RoleBinding grants inside exactly one namespace. This is the property you give up the moment you reach for a ClusterRoleBinding.

### 5. Test the `resourceNames` pin

```bash
kubectl apply -f 50-configmap.yaml

kubectl auth can-i patch configmap/demo-app-config \
  --as=system:serviceaccount:lab-05-rbac:demo-app -n lab-05-rbac
kubectl auth can-i patch configmap/some-other-config \
  --as=system:serviceaccount:lab-05-rbac:demo-app -n lab-05-rbac
```

Observe: `yes` then `no`. `resourceNames` is how you let a workload rotate its own config without handing it every ConfigMap in the namespace. Remember the restriction: it cannot be combined with `list`, `watch`, `create` or `deletecollection`, because those requests carry no object name for the authorizer to match.

### 6. Grant the cluster-scoped ClusterRole

```bash
kubectl apply -f 30-clusterrole-and-binding.yaml

kubectl auth can-i list nodes \
  --as=system:serviceaccount:lab-05-rbac:demo-app
kubectl auth can-i get --raw=/version \
  --as=system:serviceaccount:lab-05-rbac:demo-app
```

Observe: both `yes`. Note that no `-n` flag was needed — Nodes are cluster-scoped, and a RoleBinding could never have granted them regardless of what the ClusterRole said.

### 7. See a ClusterRole scoped down by a RoleBinding

```bash
# kubectl-debug got the built-in `view` ClusterRole via a *RoleBinding*.
kubectl auth can-i list services \
  --as=system:serviceaccount:lab-05-rbac:kubectl-debug -n lab-05-rbac
kubectl auth can-i list services \
  --as=system:serviceaccount:lab-05-rbac:kubectl-debug -n default

# `view` deliberately excludes Secrets.
kubectl auth can-i list secrets \
  --as=system:serviceaccount:lab-05-rbac:kubectl-debug -n lab-05-rbac
```

Observe: `yes`, `no`, `no`. Reusing an upstream ClusterRole through a RoleBinding is the cheapest correct answer to "give this team read access to their namespace".

### 8. Build the aggregated ClusterRole and watch it assemble itself

```bash
kubectl apply -f 40-aggregated-clusterrole.yaml

# Rules were EMPTY in the YAML. The aggregation controller filled them in.
kubectl get clusterrole lab-05-platform-view -o yaml | sed -n '/^rules:/,$p'

kubectl auth can-i list deployments.apps \
  --as=system:serviceaccount:lab-05-rbac:kubectl-debug -n lab-05-rbac
kubectl auth can-i list networkpolicies.networking.k8s.io \
  --as=system:serviceaccount:lab-05-rbac:kubectl-debug -n lab-05-rbac
```

Observe: the `rules:` block now contains the union of both contributor ClusterRoles, even though we submitted `rules: []`. Delete one contributor and the rules shrink within a second — try `kubectl delete clusterrole lab-05-platform-view-networking`, re-read the aggregate, then `kubectl apply -f 40-aggregated-clusterrole.yaml` to restore it.

Also check what happened to the built-in `view` role:

```bash
kubectl get clusterrole view -o yaml | grep -A4 poddisruptionbudgets
```

Observe: our `lab-05-view-poddisruptionbudgets` rules are now part of `view` cluster-wide. This is exactly how operators extend permissions for their CRDs — and exactly why a PR adding an `aggregate-to-view` label deserves the same scrutiny as a PR editing `view` directly.

### 9. Deploy the workload with a bound token

```bash
kubectl apply -f 60-deployment.yaml -f 70-service.yaml
kubectl -n lab-05-rbac rollout status deploy/demo-app

POD=$(kubectl -n lab-05-rbac get pod -l app.kubernetes.io/name=demo-app \
  -o jsonpath='{.items[0].metadata.name}')

# The bound token we projected...
kubectl -n lab-05-rbac exec "$POD" -- ls -l /var/run/secrets/tokens
# ...and the automounted default one, which is ALSO a projected token.
kubectl -n lab-05-rbac exec "$POD" -- ls /var/run/secrets/kubernetes.io/serviceaccount
```

Observe: `token`, `ca.crt` and `namespace` in our projected volume; `ca.crt`, `namespace` and `token` in the automounted one. Both are projected tokens on a modern cluster — the difference is that ours declares an explicit non-default `audience` and lifetime.

Decode the claims (base64url of the middle JWT segment):

```bash
kubectl -n lab-05-rbac exec "$POD" -- cat /var/run/secrets/tokens/token \
  | cut -d. -f2 | tr '_-' '/+' | base64 -d 2>/dev/null | tr ',' '\n'
```

Observe: `"aud":["lab-05-demo"]`, an `exp` roughly one hour out, and a
`kubernetes.io` claim naming the Pod **and its UID**. That UID binding is what makes the token die with the Pod. Because `aud` is *not* the API server's audience, this token will not authenticate to the API server at all — it is for your own downstream service to validate, which is the entire point of audience scoping.

### 10. Test permissions from *inside* the cluster

```bash
kubectl apply -f 80-kubectl-debug-pod.yaml
kubectl -n lab-05-rbac wait --for=condition=Ready pod/kubectl-debug --timeout=120s

kubectl -n lab-05-rbac exec -it kubectl-debug -- bash
```

Inside the Pod — you are now authenticating as `system:serviceaccount:lab-05-rbac:kubectl-debug` with no kubeconfig at all, purely from the automounted token and the in-cluster environment variables:

```bash
kubectl auth whoami
kubectl auth can-i --list
kubectl get pods
kubectl get nodes
kubectl get secrets           # expect: forbidden
kubectl -n kube-system get pods   # expect: forbidden
exit
```

Observe: `kubectl auth whoami` confirms the SA identity. `get pods` and `get nodes` succeed; `get secrets` fails with

```text
Error from server (Forbidden): secrets is forbidden: User
"system:serviceaccount:lab-05-rbac:kubectl-debug" cannot list resource "secrets"
in API group "" in the namespace "lab-05-rbac"
```

That message is worth learning to read: it names the **identity**, the **verb**, the **resource**, the **API group** (empty string = core), and the **namespace**. Those five fields are precisely the five you need to write the missing rule.

### 11. Contrast with the identity that has nothing

```bash
kubectl -n lab-05-rbac wait --for=condition=Ready pod/kubectl-noperms --timeout=120s
kubectl -n lab-05-rbac exec -it kubectl-noperms -- kubectl get pods
kubectl -n lab-05-rbac exec -it kubectl-noperms -- ls /var/run/secrets/kubernetes.io/
```

Observe: the API call fails before authorisation even happens, because with `automountServiceAccountToken: false` there is no token on disk — the second command shows the path does not exist. The Pod cannot present a credential, so it is `system:anonymous`. For any workload that does not call the API server, this is the correct configuration and it costs nothing.

## Verification

Run these from your admin context. All should print exactly the value shown.

```bash
# 1. The workload is running as the SA we intended, not `default`.
kubectl -n lab-05-rbac get deploy demo-app \
  -o jsonpath='{.spec.template.spec.serviceAccountName}{"\n"}'
# expected: demo-app

# 2. The narrow Role grants reads but not writes.
kubectl auth can-i list pods   --as=system:serviceaccount:lab-05-rbac:demo-app -n lab-05-rbac
kubectl auth can-i delete pods --as=system:serviceaccount:lab-05-rbac:demo-app -n lab-05-rbac
# expected: yes
# expected: no

# 3. The namespace boundary holds.
kubectl auth can-i list pods --as=system:serviceaccount:lab-05-rbac:demo-app -n kube-system
# expected: no

# 4. Cluster-scoped grant works without a namespace.
kubectl auth can-i list nodes --as=system:serviceaccount:lab-05-rbac:demo-app
# expected: yes

# 5. The aggregated ClusterRole was populated by the controller.
kubectl get clusterrole lab-05-platform-view \
  -o jsonpath='{range .rules[*]}{.resources}{"\n"}{end}' | sort
# expected: five lines covering deployments/statefulsets/daemonsets/replicasets,
#           jobs/cronjobs, services/endpoints, ingresses/networkpolicies,
#           endpointslices

# 6. The projected token is audience-bound and expiring.
kubectl -n lab-05-rbac get deploy demo-app -o jsonpath='{range .spec.template.spec.volumes[?(@.name=="bound-sa-token")].projected.sources[*]}{.serviceAccountToken.audience}{" "}{.serviceAccountToken.expirationSeconds}{"\n"}{end}'
# expected: lab-05-demo 3600

# 7. The no-perms Pod really has no token.
kubectl -n lab-05-rbac exec kubectl-noperms -- \
  sh -c 'test -e /var/run/secrets/kubernetes.io/serviceaccount/token && echo PRESENT || echo ABSENT'
# expected: ABSENT

# 8. In-cluster identity is what we think it is.
kubectl -n lab-05-rbac exec kubectl-debug -- kubectl auth whoami \
  -o jsonpath='{.status.userInfo.username}{"\n"}'
# expected: system:serviceaccount:lab-05-rbac:kubectl-debug
```

A quick audit sweep worth internalising — find every ClusterRoleBinding that hands out `cluster-admin`:

```bash
kubectl get clusterrolebindings -o json \
  | jq -r '.items[] | select(.roleRef.name=="cluster-admin")
           | "\(.metadata.name)\t\(.subjects // [] | map(.kind+"/"+.name) | join(","))"'
```

On a fresh kind cluster you should see only `cluster-admin` (bound to `system:masters`). Anything else on a real cluster is a finding.

## Cleanup

```bash
# Namespaced objects go with the namespace.
kubectl delete -f 00-namespace.yaml --ignore-not-found

# Cluster-scoped objects do NOT. This is the classic RBAC cleanup trap:
# deleting a namespace leaves orphaned ClusterRoles and ClusterRoleBindings
# behind, including ones still granting access to a namespace that no longer
# exists (and will grant it again if the namespace is recreated).
kubectl delete clusterrolebinding lab-05-demo-app-node-reader \
  lab-05-kubectl-debug-platform-view --ignore-not-found
kubectl delete clusterrole lab-05-node-reader lab-05-platform-view \
  lab-05-platform-view-workloads lab-05-platform-view-networking \
  lab-05-view-poddisruptionbudgets --ignore-not-found

# Confirm nothing of ours survives.
kubectl get clusterrole,clusterrolebinding \
  -l app.kubernetes.io/instance=lab-05
# expected: No resources found
```

## What you learned

- Every Pod authenticates as a ServiceAccount; not choosing one means choosing `default`, which is shared and therefore unauditable.
- `automountServiceAccountToken` should be set explicitly at both SA and Pod level — the default is `true`, and `true` is the insecure default for any workload that never calls the API.
- RBAC is additive, whitelist-only, and has no deny rules: you revoke by deleting bindings, never by adding a negative rule.
- A `Role` cannot be widened beyond its namespace, which makes it the safe default; a `ClusterRole` is justified when the *resource* is cluster-scoped (Nodes, Namespaces, PVs, `nonResourceURLs`) — not when you are just tired of repeating yourself.
- Binding a ClusterRole with a **RoleBinding** gives you upstream role reuse (`view`, `edit`) at namespace scope; it can never grant cluster-scoped resources.
- `resourceNames` pins a rule to named objects, and cannot be used with `list`/`watch`/`create`/`deletecollection`.
- Aggregated ClusterRoles let independent components compose permissions; `rules` is controller-owned and anything you write there is overwritten.
- Projected ServiceAccount tokens are audience-bound, time-bound, Pod-UID-bound and absent from etcd — four independent improvements over legacy Secret tokens.
- The `Forbidden` error message contains exactly the five fields (identity, verb, resource, API group, namespace) needed to write the rule that would allow it.
- `kubectl auth can-i --as=...` and `--list` let you test policy without ever holding the credential; `kubectl auth whoami` tells you who you actually are.

## Going further / production notes

- **IRSA (IAM Roles for Service Accounts).** The mature EKS pattern for giving a Pod AWS permissions. You associate an OIDC provider with the cluster (`eksctl utils associate-iam-oidc-provider --cluster k8s-labs --approve`, or `aws iam create-open-id-connect-provider` against the cluster's `.identity.oidc.issuer`), create an IAM role whose trust policy federates that provider and conditions on `sub = system:serviceaccount:<ns>:<sa>` **and** `aud = sts.amazonaws.com`, then annotate the SA with `eks.amazonaws.com/role-arn`. A mutating webhook injects `AWS_ROLE_ARN`, `AWS_WEB_IDENTITY_TOKEN_FILE` and a projected token — the exact mechanism you mounted by hand in `60-deployment.yaml`. Always condition the trust policy on `sub`; a wildcard there means *any* Pod in the cluster can assume the role.
- **EKS Pod Identity** is the newer alternative (EKS 1.24+, via the `eks-pod-identity-agent` add-on). You create a `PodIdentityAssociation` mapping namespace + SA to a role, with a single reusable trust policy on `pods.eks.amazonaws.com` — no OIDC provider per cluster, no per-role trust policy edit, and roles are reusable across clusters. Trade-offs: it does not work on Fargate, and it requires the agent DaemonSet. For greenfield clusters prefer Pod Identity; for existing IRSA estates the migration is mechanical but not urgent. Note that with Pod Identity the SDK gets credentials from the agent's local endpoint rather than from a mounted token, so the `AWS_WEB_IDENTITY_TOKEN_FILE` path disappears.
- **`aws-auth` ConfigMap vs EKS Access Entries.** The legacy path maps IAM principals to Kubernetes users/groups via a ConfigMap in `kube-system` — famously easy to lock yourself out of, since a malformed edit is applied instantly and there is no API-level validation. Access Entries (and Access Policies like `AmazonEKSClusterAdminPolicy`, `AmazonEKSViewPolicy`) move that mapping into the EKS API, so it is IAM-auditable, CloudTrail-logged, and manageable through Terraform/CloudFormation without touching the cluster. Set the cluster's authentication mode to `API_AND_CONFIG_MAP`, migrate entries, then move to `API`. Keep exactly one break-glass IAM principal with cluster-admin and alarm on its use.
- **Node/kubelet identity.** On EKS the node IAM role is a separate blast radius: any Pod on a node without IRSA/Pod Identity can reach IMDS and assume the node role. Set the IMDSv2 hop limit to 1 and/or block `169.254.169.254` egress with a NetworkPolicy — see lab 07, which does exactly that.
- **Least-privilege review tooling.** `kubectl-who-can <verb> <resource>` (Aqua) answers the inverse question — *who* can do this — which is the question an auditor actually asks. Pair it with `kubectl auth can-i --list --as=...` per SA, `rakkess` for a permission matrix, `krane`/`rbac-tool` (`rbac-tool viz` produces a graph, `rbac-tool policy-rules` a flat report) for drift detection, and `kubent`/`popeye` in CI. A cheap high-value control: fail CI on any new `ClusterRoleBinding` to `cluster-admin`, any rule containing `"*"` in verbs/resources/apiGroups, and any grant of `escalate`, `bind`, `impersonate`, or `secrets` `list`/`watch`.
- **The `secrets: list` trap.** Read access to Secrets in a namespace is effectively equivalent to becoming every workload in it. Treat `list`/`watch` on Secrets as a privileged grant and prefer `get` with `resourceNames`, or move secrets out of etcd entirely with the Secrets Store CSI driver + AWS Secrets Manager (with IRSA/Pod Identity gating access), or External Secrets Operator.
- **Audit before you tighten.** Enable the EKS audit log to CloudWatch and query with Logs Insights for `responseStatus.code = 403` grouped by `user.username` to find under-privileged workloads, and for actually-used verbs per SA to find over-privileged ones. Deriving Roles from observed traffic beats guessing, and it gives you evidence when someone objects to the tightening.
- **Automate the mundane.** Kyverno or a validating admission policy (`ValidatingAdmissionPolicy`, GA in 1.30, no webhook required) can reject any Pod that does not set `automountServiceAccountToken: false` unless it carries an explicit exemption annotation. That turns "remember to think about it" into a property of the platform.
