#!/usr/bin/env bash
#
# Validate every YAML manifest in this repository, plus the Helm chart.
#
# Runs the same three checks CI runs, so you can catch problems before pushing:
#   1. yamllint      - style and syntax
#   2. kubeconform   - schema validation against the Kubernetes OpenAPI specs
#   3. helm lint     - chart correctness
#
# Any tool that is not installed is skipped with a warning rather than failing,
# so the script stays useful on a partially provisioned laptop. CI installs all
# three, so nothing is silently skipped there.
#
# Usage:
#   ./scripts/validate.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

# shellcheck source=scripts/lib.sh
source "${REPO_ROOT}/scripts/lib.sh"

# Kubernetes version whose schemas we validate against.
KUBERNETES_VERSION="${KUBERNETES_VERSION:-1.31.0}"

CHART_DIR="labs/08-helm-chart/demo-app"

# Paths kubeconform must not try to schema-check:
#   - the Helm chart templates are Go templates, not YAML
#   - kind/*.yaml are kind configs, not Kubernetes objects
#   - values*.yaml are Helm chart inputs, not Kubernetes objects
#   - dotfiles (.yamllint.yml) are tool config
#   - .github/ holds GitHub Actions workflows
#   - anything under an optional/ directory targets a CRD that is not installed
#     by default (the VerticalPodAutoscaler in lab 06)
EXCLUDE_REGEX='(labs/08-helm-chart/demo-app/|^\./kind/|^\./\.github/|/optional/)'

failures=0

run_yamllint() {
  if ! command -v yamllint >/dev/null 2>&1; then
    log_warn "yamllint not installed - skipping (pip install yamllint)"
    return 0
  fi
  log_info "Running yamllint"
  if yamllint --strict .; then
    log_info "yamllint passed"
  else
    log_error "yamllint failed"
    failures=$((failures + 1))
  fi
}

run_kubeconform() {
  if ! command -v kubeconform >/dev/null 2>&1; then
    log_warn "kubeconform not installed - skipping (brew install kubeconform)"
    return 0
  fi
  log_info "Running kubeconform against Kubernetes ${KUBERNETES_VERSION}"

  # -ignore-missing-schemas lets CRD-backed objects (ServiceMonitor,
  # PrometheusRule, Application, VerticalPodAutoscaler) pass without us having
  # to vendor every CRD schema. The datreeio schema repo below does cover most
  # popular CRDs, so in practice very little is actually skipped.
  local files
  files="$(find . -type f \( -name '*.yaml' -o -name '*.yml' \) \
    -not -path './.git/*' \
    -not -name 'values*.yaml' \
    -not -name '.*' \
    | grep -Ev "${EXCLUDE_REGEX}" || true)"

  if [[ -z "${files}" ]]; then
    log_warn "No manifests found to validate"
    return 0
  fi

  if echo "${files}" | xargs kubeconform \
    -kubernetes-version "${KUBERNETES_VERSION}" \
    -strict \
    -ignore-missing-schemas \
    -schema-location default \
    -schema-location \
      'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
    -summary; then
    log_info "kubeconform passed"
  else
    log_error "kubeconform failed"
    failures=$((failures + 1))
  fi
}

run_helm_lint() {
  if ! command -v helm >/dev/null 2>&1; then
    log_warn "helm not installed - skipping (brew install helm)"
    return 0
  fi
  log_info "Running helm lint on ${CHART_DIR}"
  if helm lint "${CHART_DIR}"; then
    log_info "helm lint passed"
  else
    log_error "helm lint failed"
    failures=$((failures + 1))
  fi

  log_info "Rendering the chart with default values"
  if helm template demo-app "${CHART_DIR}" >/dev/null; then
    log_info "helm template (defaults) passed"
  else
    log_error "helm template (defaults) failed"
    failures=$((failures + 1))
  fi

  # Rendering with every optional feature turned on exercises the conditional
  # templates (Ingress, HPA, PDB, ServiceMonitor) that default values skip.
  log_info "Rendering the chart with all optional features enabled"
  if helm template demo-app "${CHART_DIR}" \
    --set ingress.enabled=true \
    --set autoscaling.enabled=true \
    --set pdb.enabled=true \
    --set serviceMonitor.enabled=true >/dev/null; then
    log_info "helm template (all features) passed"
  else
    log_error "helm template (all features) failed"
    failures=$((failures + 1))
  fi
}

run_yamllint
run_kubeconform
run_helm_lint

echo
if [[ "${failures}" -eq 0 ]]; then
  log_info "All validation checks passed."
else
  die "${failures} validation check(s) failed."
fi
