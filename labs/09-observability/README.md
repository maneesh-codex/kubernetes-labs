# Lab 09 — Observability with Prometheus and Grafana

A Deployment that is `Running` tells you almost nothing about whether the
service works. Observability is the difference between "three pods exist" and
"p99 latency is 40ms, error ratio is 0.1%, and the alert that would have paged
me is quiet for a reason I can verify." This lab installs kube-prometheus-stack,
wires the demo app into it with a ServiceMonitor, writes alerting rules against
the app's *actual* metric names, and ships a Grafana dashboard as a ConfigMap so
it lives in git rather than in a database nobody backs up. Most of the lab's
value is in the failure modes: the ServiceMonitor that is silently ignored, the
Service port that must be named, and the histogram query whose operator order
changes the answer.

## Objectives

- Install kube-prometheus-stack on kind with resource settings that actually fit.
- Understand `serviceMonitorSelectorNilUsesHelmValues` — the single most common reason a ServiceMonitor is ignored.
- Learn why a Service port **name** is load-bearing for metrics scraping.
- Write a ServiceMonitor with a correct `selector`, `namespaceSelector` and named endpoint.
- Write PrometheusRule alerts on real metrics: readiness, error *ratio*, p99 latency, and target absence.
- Use recording rules to make expensive expressions cheap and alerts readable.
- Provision a Grafana dashboard from a labelled ConfigMap, with no UI clicking.
- Drive load and readiness changes to make alerts fire on demand.

## Prerequisites

- A running kind cluster (see `kind/` at the repo root).
- `helm` and `kubectl` on your PATH.
- The demo image loaded into the cluster:
  `kind load docker-image ghcr.io/maneeshm/k8s-labs-demo:1.0.0 --name kubernetes-labs`
- At least ~4 GiB of memory available to Docker. kube-prometheus-stack is not small.
- Lab 08 completed is helpful but not required; this lab uses plain manifests.

## Manifests in this lab

| File | Kind | Purpose |
| --- | --- | --- |
| `00-namespace.yaml` | Namespace | `lab-09-observability`, enforcing the restricted Pod Security Standard. |
| `values-kube-prometheus-stack.yaml` | Helm values | kind-tuned stack: short retention, no PVCs, disabled control-plane scrapers, and the selector flags explained inline. |
| `10-deployment.yaml` | Deployment | Three demo-app replicas with a **named** `http` container port. |
| `20-service.yaml` | Service | ClusterIP with a **named** `http` port — the link the ServiceMonitor matches on. |
| `30-servicemonitor.yaml` | ServiceMonitor | Scrapes `/metrics` every 15s; drops `go_*` and `promhttp_*` series to control cardinality. |
| `40-prometheusrule.yaml` | PrometheusRule | 3 recording rules and 5 alerts, including an `absent()` target-missing alert. |
| `50-grafana-dashboard.yaml` | ConfigMap | 11-panel dashboard, discovered via the `grafana_dashboard: "1"` label. |

## Walkthrough

1. **Install kube-prometheus-stack.** This brings the Prometheus Operator, a
   Prometheus, Alertmanager, Grafana, node-exporter and kube-state-metrics.

   ```bash
   helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
   helm repo update

   cd labs/09-observability
   helm upgrade --install kube-prometheus-stack \
     prometheus-community/kube-prometheus-stack \
     --namespace monitoring --create-namespace \
     -f values-kube-prometheus-stack.yaml \
     --wait --timeout 10m
   ```

   The release name is not cosmetic. The chart stamps `release: kube-prometheus-stack`
   onto its objects and, by default, configures Prometheus to select only
   ServiceMonitors carrying that label. Install under a different name and the
   labels in `30-servicemonitor.yaml` stop matching.

   ```bash
   kubectl get pods -n monitoring
   kubectl get crd | grep monitoring.coreos.com
   ```

2. **Understand the flag before you need it.** In `values-kube-prometheus-stack.yaml`:

   ```yaml
   prometheus:
     prometheusSpec:
       serviceMonitorSelectorNilUsesHelmValues: false
   ```

   The chart default is `true`, which means "if the user did not set
   `serviceMonitorSelector` explicitly, derive one from the Helm release",
   producing `serviceMonitorSelector: {matchLabels: {release: kube-prometheus-stack}}`.

   The failure this causes is nasty specifically because it is *quiet*. Your
   ServiceMonitor is a valid object. `kubectl get servicemonitor` lists it. The
   operator logs no error. Prometheus reloads happily. The target simply never
   appears under Status > Targets, and there is no message anywhere to search
   for. Setting the flag to `false` makes the selector nil, and a nil selector
   in the Prometheus Operator means *match everything I am permitted to watch*.

   The same trap exists independently for PodMonitors, PrometheusRules, Probes
   and scrape configs — fixing only the ServiceMonitor one and then wondering
   why the alerts never loaded is the usual follow-up. All five are set here.

   **Which is right for production?** The label, not `false`. A nil selector
   lets any team add scrape load to a shared Prometheus with no review, and one
   high-cardinality exporter can then take the instance down. This lab sets
   `false` *and* carries the label, so the walkthrough works either way — flip
   the flag to `true`, re-run `helm upgrade`, and confirm the target is still
   discovered because of the label.

3. **Deploy the workload.**

   ```bash
   kubectl apply -f 00-namespace.yaml
   kubectl apply -f 10-deployment.yaml
   kubectl apply -f 20-service.yaml
   kubectl rollout status deployment/demo-metrics -n lab-09-observability
   ```

   Look at the Service and note the port has a `name`:

   ```bash
   kubectl get svc demo-metrics -n lab-09-observability -o yaml | grep -A5 ports:
   ```

   A ServiceMonitor's `endpoints[].port` takes a port **name**, never a number.
   Kubernetes lets you omit `name` when a Service has a single port, and
   everything else keeps working — DNS resolves, curl succeeds, Ingress routes.
   Only Prometheus breaks, and it breaks silently. When a target is missing,
   check this second (after the selector flag above).

4. **Confirm the app is actually exporting metrics** before blaming Prometheus.
   This step separates "the app is broken" from "discovery is broken", which
   are very different investigations:

   ```bash
   kubectl port-forward -n lab-09-observability svc/demo-metrics 8080:8080 &
   curl -s localhost:8080/metrics | grep -E '^demo_app_(ready|goroutines|build_info)'
   kill %1
   ```

5. **Create the ServiceMonitor and rules.**

   ```bash
   kubectl apply -f 30-servicemonitor.yaml
   kubectl apply -f 40-prometheusrule.yaml
   kubectl get servicemonitor,prometheusrule -n lab-09-observability
   ```

6. **Port-forward Prometheus and verify the target.**

   ```bash
   kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090
   ```

   Open <http://localhost:9090> and go to **Status > Targets**. Look for
   `serviceMonitor/lab-09-observability/demo-metrics/0` with three endpoints,
   all UP. **Status > Service Discovery** shows the discovered-but-dropped
   targets, which is where to look when the count is wrong rather than zero.

   If there are zero targets, work the list in order: the selector flag (step
   2), the Service port name (step 3), then whether the ServiceMonitor's
   `spec.selector.matchLabels` matches the Service's `metadata.labels` — not the
   pod labels, and not the Service's own `spec.selector`. Confusing those is the
   third most common mistake here.

7. **Run real queries.** In the Prometheus expression browser:

   ```promql
   # Are the pods ready? Expect three series, all 1.
   demo_app_ready{namespace="lab-09-observability"}

   # Request rate by path and status
   sum by (path, status) (rate(demo_app_http_requests_total[5m]))

   # p99 latency. Order matters: rate() -> sum by (le) -> histogram_quantile.
   histogram_quantile(0.99, sum by (le) (
     rate(demo_app_http_request_duration_seconds_bucket[5m])))

   # 5xx error ratio
   sum(rate(demo_app_http_requests_total{status=~"5.."}[5m]))
     / sum(rate(demo_app_http_requests_total[5m]))

   # The recording rules from 40-prometheusrule.yaml
   demo_app:http_requests:rate5m
   demo_app:http_request_duration_seconds:p99

   # Info-metric join: break any series down by app version
   demo_app_goroutines * on(pod) group_left(version) demo_app_build_info
   ```

   On the p99 query, try it the wrong way round to see why the order matters:

   ```promql
   avg(histogram_quantile(0.99, rate(demo_app_http_request_duration_seconds_bucket[5m])))
   ```

   That computes a p99 per pod and then averages the three results. The average
   of three p99s is not the p99 of the fleet — it systematically understates the
   tail, which is precisely the thing you were trying to measure.

8. **Drive load and make the graphs move.** In a second terminal:

   ```bash
   kubectl port-forward -n lab-09-observability svc/demo-metrics 8080:8080 &

   # Steady traffic across several paths
   for i in $(seq 1 2000); do
     curl -s -o /dev/null localhost:8080/
     curl -s -o /dev/null localhost:8080/api/info
     curl -s -o /dev/null localhost:8080/nope   # 404s, for the status breakdown
   done

   # Synthetic CPU load, which also inflates request duration
   curl -s "localhost:8080/burn?seconds=20"
   ```

9. **Make an alert fire on purpose.** `DemoAppNotReady` is the easiest:

   ```bash
   curl -XPOST localhost:8080/toggle-ready
   curl -s localhost:8080/metrics | grep '^demo_app_ready'   # now 0
   ```

   Watch it move through its lifecycle in Prometheus under **Alerts**: the rule
   goes `Pending` immediately and becomes `Firing` only after the `for: 2m`
   window elapses. That window is what separates an alert from a nuisance —
   a single failed scrape or a pod restarting during a normal rollout resolves
   well inside two minutes and should never page anyone.

   Note the pod also leaves the Service endpoints, since `/readyz` now fails:

   ```bash
   kubectl get endpointslices -n lab-09-observability
   ```

   Toggle it back, and confirm the alert resolves:

   ```bash
   curl -XPOST localhost:8080/toggle-ready
   ```

10. **Open Grafana and load the dashboard.**

    ```bash
    kubectl apply -f 50-grafana-dashboard.yaml
    kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
    ```

    Log in at <http://localhost:3000> as `admin` / `prom-operator` (set in the
    values file; anonymous viewer access is also enabled for convenience). The
    dashboard appears within about a minute under the **kubernetes-labs**
    folder as *Lab 09 — Demo App Golden Signals*.

    Nobody clicked anything to make that happen. The Grafana sidecar watches
    every namespace for ConfigMaps labelled `grafana_dashboard: "1"` and writes
    their contents into Grafana's provisioning directory. This is why dashboards
    belong in git: one built by clicking around the UI lives only in Grafana's
    database and vanishes with the pod, while this one is rebuilt from source on
    every restart and shows up in code review.

    Watch the sidecar notice it:

    ```bash
    kubectl logs -n monitoring -l app.kubernetes.io/name=grafana -c grafana-sc-dashboard --tail=20
    ```

11. **Check Alertmanager** received the firing alert:

    ```bash
    kubectl port-forward -n monitoring svc/kube-prometheus-stack-alertmanager 9093:9093
    ```

    <http://localhost:9093> shows firing alerts and lets you create a silence.
    No receivers are configured, so nothing is delivered anywhere — in
    production this is where SNS, PagerDuty or Slack routing would live, keyed
    off the `severity` and `team` labels the rules set.

## Verification

```bash
# Stack is healthy
kubectl get pods -n monitoring
helm list -n monitoring

# Workload is up with three endpoints
kubectl get deploy,svc,endpointslices -n lab-09-observability

# The CRD objects exist
kubectl get servicemonitor,prometheusrule -n lab-09-observability

# The Service port is NAMED (this must print "http")
kubectl get svc demo-metrics -n lab-09-observability \
  -o jsonpath='{.spec.ports[0].name}'; echo

# Prometheus is actually scraping: expect 3 healthy targets
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090 &
sleep 3
curl -s 'localhost:9090/api/v1/targets?state=active' \
  | jq -r '.data.activeTargets[]
           | select(.labels.job=="demo-metrics")
           | "\(.labels.pod) \(.health)"'

# The rules loaded
curl -s localhost:9090/api/v1/rules \
  | jq -r '.data.groups[] | select(.name|startswith("demo-app")) | .name'

# Metrics are queryable
curl -s --data-urlencode 'query=sum(demo_app_ready)' \
  localhost:9090/api/v1/query | jq '.data.result'
kill %1

# The dashboard ConfigMap holds valid JSON
kubectl get cm demo-app-dashboard -n lab-09-observability \
  -o jsonpath='{.data.demo-app\.json}' | jq -e '.title, (.panels|length)'
```

## Cleanup

```bash
kubectl delete -f 50-grafana-dashboard.yaml -f 40-prometheusrule.yaml \
               -f 30-servicemonitor.yaml -f 20-service.yaml -f 10-deployment.yaml
kubectl delete namespace lab-09-observability

helm uninstall kube-prometheus-stack --namespace monitoring
kubectl delete namespace monitoring

# Helm does NOT remove CRDs it installed, by design: deleting a CRD deletes
# every object of that kind cluster-wide, which is not something an uninstall
# should ever do implicitly. Remove them explicitly only if you are done.
kubectl get crd -o name | grep monitoring.coreos.com | xargs -r kubectl delete
```

## What you learned

- `serviceMonitorSelectorNilUsesHelmValues` silently governs whether your ServiceMonitor is read at all — and the same flag exists for PodMonitors, rules, probes and scrape configs.
- ServiceMonitors select Service **port names**, and select Services by `metadata.labels` — not pod labels, not `spec.selector`.
- Alert on error *ratios*, not counts: a count threshold is wrong at every traffic level except the one you tuned it for.
- Guard ratio alerts with a minimum-traffic clause, or low-traffic periods page you over three requests.
- `for:` duration is what distinguishes an alert from a nuisance.
- `absent()` alerts catch the failure mode where every other alert goes quiet because the data stopped arriving.
- In `histogram_quantile`, `rate()` then `sum by (le)` then the quantile — averaging per-pod quantiles understates the tail.
- Recording rules make dashboards cheap and alert expressions readable.
- `metricRelabelings` with a `drop` action is the cheapest cardinality control available.
- Dashboards belong in git as labelled ConfigMaps, not in Grafana's database.

## Going further — production notes

**Amazon Managed Prometheus (AMP).** Running Prometheus yourself means owning
its storage, retention, upgrades and the 3am page when the WAL replay outlasts
the liveness probe. AMP removes that, and the integration is a `remoteWrite`
block with SigV4 — the commented example in `values-kube-prometheus-stack.yaml`
is the exact shape. The Prometheus ServiceAccount needs an IRSA annotation for a
role with `aps:RemoteWrite`. The local Prometheus keeps a short retention window
as a buffer and ships everything onward; queries and Grafana point at AMP.
Because AMP bills per sample ingested and per query processed,
`writeRelabelConfigs` with a `keep` on the metric names you actually query is a
direct and substantial cost lever — shipping every `go_*` series from every pod
in the fleet is the usual reason the first AMP bill is a surprise.

**Amazon Managed Grafana (AMG).** Same trade for the visualisation half, with
the added benefit of IAM Identity Center SSO, so there is no local admin
password like the `prom-operator` one this lab uses. The catch worth planning
for: AMG has no dashboard sidecar. Dashboards-as-ConfigMaps stops working, so
provision them through the Grafana HTTP API or the Terraform Grafana provider
in CI. Keep the JSON in git either way — the storage backend changes, the
principle does not.

**ADOT and OpenTelemetry.** The AWS Distro for OpenTelemetry Collector can
replace the scrape-and-remote-write path entirely and, more usefully, unify
metrics, traces and logs behind one agent and one pipeline configuration. Its
`prometheus` receiver understands the same scrape config, so migration is
incremental. Traces to X-Ray with exemplars linking a latency spike on the
dashboard directly to the trace that caused it is the genuinely
harder-to-replicate capability here.

**CloudWatch Container Insights** covers a different need: cluster and node
health, control-plane metrics EKS does not expose to Prometheus, and log
correlation. It is not a Prometheus replacement — it does not do PromQL or
custom application metrics well — but for node pressure, EBS burst balance
exhaustion and API-server latency, it sees things a cluster-local Prometheus
structurally cannot. Most production EKS estates run both.

**Cardinality is the whole game.** A Prometheus outage is almost always a
cardinality event, not a load event. Series count is the product of every label
value combination, so one label carrying a user ID, a request path with an
embedded UUID, or a pod name on a Deployment that restarts constantly will
multiply your series count without bound. Defences, in order of effectiveness:
never put unbounded values in labels (normalise `/users/12345` to `/users/:id`
at instrumentation time); use `metricRelabelings` to drop metrics you do not
query, as this lab does for `go_*`; set `sample_limit` on scrape configs so one
bad exporter is rejected rather than absorbed; and alert on
`prometheus_tsdb_head_series` growth so you find out before the OOMKill.

**Recording rules and retention tiering.** Recording rules are not only a
performance optimisation — they are how you keep a year of history without
keeping a year of raw samples. Record the aggregates you actually graph
(`demo_app:http_requests:rate5m`), keep raw samples for two weeks and the
recorded series for a year. On AMP this maps directly onto its rules
configuration and is the difference between an affordable and an unaffordable
long-term retention policy.

**Alert routing that people trust.** The rules here set `severity` and `team`
labels precisely so Alertmanager can route on them: `critical` to PagerDuty via
SNS, `warning` to a Slack channel, `info` to nowhere at all. The failure mode to
design against is alert fatigue — an alert that fires routinely and is routinely
ignored is worse than no alert, because it teaches the on-call to dismiss the
notification channel. Every alert should be actionable, have a runbook (the
`runbook_url` annotations here point at this README's anchors), and be deleted
if nobody has acted on it in six months.
