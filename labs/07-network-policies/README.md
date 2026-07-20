# Lab 07 — Network Policies

By default, every Pod in a Kubernetes cluster can open a TCP connection to every other Pod, in every namespace, on every port. There is no firewall between your frontend and your database, none between the marketing team's namespace and the payments namespace, and nothing stopping a compromised sidecar from reading the EC2 instance metadata service and walking off with your node's IAM credentials. NetworkPolicy is the API that fixes this, and it is the closest thing Kubernetes has to network segmentation. It is also unusually easy to get subtly wrong: it is whitelist-only with no deny rules and no ordering, it requires both an egress rule at the source *and* an ingress rule at the destination, its selectors match Pod labels rather than Services, and — the one that costs everyone an afternoon exactly once — the moment you apply a default-deny egress policy you silently break DNS for the entire namespace. This lab builds a three-tier application, locks it down, and then breaks and fixes each of those things on purpose.

> ## ⚠️ READ THIS FIRST: kind does not enforce NetworkPolicy by default
>
> **kindnet, the default CNI in kind, has no NetworkPolicy implementation at all.** It creates the objects, the API server accepts them, `kubectl get netpol` lists them happily — and *nothing is enforced*. Every connectivity test in this lab will succeed whether or not you have applied the policies.
>
> This is not a bug you can configure around. NetworkPolicy is an API that the CNI plugin must implement, and kindnet does not. If you work through this lab on a default kind cluster you will conclude either that your policies are broken or, far worse, that they are working when they are not. See the next section for the fix.
>
> Quick check before you begin:
>
> ```bash
> kubectl -n kube-system get daemonset -o name | grep -Ei 'calico|cilium|kindnet'
> ```
>
> If that prints `daemonset.apps/kindnet`, **policies are not enforced** and you must rebuild the cluster.

## Objectives

- Build a cluster whose CNI actually enforces NetworkPolicy (Calico or Cilium on kind).
- Establish a namespace-wide default-deny for both ingress and egress, and understand exactly what "selected by a policy" means.
- Restore DNS — the mandatory companion to any default-deny-egress — and recognise its failure signature.
- Allow `frontend → backend:8080` and `backend → database:5432` with matched egress/ingress pairs, and prove `frontend → database` stays blocked.
- Admit cross-namespace traffic with a `namespaceSelector`, and understand the AND-vs-OR trap of nesting selectors.
- Write an `ipBlock` egress rule with an `except` clause that blocks `169.254.169.254`, and explain why that matters on EKS.
- Test connectivity before and after, from an ephemeral debug Pod.

## Prerequisites

- `kind` v0.20+, `kubectl` v1.29+, and the demo image `ghcr.io/maneeshm/k8s-labs-demo:1.0.0` loaded (`make image`). Ability to pull `busybox:1.36` and `nicolaka/netshoot`.
- **A cluster with a policy-enforcing CNI.** The default `make cluster-up` builds a **kindnet** cluster, which does **not** enforce NetworkPolicy. Use `make cluster-up-calico` for this lab. Run the daemonset check above to confirm which one you have.
- Roughly 2 GB of free memory — Calico's components are not tiny.

### Building an enforcing cluster

kindnet cannot be swapped out after the fact; it has to be disabled at cluster-creation time. The repo ships a ready-made config for this at [`kind/cluster-calico.yaml`](../../kind/cluster-calico.yaml), and a Make target that creates the cluster and installs Calico for you:

```bash
# Tear down the kindnet cluster first - this is a create-time decision.
make cluster-down

# Create the cluster with disableDefaultCNI: true, then install Calico.
# Takes 3-5 minutes; most of it is Calico converging.
make cluster-up-calico

# Reload the demo image into the new cluster.
make image
```

The config differs from the default one in exactly two places:

```yaml
networking:
  # kindnet is installed unless you say otherwise, and it does NOT implement
  # NetworkPolicy. This single line is the whole prerequisite for this lab.
  disableDefaultCNI: true
  # Calico's default IPv4 pool is 192.168.0.0/16. Matching it here avoids
  # having to patch the Installation CR afterwards. A mismatch gives you pods
  # that get an IP but cannot route - a miserable thing to debug.
  podSubnet: "192.168.0.0/16"
```

<details>
<summary>Doing it by hand instead</summary>

```bash
kind delete cluster --name k8s-labs
kind create cluster --config kind/cluster-calico.yaml

# Nodes will sit NotReady until a CNI is installed - that is expected.
kubectl get nodes

# Install Calico (operator + default Installation CR).
# Note `create`, not `apply`: the CRDs in the operator manifest exceed the
# annotation size limit that `kubectl apply` writes.
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.2/manifests/tigera-operator.yaml
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.2/manifests/custom-resources.yaml

# Wait for it to converge (2-4 minutes on a cold cluster).
kubectl -n calico-system rollout status daemonset/calico-node --timeout=300s
kubectl wait --for=condition=Ready nodes --all --timeout=300s
```

</details>

Verify enforcement is live:

```bash
kubectl -n calico-system get pods
kubectl get tigerastatus
# expected: calico  AVAILABLE=True  DEGRADED=False  PROGRESSING=False
```

**Cilium alternative** — better `toFQDNs`/L7 support and Hubble for flow visibility, at the cost of a slightly heavier install:

```bash
kind create cluster --config kind/cluster-calico.yaml   # same disableDefaultCNI
helm repo add cilium https://helm.cilium.io/
helm install cilium cilium/cilium --version 1.16.3 \
  --namespace kube-system \
  --set kubeProxyReplacement=false \
  --set image.pullPolicy=IfNotPresent \
  --set ipam.mode=kubernetes \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true
cilium status --wait
```

With Cilium you additionally get `hubble observe --namespace lab-07-netpol --verdict DROPPED`, which shows you *exactly* which policy dropped which packet — the single best debugging tool in this space.

## Manifests in this lab

| File | What it does |
| --- | --- |
| `00-namespace.yaml` | Creates `lab-07-netpol` and `lab-07-netpol-monitoring` (labelled `purpose: monitoring`), both restricted-PSS. |
| `10-frontend.yaml` | `frontend` Deployment + Service. Carries `netpol.kubernetes-labs.io/tier: frontend`. |
| `20-backend.yaml` | `backend` Deployment + Service on port 8080. |
| `30-database.yaml` | `database` Deployment + Service on port 5432 (demo app with `PORT=5432`; see the file header for why not real Postgres). |
| `40-default-deny.yaml` | Namespace-wide default-deny for Ingress **and** Egress. Apply first. |
| `50-allow-dns.yaml` | Egress to CoreDNS on **UDP and TCP** 53. The mandatory companion to the file above. |
| `60-allow-frontend-to-backend.yaml` | Matched pair: frontend egress → backend:8080, backend ingress ← frontend. |
| `70-allow-backend-to-database.yaml` | Matched pair: backend egress → database:5432, database ingress ← backend. Database gets **no** egress allowance. |
| `80-allow-monitoring-namespace.yaml` | `namespaceSelector` ingress from the monitoring namespace, plus a `scraper` Deployment there to prove it. |
| `90-egress-ipblock-imds.yaml` | `ipBlock: 0.0.0.0/0` with `except` for 169.254/16 and RFC1918 — blocks IMDS. Plus a stricter allowlist example. |

## Walkthrough

### 1. Confirm your CNI enforces policy

```bash
kubectl -n kube-system get daemonset kindnet 2>/dev/null \
  && echo "*** kindnet detected - POLICIES WILL NOT BE ENFORCED ***"
kubectl get daemonset -A | grep -Ei 'calico-node|cilium'
```

Do not continue until you see `calico-node` or `cilium` and no `kindnet`.

### 2. Deploy the three tiers, with no policies yet

```bash
kubectl apply -f 00-namespace.yaml
kubectl apply -f 10-frontend.yaml -f 20-backend.yaml -f 30-database.yaml

kubectl -n lab-07-netpol rollout status deploy/frontend --timeout=180s
kubectl -n lab-07-netpol rollout status deploy/backend  --timeout=180s
kubectl -n lab-07-netpol rollout status deploy/database --timeout=180s

kubectl -n lab-07-netpol get pods -o wide --show-labels
kubectl -n lab-07-netpol get endpoints
```

Observe: five Pods, all Ready, each with a `netpol.kubernetes-labs.io/tier` label. Every Service has endpoints.

### 3. Baseline — measure the flat network BEFORE locking it down

Start a throwaway debug Pod labelled as the frontend tier, so that later policy rules apply to it:

```bash
kubectl -n lab-07-netpol run netshoot-frontend \
  --image=nicolaka/netshoot --restart=Never \
  --labels="netpol.kubernetes-labs.io/tier=frontend,run=netshoot-frontend" \
  --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":65532,"runAsGroup":65532,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"netshoot-frontend","image":"nicolaka/netshoot","command":["sleep","infinity"],"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}' \
  -- sleep infinity

kubectl -n lab-07-netpol wait --for=condition=Ready pod/netshoot-frontend --timeout=120s
```

Now run every test. Save this loop — you will run it three more times:

```bash
kubectl -n lab-07-netpol exec netshoot-frontend -- sh -c '
  for t in "backend:8080" "database:5432"; do
    printf "%-18s " "$t"
    curl -s -o /dev/null -m 4 -w "%{http_code}\n" "http://$t/" || echo TIMEOUT
  done
  printf "%-18s " "dns"
  nslookup backend >/dev/null 2>&1 && echo OK || echo FAIL
  printf "%-18s " "internet(1.1.1.1)"
  curl -s -o /dev/null -m 4 -w "%{http_code}\n" https://1.1.1.1/ || echo TIMEOUT
  printf "%-18s " "imds(169.254)"
  curl -s -o /dev/null -m 3 -w "%{http_code}\n" http://169.254.169.254/latest/meta-data/ || echo TIMEOUT
'
```

Observe — everything is reachable:

```text
backend:8080       200
database:5432      200
dns                OK
internet(1.1.1.1)  200
imds(169.254)      TIMEOUT   <- on kind there is no IMDS; on EKS this returns 200/401
```

**The frontend can reach the database directly.** That is the flat default network, and it is what you are about to remove.

### 4. Apply default-deny and watch everything break

```bash
kubectl apply -f 40-default-deny.yaml
kubectl -n lab-07-netpol get netpol
```

Re-run the test loop from step 3.

Observe — total blackout:

```text
backend:8080       TIMEOUT
database:5432      TIMEOUT
dns                FAIL
internet(1.1.1.1)  TIMEOUT
imds(169.254)      TIMEOUT
```

Note that `curl` fails with `Could not resolve host: backend` rather than a connection error — because DNS itself is gone. This is the moment to internalise the gotcha.

Meanwhile, check the app Pods:

```bash
kubectl -n lab-07-netpol get pods
```

Observe: **still Ready.** Kubelet probes originate from the node, not from another Pod, so a conformant CNI does not subject them to NetworkPolicy. If your probes *do* start failing here, that is a CNI bug worth reporting.

### 5. Restore DNS — the classic gotcha, fixed

```bash
kubectl apply -f 50-allow-dns.yaml
```

Re-run the test loop.

Observe:

```text
backend:8080       TIMEOUT     <- resolves now, but the connection is denied
database:5432      TIMEOUT
dns                OK          <- fixed
internet(1.1.1.1)  TIMEOUT
imds(169.254)      TIMEOUT
```

The error message changed from `Could not resolve host` to a connection timeout. That transition — name resolution failure becoming connection failure — is the diagnostic signature you want burned in. **A DNS-shaped error after a policy change is almost never a DNS problem; it is a missing egress rule to kube-system.**

To see it from the other direction, delete the DNS policy, watch resolution break again, then re-apply:

```bash
kubectl delete -f 50-allow-dns.yaml
kubectl -n lab-07-netpol exec netshoot-frontend -- nslookup backend    # fails
kubectl apply -f 50-allow-dns.yaml
kubectl -n lab-07-netpol exec netshoot-frontend -- nslookup backend    # works
```

Also verify the UDP/TCP point, since it is the subtle half of the rule:

```bash
kubectl -n lab-07-netpol exec netshoot-frontend -- dig +tcp +short backend.lab-07-netpol.svc.cluster.local
```

Observe: a ClusterIP is returned. Had the policy allowed only UDP 53, this forced-TCP query would hang — and in production you would see it only when a response exceeded 512 bytes, i.e. intermittently and at the worst possible time.

### 6. Open frontend → backend

```bash
kubectl apply -f 60-allow-frontend-to-backend.yaml
```

Re-run the test loop.

Observe:

```text
backend:8080       200        <- open
database:5432      TIMEOUT    <- still blocked, correctly
dns                OK
internet(1.1.1.1)  TIMEOUT
```

Now prove that **both halves** were required. Delete just the ingress half:

```bash
kubectl -n lab-07-netpol delete netpol backend-ingress-from-frontend
kubectl -n lab-07-netpol exec netshoot-frontend -- \
  curl -s -o /dev/null -m 4 -w "%{http_code}\n" http://backend:8080/ || echo TIMEOUT
# expected: TIMEOUT - the frontend is allowed OUT, but the backend denies IN.

kubectl apply -f 60-allow-frontend-to-backend.yaml
```

And prove the port number is the *Pod's* port, not the Service's:

```bash
kubectl -n lab-07-netpol get svc backend \
  -o jsonpath='svc port={.spec.ports[0].port} targetPort={.spec.ports[0].targetPort}{"\n"}'
kubectl -n lab-07-netpol get netpol frontend-egress-to-backend \
  -o jsonpath='policy port={.spec.egress[0].ports[0].port}{"\n"}'
```

Observe: the policy names 8080, the container port. kube-proxy DNAT happens before policy evaluation, so a policy written against the Service port would drop everything.

### 7. Open backend → database, and confirm the frontend still cannot

```bash
kubectl apply -f 70-allow-backend-to-database.yaml

# From the BACKEND tier - should work.
BACKEND=$(kubectl -n lab-07-netpol get pod \
  -l app.kubernetes.io/name=backend -o jsonpath='{.items[0].metadata.name}')
kubectl -n lab-07-netpol debug -it "$BACKEND" --image=nicolaka/netshoot \
  --target=backend -- curl -s -m 4 -o /dev/null -w "%{http_code}\n" http://database:5432/
```

> Note: an **ephemeral container added via `kubectl debug` shares the target Pod's network namespace**, so it inherits that Pod's labels and therefore its policies exactly. This is the only reliable way to test connectivity *as* a specific workload. A separate `kubectl run` Pod has different labels and will give you different — misleading — answers.

```bash
# From the FRONTEND tier - should still fail.
kubectl -n lab-07-netpol exec netshoot-frontend -- \
  curl -s -o /dev/null -m 4 -w "%{http_code}\n" http://database:5432/ || echo TIMEOUT
```

Observe: `200` from the backend, `TIMEOUT` from the frontend. That asymmetry *is* tiered segmentation. A compromised frontend now has exactly two reachable destinations: the backend on 8080, and DNS.

Confirm the database cannot phone home:

```bash
DB=$(kubectl -n lab-07-netpol get pod \
  -l app.kubernetes.io/name=database -o jsonpath='{.items[0].metadata.name}')
kubectl -n lab-07-netpol debug -it "$DB" --image=nicolaka/netshoot \
  --target=database -- curl -s -m 4 -o /dev/null -w "%{http_code}\n" https://1.1.1.1/ || echo TIMEOUT
```

Observe: `TIMEOUT`. The database tier was never granted any egress beyond DNS, so a fully compromised data tier still cannot exfiltrate outbound. One omitted stanza, enormous value.

### 8. Cross-namespace access with a namespaceSelector

```bash
kubectl apply -f 80-allow-monitoring-namespace.yaml
kubectl -n lab-07-netpol-monitoring rollout status deploy/scraper --timeout=180s

kubectl -n lab-07-netpol-monitoring logs -l app.kubernetes.io/name=scraper --tail=8 -f
# Ctrl-C after a couple of cycles
```

Observe: `scrape OK` for both targets. The monitoring namespace has no policies of its own (unrestricted egress), and our ingress rule admits it.

Now break it two ways, to feel where the selector actually binds:

```bash
# (a) Remove the namespace label the selector matches on.
kubectl label namespace lab-07-netpol-monitoring netpol.kubernetes-labs.io/purpose-
kubectl -n lab-07-netpol-monitoring logs -l app.kubernetes.io/name=scraper --tail=4
# expected: scrape FAIL - the namespaceSelector no longer matches

kubectl label namespace lab-07-netpol-monitoring netpol.kubernetes-labs.io/purpose=monitoring

# (b) Remove the POD label. Both selectors are AND-ed, so either one breaks it.
kubectl -n lab-07-netpol-monitoring patch deploy scraper --type=json -p='[
  {"op":"remove","path":"/spec/template/metadata/labels/netpol.kubernetes-labs.io~1tier"}
]'
kubectl -n lab-07-netpol-monitoring rollout status deploy/scraper
kubectl -n lab-07-netpol-monitoring logs -l app.kubernetes.io/name=scraper --tail=4
# expected: scrape FAIL

kubectl apply -f 80-allow-monitoring-namespace.yaml   # restore
```

(`~1` in that JSON patch path is the JSON Pointer escape for `/`, which the label key contains.)

The AND-vs-OR distinction is worth restating because it is a single dash of YAML:

```yaml
# AND - "scraper pods IN monitoring namespaces". What you almost always want.
from:
  - namespaceSelector: {matchLabels: {purpose: monitoring}}
    podSelector: {matchLabels: {tier: scraper}}

# OR - "ALL pods in monitoring namespaces, OR ALL scraper pods ANYWHERE."
from:
  - namespaceSelector: {matchLabels: {purpose: monitoring}}
  - podSelector: {matchLabels: {tier: scraper}}
```

### 9. Selective internet egress, with IMDS carved out

```bash
kubectl apply -f 90-egress-ipblock-imds.yaml

kubectl -n lab-07-netpol debug -it "$BACKEND" --image=nicolaka/netshoot \
  --target=backend -- sh -c '
    printf "internet     "; curl -s -o /dev/null -m 5 -w "%{http_code}\n" https://1.1.1.1/ || echo TIMEOUT
    printf "imds         "; curl -s -o /dev/null -m 3 -w "%{http_code}\n" http://169.254.169.254/latest/meta-data/ || echo TIMEOUT
    printf "database     "; curl -s -o /dev/null -m 4 -w "%{http_code}\n" http://database:5432/ || echo TIMEOUT
'
```

Observe: internet `200`, IMDS `TIMEOUT`, database `200`. The backend reaches the public internet on 443/80 and nothing in link-local or RFC1918 space, while the explicit `70-*` rule still carries the database traffic.

Inspect the object to see why:

```bash
kubectl -n lab-07-netpol get netpol backend-egress-internet-except-metadata \
  -o jsonpath='{.spec.egress[0].to[0].ipBlock.except}{"\n"}'
```

On kind there is no real IMDS to block, so the test is only *shape*-correct. On an EKS node the pre-policy version of this test returns a live credential document — try it once in a sandbox account and you will never forget why this rule exists.

### 10. Review the final policy set

```bash
kubectl -n lab-07-netpol get netpol
kubectl -n lab-07-netpol describe netpol default-deny-all

# Which policies select a given Pod? Calico answers this directly:
kubectl -n lab-07-netpol get pod "$BACKEND" -o jsonpath='{.metadata.labels}{"\n"}'
```

Observe: eight policy objects. Remember that no single object tells you a Pod's effective access — you must union every policy whose `podSelector` matches it. That is why tooling matters; see the production notes.

## Verification

```bash
# 0. GATE: your CNI must enforce policy or every result below is meaningless.
kubectl -n kube-system get daemonset kindnet --ignore-not-found -o name
# expected: (empty)
kubectl get daemonset -A -o name | grep -Ec 'calico-node|cilium'
# expected: 1 or more

# 1. All eight policies exist.
kubectl -n lab-07-netpol get netpol -o name | wc -l
# expected: 8

# 2. The default-deny covers BOTH directions.
kubectl -n lab-07-netpol get netpol default-deny-all \
  -o jsonpath='{.spec.policyTypes}{"\n"}'
# expected: ["Ingress","Egress"]

# 3. DNS is allowed on both protocols.
kubectl -n lab-07-netpol get netpol allow-dns-egress \
  -o jsonpath='{range .spec.egress[0].ports[*]}{.protocol}/{.port} {end}{"\n"}'
# expected: UDP/53 TCP/53

# 4. Allowed path works.
kubectl -n lab-07-netpol exec netshoot-frontend -- \
  curl -s -o /dev/null -m 5 -w "%{http_code}\n" http://backend:8080/
# expected: 200

# 5. Blocked path stays blocked (exit code 28 = curl operation timeout).
kubectl -n lab-07-netpol exec netshoot-frontend -- \
  curl -s -o /dev/null -m 5 http://database:5432/; echo "curl exit=$?"
# expected: curl exit=28

# 6. DNS resolves.
kubectl -n lab-07-netpol exec netshoot-frontend -- \
  nslookup backend.lab-07-netpol.svc.cluster.local >/dev/null && echo RESOLVES
# expected: RESOLVES

# 7. Cross-namespace scrape succeeds.
kubectl -n lab-07-netpol-monitoring logs -l app.kubernetes.io/name=scraper --tail=4 \
  | grep -c "scrape OK"
# expected: >= 1

# 8. IMDS and RFC1918 are excluded from the internet allowance.
kubectl -n lab-07-netpol get netpol backend-egress-internet-except-metadata \
  -o jsonpath='{.spec.egress[0].to[0].ipBlock.except}{"\n"}' \
  | grep -q '169.254.0.0/16' && echo IMDS_EXCLUDED
# expected: IMDS_EXCLUDED

# 9. The database tier has no egress policy granting it anything but DNS.
kubectl -n lab-07-netpol get netpol -o json | jq -r '
  .items[] | select(.spec.policyTypes[]? == "Egress")
  | select(.spec.podSelector.matchLabels["netpol.kubernetes-labs.io/tier"] == "database")
  | .metadata.name'
# expected: (empty)
```

## Cleanup

```bash
kubectl -n lab-07-netpol delete pod netshoot-frontend --ignore-not-found
kubectl delete -f 00-namespace.yaml --ignore-not-found

kubectl get ns lab-07-netpol lab-07-netpol-monitoring
# expected: Error from server (NotFound) for both

# Optional: if you built a dedicated Calico cluster for this lab and want the
# standard kindnet one back.
# kind delete cluster --name k8s-labs && make cluster-up && make image
```

## What you learned

- NetworkPolicy is implemented by the **CNI**, not by Kubernetes. kindnet accepts the objects and enforces nothing — always verify enforcement before trusting a policy.
- A Pod is unrestricted until some policy's `podSelector` matches it; once selected for a direction, that direction becomes default-deny and only the union of matching rules is permitted.
- Policies are additive and whitelist-only. No deny rules, no ordering, no priorities. You cannot subtract access by adding a policy — you remove the policy that granted it.
- Connectivity requires **both** an egress rule at the source and an ingress rule at the destination. Deleting either half produces an identical timeout, from opposite ends.
- Default-deny-egress breaks DNS. Ship `50-allow-dns.yaml` in the same commit as `40-default-deny.yaml`, and allow **both UDP and TCP** on port 53.
- Policy `ports` refer to the destination **Pod's** port, because kube-proxy has already DNAT'd away the Service port.
- Nesting `namespaceSelector` and `podSelector` in one list item ANDs them; splitting them into two items ORs them, which is dramatically broader.
- `ipBlock` + `except` grants everything in a CIDR minus the exceptions; it protects only because a default-deny already covers the rest. Excluding `169.254.0.0/16` blocks the metadata service; excluding RFC1918 forces east-west traffic through explicit rules.
- Kubelet probes come from the node and are not subject to NetworkPolicy — if probes fail after a policy change, suspect DNS, not ingress.
- `kubectl debug --target=<container>` shares the target's network namespace and is the only faithful way to test connectivity as a given workload.

## Going further / production notes

- **Choosing a CNI on EKS.** The default `amazon-vpc-cni-k8s` gives every Pod a real VPC IP, which is excellent for VPC-native routing and observability — but for years it enforced no NetworkPolicy at all. Since VPC CNI v1.14 (EKS 1.25+) it ships a built-in eBPF NetworkPolicy agent: enable with `--set enableNetworkPolicy=true` on the add-on, or `ENABLE_NETWORK_POLICY=true` on `aws-node`. It covers the core `networking.k8s.io/v1` API and nothing beyond it. Calico in policy-only mode (VPC CNI for IPAM, Calico for policy) adds `GlobalNetworkPolicy`, rule ordering, and explicit deny actions. Cilium adds `toFQDNs`, L7-aware rules (HTTP method/path, Kafka topics), `CiliumClusterwideNetworkPolicy`, and Hubble flow visibility. My default recommendation for a serious EKS platform: VPC CNI for IPAM plus Cilium in chaining mode, or Cilium outright if you can accept losing VPC-native Pod IPs.
- **Security groups for Pods** is the AWS-native complement, not a replacement. A `SecurityGroupPolicy` (from the `vpc-resource-controller`) attaches an EC2 security group to Pods matching a selector via a branch ENI, which lets you use security-group references to gate access to RDS, ElastiCache and other VPC resources — something NetworkPolicy cannot express at all, since it only knows CIDRs. Limitations worth knowing: it needs Nitro instances, it consumes branch ENIs (a hard per-instance limit), and it does not work with Fargate. Use NetworkPolicy for Pod-to-Pod and security groups for Pod-to-AWS-resource.
- **Why whitelist-only is a feature.** With no deny rules and no ordering, a policy set has no evaluation-order bugs and no shadowing — properties that make traditional firewall rulesets so hard to audit. The cost is that you cannot express "allow everything except X" for Pod selectors (only for `ipBlock`), and that you must reason about the union of all matching policies rather than reading one object. Budget for tooling: `np-viewer`, `netpol-analyzer` (dry-run connectivity diffs in CI), Cilium's `cilium policy trace`, or Calico's flow logs into an audit pipeline.
- **AdminNetworkPolicy** (`policy.networking.k8s.io/v1alpha1`, from SIG-Network) is the upstream answer to the missing pieces: cluster-scoped, ordered by `priority`, and it *does* have `Deny` and `Pass` actions. `AdminNetworkPolicy` is evaluated before namespaced policies (so a platform team can enforce a non-overridable baseline) and `BaselineAdminNetworkPolicy` after (so it acts as a cluster-wide default). Supported by Cilium and Calico today. This is where cluster-wide default-deny is heading; adopt it when your CNI supports it in a stable channel.
- **IMDS defence in depth on EKS.** Set `httpTokens: required` and `httpPutResponseHopLimit: 1` in the launch template (or `metadataOptions` on a Karpenter `EC2NodeClass`) — the hop limit alone stops the vast majority of container-to-IMDS access because the packet TTL expires crossing the veth pair. Layer the NetworkPolicy on top for the cases hop limit misses (host-network Pods), and give workloads IRSA or Pod Identity so they have no legitimate reason to want IMDS. Then alert on any IMDS access from a Pod CIDR.
- **Rollout strategy for an existing cluster.** Never apply default-deny to a live namespace as your first move. Run in observe mode first: Cilium's Hubble (`hubble observe --namespace X`) or Calico flow logs for a week, generate candidate policies from observed flows (`hubble` + `cilium-cli`, `np-guard`, or Inspektor Gadget's `advise network-policy`), review them, apply the allow rules, confirm zero drops for another week, and only then add the default-deny. Namespace by namespace, least critical first.
- **Testing policies in CI.** Treat them as code: `netpol-analyzer` can diff the connectivity graph between two commits and fail a PR that opens an unexpected path, which catches "someone added an allow-all rule" far more reliably than review. Combine with Kyverno or a `ValidatingAdmissionPolicy` that rejects any NetworkPolicy containing a bare `- {}` rule, and a policy requiring every namespace to carry a default-deny.
- **Operational gotchas that will bite you.** Policies are namespaced, so a new namespace starts wide open — enforce a default-deny at namespace creation via Kyverno's `generate` rule. `hostNetwork: true` Pods bypass Pod-level policy entirely because they share the node's network namespace. Traffic from a LoadBalancer in `externalTrafficPolicy: Cluster` mode arrives SNAT'd from a node IP, so an ingress rule selecting client Pods will not match it — use `Local` or an `ipBlock` covering the node CIDR. And node-local DNS caches (NodeLocal DNSCache) change the DNS destination from a CoreDNS Pod IP to a link-local address, which your carefully written DNS policy will then block.
