#!/usr/bin/env bash
#
# Delete the local kind cluster. Destructive but cheap - the whole point of a
# throwaway cluster is that you can recreate it in a minute.
#
# Usage:
#   ./scripts/cluster-down.sh
#   ASSUME_YES=1 ./scripts/cluster-down.sh

set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-k8s-labs}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=scripts/lib.sh
source "${REPO_ROOT}/scripts/lib.sh"

require_command kind

if ! kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  log_warn "No kind cluster named '${CLUSTER_NAME}' - nothing to do."
  exit 0
fi

if ! confirm "Delete kind cluster '${CLUSTER_NAME}' and everything in it?"; then
  log_warn "Aborted."
  exit 0
fi

log_info "Deleting kind cluster '${CLUSTER_NAME}'"
kind delete cluster --name "${CLUSTER_NAME}"
log_info "Done."
