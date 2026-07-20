# kubernetes-labs

[![CI](https://github.com/maneeshm/kubernetes-labs/actions/workflows/ci.yml/badge.svg)](https://github.com/maneeshm/kubernetes-labs/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Kubernetes](https://img.shields.io/badge/kubernetes-1.31-326ce5.svg)](https://kubernetes.io/)

A progressive, hands-on Kubernetes curriculum built as **real, working
manifests** — not snippets. Every lab runs on a local [kind](https://kind.sigs.k8s.io/)
cluster you can create in about a minute, and every manifest is validated in CI
against the Kubernetes OpenAPI schemas.

I built this while working as a platform engineer on AWS/EKS. Each lab ends with
a **production notes** section connecting the local exercise to how the same
problem is actually solved on a managed cluster — IRSA instead of raw
ServiceAccounts, the EBS CSI driver instead of `local-path`, Karpenter instead
of a hand-tuned Cluster Autoscaler, and so on.

---

## Lab index

| # | Lab | What you build | Key objects |
| --- | --- | --- | --- |
| 01 | [Pods and Deployments](labs/01-pods-and-deployments/) | A bare Pod vs. a managed Deployment; rolling updates and rollbacks | `Pod`, `Deployment`, `PodDisruptionBudget` |
| 02 | [Services and Ingress](labs/02-services-and-ingress/) | Path-based HTTP fanout through the nginx ingress controller | `Service` (ClusterIP/NodePort/headless), `Ingress` |
| 03 | [ConfigMaps and Secrets](labs/03-configmaps-and-secrets/) | Configuration as env vars and mounted files; rollout-on-change | `ConfigMap`, `Secret`, projected volumes |
| 04 | [Persistent storage](labs/04-persistent-storage/) | A stateful database with stable identity and durable disks | `StatefulSet`, `PVC`, `StorageClass` |
| 05 | [RBAC and ServiceAccounts](labs/05-rbac-and-service-accounts/) | Least-privilege identity for workloads, proven with `auth can-i` | `ServiceAccount`, `Role`, `ClusterRole`, bindings |
| 06 | [Autoscaling](labs/06-autoscaling/) | Horizontal scaling driven by real CPU load | `HPA` (autoscaling/v2), metrics-server, VPA |
| 07 | [Network policies](labs/07-network-policies/) | Default-deny, then explicit allow between three tiers | `NetworkPolicy` |
| 08 | [Helm chart](labs/08-helm-chart/) | A complete, lint-clean chart with schema and tests | `Chart.yaml`, templates, `NOTES.txt` |
| 09 | [Observability](labs/09-observability/) | Prometheus scraping, alerting rules and a Grafana dashboard | `ServiceMonitor`, `PrometheusRule` |
| 10 | [GitOps with Argo CD](labs/10-gitops-argocd/) | App-of-apps, sync waves, self-heal and prune | `Application`, `AppProject` |
| 11 | [Troubleshooting](labs/11-troubleshooting/) | Ten broken manifests and the runbook to fix them | everything, deliberately broken |

---

## Learning path

The labs build on each other. If you are working through them in order:

**Foundations (01 → 04)** — the objects you touch every day. Start here even if
you have used Kubernetes before; lab 01's bare-Pod-vs-Deployment exercise and
lab 03's "a ConfigMap change does not restart your pods" lesson are the two
things people most often learn the hard way.

**Operating safely (05 → 07)** — identity, elasticity and isolation. These are
the labs that separate "I can deploy an app" from "I can run a platform other
teams deploy onto."

**Packaging and delivery (08 → 10)** — how the manifests you wrote by hand in
01–07 get templated, observed and delivered continuously. Lab 08's chart is the
same app you have been deploying all along, so the diff against the raw
manifests is easy to see.

**Proving it (11)** — the troubleshooting lab is deliberately last. Every
scenario in it is a failure mode of something taught earlier, so it doubles as
a self-assessment. If you can diagnose all ten from the symptom alone, the rest
of the repo landed.

Budget roughly 30–60 minutes per lab. Labs 08 and 10 are the longest.

---

## Prerequisites

| Tool | Minimum | Install |
| --- | --- | --- |
| Docker | 20.10 | [docs.docker.com](https://docs.docker.com/get-docker/) — must be running |
| kind | 0.24 | `brew install kind` |
| kubectl | 1.30 | `brew install kubectl` |
| Helm | 3.14 | `brew install helm` (labs 08–10) |
| Go | 1.22 | `brew install go` (only to build the demo app locally) |

Optional, for running the same checks CI runs:

```bash
brew install kubeconform shellcheck
pip install yamllint
```

You will also want **4 GB of RAM and 2 CPUs free** for Docker. Lab 09
(kube-prometheus-stack) is the hungriest; if it struggles, the lab's values file
has a trimmed-down profile.

---

## Quick start

```bash
git clone https://github.com/maneeshm/kubernetes-labs.git
cd kubernetes-labs

# 1. Create a 3-node kind cluster with ingress-nginx and metrics-server
make cluster-up

# 2. Build the demo app image and load it into the cluster
make image

# 3. Deploy the first lab
make deploy-lab LAB=01-pods-and-deployments

# 4. Look around
kubectl get all -n lab-01-workloads

# ... work through labs/01-pods-and-deployments/README.md ...

# 5. Tear it all down when you are done
make cluster-down
```

Each lab's `README.md` is self-contained: objectives, prerequisites,
step-by-step commands, verification, cleanup, and what you should have taken
away.

---

## The demo app

Every lab deploys the same small Go service from [`app/`](app/). It exposes
`/healthz`, `/readyz`, `/metrics`, `/api/info`, a `POST /toggle-ready` endpoint
for demonstrating readiness gating, and `GET /burn?seconds=N` for driving the
HPA in lab 06.

It uses **only the Go standard library**, which lets it ship on a `scratch`
base image. That is what makes it possible for every manifest in this repository
to run with `readOnlyRootFilesystem: true` as a non-root user with all
capabilities dropped — see [`app/README.md`](app/README.md).

---

## Makefile targets

```
make help                    # the full list, always current

make cluster-up              # create the kind cluster + add-ons
make cluster-up-calico       # same, but with Calico so NetworkPolicy works (lab 07)
make cluster-down            # delete it
make cluster-reset           # both
make cluster-info            # nodes and add-on status

make image                   # build + load the demo app image
make run-local               # run the app on localhost:8080

make deploy-lab LAB=03-configmaps-and-secrets
make delete-lab LAB=03-configmaps-and-secrets
make list-labs
make clean-labs              # delete every lab namespace

make helm-lint               # lint the chart from lab 08
make helm-template           # render it with all features on

make validate                # yamllint + kubeconform + helm lint
```

---

## Manifest conventions

Every manifest in this repository holds to the same bar. This is as much of the
lesson as the labs themselves — these are the defaults a platform team should
enforce with an admission policy rather than leaving to reviewer discipline.

**Security context.** Pods run as non-root (UID/GID 65532), with
`seccompProfile: RuntimeDefault` and an `fsGroup` so mounted volumes are
writable. Containers set `allowPrivilegeEscalation: false`, drop **all**
capabilities, and mount a read-only root filesystem. Where a workload genuinely
needs to write (postgres in lab 04), the exception is narrowed to that one
container and carries a comment explaining why.

**Resources.** Every container declares both requests and limits. Requests are
what the scheduler packs against and what the HPA computes utilisation from;
limits are what the kernel enforces. A pod with limits but no requests gets
`Burstable` QoS and surprising eviction behaviour — lab 11 has a scenario on it.

**Probes.** Liveness and readiness are always distinct, and never point at the
same logic. Liveness restarts the container; readiness only removes it from
Service endpoints. Conflating them turns a dependency outage into a crash loop.

**Labels.** All objects carry the full `app.kubernetes.io/` recommended set —
`name`, `instance`, `version`, `component`, `part-of`, `managed-by` — so that
selectors, Prometheus relabeling and `kubectl get -l` all work predictably.

**Namespaces.** Each lab owns a namespace (`lab-NN-<topic>`), so cleanup is a
single `kubectl delete ns` and no lab can interfere with another.

---

## Validation and CI

[`.github/workflows/ci.yml`](.github/workflows/ci.yml) runs on every push and PR:

| Job | What it checks |
| --- | --- |
| `yamllint` | Style and syntax across all YAML |
| `kubeconform` | Schema validation against the Kubernetes 1.31 OpenAPI specs, strict mode, with the datreeio CRD catalog for `ServiceMonitor`/`Application`/etc. |
| `helm` | `helm lint` and `helm template` with defaults *and* with every optional feature enabled, then kubeconform over the rendered output |
| `app` | `go vet`, `gofmt`, build, a probe smoke test against the running binary, and a container build |
| `shellcheck` | The setup scripts |
| `e2e` | Creates a real kind cluster, deploys lab 01, installs the chart and runs `helm test` |

Run the same checks locally with `make validate`.

> The `e2e` job matters: schema validation proves a manifest is *well-formed*,
> not that it *works*. Only actually scheduling the pods proves that.

---

## Repository layout

```
kubernetes-labs/
├── app/                     the demo service (Go, stdlib only) + Dockerfile
├── kind/
│   ├── cluster.yaml         3-node cluster, ingress ports, fake zone labels
│   └── cluster-calico.yaml  same, minus the default CNI, for lab 07
├── scripts/                 cluster-up / cluster-down / validate
├── labs/
│   ├── 01-pods-and-deployments/
│   ├── ...
│   └── 11-troubleshooting/  broken/ and fixed/ manifests + runbook
├── .github/workflows/ci.yml
├── Makefile
└── README.md
```

---

## A note on the local-vs-EKS gap

kind is not EKS, and a few labs will behave differently from a managed cluster
in ways worth knowing up front:

- **NetworkPolicy is not enforced** by kind's default CNI (kindnet). Policies
  are accepted by the API server and then silently ignored, which is the worst
  possible failure mode for learning. Use `make cluster-up-calico` before lab
  07 — it builds the same cluster with `disableDefaultCNI: true` and installs
  Calico in kindnet's place.
- **The default StorageClass** is rancher's `local-path`, which is
  node-local and has no topology constraints. Lab 04 covers what changes with
  the EBS CSI driver and `WaitForFirstConsumer`.
- **There is no cloud load balancer.** `Service type: LoadBalancer` stays
  `<pending>` forever. Lab 02 uses the ingress controller's host port mapping
  instead, and covers the AWS Load Balancer Controller as the real-world path.
- **There is no IAM.** Lab 05 teaches RBAC on its own terms and then explains
  how IRSA and EKS Pod Identity layer AWS identity on top of a ServiceAccount.

---

## License

[MIT](LICENSE) © Maneesh M
