# kubernetes-labs
#
# Run `make help` for the full target list.

SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

# ---------------------------------------------------------------------------
# Configuration (override on the command line, e.g. `make LAB=03-... deploy-lab`)
# ---------------------------------------------------------------------------
CLUSTER_NAME       ?= k8s-labs
KUBERNETES_VERSION ?= 1.31.0
IMAGE_REPO         ?= ghcr.io/maneeshm/k8s-labs-demo
IMAGE_TAG          ?= 1.0.0
IMAGE              := $(IMAGE_REPO):$(IMAGE_TAG)
CHART_DIR          := labs/08-helm-chart/demo-app
LABS_DIR           := labs

# LAB selects which lab the lab-scoped targets act on.
LAB ?= 01-pods-and-deployments
LAB_PATH := $(LABS_DIR)/$(LAB)

# Manifests to validate: everything except Helm templates (Go templates, not
# YAML) and the kind config (not a Kubernetes object).
MANIFESTS := $(shell find . -type f \( -name '*.yaml' -o -name '*.yml' \) \
	-not -path './.git/*' \
	-not -path './$(CHART_DIR)/*' \
	-not -path './kind/*' \
	-not -path '*/optional/*' \
	-not -name 'values*.yaml' \
	-not -name '.*' 2>/dev/null)

.PHONY: help
help: ## Show this help
	@echo "kubernetes-labs — available targets"
	@echo
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| sort \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "Variables: CLUSTER_NAME=$(CLUSTER_NAME)  IMAGE=$(IMAGE)  LAB=$(LAB)"
	@echo
	@echo "Available labs:"
	@ls -1 $(LABS_DIR) | sed 's/^/  /'

# ---------------------------------------------------------------------------
# Cluster lifecycle
# ---------------------------------------------------------------------------

.PHONY: cluster-up
cluster-up: ## Create the kind cluster with ingress-nginx and metrics-server
	CLUSTER_NAME=$(CLUSTER_NAME) ./scripts/cluster-up.sh

.PHONY: cluster-up-calico
cluster-up-calico: ## Create the cluster with Calico instead of kindnet (required for lab 07)
	CLUSTER_NAME=$(CLUSTER_NAME) WITH_CALICO=1 ./scripts/cluster-up.sh

.PHONY: cluster-down
cluster-down: ## Delete the kind cluster
	CLUSTER_NAME=$(CLUSTER_NAME) ./scripts/cluster-down.sh

.PHONY: cluster-reset
cluster-reset: ## Delete and recreate the cluster from scratch
	ASSUME_YES=1 $(MAKE) cluster-down
	$(MAKE) cluster-up

.PHONY: cluster-info
cluster-info: ## Show nodes, add-on status and current context
	@echo "context: $$(kubectl config current-context)"
	@echo
	@kubectl get nodes -o wide
	@echo
	@kubectl get pods -n ingress-nginx 2>/dev/null || echo "ingress-nginx: not installed"
	@echo
	@kubectl get deploy metrics-server -n kube-system 2>/dev/null || echo "metrics-server: not installed"

# ---------------------------------------------------------------------------
# Demo application image
# ---------------------------------------------------------------------------

.PHONY: build-image
build-image: ## Build the demo app container image
	docker build \
		--build-arg VERSION=$(IMAGE_TAG) \
		-t $(IMAGE) \
		app/

.PHONY: load-image
load-image: ## Load the demo app image into the kind cluster
	kind load docker-image $(IMAGE) --name $(CLUSTER_NAME)

.PHONY: image
image: build-image load-image ## Build the image and load it into kind

.PHONY: run-local
run-local: ## Run the demo app locally on :8080 (requires Go)
	cd app && PORT=8080 GREETING="Hello from localhost" go run .

.PHONY: test-app
test-app: ## Run the Go unit tests / vet for the demo app
	cd app && go vet ./... && go test ./...

# ---------------------------------------------------------------------------
# Labs
# ---------------------------------------------------------------------------

.PHONY: deploy-lab
deploy-lab: ## Apply a lab's manifests (make deploy-lab LAB=02-services-and-ingress)
	@test -d "$(LAB_PATH)" || { echo "No such lab: $(LAB_PATH)"; exit 1; }
	@echo "==> Applying $(LAB_PATH)"
	kubectl apply -f $(LAB_PATH) --recursive

.PHONY: delete-lab
delete-lab: ## Delete a lab's resources (make delete-lab LAB=02-services-and-ingress)
	@test -d "$(LAB_PATH)" || { echo "No such lab: $(LAB_PATH)"; exit 1; }
	@echo "==> Deleting $(LAB_PATH)"
	kubectl delete -f $(LAB_PATH) --recursive --ignore-not-found

.PHONY: lab-status
lab-status: ## Show all resources in a lab's namespace
	@kubectl get all,ingress,configmap,secret,pvc \
		-n $$(kubectl get ns -o name | grep -o 'lab-$(firstword $(subst -, ,$(LAB)))-[a-z]*' | head -1) 2>/dev/null \
		|| echo "Namespace for $(LAB) not found — has it been deployed?"

.PHONY: list-labs
list-labs: ## List every available lab
	@ls -1 $(LABS_DIR)

.PHONY: clean-labs
clean-labs: ## Delete every lab namespace
	@for ns in $$(kubectl get ns -o name | grep -o 'lab-[0-9]*-[a-z]*'); do \
		echo "==> deleting namespace $$ns"; \
		kubectl delete ns "$$ns" --ignore-not-found --wait=false; \
	done

# ---------------------------------------------------------------------------
# Helm
# ---------------------------------------------------------------------------

.PHONY: helm-lint
helm-lint: ## Lint the demo-app Helm chart
	helm lint $(CHART_DIR)

.PHONY: helm-template
helm-template: ## Render the chart with all optional features enabled
	helm template demo-app $(CHART_DIR) \
		--set ingress.enabled=true \
		--set autoscaling.enabled=true \
		--set pdb.enabled=true \
		--set serviceMonitor.enabled=true

.PHONY: helm-install
helm-install: ## Install the demo-app chart into the lab-08-helm namespace
	helm upgrade --install demo-app $(CHART_DIR) \
		--namespace lab-08-helm \
		--create-namespace \
		--wait

.PHONY: helm-uninstall
helm-uninstall: ## Uninstall the demo-app chart
	helm uninstall demo-app --namespace lab-08-helm --ignore-not-found

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

.PHONY: validate
validate: ## Run every validation check (yamllint + kubeconform + helm lint)
	./scripts/validate.sh

.PHONY: lint
lint: ## Run yamllint over all YAML
	yamllint --strict .

.PHONY: kubeconform
kubeconform: ## Schema-validate all manifests
	@echo "$(MANIFESTS)" | tr ' ' '\n' | xargs kubeconform \
		-kubernetes-version $(KUBERNETES_VERSION) \
		-strict \
		-ignore-missing-schemas \
		-schema-location default \
		-schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
		-summary

.PHONY: yaml-parse
yaml-parse: ## Fast local check that every YAML file parses
	@python3 -c "import sys, yaml, glob; \
		files = [f for f in glob.glob('**/*.yaml', recursive=True) if '08-helm-chart/demo-app/templates' not in f]; \
		[list(yaml.safe_load_all(open(f))) for f in files]; \
		print(f'{len(files)} YAML files parsed successfully')"

.PHONY: shellcheck
shellcheck: ## Lint the shell scripts
	shellcheck scripts/*.sh
