#!/usr/bin/env bash
#
# Create the local kind cluster used by every lab in this repository, then
# install the add-ons the labs depend on (ingress-nginx and metrics-server).
#
# The script is idempotent: re-running it against an existing cluster reconciles
# the add-ons rather than failing.
#
# Usage:
#   ./scripts/cluster-up.sh
#   WITH_CALICO=1 ./scripts/cluster-up.sh       # Calico instead of kindnet, so
#                                               # NetworkPolicy is enforced (lab 07)
#   SKIP_INGRESS=1 ./scripts/cluster-up.sh      # bare cluster only
#   SKIP_METRICS=1 ./scripts/cluster-up.sh
#   CLUSTER_NAME=scratch ./scripts/cluster-up.sh

set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-k8s-labs}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# WITH_CALICO=1 swaps kindnet for Calico. Required for lab 07: kindnet does not
# implement NetworkPolicy, so policies applied to a default kind cluster are
# accepted and then silently ignored.
if [[ "${WITH_CALICO:-0}" == "1" ]]; then
  KIND_CONFIG="${REPO_ROOT}/kind/cluster-calico.yaml"
else
  KIND_CONFIG="${REPO_ROOT}/kind/cluster.yaml"
fi

# Pinned versions. Floating "latest" tags are how a lab that worked in January
# breaks silently in March.
INGRESS_NGINX_VERSION="${INGRESS_NGINX_VERSION:-controller-v1.11.2}"
METRICS_SERVER_VERSION="${METRICS_SERVER_VERSION:-v0.7.2}"
CALICO_VERSION="${CALICO_VERSION:-v3.28.2}"

# shellcheck source=scripts/lib.sh
source "${REPO_ROOT}/scripts/lib.sh"

main() {
  require_command kind
  require_command kubectl
  require_command docker

  ensure_docker_running
  create_cluster

  # Calico must go in before we wait on node readiness: with the default CNI
  # disabled there is no pod networking at all, so every node sits NotReady
  # until a CNI is running. Waiting first would just time out.
  if [[ "${WITH_CALICO:-0}" == "1" ]]; then
    install_calico
  fi

  wait_for_nodes

  if [[ "${SKIP_INGRESS:-0}" != "1" ]]; then
    install_ingress_nginx
  fi

  if [[ "${SKIP_METRICS:-0}" != "1" ]]; then
    install_metrics_server
  fi

  summary
}

create_cluster() {
  if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
    log_warn "kind cluster '${CLUSTER_NAME}' already exists - skipping creation"
  else
    log_info "Creating kind cluster '${CLUSTER_NAME}' from $(basename "${KIND_CONFIG}") (this takes ~60s)"
    # --wait is intentionally omitted when Calico is in play: kind would wait
    # for node readiness that cannot happen until we install the CNI ourselves.
    if [[ "${WITH_CALICO:-0}" == "1" ]]; then
      kind create cluster --name "${CLUSTER_NAME}" --config "${KIND_CONFIG}"
    else
      kind create cluster --name "${CLUSTER_NAME}" --config "${KIND_CONFIG}" --wait 120s
    fi
  fi

  # kind writes a context named kind-<cluster>; make sure kubectl is pointed at
  # it so a stray context from another project cannot receive our manifests.
  kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null
  log_info "kubectl context set to 'kind-${CLUSTER_NAME}'"
}

wait_for_nodes() {
  log_info "Waiting for all nodes to become Ready"
  kubectl wait --for=condition=Ready nodes --all --timeout=300s
}

install_calico() {
  log_info "Installing the Tigera operator (Calico ${CALICO_VERSION})"
  # `create`, not `apply`: the operator manifest contains CRDs whose annotations
  # exceed the 262144-byte limit that `kubectl apply` writes into
  # last-applied-configuration. This is the documented install path.
  kubectl create -f \
    "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/tigera-operator.yaml"

  log_info "Applying the Calico Installation custom resource"
  # The default pool in this manifest is 192.168.0.0/16, which is why
  # kind/cluster-calico.yaml sets podSubnet to match.
  kubectl create -f \
    "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/custom-resources.yaml"

  log_info "Waiting for Calico to converge (2-4 minutes on a cold cluster)"
  # The calico-system namespace and its DaemonSet are created by the operator,
  # so we have to wait for them to exist before we can wait on their rollout.
  local attempts=0
  until kubectl get daemonset/calico-node -n calico-system >/dev/null 2>&1; do
    attempts=$((attempts + 1))
    if [[ "${attempts}" -gt 60 ]]; then
      die "Timed out waiting for the Tigera operator to create the calico-node DaemonSet."
    fi
    sleep 5
  done

  kubectl rollout status daemonset/calico-node -n calico-system --timeout=300s
}

install_ingress_nginx() {
  log_info "Installing ingress-nginx (${INGRESS_NGINX_VERSION})"
  kubectl apply -f \
    "https://raw.githubusercontent.com/kubernetes/ingress-nginx/${INGRESS_NGINX_VERSION}/deploy/static/provider/kind/deploy.yaml"

  log_info "Waiting for the ingress-nginx controller to become ready"
  # The admission-webhook Job races the controller Deployment on a cold
  # cluster, so we wait on the controller Pod specifically rather than on the
  # whole namespace.
  kubectl wait --namespace ingress-nginx \
    --for=condition=ready pod \
    --selector=app.kubernetes.io/component=controller \
    --timeout=180s
}

install_metrics_server() {
  log_info "Installing metrics-server (${METRICS_SERVER_VERSION})"
  kubectl apply -f \
    "https://github.com/kubernetes-sigs/metrics-server/releases/download/${METRICS_SERVER_VERSION}/components.yaml"

  # kind's kubelets serve their metrics endpoint with a self-signed certificate
  # that metrics-server will not trust. Without this patch every `kubectl top`
  # and every HPA in lab 06 reports <unknown> forever.
  log_info "Patching metrics-server with --kubelet-insecure-tls (required on kind)"
  kubectl patch deployment metrics-server -n kube-system --type=json -p='[
    {
      "op": "add",
      "path": "/spec/template/spec/containers/0/args/-",
      "value": "--kubelet-insecure-tls"
    }
  ]'

  log_info "Waiting for metrics-server to become available"
  kubectl wait --namespace kube-system \
    --for=condition=Available deployment/metrics-server \
    --timeout=180s
}

summary() {
  echo
  log_info "Cluster '${CLUSTER_NAME}' is ready."
  echo
  kubectl get nodes -o wide
  echo
  cat <<EOF
Next steps:
  make build-image     # build the demo app image
  make load-image      # load it into the kind cluster
  make deploy-lab LAB=01-pods-and-deployments

Ingress is published on http://localhost:80 - the labs use the hostname
demo.localtest.me, which resolves to 127.0.0.1 without any /etc/hosts edits.
EOF
}

main "$@"
