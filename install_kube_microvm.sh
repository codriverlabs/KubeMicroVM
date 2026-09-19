#!/usr/bin/env bash
# install_kube_microvm.sh — KubeMicroVM installer (Community and PRO)
#
# Usage:
#   ./install_kube_microvm.sh [options]
#
# Options:
#   --cluster    <name>   EKS cluster name (required for --iam and helm install)
#   --region     <name>   AWS region (default: us-east-1)
#   --registry   <url>    Private registry URL — import images here (e.g. 123456789.dkr.ecr.us-east-1.amazonaws.com)
#   --iam                 Create IAM role + Pod Identity association via CloudFormation
#   --role-arn   <arn>    Use existing IAM role ARN (skips --iam)
#   --edition    <name>   Edition to install: community (default) or pro
#   --registry-token <t>  GHCR PAT for PRO edition (required when --edition pro and no --registry)
#   --pro-version <ver>   PRO chart/image version to install (default: latest from GHCR)
#
#   --cli-only            Only install the microvm CLI (skip Helm installs)
#   --dry-run             Print what would be done without executing
#   --help                Show this help
#
# Examples:
#   # Community — full install with IAM setup
#   ./install_kube_microvm.sh --cluster my-cluster --region us-east-1 --iam
#
#   # PRO — full install with GHCR token
#   ./install_kube_microvm.sh --cluster my-cluster --region us-east-1 --iam \
#     --edition pro --registry-token <GHCR_PAT>
#
#   # PRO — with private ECR mirror (air-gapped)
#   ./install_kube_microvm.sh --cluster my-cluster --region us-east-1 --iam \
#     --edition pro --registry 123456789.dkr.ecr.us-east-1.amazonaws.com
#
#   # Install using existing IAM role
#   ./install_kube_microvm.sh --cluster my-cluster --region us-east-1 \
#     --role-arn arn:aws:iam::123456789:role/kube-microvm-operator

set -euo pipefail

# ─── Defaults ─────────────────────────────────────────────────────────────────
CLUSTER=""
REGION="${AWS_REGION:-us-east-1}"
REGISTRY=""
ROLE_ARN=""
DO_IAM=false

# Edition — community or pro
EDITION="${KUBE_MICROVM_EDITION:-community}"
REGISTRY_TOKEN="${KUBE_MICROVM_REGISTRY_TOKEN:-}"
PRO_VERSION="${KUBE_MICROVM_PRO_VERSION:-}"

# Private Helm registry — for air-gapped/enterprise deployments
# If unset: Community charts pulled from GHCR (public), PRO charts from private GHCR
# If set: charts pulled from <helm-registry>/codriverlabs/helm/<chart-name>
# For ECR: same URL as --registry (e.g. 123456789.dkr.ecr.us-east-1.amazonaws.com)
HELM_REGISTRY="${KUBE_MICROVM_HELM_REGISTRY:-}"
HELM_REGISTRY_USER="${KUBE_MICROVM_HELM_REGISTRY_USER:-}"
HELM_REGISTRY_TOKEN="${KUBE_MICROVM_HELM_REGISTRY_TOKEN:-}"

CLI_ONLY=false
DRY_RUN=false
INSTALL_DIR="${HOME}/bin"
CONFIG_DIR="${HOME}/.kube-microvm"
CONFIG_FILE="${CONFIG_DIR}/config"

# Quota overrides — defaults match AWS account-level defaults
# Populated automatically at install time via aws service-quotas get-service-quota
QUOTA_RUN_MICROVM_RATE=""
QUOTA_TERMINATE_MICROVM_RATE=""
QUOTA_SUSPEND_MICROVM_RATE=""
QUOTA_RESUME_MICROVM_RATE=""
QUOTA_AUTH_TOKEN_RATE=""
QUOTA_CONCURRENT_IMAGE_BUILDS=""
QUOTA_DISCOVERY_RUNTIME=false

# Resolved at runtime
VERSION="${KUBE_MICROVM_VERSION:-}"

# Community image/chart coordinates (public GHCR)
GHCR_OPERATOR="ghcr.io/codriverlabs/kube-microvm-operator"
GHCR_AGENT="ghcr.io/codriverlabs/microvm-auth-agent"
GHCR_HELM="oci://ghcr.io/codriverlabs/helm"

# PRO image/chart coordinates (private GHCR)
GHCR_PRO_OPERATOR="ghcr.io/codriverlabs/kubemicrovm-pro/kube-microvm-operator-pro"
GHCR_PRO_GATEWAY="ghcr.io/codriverlabs/kubemicrovm-pro/microvm-gateway"
GHCR_PRO_HELM="oci://ghcr.io/codriverlabs/kubemicrovm-pro/helm"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Version resolution ───────────────────────────────────────────────────────
resolve_version() {
    [[ -n "$VERSION" ]] && return 0
    if [[ -f "${SCRIPT_DIR}/VERSION" ]]; then
        VERSION=$(cat "${SCRIPT_DIR}/VERSION")
        info "Version from bundle: $VERSION"
        return 0
    fi
    info "Resolving latest Community version from GitHub..."
    VERSION=$(curl -fsSL \
        "https://api.github.com/repos/codriverlabs/KubeMicroVM/releases/latest" \
        2>/dev/null | grep '"tag_name"' | grep -oP 'v[\d.]+(-rc\d+)?' | head -1)
    if [[ -z "$VERSION" ]]; then
        error "Could not resolve version. Set KUBE_MICROVM_VERSION env var."
        exit 1
    fi
    info "Latest Community version: $VERSION"
}

resolve_pro_version() {
    [[ -n "$PRO_VERSION" ]] && return 0
    info "Resolving latest PRO version from GHCR..."
    # Resolve from GHCR OCI tags using helm CLI if available
    if command -v helm &>/dev/null && [[ -n "$REGISTRY_TOKEN" ]]; then
        PRO_VERSION=$(helm show chart \
            "${GHCR_PRO_HELM}/kube-microvm-pro" \
            --registry-config /dev/stdin <<< \
            "{\"auths\":{\"ghcr.io\":{\"auth\":\"$(echo -n "token:${REGISTRY_TOKEN}" | base64)\"}}}" \
            2>/dev/null | grep '^version:' | awk '{print $2}' | head -1 || echo "")
    fi
    if [[ -z "$PRO_VERSION" ]]; then
        warn "Could not auto-resolve PRO version — defaulting to Community version ${VERSION#v}"
        warn "Override with: --pro-version <version> or KUBE_MICROVM_PRO_VERSION env var"
        PRO_VERSION="${VERSION#v}"
    fi
    info "PRO version: $PRO_VERSION"
}

# ─── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
step()    { echo -e "\n${BOLD}==> $*${NC}"; }
run()     { if $DRY_RUN; then echo -e "${YELLOW}[DRY-RUN]${NC} $*"; else eval "$*"; fi; }

# ─── Parse arguments ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --cluster)           CLUSTER="$2";          shift 2 ;;
        --region)            REGION="$2";            shift 2 ;;
        --registry)          REGISTRY="$2";          shift 2 ;;
        --role-arn)          ROLE_ARN="$2";          shift 2 ;;
        --iam)               DO_IAM=true;            shift ;;
        --edition)           EDITION="$2";           shift 2 ;;
        --registry-token)    REGISTRY_TOKEN="$2";    shift 2 ;;
        --pro-version)       PRO_VERSION="$2";       shift 2 ;;
        --helm-registry)     HELM_REGISTRY="$2";     shift 2 ;;
        --helm-registry-user)  HELM_REGISTRY_USER="$2";  shift 2 ;;
        --helm-registry-token) HELM_REGISTRY_TOKEN="$2"; shift 2 ;;

        --quota-run-microvm-rate)         QUOTA_RUN_MICROVM_RATE="$2";         shift 2 ;;
        --quota-terminate-microvm-rate)   QUOTA_TERMINATE_MICROVM_RATE="$2";   shift 2 ;;
        --quota-suspend-microvm-rate)     QUOTA_SUSPEND_MICROVM_RATE="$2";     shift 2 ;;
        --quota-resume-microvm-rate)      QUOTA_RESUME_MICROVM_RATE="$2";      shift 2 ;;
        --quota-auth-token-rate)          QUOTA_AUTH_TOKEN_RATE="$2";          shift 2 ;;
        --quota-concurrent-image-builds)  QUOTA_CONCURRENT_IMAGE_BUILDS="$2";  shift 2 ;;
        --no-quota-discovery)             QUOTA_RUN_MICROVM_RATE="${QUOTA_RUN_MICROVM_RATE:-skip}"; shift ;;
        --quota-discovery=runtime)        QUOTA_DISCOVERY_RUNTIME=true;        shift ;;

        --cli-only)  CLI_ONLY=true;  shift ;;
        --dry-run)   DRY_RUN=true;   shift ;;
        --help|-h)
            cat <<'HELP'
install_kube_microvm.sh — KubeMicroVM installer (Community and PRO)

Usage:
  ./install_kube_microvm.sh [options]

Options:
  --cluster    <name>   EKS cluster name (required for --iam and helm install)
  --region     <name>   AWS region (default: us-east-1)
  --registry   <url>    Private registry URL (e.g. 123456789.dkr.ecr.us-east-1.amazonaws.com)
  --iam                 Create IAM role + Pod Identity association via CloudFormation
  --role-arn   <arn>    Use existing IAM role ARN (skips --iam)
  --edition    <name>   Edition to install: community (default) or pro
  --registry-token <t>  GHCR PAT for PRO edition (or set KUBE_MICROVM_REGISTRY_TOKEN)
  --pro-version <ver>   PRO chart/image version (default: auto-resolved from GHCR)
  --helm-registry <url> Private Helm OCI registry (default: GHCR)
                        For ECR: same URL as --registry
                        e.g. 123456789.dkr.ecr.us-east-1.amazonaws.com
  --helm-registry-user <u>   Helm registry username (default: AWS for ECR, token for GHCR-like)
  --helm-registry-token <t>  Helm registry password/token

  # Quota — auto-discovered by default via aws service-quotas get-service-quota
  --no-quota-discovery               Skip quota discovery, use AWS defaults
  --quota-discovery=runtime          Operator queries quotas on startup
  --quota-run-microvm-rate    <N>    Override RunMicrovm rate/s
  --quota-terminate-microvm-rate <N> Override TerminateMicrovm rate/s
  --quota-suspend-microvm-rate <N>   Override SuspendMicrovm rate/s
  --quota-resume-microvm-rate  <N>   Override ResumeMicrovm rate/s
  --quota-auth-token-rate      <N>   Override CreateMicrovmAuthToken rate/s
  --quota-concurrent-image-builds <N> Override concurrent image build limit

  --cli-only            Only install the microvm CLI (skip Helm installs)
  --dry-run             Print what would be done without executing
  --help                Show this help

Environment variables:
  KUBE_MICROVM_VERSION             Pin Community version (e.g. v1.0.17)
  KUBE_MICROVM_EDITION             community or pro (same as --edition)
  KUBE_MICROVM_REGISTRY_TOKEN      GHCR PAT for PRO (same as --registry-token)
  KUBE_MICROVM_PRO_VERSION         Pin PRO version (same as --pro-version)
  KUBE_MICROVM_HELM_REGISTRY       Private Helm OCI registry URL
  KUBE_MICROVM_HELM_REGISTRY_USER  Helm registry username
  KUBE_MICROVM_HELM_REGISTRY_TOKEN Helm registry password/token

Examples:
  # Community — full install with IAM setup
  ./install_kube_microvm.sh --cluster my-cluster --region us-east-1 --iam

  # PRO — GHCR token (Helm + images from private GHCR)
  ./install_kube_microvm.sh --cluster my-cluster --region us-east-1 --iam \
    --edition pro --registry-token <GHCR_PAT>

  # PRO — air-gapped: images + Helm charts both mirrored to private ECR
  ./install_kube_microvm.sh --cluster my-cluster --region us-east-1 --iam \
    --edition pro \
    --registry 123456789.dkr.ecr.us-east-1.amazonaws.com \
    --helm-registry 123456789.dkr.ecr.us-east-1.amazonaws.com

  # PRO — separate container + Helm registries (Harbor, Nexus, etc.)
  ./install_kube_microvm.sh --cluster my-cluster --region us-east-1 --iam \
    --edition pro \
    --registry my-harbor.example.com \
    --helm-registry my-harbor.example.com \
    --helm-registry-user admin --helm-registry-token <password>

  # PRO — use existing IAM role, skip IAM step
  ./install_kube_microvm.sh --cluster my-cluster --region us-east-1 \
    --edition pro --registry-token <GHCR_PAT> \
    --role-arn arn:aws:iam::123456789:role/kube-microvm-operator

  # CLI only
  ./install_kube_microvm.sh --cli-only
HELP
            exit 0 ;;
        *) error "Unknown option: $1"; exit 1 ;;
    esac
done

# Validate edition
case "$EDITION" in
    community|pro) ;;
    *) error "Unknown edition: $EDITION (must be 'community' or 'pro')"; exit 1 ;;
esac

# PRO requires a registry token (or a private registry mirror)
if [[ "$EDITION" == "pro" ]] && ! $CLI_ONLY; then
    if [[ -z "$REGISTRY_TOKEN" && -z "$REGISTRY" ]]; then
        error "PRO edition requires --registry-token <GHCR_PAT> or --registry <private-url>"
        error "Get your GHCR PAT from https://github.com/settings/tokens (read:packages scope)"
        exit 1
    fi
fi

# ─── Detect arch ──────────────────────────────────────────────────────────────
ARCH="$(uname -m)"
case "$ARCH" in
    x86_64)        ARCH_TAG="amd64" ;;
    aarch64|arm64) ARCH_TAG="arm64" ;;
    *) error "Unsupported architecture: $ARCH"; exit 1 ;;
esac

# ─── Prerequisites check ──────────────────────────────────────────────────────
check_cmd() {
    command -v "$1" &>/dev/null || { error "Required tool not found: $1"; exit 1; }
}

check_prerequisites() {
    step "Checking prerequisites"
    check_cmd curl
    if ! $CLI_ONLY; then
        check_cmd kubectl
        check_cmd helm
        check_cmd aws
        [[ -n "$CLUSTER" ]] || { error "--cluster is required (unless --cli-only)"; exit 1; }
    fi
    success "Prerequisites OK (arch: $ARCH_TAG, edition: $EDITION)"
}

# ─── cert-manager check ───────────────────────────────────────────────────────
ensure_cert_manager() {
    step "Checking cert-manager"
    if kubectl get crd certificates.cert-manager.io &>/dev/null; then
        success "cert-manager CRDs found"
        return
    fi

    warn "cert-manager is not installed — the operator chart requires Certificate and Issuer CRDs."
    echo ""
    echo "  Install cert-manager with:"
    echo "    kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml"
    echo ""
    read -rp "  Install cert-manager now? [Y/n] " answer
    answer="${answer:-Y}"
    if [[ "$answer" =~ ^[Yy] ]]; then
        info "Installing cert-manager..."
        kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
        info "Waiting for cert-manager webhook to become ready..."
        kubectl wait --for=condition=Available deployment/cert-manager-webhook \
            -n cert-manager --timeout=120s
        success "cert-manager installed"
    else
        error "cert-manager is required. Install it manually and re-run the installer."
        exit 1
    fi
}

# ─── GHCR auth for PRO ────────────────────────────────────────────────────────
ghcr_login_pro() {
    [[ "$EDITION" != "pro" ]] && return 0
    [[ -z "$REGISTRY_TOKEN" ]] && return 0  # using private registry mirror — no GHCR auth needed
    info "Authenticating with GHCR for PRO images..."
    run "echo ${REGISTRY_TOKEN} | helm registry login ghcr.io --username token --password-stdin"
    success "GHCR authenticated"
}

ghcr_logout_pro() {
    [[ "$EDITION" != "pro" ]] && return 0
    [[ -z "$REGISTRY_TOKEN" ]] && return 0
    helm registry logout ghcr.io 2>/dev/null || true
}

# Private Helm registry login/logout — used when --helm-registry is set.
# Supports ECR (auto-detects, uses aws ecr get-login-password) and generic
# OCI registries (uses --helm-registry-user / --helm-registry-token).
_helm_registry_login() {
    local registry="$1"
    if [[ "$registry" == *".ecr."* ]]; then
        # ECR: token from aws CLI, username always "AWS"
        local ecr_region
        ecr_region=$(echo "$registry" | grep -oP 'ecr\.\K[a-z0-9-]+(?=\.)')
        info "Helm registry login (ECR): $registry"
        run "aws ecr get-login-password --region $ecr_region | \
            helm registry login $registry --username AWS --password-stdin"
    elif [[ -n "$HELM_REGISTRY_TOKEN" ]]; then
        local user="${HELM_REGISTRY_USER:-token}"
        info "Helm registry login: $registry (user: $user)"
        run "echo ${HELM_REGISTRY_TOKEN} | helm registry login $registry --username $user --password-stdin"
    elif [[ -n "$REGISTRY_TOKEN" && "$EDITION" == "pro" ]]; then
        # Fall back to PRO GHCR token for GHCR-compatible registries
        info "Helm registry login (PRO token): $registry"
        run "echo ${REGISTRY_TOKEN} | helm registry login $registry --username token --password-stdin"
    else
        warn "No Helm registry credentials — login skipped for $registry"
        warn "Provide --helm-registry-token or --registry-token (PRO)"
    fi
}

_helm_registry_logout() {
    [[ -z "$HELM_REGISTRY" ]] && return 0
    helm registry logout "$HELM_REGISTRY" 2>/dev/null || true
}

# ─── Load/save config ─────────────────────────────────────────────────────────
load_config() {
    mkdir -p "$CONFIG_DIR"
    [[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE" || true
}

save_config() {
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_FILE" <<EOF
# KubeMicroVM installer config — written by install_kube_microvm.sh
KUBE_MICROVM_VERSION="${VERSION}"
KUBE_MICROVM_EDITION="${EDITION}"
KUBE_MICROVM_REGISTRY="${REGISTRY}"
KUBE_MICROVM_REGION="${REGION}"
KUBE_MICROVM_CLUSTER="${CLUSTER}"
KUBE_MICROVM_ROLE_ARN="${ROLE_ARN}"
EOF
    [[ -n "$PRO_VERSION" ]]     && echo "KUBE_MICROVM_PRO_VERSION=\"${PRO_VERSION}\"" >> "$CONFIG_FILE"
    [[ -n "$HELM_REGISTRY" ]]   && echo "KUBE_MICROVM_HELM_REGISTRY=\"${HELM_REGISTRY}\"" >> "$CONFIG_FILE"
    info "Config saved to $CONFIG_FILE"
}

# ─── a. Private registry image import ─────────────────────────────────────────
import_images() {
    [[ -z "$REGISTRY" ]] && return 0
    step "a. Importing images into private registry: $REGISTRY"

    # ECR login
    if [[ "$REGISTRY" == *".ecr."* ]]; then
        ACCOUNT_ID="${REGISTRY%%.*}"
        ECR_REGION=$(echo "$REGISTRY" | grep -oP 'ecr\.\K[a-z0-9-]+(?=\.)')
        info "ECR login for $REGISTRY"
        run "aws ecr get-login-password --region $ECR_REGION | \
            docker login --username AWS --password-stdin $REGISTRY"
    fi

    if [[ "$EDITION" == "community" ]]; then
        IMAGES=("kube-microvm-operator" "microvm-auth-agent")
        SRC_BASE="ghcr.io/codriverlabs"
    else
        # PRO — authenticate GHCR if token provided
        if [[ -n "$REGISTRY_TOKEN" ]]; then
            run "echo ${REGISTRY_TOKEN} | docker login ghcr.io --username token --password-stdin"
        fi
        IMAGES=("kubemicrovm-pro/kube-microvm-operator-pro" "kubemicrovm-pro/microvm-gateway" "microvm-auth-agent")
        SRC_BASE="ghcr.io/codriverlabs"
    fi

    for IMAGE_PATH in "${IMAGES[@]}"; do
        IMAGE_NAME="${IMAGE_PATH##*/}"
        SRC_REPO="${SRC_BASE}/${IMAGE_PATH}"
        DST_REPO="${REGISTRY}/codriverlabs/${IMAGE_NAME}"
        TAG="${IMAGE_TAG}"
        # auth-agent always uses Community tag even in PRO
        [[ "$IMAGE_NAME" == "microvm-auth-agent" ]] && TAG="${IMAGE_TAG}"

        if [[ "$REGISTRY" == *".ecr."* ]]; then
            info "Ensuring ECR repo: codriverlabs/${IMAGE_NAME}"
            run "aws ecr create-repository \
                --repository-name codriverlabs/${IMAGE_NAME} \
                --region ${ECR_REGION} 2>/dev/null || true"
        fi

        for ARCH in amd64 arm64; do
            SRC="${SRC_REPO}:${TAG}-${ARCH}"
            info "  $SRC → ${DST_REPO}:${TAG}-${ARCH}"
            run "docker pull --platform linux/${ARCH} $SRC"
            run "docker tag $SRC ${DST_REPO}:${TAG}-${ARCH}"
            run "docker push ${DST_REPO}:${TAG}-${ARCH}"
        done

        run "docker manifest create ${DST_REPO}:${TAG} \
            ${DST_REPO}:${TAG}-amd64 \
            ${DST_REPO}:${TAG}-arm64"
        run "docker manifest push ${DST_REPO}:${TAG}"
        success "Pushed $IMAGE_NAME → $REGISTRY"
    done
}

# ─── b. IAM role + Pod Identity ───────────────────────────────────────────────
# Both Community and PRO use the same IAM role: kube-microvm-operator
# The CloudFormation template is published with the Community release and
# is authoritative for both editions.
setup_iam() {
    ! $DO_IAM && [[ -z "$ROLE_ARN" ]] && return 0
    [[ -n "$ROLE_ARN" ]] && { info "Using existing role: $ROLE_ARN"; return 0; }

    step "b. Setting up IAM role + Pod Identity"
    info "IAM role name: kube-microvm-operator (shared across Community and PRO)"

    STACK_NAME="kube-microvm-operator-role-${CLUSTER}"
    IAM_TEMPLATE="${SCRIPT_DIR}/iam/kube-microvm-operator-role.yaml"

    # Download IAM template from Community release (authoritative for both editions)
    if [[ ! -f "$IAM_TEMPLATE" ]]; then
        info "Downloading IAM CloudFormation template from Community release ${VERSION}..."
        RELEASE_BASE="https://github.com/codriverlabs/KubeMicroVM/releases/download/${VERSION}"
        mkdir -p "${SCRIPT_DIR}/iam"
        run "curl -fsSL ${RELEASE_BASE}/kube-microvm-operator-role.yaml -o $IAM_TEMPLATE"
        run "curl -fsSL ${RELEASE_BASE}/kube-microvm-operator-role.yaml.sha256 -o ${IAM_TEMPLATE}.sha256"
        info "Verifying IAM template checksum..."
        if ! sha256sum -c "${IAM_TEMPLATE}.sha256" 2>/dev/null; then
            error "Checksum verification failed for IAM template!"
            rm -f "$IAM_TEMPLATE" "${IAM_TEMPLATE}.sha256"
            exit 1
        fi
        success "IAM template verified"
    fi

    info "Deploying CloudFormation stack: $STACK_NAME"
    run "aws cloudformation deploy \
        --stack-name $STACK_NAME \
        --template-file $IAM_TEMPLATE \
        --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM \
        --parameter-overrides ClusterName=$CLUSTER \
        --region $REGION"

    ROLE_ARN=$(aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --region "$REGION" \
        --query 'Stacks[0].Outputs[?OutputKey==`RoleArn`].OutputValue' \
        --output text 2>/dev/null)

    info "Configuring IAM role for operator service account"

    if aws eks list-pod-identity-associations --cluster-name "$CLUSTER" --region "$REGION" &>/dev/null; then
        info "EKS Pod Identity detected — creating association"
        run "aws eks create-pod-identity-association \
            --cluster-name $CLUSTER \
            --namespace kube-microvm \
            --service-account kube-microvm-operator \
            --role-arn $ROLE_ARN \
            --region $REGION 2>/dev/null || true"
        success "Pod Identity association created: $ROLE_ARN"

    elif command -v eks-dx &>/dev/null; then
        info "EKS-DX detected — configuring Pod Identity via eks-dx CLI"
        ROLE_NAME="${ROLE_ARN##*/}"
        run "aws iam tag-role --role-name $ROLE_NAME \
            --tags Key=eks-dx-managed,Value=true"
        run "eks-dx create-pod-identity-association \
            --cluster $CLUSTER \
            --namespace kube-microvm \
            --service-account kube-microvm-operator \
            --role-arn $ROLE_ARN"
        success "EKS-DX Pod Identity association created: $ROLE_ARN"

    else
        info "Pod Identity not available — configuring IRSA annotation"
        run "kubectl annotate serviceaccount kube-microvm-operator \
            -n kube-microvm \
            eks.amazonaws.com/role-arn=$ROLE_ARN \
            --overwrite 2>/dev/null || true"
        run "kubectl rollout restart deployment kube-microvm-operator -n kube-microvm 2>/dev/null || true"
        success "IRSA annotation set: $ROLE_ARN"
    fi

    success "IAM role: $ROLE_ARN"
}

# ─── b2. Quota discovery ──────────────────────────────────────────────────────
discover_quotas() {
    step "b2. Discovering AWS Lambda MicroVMs service quotas"

    local all_set=true
    for v in "$QUOTA_RUN_MICROVM_RATE" "$QUOTA_TERMINATE_MICROVM_RATE" \
              "$QUOTA_SUSPEND_MICROVM_RATE" "$QUOTA_RESUME_MICROVM_RATE" \
              "$QUOTA_AUTH_TOKEN_RATE" "$QUOTA_CONCURRENT_IMAGE_BUILDS"; do
        [[ -z "$v" ]] && all_set=false && break
    done
    $all_set && { info "All quota values explicitly set — skipping discovery"; return 0; }

    local SQ_RUN="L-91B95582"
    local SQ_TERMINATE="L-2CCA0501"
    local SQ_SUSPEND="L-139F9A48"
    local SQ_RESUME="L-25EEC0A4"
    local SQ_AUTH_TOKEN="L-D65D9F16"
    local SQ_IMAGE_BUILDS="L-72E0D058"

    get_quota() {
        local code="$1" fallback="$2"
        local val
        val=$(aws service-quotas get-service-quota \
            --service-code lambda \
            --quota-code "$code" \
            --region "${REGION}" \
            --query "Quota.Value" \
            --output text 2>/dev/null | cut -d. -f1)
        [[ -n "$val" && "$val" =~ ^[0-9]+$ ]] && echo "$val" || echo "$fallback"
    }

    if aws service-quotas get-service-quota \
           --service-code lambda \
           --quota-code "$SQ_RUN" \
           --region "${REGION}" \
           --query "Quota.Value" \
           --output text &>/dev/null; then

        [[ -z "$QUOTA_RUN_MICROVM_RATE" ]]        && QUOTA_RUN_MICROVM_RATE=$(get_quota "$SQ_RUN" 5)
        [[ -z "$QUOTA_TERMINATE_MICROVM_RATE" ]]  && QUOTA_TERMINATE_MICROVM_RATE=$(get_quota "$SQ_TERMINATE" 10)
        [[ -z "$QUOTA_SUSPEND_MICROVM_RATE" ]]    && QUOTA_SUSPEND_MICROVM_RATE=$(get_quota "$SQ_SUSPEND" 2)
        [[ -z "$QUOTA_RESUME_MICROVM_RATE" ]]     && QUOTA_RESUME_MICROVM_RATE=$(get_quota "$SQ_RESUME" 5)
        [[ -z "$QUOTA_AUTH_TOKEN_RATE" ]]         && QUOTA_AUTH_TOKEN_RATE=$(get_quota "$SQ_AUTH_TOKEN" 50)
        [[ -z "$QUOTA_CONCURRENT_IMAGE_BUILDS" ]] && QUOTA_CONCURRENT_IMAGE_BUILDS=$(get_quota "$SQ_IMAGE_BUILDS" 10)

        success "Quotas discovered: run=${QUOTA_RUN_MICROVM_RATE}/s terminate=${QUOTA_TERMINATE_MICROVM_RATE}/s" \
                "suspend=${QUOTA_SUSPEND_MICROVM_RATE}/s authToken=${QUOTA_AUTH_TOKEN_RATE}/s" \
                "imageBuilds=${QUOTA_CONCURRENT_IMAGE_BUILDS}"
    else
        warn "Cannot query service quotas — using AWS defaults"
        QUOTA_RUN_MICROVM_RATE="${QUOTA_RUN_MICROVM_RATE:-5}"
        QUOTA_TERMINATE_MICROVM_RATE="${QUOTA_TERMINATE_MICROVM_RATE:-10}"
        QUOTA_SUSPEND_MICROVM_RATE="${QUOTA_SUSPEND_MICROVM_RATE:-2}"
        QUOTA_RESUME_MICROVM_RATE="${QUOTA_RESUME_MICROVM_RATE:-5}"
        QUOTA_AUTH_TOKEN_RATE="${QUOTA_AUTH_TOKEN_RATE:-50}"
        QUOTA_CONCURRENT_IMAGE_BUILDS="${QUOTA_CONCURRENT_IMAGE_BUILDS:-10}"
    fi
}

# ─── c. helm install operator ─────────────────────────────────────────────────
install_operator() {
    if [[ "$EDITION" == "pro" ]]; then
        install_operator_pro
    else
        install_operator_community
    fi
}

install_operator_community() {
    step "c. Installing kube-microvm-operator (Community) Helm chart"

    if [[ -f "${SCRIPT_DIR}/charts/kube-microvm-operator-${HELM_VERSION}.tar.gz" ]]; then
        CHART="${SCRIPT_DIR}/charts/kube-microvm-operator-${HELM_VERSION}.tar.gz"
        info "Using bundled chart: $CHART"
    elif [[ -n "$HELM_REGISTRY" ]]; then
        CHART="oci://${HELM_REGISTRY}/codriverlabs/helm/kube-microvm-operator --version $HELM_VERSION"
        info "Using private Helm registry: $CHART"
        _helm_registry_login "$HELM_REGISTRY"
    else
        CHART="${GHCR_HELM}/kube-microvm-operator --version $HELM_VERSION"
        info "Using GHCR chart: $CHART"
    fi

    OPERATOR_IMAGE="${GHCR_OPERATOR}:${IMAGE_TAG}"
    [[ -n "$REGISTRY" ]] && OPERATOR_IMAGE="${REGISTRY}/codriverlabs/kube-microvm-operator:${IMAGE_TAG}"

    AGENT_IMAGE="${GHCR_AGENT}:${IMAGE_TAG}"
    [[ -n "$REGISTRY" ]] && AGENT_IMAGE="${REGISTRY}/codriverlabs/microvm-auth-agent:${IMAGE_TAG}"

    run "kubectl create namespace kube-microvm --dry-run=client -o yaml | kubectl apply -f -"

    HELM_ARGS="--namespace kube-microvm \
        --set app.image=${OPERATOR_IMAGE} \
        --set app.envs.AWS_REGION=${REGION} \
        --set app.envs.MICROVM_AUTH_AGENT_IMAGE=${AGENT_IMAGE} \
        --timeout 4m --wait"

    [[ -n "$ROLE_ARN" ]] && HELM_ARGS="$HELM_ARGS --set serviceAccount.roleArn=${ROLE_ARN}"
    _append_quota_args

    run "helm upgrade --install kube-microvm-operator $CHART $HELM_ARGS"
    success "kube-microvm-operator (Community) installed"
}

install_operator_pro() {
    step "c. Installing kube-microvm-pro (PRO) Helm chart"

    if [[ -f "${SCRIPT_DIR}/charts/kube-microvm-pro-${PRO_HELM_VERSION}.tar.gz" ]]; then
        CHART="${SCRIPT_DIR}/charts/kube-microvm-pro-${PRO_HELM_VERSION}.tar.gz"
        info "Using bundled PRO chart: $CHART"
    elif [[ -n "$HELM_REGISTRY" ]]; then
        CHART="oci://${HELM_REGISTRY}/codriverlabs/kubemicrovm-pro/helm/kube-microvm-pro --version $PRO_HELM_VERSION"
        info "Using private Helm registry: $CHART"
        _helm_registry_login "$HELM_REGISTRY"
    else
        CHART="${GHCR_PRO_HELM}/kube-microvm-pro --version $PRO_HELM_VERSION"
        info "Using GHCR PRO chart: $CHART (authenticated)"
    fi

    OPERATOR_IMAGE="${GHCR_PRO_OPERATOR}:${PRO_IMAGE_TAG}"
    GATEWAY_IMAGE="${GHCR_PRO_GATEWAY}:${PRO_IMAGE_TAG}"
    AGENT_IMAGE="${GHCR_AGENT}:${IMAGE_TAG}"

    if [[ -n "$REGISTRY" ]]; then
        OPERATOR_IMAGE="${REGISTRY}/codriverlabs/kube-microvm-operator-pro:${PRO_IMAGE_TAG}"
        GATEWAY_IMAGE="${REGISTRY}/codriverlabs/microvm-gateway:${PRO_IMAGE_TAG}"
        AGENT_IMAGE="${REGISTRY}/codriverlabs/microvm-auth-agent:${IMAGE_TAG}"
    fi

    run "kubectl create namespace kube-microvm --dry-run=client -o yaml | kubectl apply -f -"

    HELM_ARGS="--namespace kube-microvm \
        --set app.image=${OPERATOR_IMAGE} \
        --set app.envs.AWS_REGION=${REGION} \
        --set app.envs.MICROVM_AUTH_AGENT_IMAGE=${AGENT_IMAGE} \
        --set app.envs.PRO_GATEWAY_DEFAULT_IMAGE=${GATEWAY_IMAGE} \
        --timeout 5m --wait"

    [[ -n "$ROLE_ARN" ]] && HELM_ARGS="$HELM_ARGS --set serviceAccount.roleArn=${ROLE_ARN}"
    _append_quota_args

    run "helm upgrade --install kube-microvm-operator-pro $CHART $HELM_ARGS"
    success "kube-microvm-pro (PRO) installed"

    # Inject caBundle into MutatingWebhookConfiguration
    # (PRO chart doesn't use cert-manager; caBundle is patched post-install)
    _patch_pro_cabundle
}

_append_quota_args() {
    [[ -n "$QUOTA_RUN_MICROVM_RATE" ]]        && HELM_ARGS="$HELM_ARGS --set-string app.envs.AWS_QUOTA_RUN_MICROVM_RATE=${QUOTA_RUN_MICROVM_RATE}"
    [[ -n "$QUOTA_TERMINATE_MICROVM_RATE" ]]  && HELM_ARGS="$HELM_ARGS --set-string app.envs.AWS_QUOTA_TERMINATE_MICROVM_RATE=${QUOTA_TERMINATE_MICROVM_RATE}"
    [[ -n "$QUOTA_SUSPEND_MICROVM_RATE" ]]    && HELM_ARGS="$HELM_ARGS --set-string app.envs.AWS_QUOTA_SUSPEND_MICROVM_RATE=${QUOTA_SUSPEND_MICROVM_RATE}"
    [[ -n "$QUOTA_RESUME_MICROVM_RATE" ]]     && HELM_ARGS="$HELM_ARGS --set-string app.envs.AWS_QUOTA_RESUME_MICROVM_RATE=${QUOTA_RESUME_MICROVM_RATE}"
    [[ -n "$QUOTA_AUTH_TOKEN_RATE" ]]         && HELM_ARGS="$HELM_ARGS --set-string app.envs.AWS_QUOTA_AUTH_TOKEN_RATE=${QUOTA_AUTH_TOKEN_RATE}"
    [[ -n "$QUOTA_CONCURRENT_IMAGE_BUILDS" ]] && HELM_ARGS="$HELM_ARGS --set-string app.envs.AWS_QUOTA_CONCURRENT_IMAGE_BUILDS=${QUOTA_CONCURRENT_IMAGE_BUILDS}"
    $QUOTA_DISCOVERY_RUNTIME                  && HELM_ARGS="$HELM_ARGS --set-string app.envs.AWS_QUOTA_DISCOVERY_ENABLED=true"
}

_patch_pro_cabundle() {
    info "Waiting for PRO operator to register MutatingWebhookConfiguration..."
    for i in $(seq 1 30); do
        if kubectl get mutatingwebhookconfiguration kube-microvm-operator-mutating \
            > /dev/null 2>&1; then
            CA_BUNDLE=$(kubectl get secret kube-microvm-operator-webhook-tls \
                -n kube-microvm \
                -o jsonpath='{.data.tls\.crt}' 2>/dev/null || echo "")
            if [[ -n "$CA_BUNDLE" ]]; then
                kubectl patch mutatingwebhookconfiguration kube-microvm-operator-mutating \
                    --type='json' \
                    -p="[
                      {\"op\":\"replace\",\"path\":\"/webhooks/0/clientConfig/caBundle\",\"value\":\"${CA_BUNDLE}\"},
                      {\"op\":\"replace\",\"path\":\"/webhooks/1/clientConfig/caBundle\",\"value\":\"${CA_BUNDLE}\"}
                    ]" 2>/dev/null || \
                kubectl patch mutatingwebhookconfiguration kube-microvm-operator-mutating \
                    --type='json' \
                    -p="[
                      {\"op\":\"add\",\"path\":\"/webhooks/0/clientConfig/caBundle\",\"value\":\"${CA_BUNDLE}\"},
                      {\"op\":\"add\",\"path\":\"/webhooks/1/clientConfig/caBundle\",\"value\":\"${CA_BUNDLE}\"}
                    ]" 2>/dev/null && \
                success "caBundle injected into MutatingWebhookConfiguration"
                kubectl patch validatingwebhookconfiguration kube-microvm-operator-validating \
                    --type='json' \
                    -p="[{\"op\":\"replace\",\"path\":\"/webhooks/0/clientConfig/caBundle\",\"value\":\"${CA_BUNDLE}\"}]" 2>/dev/null || \
                kubectl patch validatingwebhookconfiguration kube-microvm-operator-validating \
                    --type='json' \
                    -p="[{\"op\":\"add\",\"path\":\"/webhooks/0/clientConfig/caBundle\",\"value\":\"${CA_BUNDLE}\"}]" 2>/dev/null && \
                success "caBundle injected into ValidatingWebhookConfiguration"
            fi
            return 0
        fi
        sleep 5
    done
    warn "MutatingWebhookConfiguration not found after 150s — webhook injection skipped"
    warn "Sidecar injection and MicroVMClass defaults may not work until operator restarts"
}

# ─── d. Auth-agent image availability ─────────────────────────────────────────
install_auth_agent() {
    step "d. Verifying microvm-auth-agent image"
    if [[ -n "$REGISTRY" ]]; then
        success "Auth-agent image imported to $REGISTRY (step a) and operator configured (step c)"
    else
        info "Auth-agent image: ${GHCR_AGENT}:${IMAGE_TAG} (pulled from GHCR at injection time)"
        success "Auth-agent ready"
    fi
}

# ─── e. Install CLI ───────────────────────────────────────────────────────────
install_cli() {
    step "e. Installing microvm CLI"

    mkdir -p "$INSTALL_DIR"

    BUNDLED="${SCRIPT_DIR}/bin/microvm-linux-${ARCH_TAG}"
    if [[ -f "$BUNDLED" ]]; then
        info "Installing bundled binary: $BUNDLED"
        run "cp $BUNDLED $INSTALL_DIR/microvm"
    else
        info "Downloading microvm-linux-${ARCH_TAG} (version: ${VERSION})"
        DOWNLOAD_URL="https://github.com/codriverlabs/KubeMicroVM/releases/download/${VERSION}/microvm-linux-${ARCH_TAG}"
        run "curl -fsSL $DOWNLOAD_URL -o $INSTALL_DIR/microvm"
    fi

    run "chmod +x $INSTALL_DIR/microvm"
    run "ln -sf $INSTALL_DIR/microvm $INSTALL_DIR/kubectl-microvm"
    success "Installed: $INSTALL_DIR/microvm → symlink: $INSTALL_DIR/kubectl-microvm"

    SHELL_RC=""
    [[ -f "$HOME/.bashrc" ]] && SHELL_RC="$HOME/.bashrc"
    [[ -f "$HOME/.zshrc" && -z "$SHELL_RC" ]] && SHELL_RC="$HOME/.zshrc"

    if [[ -n "$SHELL_RC" ]] && ! grep -q "microvm completion" "$SHELL_RC" 2>/dev/null; then
        info "Adding shell completion to $SHELL_RC"
        run "echo '' >> $SHELL_RC"
        run "echo '# KubeMicroVM CLI completion' >> $SHELL_RC"
        run "echo 'command -v microvm &>/dev/null && source <(microvm completion bash)' >> $SHELL_RC"
        info "Reload with: source $SHELL_RC"
    fi

    if ! echo "$PATH" | grep -q "$INSTALL_DIR"; then
        warn "$INSTALL_DIR is not in your PATH"
        warn "Add to your shell rc: export PATH=\"\$PATH:$INSTALL_DIR\""
    fi
}

# ─── f. Validate ──────────────────────────────────────────────────────────────
validate() {
    step "f. Validating installation"

    if command -v microvm &>/dev/null; then
        VER=$(microvm --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "unknown")
        success "microvm CLI: $VER"
    else
        warn "microvm not found in PATH — add $INSTALL_DIR to PATH"
    fi

    $CLI_ONLY && return 0

    # Check the right deployment name per edition
    local DEPLOY_NAME="kube-microvm-operator"
    [[ "$EDITION" == "pro" ]] && DEPLOY_NAME="kube-microvm-operator"  # same SA/deploy name in PRO

    OPERATOR_READY=$(kubectl get pods -n kube-microvm \
        -l app.kubernetes.io/name=kube-microvm-operator \
        -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
    if [[ "$OPERATOR_READY" == "True" ]]; then
        success "kube-microvm-operator ($EDITION): Running"
    else
        warn "Operator not ready yet — check: kubectl get pods -n kube-microvm"
    fi

    if command -v microvm &>/dev/null && command -v aws &>/dev/null; then
        info "Testing AWS connectivity..."
        if microvm image list-base --region "$REGION" &>/dev/null; then
            success "AWS connectivity: OK"
        else
            warn "AWS connectivity check failed — verify IAM role and region"
        fi
    fi
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
    echo ""
    echo -e "${BOLD}KubeMicroVM Installer${NC} (edition: ${EDITION}, version: ${VERSION:-resolving...})"
    echo "────────────────────────────────────────"
    $DRY_RUN && warn "DRY-RUN mode — no changes will be made"

    resolve_version
    # Tags/versions must not have 'v' prefix
    HELM_VERSION="${VERSION#v}"
    IMAGE_TAG="${VERSION#v}"

    if [[ "$EDITION" == "pro" ]]; then
        resolve_pro_version
        PRO_HELM_VERSION="${PRO_VERSION#v}"
        PRO_IMAGE_TAG="${PRO_VERSION#v}"
    fi

    echo -e "${BOLD}KubeMicroVM Installer${NC} (edition: ${EDITION}, community: ${VERSION}${PRO_VERSION:+, pro: ${PRO_VERSION}})"

    load_config
    check_prerequisites

    if ! $CLI_ONLY; then
        [[ "$EDITION" == "pro" ]] && ghcr_login_pro
        import_images
        setup_iam
        ensure_cert_manager
        discover_quotas
        install_operator
        install_auth_agent
        [[ "$EDITION" == "pro" ]] && ghcr_logout_pro
        _helm_registry_logout
    fi

    install_cli
    save_config
    validate

    echo ""
    echo -e "${GREEN}${BOLD}Installation complete! (${EDITION})${NC}"
    echo ""
    if ! $CLI_ONLY; then
        echo "Next steps:"
        echo "  1. Label a namespace:  kubectl label namespace default lambda.aws.amazon.com/manage-microvms=true"
        echo "  2. Create a MicroVMImage and MicroVM"
        if [[ "$EDITION" == "pro" ]]; then
            echo "  3. Create a MicroVMGateway for session-affine routing"
        fi
        echo "  Docs: https://codriverlabs.github.io/KubeMicroVM/"
    fi
}

main "$@"
