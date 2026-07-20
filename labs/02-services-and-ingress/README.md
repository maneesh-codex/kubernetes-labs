# Lab 02 — Services and Ingress

Pod IPs are ephemeral. They change on every restart, every rollout, every node replacement — which makes them useless as an address anyone can hard-code. A Service is the stable indirection that fixes this, and understanding *how* it is stable matters, because a ClusterIP is not a process listening anywhere: it is a virtual IP that kube-proxy translates into pod IPs via iptables rules on every node. An Ingress sits one layer higher, terminating real HTTP at the cluster edge and fanning requests out to Services by host and path. This lab builds the full chain — two Deployments, three Service types, and an nginx Ingress doing path-based routing — and then takes it apart so you can see EndpointSlices update in real time as pods go ready and unready.

## Objectives

- Distinguish ClusterIP, NodePort, and headless Services by what each one actually programs in the cluster.
- Trace the `Service` → `EndpointSlice` → `kube-proxy` → pod chain and watch it react to a readiness change.
- Route by path with a single `networking.k8s.io/v1` Ingress and understand nginx's longest-prefix matching.
- Apply nginx annotations correctly, including why `rewrite-target` forces you into a second Ingress object.
- Explain why headless Services exist and when a ClusterIP actively hurts you (gRPC, long-lived HTTP/2).
- Map all of this onto the AWS Load Balancer Controller, ALBs, and NLBs on EKS.

## Prerequisites

- A running kind cluster named `k8s-labs`, created with `make cluster-up`. The kind config includes `extraPortMappings` for host ports 80 and 443 onto the control-plane node, and a `node-labels: ingress-ready=true` label — both are required for the ingress-nginx kind provider manifest to work.
- `make cluster-up` also installs ingress-nginx. If you are working against a cluster where it is missing, install it manually:

  ```bash
  kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.11.2/deploy/static/provider/kind/deploy.yaml
  kubectl wait --namespace ingress-nginx \
    --for=condition=ready pod \
    --selector=app.kubernetes.io/component=controller \
    --timeout=120s
  ```

- `curl` and `kubectl` v1.29+ on your `PATH`.
- No other process bound to host ports 80 or 30080.

## Manifests in this lab

| File | What it does |
| --- | --- |
| `00-namespace.yaml` | Creates namespace `lab-02-networking` under the `restricted` Pod Security Standard. |
| `10-deployment-web.yaml` | The `web` tier, 2 replicas, greeting identifies it as the `/` backend. |
| `11-deployment-api.yaml` | The `api` tier, 3 replicas, greeting identifies it as the `/api` backend. |
| `20-service-clusterip.yaml` | Two ClusterIP Services (`web`, `api`) — the Ingress backends. |
| `21-service-nodeport.yaml` | `web-nodeport` on fixed port 30080, showing NodePort as a superset of ClusterIP. |
| `22-service-headless.yaml` | `api-headless` with `clusterIP: None` — DNS returns pod IPs, no VIP, no kube-proxy rules. |
| `30-ingress.yaml` | `demo-fanout` (`/` → web, `/api` → api) plus `demo-legacy-rewrite` demonstrating `rewrite-target`. |

## Walkthrough

### 1. Deploy both tiers and all three Services

```bash
kubectl apply -f 00-namespace.yaml
kubectl apply -f . -n lab-02-networking
kubectl rollout status deployment/web -n lab-02-networking --timeout=120s
kubectl rollout status deployment/api -n lab-02-networking --timeout=120s
kubectl get svc,ingress -n lab-02-networking
```

Look at the `CLUSTER-IP` column: `web` and `api` have VIPs from the service CIDR, `web-nodeport` has both a VIP and a `PORT(S)` entry of `80:30080/TCP`, and `api-headless` shows `None`. That `None` is the entire difference — no VIP means no kube-proxy rules and no kernel-level load balancing.

### 2. Inspect the EndpointSlices behind each Service

```bash
kubectl get endpointslices -n lab-02-networking
kubectl get endpointslices -n lab-02-networking \
  -l kubernetes.io/service-name=api \
  -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}{"  ready="}{.conditions.ready}{"  node="}{.nodeName}{"\n"}{end}'
```

The endpoints controller watches pods matching the Service selector and writes their IPs into EndpointSlices. EndpointSlices replaced the older `Endpoints` object precisely because a single Endpoints resource for a 5,000-pod Service had to be rewritten in full on every pod change, and every kube-proxy in the cluster re-read it. Slices cap at 100 endpoints each, so a change rewrites one small object.

### 3. Watch readiness drive the data path

Open a watch in one terminal:

```bash
kubectl get endpointslices -n lab-02-networking -l kubernetes.io/service-name=api -w
```

In another terminal, make one api pod report itself unready:

```bash
POD=$(kubectl get pod -n lab-02-networking -l app.kubernetes.io/name=api -o jsonpath='{.items[0].metadata.name}')
kubectl port-forward -n lab-02-networking "pod/$POD" 8081:8080 >/dev/null 2>&1 &
sleep 2
curl -s -X POST http://localhost:8081/toggle-ready
```

Within one readiness period the pod's `conditions.ready` flips to `false` and kube-proxy removes it from the iptables chain — no traffic reaches it, but the pod is *not* restarted. That is the liveness/readiness distinction made concrete: readiness gates traffic, liveness gates restarts. Toggle it back and kill the port-forward:

```bash
curl -s -X POST http://localhost:8081/toggle-ready
kill %1
```

### 4. Reach the app through the NodePort

```bash
curl -s http://localhost:30080/ | head -3
```

This works because the kind config maps the host's port 30080 to the node's. On a real cluster you would need a node's IP and a security group that permits the port — which is a large part of why NodePort is not an edge strategy.

### 5. Resolve the headless Service from inside the cluster

```bash
kubectl run dnsutils -n lab-02-networking --rm -it --restart=Never \
  --image=registry.k8s.io/e2e-test-images/jessie-dnsutils:1.7 \
  --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":65532,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"dnsutils","image":"registry.k8s.io/e2e-test-images/jessie-dnsutils:1.7","command":["sh","-c","nslookup api.lab-02-networking.svc.cluster.local; echo ---; nslookup api-headless.lab-02-networking.svc.cluster.local"],"securityContext":{"allowPrivilegeEscalation":false,"readOnlyRootFilesystem":true,"capabilities":{"drop":["ALL"]}}}]}}'
```

`api` resolves to exactly one address — the ClusterIP. `api-headless` resolves to three addresses — one per ready pod. A client that wants to do its own load balancing, or a gRPC client that would otherwise pin its single HTTP/2 connection to whichever pod the VIP first chose, uses the second form.

### 6. Route through the Ingress

```bash
curl -s -H "Host: demo.localtest.me" http://localhost/ | head -2
curl -s -H "Host: demo.localtest.me" http://localhost/api/info
```

The first lands on the `web` tier, the second on `api`, from the same VIP-less entry point on port 80. Note that both requests hit the *ingress controller's* Service, and the controller then talks directly to pod IPs — it does not go through the backend ClusterIP at all. That is why an Ingress can do sticky sessions and weighted canaries that a ClusterIP cannot.

### 7. Exercise the rewrite

```bash
curl -s -H "Host: demo.localtest.me" http://localhost/legacy/api/info
```

The backend sees `/api/info`; the client asked for `/legacy/api/info`. Remove `use-regex: "true"` from `demo-legacy-rewrite`, re-apply, and the same request 404s — the literal string `/$2` gets sent upstream. This is the single most common nginx Ingress misconfiguration.

### 8. Read the generated nginx config

```bash
CTRL=$(kubectl get pod -n ingress-nginx -l app.kubernetes.io/component=controller \
  -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n ingress-nginx "$CTRL" -- cat /etc/nginx/nginx.conf | grep -A4 'location /api'
```

The controller is a control loop that watches Ingress objects and regenerates `nginx.conf`. Seeing your `location` blocks appear here — ordered by descending path length, not by the order in your YAML — makes the longest-prefix rule concrete rather than folklore.

## Verification

```bash
curl -s -o /dev/null -w '%{http_code}\n' -H "Host: demo.localtest.me" http://localhost/
```

Expected output:

```text
200
```

```bash
curl -s http://demo.localtest.me/api/info | grep -o '"message":"[^"]*"'
```

Expected output:

```text
"message":"API tier - served via the /api path of the Ingress"
```

```bash
curl -s -H "Host: demo.localtest.me" http://localhost/ | grep -o 'WEB tier[^"]*'
```

Expected output:

```text
WEB tier - served via the / path of the Ingress
```

```bash
kubectl get svc api-headless -n lab-02-networking -o jsonpath='{.spec.clusterIP}{"\n"}'
```

Expected output:

```text
None
```

```bash
kubectl get endpointslices -n lab-02-networking -l kubernetes.io/service-name=api \
  -o jsonpath='{range .items[*].endpoints[*]}{.conditions.ready}{"\n"}{end}' | sort | uniq -c
```

Expected output: `3 true`.

```bash
kubectl get ingress -n lab-02-networking -o custom-columns=NAME:.metadata.name,CLASS:.spec.ingressClassName,HOSTS:.spec.rules[*].host
```

Expected output:

```text
NAME                  CLASS   HOSTS
demo-fanout           nginx   demo.localtest.me
demo-legacy-rewrite   nginx   demo.localtest.me
```

## Cleanup

```bash
kubectl delete namespace lab-02-networking --wait=true
```

This leaves the `ingress-nginx` namespace alone, since later labs reuse the controller. To remove that too:

```bash
kubectl delete -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.11.2/deploy/static/provider/kind/deploy.yaml --ignore-not-found
```

## What you learned

- A ClusterIP is a virtual IP with no process behind it; kube-proxy DNATs it to a ready pod IP using iptables/IPVS rules present on every node.
- The endpoints controller translates "pods matching this selector that are Ready" into EndpointSlices, and kube-proxy turns those into kernel rules. Readiness changes propagate through that chain in seconds without restarting anything.
- EndpointSlices exist because a monolithic Endpoints object does not scale past a few hundred pods.
- NodePort is ClusterIP plus a port on every node — fine for local dev, poor as a production edge.
- Headless (`clusterIP: None`) returns pod IPs from DNS and moves load balancing to the client. It is the right answer for gRPC and for peer discovery, and the wrong answer for ordinary HTTP.
- `pathType: Prefix` matches on path segments; nginx orders `location` blocks by descending specificity, so rule order in YAML is irrelevant.
- nginx annotations are scoped to the whole Ingress object, so `rewrite-target` needs its own Ingress, and it needs `use-regex: "true"` to interpolate capture groups.
- An Ingress controller proxies straight to pod IPs, bypassing the backend Service's ClusterIP entirely.

## Going further / production notes

- **ALB vs NLB on EKS.** The AWS Load Balancer Controller gives you two paths. `kind: Ingress` with `ingressClassName: alb` and `alb.ingress.kubernetes.io/scheme: internet-facing`, `alb.ingress.kubernetes.io/target-type: ip`, and `alb.ingress.kubernetes.io/listen-ports: '[{"HTTP":80},{"HTTPS":443}]'` provisions a real ALB doing L7 routing. `kind: Service` with `type: LoadBalancer` and `service.beta.kubernetes.io/aws-load-balancer-type: external` plus `...-nlb-target-type: ip` provisions an NLB for L4. Use the ALB when you want path routing, WAF, and OIDC auth at the edge; use the NLB for raw TCP, gRPC passthrough, or static IPs.
- **`target-type: ip` is not optional in practice.** With `instance` mode traffic goes to a NodePort and then hops again through kube-proxy, which costs you a hop and the client source IP. With `ip` mode the ALB registers pod IPs directly in the target group — which requires the VPC CNI (it works because EKS pods get real VPC IPs) and makes pod readiness gates meaningful.
- **Pod readiness gates.** Install the controller's webhook and label the namespace with `elbv2.k8s.aws/pod-readiness-gate-inject: enabled`. Pods then stay unready until the ALB target group reports them healthy, which closes the race where a rolling update completes before the load balancer has actually registered the new pods.
- **`externalTrafficPolicy: Local`.** Preserves the client source IP and removes the second hop, but a node with no ready pod stops answering health checks. Pair it with topology spread constraints so every node in the target group actually hosts a pod.
- **TLS.** On EKS, terminate at the ALB with an ACM certificate (`alb.ingress.kubernetes.io/certificate-arn`) rather than managing cert-manager Secrets, unless you need end-to-end encryption into the pod. On kind, cert-manager with a self-signed ClusterIssuer is the local equivalent.
- **Ingress is in maintenance mode.** The Gateway API (`gateway.networking.k8s.io`) is the successor: it splits `GatewayClass`/`Gateway`/`HTTPRoute` so platform and application teams own separate objects, and it standardises header matching, traffic splitting, and rewrites that are annotation-only in Ingress. Both the AWS Load Balancer Controller and ingress-nginx ship Gateway API support — new platforms should start there.
- **One controller per class, not per cluster.** Running separate internal and internet-facing ingress controllers with distinct `IngressClass` names is the standard way to keep admin endpoints off the public LB. Set `ingressClassName` explicitly on every Ingress; relying on the default-class annotation is how internal services end up on the internet.
