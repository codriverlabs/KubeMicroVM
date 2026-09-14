# KubeMicroVM — developer task runner
#
# Prerequisites for the m80/* targets:
#   docker, k3d (https://k3d.io), kubectl, helm, node >= 20, npm, just
#   Install just:  cargo install just  OR  brew install just  OR  see https://just.systems
#
# Quick start:
#   make full                  # clone m80, spin up k3d, run UAT, tear down
#   make m80-up                # bring up the stack only (leave it running)
#   make m80-run               # run the suite against a running stack
#   make m80-down              # tear the cluster down
#
# Overridable variables (all have sensible defaults):
#   CHART_VERSION    KubeMicroVM Helm chart version to install  (default: current tag or main)
#   M80_IMAGE        m80 container image                        (default: latest release)
#   M80_DIR          where to clone m80                        (default: .m80/)
#   REGION           AWS region passed to the operator          (default: us-east-1)
#   RESULTS          Robot Framework output directory           (default: uat/results/m80/)
#   MAX_ACCOUNT_MEMORY_MIB  m80 memory ceiling (raise for large suites, default: 262144)
#
# To test against your own m80 build:
#   make m80-up M80_IMAGE=m80:my-branch
#
# To run against k3s-xpress (once available) instead of k3d:
#   Set CLUSTER_PROVIDER=k3s-xpress and implement the _cluster-up / _cluster-down
#   private targets below.  The run step (m80-run) is provider-agnostic.

# ─── Variables ────────────────────────────────────────────────────────────────

M80_REPO    := https://github.com/INTENTIUS/m80.git
M80_DIR     ?= $(CURDIR)/.m80
M80_IMAGE   ?= ghcr.io/intentius/m80:v0.4.0

# Resolve the current chart version from git (nearest tag), falling back to
# "main" so a freshly-cloned repo without tags still works.
CHART_VERSION ?= $(shell git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo main)

REGION      ?= us-east-1
RESULTS     ?= $(CURDIR)/uat/results/m80
MAX_ACCOUNT_MEMORY_MIB ?= 262144

# The cluster provider controls which _cluster-up / _cluster-down recipe runs.
# Supported: k3d (default), k3s-xpress (future)
CLUSTER_PROVIDER ?= k3d

# ─── Phony targets ────────────────────────────────────────────────────────────

.PHONY: full m80-up m80-run m80-down m80-clean m80-deps \
        _m80-fetch _prereq-check _cluster-up _cluster-down \
        build test help

# ─── Default target ───────────────────────────────────────────────────────────

.DEFAULT_GOAL := help

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?##' $(MAKEFILE_LIST) | \
	  awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-20s\033[0m %s\n",$$1,$$2}'
	@echo ""
	@echo "  Variables (override on command line or in env):"
	@echo "    CHART_VERSION=$(CHART_VERSION)"
	@echo "    M80_IMAGE=$(M80_IMAGE)"
	@echo "    M80_DIR=$(M80_DIR)"
	@echo "    REGION=$(REGION)"
	@echo "    RESULTS=$(RESULTS)"
	@echo "    CLUSTER_PROVIDER=$(CLUSTER_PROVIDER)"

# ─── Build & unit tests ───────────────────────────────────────────────────────

build: ## Build all modules (skips tests)
	./mvnw -B --no-transfer-progress clean install -DskipTests -q

test: ## Run unit + integration tests (no cluster needed)
	./mvnw -B --no-transfer-progress clean verify

# ─── Full local UAT (m80 emulator + k3d) ─────────────────────────────────────

full: _prereq-check _m80-fetch ## Clone m80, spin up cluster+operator, run UAT, tear down
	$(MAKE) m80-up
	$(MAKE) m80-run || ($(MAKE) m80-down; exit 1)
	$(MAKE) m80-down
	@echo ""
	@echo "Results: $(RESULTS)"

m80-up: _prereq-check _m80-fetch _cluster-up ## Bring up k3d + m80 + KubeMicroVM operator
	@echo "==> Stack is up. Run 'make m80-run' to execute the UAT suite."

m80-run: ## Run KubeMicroVM UAT against the running m80 stack
	@test -d "$(M80_DIR)" || (echo "ERROR: m80 not found at $(M80_DIR). Run 'make m80-up' first." && exit 1)
	@mkdir -p "$(RESULTS)"
	KUBEMICROVM="$(CURDIR)" \
	RESULTS="$(RESULTS)" \
	REGION="$(REGION)" \
	CHART_VERSION="$(CHART_VERSION)" \
	  "$(M80_DIR)/uat/run.sh"
	@echo ""
	@echo "Results written to: $(RESULTS)"
	@echo "Open: $(RESULTS)/report.html"

m80-down: ## Tear down the k3d cluster
	$(MAKE) _cluster-down

m80-clean: m80-down ## Tear down cluster and remove the m80 checkout
	rm -rf "$(M80_DIR)"

# ─── Cluster provider: k3d (default) ─────────────────────────────────────────

ifeq ($(CLUSTER_PROVIDER),k3d)

_cluster-up:
	@echo "==> Bringing up k3d cluster (m80 + KubeMicroVM operator v$(CHART_VERSION))"
	M80_IMAGE="$(M80_IMAGE)" \
	CHART_VERSION="$(CHART_VERSION)" \
	REGION="$(REGION)" \
	MAX_ACCOUNT_MEMORY_MIB="$(MAX_ACCOUNT_MEMORY_MIB)" \
	  "$(M80_DIR)/uat/up.sh"

_cluster-down:
	@echo "==> Tearing down k3d cluster"
	k3d cluster delete m80-uat 2>/dev/null || true

# ─── Cluster provider: k3s-xpress (future) ───────────────────────────────────
# When k3s-xpress is available, set CLUSTER_PROVIDER=k3s-xpress.
# This provider skips k3d entirely and deploys m80 + the operator into an
# existing k3s-xpress cluster (EKS Pod Identity layer included).
# The run step (m80-run) is provider-agnostic and needs no changes.

else ifeq ($(CLUSTER_PROVIDER),k3s-xpress)

K3S_XPRESS_CLUSTER ?=  # set to your k3s-xpress cluster name
K3S_XPRESS_REGION  ?= $(REGION)

_cluster-up:
	@test -n "$(K3S_XPRESS_CLUSTER)" || \
	  (echo "ERROR: set K3S_XPRESS_CLUSTER=<name>" && exit 1)
	@echo "==> Deploying m80 + KubeMicroVM operator into k3s-xpress cluster $(K3S_XPRESS_CLUSTER)"
	# Switch kubectl context to the k3s-xpress cluster
	kubectl config use-context "$(K3S_XPRESS_CLUSTER)"
	# Deploy m80 into kube-microvm namespace
	kubectl create namespace kube-microvm --dry-run=client -o yaml | kubectl apply -f -
	kubectl apply -f - <<YAML
	apiVersion: apps/v1
	kind: Deployment
	metadata: { name: m80, namespace: kube-microvm }
	spec:
	  replicas: 1
	  selector: { matchLabels: { app: m80 } }
	  template:
	    metadata: { labels: { app: m80 } }
	    spec:
	      containers:
	        - name: m80
	          image: $(M80_IMAGE)
	          args: ["-addr", ":4290", "-build-delay", "500ms",
	                 "-max-account-memory-mib", "$(MAX_ACCOUNT_MEMORY_MIB)", "-serve-sts"]
	          ports: [{ containerPort: 4290 }]
	YAML
	# Install the operator pointing at m80
	# k3s-xpress provides EKS Pod Identity — use it instead of static creds
	helm upgrade --install kube-microvm-operator \
	  "oci://ghcr.io/codriverlabs/helm/kube-microvm-operator" \
	  --version "$(CHART_VERSION)" -n kube-microvm \
	  --set "app.envs.AWS_MICROVM_ENDPOINT=http://m80.kube-microvm.svc.cluster.local:4290" \
	  --set "app.envs.AWS_REGION=$(K3S_XPRESS_REGION)" \
	  --set "app.envs.AWS_ENDPOINT_URL_STS=http://m80.kube-microvm.svc.cluster.local:4290" \
	  --wait --timeout 6m
	kubectl label namespace default lambda.aws.amazon.com/manage-microvms=true --overwrite

_cluster-down:
	@echo "==> Uninstalling m80 + operator from k3s-xpress (cluster left running)"
	helm uninstall kube-microvm-operator -n kube-microvm --ignore-not-found || true
	kubectl delete deployment m80 -n kube-microvm --ignore-not-found || true
	kubectl delete service m80 m80-node -n kube-microvm --ignore-not-found || true

else
$(error Unknown CLUSTER_PROVIDER '$(CLUSTER_PROVIDER)'. Supported: k3d, k3s-xpress)
endif

# ─── Internal helpers ─────────────────────────────────────────────────────────

_prereq-check:
	@echo "==> Checking prerequisites"
	@for cmd in docker kubectl helm; do \
	  command -v $$cmd >/dev/null 2>&1 || \
	    (echo "ERROR: '$$cmd' not found in PATH" && exit 1); \
	done
ifeq ($(CLUSTER_PROVIDER),k3d)
	@command -v k3d >/dev/null 2>&1 || \
	  (echo "ERROR: k3d not found. Install from https://k3d.io" && exit 1)
	@command -v node >/dev/null 2>&1 || \
	  (echo "ERROR: node not found (needed by m80's cluster config builder)" && exit 1)
	@command -v npm >/dev/null 2>&1 || \
	  (echo "ERROR: npm not found" && exit 1)
endif
	@echo "    docker, kubectl, helm$(if $(filter k3d,$(CLUSTER_PROVIDER)), k3d node npm,) — OK"

_m80-fetch:
	@if [ ! -d "$(M80_DIR)/.git" ]; then \
	  echo "==> Cloning m80 into $(M80_DIR)"; \
	  git clone --depth 1 $(M80_REPO) "$(M80_DIR)"; \
	else \
	  echo "==> m80 already present at $(M80_DIR) (run 'make m80-clean' to reset)"; \
	fi
