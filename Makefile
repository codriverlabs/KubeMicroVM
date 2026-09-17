# KubeMicroVM — developer task runner
#
# Prerequisites for the m80/* targets:
#   docker, k3d (https://k3d.io), kubectl, helm, node >= 20, npm
#
# Quick start:
#   make full                  # clone m80, spin up k3d, run UAT, tear down
#   make m80-up                # bring up the stack only (leave it running)
#   make m80-run               # run the suite against a running stack
#   make m80-down              # tear the cluster down
#
# Overridable variables (all have sensible defaults):
#   CHART_VERSION    KubeMicroVM Helm chart version to install  (default: nearest git tag)
#   M80_IMAGE        m80 container image                        (default: latest release)
#   M80_DIR          where to clone m80                        (default: .m80/)
#   REGION           AWS region passed to the operator          (default: us-east-1)
#   RESULTS          Robot Framework output directory           (default: uat/results/m80/)
#   MAX_ACCOUNT_MEMORY_MIB  m80 memory ceiling                 (default: 262144)
#
# Cluster providers (CLUSTER_PROVIDER variable):
#   k3d (default)    local k3d cluster, follows m80's own harness
#   k3s-xpress       deploy into an existing k3s-xpress cluster (EKS Pod Identity layer);
#                    set K3S_XPRESS_CLUSTER=<kubectl context name>
#
# Examples:
#   make full
#   make m80-up M80_IMAGE=m80:my-branch
#   make full CLUSTER_PROVIDER=k3s-xpress K3S_XPRESS_CLUSTER=my-cluster

# ─── Variables ────────────────────────────────────────────────────────────────

M80_REPO    := https://github.com/INTENTIUS/m80.git
M80_DIR     ?= $(CURDIR)/.m80
M80_IMAGE   ?= ghcr.io/intentius/m80:v0.4.1

# Resolve chart version from nearest git tag; fall back to "main" for
# untagged clones.
CHART_VERSION ?= $(shell git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo main)

REGION                 ?= us-east-1
RESULTS                ?= $(CURDIR)/uat/results/m80
MAX_ACCOUNT_MEMORY_MIB ?= 262144
CLUSTER_PROVIDER       ?= k3d

# k3s-xpress provider — only used when CLUSTER_PROVIDER=k3s-xpress
K3S_XPRESS_CLUSTER ?=
K3S_XPRESS_REGION  ?= $(REGION)

# ─── Phony targets ────────────────────────────────────────────────────────────

.PHONY: full m80-up m80-run m80-down m80-clean m80-deps \
        _m80-fetch _prereq-check _cluster-up _cluster-down \
        build test help

.DEFAULT_GOAL := help

# ─── Help ─────────────────────────────────────────────────────────────────────

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?##' $(MAKEFILE_LIST) | \
	  awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-20s\033[0m %s\n",$$1,$$2}'
	@echo ""
	@echo "  Variables:"
	@echo "    CHART_VERSION=$(CHART_VERSION)"
	@echo "    M80_IMAGE=$(M80_IMAGE)"
	@echo "    M80_DIR=$(M80_DIR)"
	@echo "    REGION=$(REGION)"
	@echo "    RESULTS=$(RESULTS)"
	@echo "    CLUSTER_PROVIDER=$(CLUSTER_PROVIDER)"

# ─── Build & unit tests ───────────────────────────────────────────────────────

build: ## Build all Maven modules (skips tests)
	./mvnw -B --no-transfer-progress clean install -DskipTests -q

test: ## Run unit + integration tests (no cluster needed)
	./mvnw -B --no-transfer-progress clean verify

# ─── Full local UAT (m80 emulator) ───────────────────────────────────────────

full: _prereq-check _m80-fetch ## Clone m80, spin up cluster+operator, run full UAT, tear down
	$(MAKE) m80-up
	$(MAKE) m80-run || ($(MAKE) m80-down; exit 1)
	$(MAKE) m80-down
	@echo ""
	@echo "Results: $(RESULTS)"

m80-up: _prereq-check _m80-fetch _cluster-up ## Bring up cluster + m80 + KubeMicroVM operator
	@echo ""
	@echo "==> Stack is up. Run 'make m80-run' to execute the UAT suite."

m80-run: ## Run KubeMicroVM UAT against the running m80 stack
	@test -d "$(M80_DIR)" || \
	  (echo "ERROR: m80 not found at $(M80_DIR). Run 'make m80-up' first." && exit 1)
	@mkdir -p "$(RESULTS)"
	KUBEMICROVM="$(CURDIR)" \
	RESULTS="$(RESULTS)" \
	REGION="$(REGION)" \
	CHART_VERSION="$(CHART_VERSION)" \
	  "$(M80_DIR)/uat/run.sh"
	@echo ""
	@echo "Results: $(RESULTS)/report.html"

m80-down: _cluster-down ## Tear down the cluster

m80-clean: m80-down ## Tear down cluster and remove the m80 checkout
	rm -rf "$(M80_DIR)"

# ─── Cluster providers ────────────────────────────────────────────────────────

ifeq ($(CLUSTER_PROVIDER),k3d)

NS ?= kube-microvm

# Prefer a locally-built chart tgz over the OCI registry — allows testing
# chart changes (like ClusterIssuer hook fixes) without a release.
LOCAL_CHART := $(shell find $(CURDIR)/operator-controller/target/helm/kubernetes -name "*.tgz" 2>/dev/null | head -1)
CHART_REF   := $(if $(LOCAL_CHART),$(LOCAL_CHART),oci://ghcr.io/codriverlabs/helm/kube-microvm-operator)

_cluster-up:
	@echo "==> Bringing up k3d cluster (m80 + KubeMicroVM operator v$(CHART_VERSION))"
	@echo "    Chart: $(CHART_REF)"
	@# m80's up.sh installs whatever CHART_VERSION is set to. When CHART_VERSION is
	@# unset, it defaults to 1.0.12 (pre-ClusterIssuer). We unset it so up.sh
	@# installs 1.0.12 successfully, then do a clean uninstall and fresh install of
	@# our target version. Helm upgrade is not used — ClusterRoleBinding.roleRef and
	@# Deployment.spec.selector are immutable between versions.
	M80_IMAGE="$(M80_IMAGE)" \
	REGION="$(REGION)" \
	MAX_ACCOUNT_MEMORY_MIB="$(MAX_ACCOUNT_MEMORY_MIB)" \
	M80_DIR="$(M80_DIR)" \
	CHART_REF="$(CHART_REF)" \
	  env -u CHART_VERSION "$(CURDIR)/uat/m80-up-wrapper.sh"
	@echo "==> Uninstalling chart 1.0.12 and doing fresh install of v$(CHART_VERSION)"
	helm uninstall kube-microvm-operator -n "$(NS)" --wait 2>/dev/null || true
	helm install kube-microvm-operator "$(CHART_REF)" \
	  --version "$(CHART_VERSION)" -n "$(NS)" \
	  --set "app.envs.AWS_MICROVM_ENDPOINT=http://m80.$(NS).svc.cluster.local:4290" \
	  --set "app.envs.AWS_REGION=$(REGION)" \
	  --wait --timeout 5m
	kubectl -n "$(NS)" set env deploy/kube-microvm-operator \
	  AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test \
	  AWS_EC2_METADATA_DISABLED=true \
	  "AWS_ENDPOINT_URL_STS=http://m80.$(NS).svc.cluster.local:4290" 2>/dev/null || true
	kubectl -n "$(NS)" rollout status deploy/kube-microvm-operator --timeout=120s
	kubectl label namespace default lambda.aws.amazon.com/manage-microvms=true --overwrite

_cluster-down:
	@echo "==> Tearing down k3d cluster"
	k3d cluster delete m80-uat 2>/dev/null || true

else ifeq ($(CLUSTER_PROVIDER),k3s-xpress)

# k3s-xpress: deploy m80 + operator into an existing k3s-xpress cluster
# (EKS Pod Identity layer included — no static credentials needed).
# The run step is provider-agnostic; only cluster setup/teardown differ.
_cluster-up:
	@test -n "$(K3S_XPRESS_CLUSTER)" || \
	  (echo "ERROR: set K3S_XPRESS_CLUSTER=<kubectl context name>" && exit 1)
	K3S_XPRESS_CLUSTER="$(K3S_XPRESS_CLUSTER)" \
	M80_IMAGE="$(M80_IMAGE)" \
	CHART_VERSION="$(CHART_VERSION)" \
	REGION="$(K3S_XPRESS_REGION)" \
	MAX_ACCOUNT_MEMORY_MIB="$(MAX_ACCOUNT_MEMORY_MIB)" \
	  $(CURDIR)/uat/k3s-xpress-up.sh

_cluster-down:
	@echo "==> Removing m80 + operator from k3s-xpress (cluster itself left running)"
	helm uninstall kube-microvm-operator -n kube-microvm --ignore-not-found 2>/dev/null || true
	kubectl delete deploy m80 svc/m80 svc/m80-node -n kube-microvm --ignore-not-found 2>/dev/null || true

else
$(error Unknown CLUSTER_PROVIDER='$(CLUSTER_PROVIDER)'. Supported values: k3d, k3s-xpress)
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
	  (echo "ERROR: k3d not found — install from https://k3d.io" && exit 1)
	@command -v node >/dev/null 2>&1 || \
	  (echo "ERROR: node not found (needed by m80's cluster config builder)" && exit 1)
	@command -v npm >/dev/null 2>&1 || \
	  (echo "ERROR: npm not found" && exit 1)
endif
	@echo "    OK"

_m80-fetch:
	@if [ ! -d "$(M80_DIR)/.git" ]; then \
	  echo "==> Cloning m80 into $(M80_DIR)"; \
	  git clone --depth 1 $(M80_REPO) "$(M80_DIR)"; \
	else \
	  echo "==> m80 already present at $(M80_DIR) (run 'make m80-clean' to reset)"; \
	fi

# ─── UAT report enrichment ────────────────────────────────────────────────────

UAT_RESULTS ?= $(CURDIR)/uat/results/m80
DOCS_BASE_URL ?= https://docs.codriverlabs.ai/kubemicrovm

uat-report: ## Merge suite outputs + inject doc links + regenerate HTML report
	@echo "==> Merging UAT outputs from $(UAT_RESULTS)"
	@python3 -m robot.rebot \
	  --outputdir $(UAT_RESULTS)/merged \
	  --output output.xml --nostatusrc \
	  $(UAT_RESULTS)/*/output.xml
	@echo "==> Enriching with documentation links (base: $(DOCS_BASE_URL))"
	@python3 $(CURDIR)/uat/scripts/enrich-report.py \
	  --input  $(UAT_RESULTS)/merged/output.xml \
	  --output $(UAT_RESULTS)/merged/output-enriched.xml \
	  --base-url $(DOCS_BASE_URL)
	@python3 -m robot.rebot \
	  --outputdir $(UAT_RESULTS)/report \
	  --nostatusrc \
	  $(UAT_RESULTS)/merged/output-enriched.xml
	@echo "Report: $(UAT_RESULTS)/report/report.html"
