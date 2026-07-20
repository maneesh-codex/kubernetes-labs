# demo-app

The workload every lab in this repository deploys. It exists to be *observable
and controllable* — each endpoint maps onto a Kubernetes concept the labs teach.

It is written in Go using **only the standard library**. No `go.sum`, no vendor
directory, no network access needed at build time. That constraint is
deliberate: it lets the image build on a `scratch` base, which in turn is why
every manifest in this repo can set `readOnlyRootFilesystem: true` and
`runAsNonRoot: true` without workarounds.

## Endpoints

| Method | Path            | Purpose                                                                 |
| ------ | --------------- | ----------------------------------------------------------------------- |
| `GET`  | `/`             | Plain-text index echoing pod name, namespace, node, uptime and readiness |
| `GET`  | `/healthz`      | **Liveness** probe. Returns 200 unless the process is unrecoverable      |
| `GET`  | `/readyz`       | **Readiness** probe. Returns 503 when readiness has been toggled off     |
| `GET`  | `/metrics`      | Prometheus text exposition format (v0.0.4)                              |
| `GET`  | `/api/info`     | JSON pod identity + config, including a redacted API-key fingerprint     |
| `POST` | `/toggle-ready` | Flips readiness — use it to watch a Service drop the pod from Endpoints  |
| `GET`  | `/burn?seconds=N` | Burns CPU for N seconds (capped at 60) to drive the HPA in lab 06     |

### Why liveness and readiness are separate

`/healthz` deliberately *never* reports failure for downstream problems. A
liveness probe that fails when a database is unreachable converts a dependency
blip into a cluster-wide crash loop, which makes the outage worse. `/readyz` is
the endpoint allowed to flap: it gates traffic, not restarts. Lab 11 has a
scenario built on getting this wrong.

## Metrics

| Metric | Type | Labels |
| --- | --- | --- |
| `demo_app_build_info` | gauge | `version`, `goversion` |
| `demo_app_uptime_seconds` | gauge | — |
| `demo_app_ready` | gauge | — (1 = ready, 0 = not) |
| `demo_app_cpu_burn_seconds_total` | counter | — |
| `demo_app_goroutines` | gauge | — |
| `demo_app_http_requests_total` | counter | `method`, `path`, `status` |
| `demo_app_http_request_duration_seconds` | histogram | `method`, `path`, `status`, `le` |

Lab 09's `ServiceMonitor`, `PrometheusRule` alerts and Grafana dashboard are all
built against these exact names.

> The registry is hand-rolled rather than using `prometheus/client_golang`.
> That is the *wrong* choice for production — it is done here purely to keep the
> module dependency-free. Reach for the official client in real services.

## Configuration

All configuration is via environment variables.

| Variable | Default | Notes |
| --- | --- | --- |
| `PORT` | `8080` | Listen port |
| `GREETING` | `Hello from the kubernetes-labs demo app!` | Set from a ConfigMap in lab 03 |
| `API_KEY` | *(unset)* | Set from a Secret in lab 03. Never logged; only a fingerprint is exposed |
| `POD_NAME` | `unknown` | Downward API: `metadata.name` |
| `POD_NAMESPACE` | `default` | Downward API: `metadata.namespace` |
| `NODE_NAME` | `unknown` | Downward API: `spec.nodeName` |

## Graceful shutdown

On `SIGTERM` the app:

1. Immediately flips `/readyz` to 503, so the endpoints controller removes the
   pod from Service rotation.
2. Sleeps 5 seconds — longer than the 5s readiness `periodSeconds` used by the
   manifests here — giving kube-proxy and any ingress controller time to notice.
3. Calls `http.Server.Shutdown` with a 20s deadline to drain in-flight requests.

This is the shape you want in production. Skipping step 1 and 2 is the usual
cause of 502s during rolling deploys: the pod stops accepting connections before
load balancers have stopped sending them.

Set `terminationGracePeriodSeconds` to comfortably exceed 5s + your longest
request. The manifests in this repo use the 30s default.

## Building

```bash
# From the repository root
make build-image           # docker build -t ghcr.io/maneeshm/k8s-labs-demo:1.0.0 app/
make load-image            # kind load docker-image ... --name k8s-labs
make image                 # both

# Or directly
docker build -t ghcr.io/maneeshm/k8s-labs-demo:1.0.0 app/
```

The Dockerfile is multi-stage: `golang:1.22-alpine` compiles a static binary
(`CGO_ENABLED=0`), and the runtime stage is `scratch` plus the CA bundle. The
build asserts the binary really is static — a dynamically linked binary on
`scratch` fails at runtime with a maddeningly unhelpful
`exec /demo-app: no such file or directory`.

Resulting image: roughly 6 MB, no shell, no package manager, no libc. Note that
"no shell" means `kubectl exec -it ... -- sh` will not work — use
`kubectl debug` with an ephemeral container instead. Lab 11 covers this.

## Running locally

```bash
make run-local             # go run, on :8080

curl localhost:8080/
curl localhost:8080/healthz
curl localhost:8080/metrics
curl -X POST localhost:8080/toggle-ready
curl "localhost:8080/burn?seconds=10"
```

## Layout

```
app/
├── Dockerfile        multi-stage build → scratch
├── .dockerignore     keeps the build context to three files
├── go.mod            module definition; zero dependencies
├── main.go           the entire service
└── README.md         this file
```
