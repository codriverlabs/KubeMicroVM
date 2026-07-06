#!/usr/bin/env bash
# install_kube_microvm.sh — KubeMicroVM installer
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

#   --cli-only            Only install the microvm CLI (skip Helm installs)
#   --dry-run             Print what would be done without executing
#   --help                Show this help
#
# Examples:
#   # Full install with private ECR registry + IAM setup
#   ./install_kube_microvm.sh --cluster my-cluster --region us-east-1 \
#     --registry 123456789.dkr.ecr.us-east-1.amazonaws.com --iam
#
#   # Install using existing IAM role
#   ./install_kube_microvm.sh --cluster my-cluster --region us-east-1 \
#     --role-arn arn:aws:iam::123456789:role/kube-microvm-operator
#
#   # CLI only
#   ./install_kube_microvm.sh --cli-only

set -euo pipefail

# ─── Defaults ─────────────────────────────────────────────────────────────────
CLUSTER=""
REGION="${AWS_REGION:-us-east-1}"
REGISTRY=""
ROLE_ARN=""
DO_IAM=false

CLI_ONLY=false
DRY_RUN=false
INSTALL_DIR="${HOME}/bin"
CONFIG_DIR="${HOME}/.kube-microvm"
CONFIG_FILE="${CONFIG_DIR}/config"

# Quota overrides — defaults match AWS account-level defaults (90% of limit)
# Override if you have received a quota increase from AWS Support
QUOTA_RUN_MICROVM_RATE=""
QUOTA_TERMINATE_MICROVM_RATE=""
QUOTA_SUSPEND_MICROVM_RATE=""
QUOTA_RESUME_MICROVM_RATE=""
QUOTA_AUTH_TOKEN_RATE=""
QUOTA_CONCURRENT_IMAGE_BUILDS=""

# Resolved at runtime from GitHub Release or bundled in installer image
VERSION="${KUBE_MICROVM_VERSION:-}"
GHCR_OPERATOR="ghcr.io/plasticity-of-cloud/kube-microvm-operator"
GHCR_AGENT="ghcr.io/plasticity-of-cloud/microvm-auth-agent"
GHCR_HELM="oci://ghcr.io/plasticity-of-cloud/helm"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Resolve version — prefer env var, then bundled VERSION file, then GitHub API
resolve_version() {
    [[ -n "$VERSION" ]] && return 0
    # Check for bundled VERSION file (installer Docker image)
    if [[ -f "${SCRIPT_DIR}/VERSION" ]]; then
        VERSION=$(cat "${SCRIPT_DIR}/VERSION")
        info "Version from bundle: $VERSION"
        return 0
    fi
    # Query GitHub Releases API for latest
    info "Resolving latest version from GitHub..."
    VERSION=$(curl -fsSL \
        "https://api.github.com/repos/plasticity-of-cloud/KubeMicroVM/releases/latest" \
        2>/dev/null | grep '"tag_name"' | grep -oP 'v[\d.]+(-rc\d+)?' | head -1)
    if [[ -z "$VERSION" ]]; then
        error "Could not resolve version. Set KUBE_MICROVM_VERSION env var or pass bundled installer."
        exit 1
    fi
    info "Latest version: $VERSION"
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
        --cluster)   CLUSTER="$2";   shift 2 ;;
        --region)    REGION="$2";    shift 2 ;;
        --registry)  REGISTRY="$2";  shift 2 ;;
        --role-arn)  ROLE_ARN="$2";  shift 2 ;;
        --iam)       DO_IAM=true;    shift ;;

        --quota-run-microvm-rate)         QUOTA_RUN_MICROVM_RATE="$2";         shift 2 ;;
        --quota-terminate-microvm-rate)   QUOTA_TERMINATE_MICROVM_RATE="$2";   shift 2 ;;
        --quota-suspend-microvm-rate)     QUOTA_SUSPEND_MICROVM_RATE="$2";     shift 2 ;;
        --quota-resume-microvm-rate)      QUOTA_RESUME_MICROVM_RATE="$2";      shift 2 ;;
        --quota-auth-token-rate)          QUOTA_AUTH_TOKEN_RATE="$2";          shift 2 ;;
        --quota-concurrent-image-builds)  QUOTA_CONCURRENT_IMAGE_BUILDS="$2";  shift 2 ;;

        --cli-only)  CLI_ONLY=true;  shift ;;
        --dry-run)   DRY_RUN=true;   shift ;;
        --help|-h)
            cat <<'HELP'
install_kube_microvm.sh — KubeMicroVM installer

Usage:
  ./install_kube_microvm.sh [options]

Options:
  --cluster    <name>   EKS cluster name (required for --iam and helm install)
  --region     <name>   AWS region (default: us-east-1)
  --registry   <url>    Private registry URL (e.g. 123456789.dkr.ecr.us-east-1.amazonaws.com)
  --iam                 Create IAM role + Pod Identity association via CloudFormation
  --role-arn   <arn>    Use existing IAM role ARN (skips --iam)

  # Quota overrides — set if you have received an AWS quota increase
  --quota-run-microvm-rate         <N>   RunMicrovm rate/s (default: 4, AWS limit: 5)
  --quota-terminate-microvm-rate   <N>   TerminateMicrovm rate/s (default: 9, AWS limit: 10)
  --quota-suspend-microvm-rate     <N>   SuspendMicrovm rate/s (default: 1, AWS limit: 2)
  --quota-resume-microvm-rate      <N>   ResumeMicrovm rate/s (default: 4, AWS limit: 5)
  --quota-auth-token-rate          <N>   CreateMicrovmAuthToken rate/s (default: 45, AWS limit: 50)
  --quota-concurrent-image-builds  <N>   Concurrent image builds (default: 9, AWS limit: 10)

  --cli-only            Only install the microvm CLI (skip Helm installs)
  --dry-run             Print what would be done without executing
  --help                Show this help

Examples:
  # Full install with private ECR registry + IAM setup
  ./install_kube_microvm.sh --cluster my-cluster --region us-east-1 \
    --registry 123456789.dkr.ecr.us-east-1.amazonaws.com --iam

  # Install using existing IAM role
  ./install_kube_microvm.sh --cluster my-cluster --region us-east-1 \
    --role-arn arn:aws:iam::123456789:role/kube-microvm-operator

  # CLI only
  ./install_kube_microvm.sh --cli-only
HELP
            exit 0 ;;
        *) error "Unknown option: $1"; exit 1 ;;
    esac
done

# ─── Detect arch ──────────────────────────────────────────────────────────────
ARCH="$(uname -m)"
case "$ARCH" in
    x86_64)  ARCH_TAG="amd64" ;;
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
    success "Prerequisites OK (arch: $ARCH_TAG)"
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
KUBE_MICROVM_REGISTRY="${REGISTRY}"
KUBE_MICROVM_REGION="${REGION}"
KUBE_MICROVM_CLUSTER="${CLUSTER}"
KUBE_MICROVM_ROLE_ARN="${ROLE_ARN}"
EOF
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

    for IMAGE_NAME in kube-microvm-operator microvm-auth-agent; do
        SRC_REPO="ghcr.io/plasticity-of-cloud/${IMAGE_NAME}"
        DST_REPO="${REGISTRY}/plasticity-of-cloud/${IMAGE_NAME}"

        # Create ECR repo if needed
        if [[ "$REGISTRY" == *".ecr."* ]]; then
            info "Ensuring ECR repo: plasticity-of-cloud/${IMAGE_NAME}"
            run "aws ecr create-repository \
                --repository-name plasticity-of-cloud/${IMAGE_NAME} \
                --region ${ECR_REGION} 2>/dev/null || true"
        fi

        # Pull, retag, push both arches
        for ARCH in amd64 arm64; do
            SRC="${SRC_REPO}:${IMAGE_TAG}-${ARCH}"
            DST="${DST_REPO}:${IMAGE_TAG}"
            info "  $SRC → $DST (${ARCH})"
            run "docker pull --platform linux/${ARCH} $SRC"
            run "docker tag $SRC ${DST_REPO}:${IMAGE_TAG}-${ARCH}"
            run "docker push ${DST_REPO}:${IMAGE_TAG}-${ARCH}"
        done

        # Create and push multi-arch manifest
        run "docker manifest create ${DST_REPO}:${IMAGE_TAG} \
            ${DST_REPO}:${IMAGE_TAG}-amd64 \
            ${DST_REPO}:${IMAGE_TAG}-arm64"
        run "docker manifest push ${DST_REPO}:${IMAGE_TAG}"
        success "Pushed $IMAGE_NAME → $REGISTRY"
    done
}

# ─── b. IAM role + Pod Identity ───────────────────────────────────────────────
setup_iam() {
    ! $DO_IAM && [[ -z "$ROLE_ARN" ]] && return 0
    [[ -n "$ROLE_ARN" ]] && { info "Using existing role: $ROLE_ARN"; return 0; }

    step "b. Setting up IAM role + Pod Identity"

    STACK_NAME="kube-microvm-operator-role-${CLUSTER}"
    IAM_TEMPLATE="${SCRIPT_DIR}/iam/kube-microvm-operator-role.yaml"

    # Download IAM template from release if not bundled locally
    if [[ ! -f "$IAM_TEMPLATE" ]]; then
        info "Downloading IAM CloudFormation template from release..."
        RELEASE_BASE="https://github.com/plasticity-of-cloud/KubeMicroVM/releases/download/${VERSION}"
        mkdir -p "${SCRIPT_DIR}/iam"
        run "curl -fsSL ${RELEASE_BASE}/kube-microvm-operator-role.yaml -o $IAM_TEMPLATE"
        run "curl -fsSL ${RELEASE_BASE}/kube-microvm-operator-role.yaml.sha256 -o ${IAM_TEMPLATE}.sha256"
        info "Verifying IAM template checksum..."
        if ! sha256sum -c "${IAM_TEMPLATE}.sha256" 2>/dev/null; then
            error "Checksum verification failed for IAM template!"
            error "The downloaded file may be corrupted or tampered with."
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

    # Detect cluster type and configure credentials accordingly:
    # 1. EKS (standard or Auto Mode): aws eks list-pod-identity-associations succeeds
    # 2. EKS-DX: eks-dx CLI available
    # 3. Fallback: IRSA annotation on ServiceAccount

    if aws eks list-pod-identity-associations --cluster-name "$CLUSTER" --region "$REGION" &>/dev/null; then
        # EKS cluster (standard or Auto Mode) — use native Pod Identity
        info "EKS Pod Identity detected — creating association"
        run "aws eks create-pod-identity-association \
            --cluster-name $CLUSTER \
            --namespace kube-microvm \
            --service-account kube-microvm-operator \
            --role-arn $ROLE_ARN \
            --region $REGION 2>/dev/null || true"
        success "Pod Identity association created: $ROLE_ARN"

    elif command -v eks-dx &>/dev/null; then
        # EKS-DX cluster — tag role for automatic trust policy, use eks-dx CLI
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
        # Fallback: IRSA annotation
        info "Pod Identity not available — configuring IRSA annotation"
        run "kubectl annotate serviceaccount kube-microvm-operator \
            -n kube-microvm \
            eks.amazonaws.com/role-arn=$ROLE_ARN \
            --overwrite 2>/dev/null || true"
        # Restart operator to pick up new annotation
        run "kubectl rollout restart deployment kube-microvm-operator -n kube-microvm 2>/dev/null || true"
        success "IRSA annotation set: $ROLE_ARN"
    fi

    success "IAM role: $ROLE_ARN"
}

# ─── c. helm install kube-microvm-operator ────────────────────────────────────
install_operator() {
    step "c. Installing kube-microvm-operator Helm chart"

    # Determine chart source
    if [[ -f "${SCRIPT_DIR}/charts/kube-microvm-operator-${HELM_VERSION}.tar.gz" ]]; then
        CHART="${SCRIPT_DIR}/charts/kube-microvm-operator-${HELM_VERSION}.tar.gz"
        info "Using bundled chart: $CHART"
    else
        CHART="${GHCR_HELM}/kube-microvm-operator --version $HELM_VERSION"
        info "Using GHCR chart: $CHART"
    fi

    # Determine image
    OPERATOR_IMAGE="${GHCR_OPERATOR}:${IMAGE_TAG}"
    [[ -n "$REGISTRY" ]] && OPERATOR_IMAGE="${REGISTRY}/plasticity-of-cloud/kube-microvm-operator:${IMAGE_TAG}"

    # Determine auth-agent image (injected as sidecar by mutating webhook)
    AGENT_IMAGE="${GHCR_AGENT}:${IMAGE_TAG}"
    [[ -n "$REGISTRY" ]] && AGENT_IMAGE="${REGISTRY}/plasticity-of-cloud/microvm-auth-agent:${IMAGE_TAG}"

    # Ensure namespace
    run "kubectl create namespace kube-microvm --dry-run=client -o yaml | kubectl apply -f -"

    # Helm install
    HELM_ARGS="--namespace kube-microvm \
        --set app.image=${OPERATOR_IMAGE} \
        --set app.envs.AWS_REGION=${REGION} \
        --set app.envs.MICROVM_AUTH_AGENT_IMAGE=${AGENT_IMAGE} \
        --timeout 4m --wait"

    [[ -n "$ROLE_ARN" ]] && HELM_ARGS="$HELM_ARGS --set serviceAccount.roleArn=${ROLE_ARN}"

    # Quota overrides — only set if explicitly provided
    [[ -n "$QUOTA_RUN_MICROVM_RATE" ]]        && HELM_ARGS="$HELM_ARGS --set quotas.runMicrovmRate=${QUOTA_RUN_MICROVM_RATE}"
    [[ -n "$QUOTA_TERMINATE_MICROVM_RATE" ]]  && HELM_ARGS="$HELM_ARGS --set quotas.terminateMicrovmRate=${QUOTA_TERMINATE_MICROVM_RATE}"
    [[ -n "$QUOTA_SUSPEND_MICROVM_RATE" ]]    && HELM_ARGS="$HELM_ARGS --set quotas.suspendMicrovmRate=${QUOTA_SUSPEND_MICROVM_RATE}"
    [[ -n "$QUOTA_RESUME_MICROVM_RATE" ]]     && HELM_ARGS="$HELM_ARGS --set quotas.resumeMicrovmRate=${QUOTA_RESUME_MICROVM_RATE}"
    [[ -n "$QUOTA_AUTH_TOKEN_RATE" ]]         && HELM_ARGS="$HELM_ARGS --set quotas.authTokenRate=${QUOTA_AUTH_TOKEN_RATE}"
    [[ -n "$QUOTA_CONCURRENT_IMAGE_BUILDS" ]] && HELM_ARGS="$HELM_ARGS --set quotas.concurrentImageBuilds=${QUOTA_CONCURRENT_IMAGE_BUILDS}"

    run "helm upgrade --install kube-microvm-operator $CHART $HELM_ARGS"
    success "kube-microvm-operator installed"
}

# ─── d. Auth-agent image availability ─────────────────────────────────────────
install_auth_agent() {
    step "d. Verifying microvm-auth-agent image"

    # Image import is already handled by import_images() in step (a) when --registry is set
    # Operator is configured with MICROVM_AUTH_AGENT_IMAGE env in step (c)
    if [[ -n "$REGISTRY" ]]; then
        success "Auth-agent image imported to $REGISTRY (step a) and operator configured (step c)"
    else
        info "Auth-agent image: ${GHCR_AGENT}:${IMAGE_TAG} (pulled from GHCR at injection time)"
        success "Auth-agent ready"
    fi
}    success "microvm-auth-agent installed"
}

# ─── e. Install CLI ───────────────────────────────────────────────────────────
install_cli() {
    step "e. Installing microvm CLI"

    mkdir -p "$INSTALL_DIR"

    # Check if bundled binary exists
    BUNDLED="${SCRIPT_DIR}/bin/microvm-linux-${ARCH_TAG}"
    if [[ -f "$BUNDLED" ]]; then
        info "Installing bundled binary: $BUNDLED"
        run "cp $BUNDLED $INSTALL_DIR/microvm"
    else
        # Download from GitHub Release — VERSION includes 'v' prefix (e.g. v1.0.0)
        info "Downloading microvm-linux-${ARCH_TAG} (version: ${VERSION})"
        DOWNLOAD_URL="https://github.com/plasticity-of-cloud/KubeMicroVM/releases/download/${VERSION}/microvm-linux-${ARCH_TAG}"
        run "curl -fsSL $DOWNLOAD_URL -o $INSTALL_DIR/microvm"
    fi

    run "chmod +x $INSTALL_DIR/microvm"

    # Create kubectl-microvm symlink
    run "ln -sf $INSTALL_DIR/microvm $INSTALL_DIR/kubectl-microvm"
    success "Installed: $INSTALL_DIR/microvm → symlink: $INSTALL_DIR/kubectl-microvm"

    # Shell completion
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

    # PATH hint if needed
    if ! echo "$PATH" | grep -q "$INSTALL_DIR"; then
        warn "$INSTALL_DIR is not in your PATH"
        warn "Add to your shell rc: export PATH=\"\$PATH:$INSTALL_DIR\""
    fi
}

# ─── f. Validate ──────────────────────────────────────────────────────────────
validate() {
    step "f. Validating installation"

    # CLI
    if command -v microvm &>/dev/null; then
        VER=$(microvm --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "unknown")
        success "microvm CLI: $VER"
    else
        warn "microvm not found in PATH — add $INSTALL_DIR to PATH"
    fi

    $CLI_ONLY && return 0

    # Operator pod
    OPERATOR_READY=$(kubectl get pods -n kube-microvm \
        -l app.kubernetes.io/name=kube-microvm-operator \
        -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
    if [[ "$OPERATOR_READY" == "True" ]]; then
        success "kube-microvm-operator: Running"
    else
        warn "kube-microvm-operator not ready yet — check: kubectl get pods -n kube-microvm"
    fi

    # AWS connectivity (optional — requires credentials)
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
    echo -e "${BOLD}KubeMicroVM Installer${NC} (version: ${VERSION:-resolving...})"
    echo "────────────────────────────────────────"
    $DRY_RUN && warn "DRY-RUN mode — no changes will be made"

    resolve_version
    # Helm chart and image tags must not have 'v' prefix
    HELM_VERSION="${VERSION#v}"
    IMAGE_TAG="${VERSION#v}"

    echo -e "${BOLD}KubeMicroVM Installer${NC} (version: ${VERSION})"

    load_config
    check_prerequisites

    if ! $CLI_ONLY; then
        import_images
        setup_iam
        install_operator
        install_auth_agent
    fi

    install_cli
    save_config
    validate

    echo ""
    echo -e "${GREEN}${BOLD}Installation complete!${NC}"
    echo ""
    if ! $CLI_ONLY; then
        echo "Next steps:"
        echo "  1. Label a namespace:  kubectl label namespace default lambda.aws.amazon.com/manage-microvms=true"
        echo "  2. Create a MicroVMImage and MicroVM"
        echo "  3. See docs: https://github.com/plasticity-of-cloud/KubeMicroVM"
    fi
}

main "$@"
