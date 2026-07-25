#!/usr/bin/env bash
# build-local.sh — KubeMicroVM operator local build
#
# Usage:
#   ./build-local.sh                          # JVM build, all modules
#   ./build-local.sh --native                 # GraalVM native (CLI + operator)
#   ./build-local.sh --skip-tests             # skip unit + integration tests
#   ./build-local.sh --push                   # build + push container images
#   ./build-local.sh --helm                   # generate Helm chart tarball
#   ./build-local.sh --only operator          # operator-controller only
#   ./build-local.sh --only cli               # kubectl-microvm CLI only
#   ./build-local.sh --only operator,cli      # multiple modules
#   ./build-local.sh --registry 123.dkr.ecr.us-east-1.amazonaws.com
#   ./build-local.sh --push --helm --registry 123.dkr.ecr.us-east-1.amazonaws.com
#
set -euo pipefail

NATIVE=false
SKIP_TESTS=false
PUSH=false
HELM=false
ONLY=""
REGISTRY=""

for arg in "$@"; do
  case $arg in
    --help)
      echo "Usage: ./build-local.sh [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --native              Build GraalVM native binaries (operator + CLI)"
      echo "  --skip-tests          Skip unit + integration tests"
      echo "  --push                Push container images after build"
      echo "  --helm                Generate Helm chart tarball into operator-controller/target/helm/"
      echo "  --only <list>         Comma-separated: operator, cli, agent, tests"
      echo "  --registry <url>      Container registry (default: ghcr.io/codriverlabs)"
      echo "  --help                Show this help"
      echo ""
      echo "Examples:"
      echo "  ./build-local.sh --skip-tests"
      echo "  ./build-local.sh --push --helm --registry 123.dkr.ecr.us-east-1.amazonaws.com"
      echo "  ./build-local.sh --native --only cli"
      echo "  ./build-local.sh --only operator --push --helm"
      exit 0
      ;;
    --native)     NATIVE=true ;;
    --skip-tests) SKIP_TESTS=true ;;
    --push)       PUSH=true ;;
    --helm)       HELM=true ;;
    --only=*)     ONLY="${arg#--only=}" ;;
    --registry=*) REGISTRY="${arg#--registry=}" ;;
    --only)       ;;
    --registry)   ;;
    *)
      if [[ "${PREV_ARG:-}" == "--only" ]];     then ONLY="$arg"
      elif [[ "${PREV_ARG:-}" == "--registry" ]]; then REGISTRY="$arg"
      fi
      ;;
  esac
  PREV_ARG="$arg"
done

should_build() { [[ -z "$ONLY" ]] || [[ ",$ONLY," == *",$1,"* ]]; }

SKIP_FLAG=""; $SKIP_TESTS && SKIP_FLAG="-DskipTests"

# Resolve image tag from git (strip leading 'v' and dirty suffix)
IMAGE_TAG=$(git describe --tags 2>/dev/null | sed 's/^v//;s/-[0-9]*-g[0-9a-f]*$//' || echo "dev")

# ECR login if pushing to ECR registry
if $PUSH && [[ "${REGISTRY:-}" =~ \.dkr\.ecr\.([a-z0-9-]+)\.amazonaws\.com ]]; then
  ECR_REGION="${BASH_REMATCH[1]}"
  echo "==> ECR login (${ECR_REGION})"
  aws ecr get-login-password --region "${ECR_REGION}" \
    | docker login --username AWS --password-stdin "${REGISTRY}"
fi

# Build Quarkus container-image flags
image_flags() {
  # Only build/push image when --push is set
  if $PUSH; then
    local flags="-Pjib"   # Jib: no local Docker needed, cross-compiles linux/amd64+arm64
    flags+=" -Dquarkus.container-image.build=true -Dquarkus.container-image.push=true"
    flags+=" -Dquarkus.container-image.tag=${IMAGE_TAG}"
    [[ -n "$REGISTRY" ]] && flags+=" -Dquarkus.container-image.registry=${REGISTRY%%/*}"
    [[ -n "$REGISTRY" && "$REGISTRY" == */* ]] && flags+=" -Dquarkus.container-image.group=${REGISTRY#*/}"
    echo "$flags"
  else
    echo "-Dquarkus.container-image.build=false"
  fi
}

echo "==> KubeMicroVM build  native=${NATIVE}  skipTests=${SKIP_TESTS}  only=${ONLY:-all}  push=${PUSH}  helm=${HELM}  tag=${IMAGE_TAG}"

# 0. Parent POM + core (always required)
echo "--- [0] parent + operator-core"
./mvnw -B -N install $SKIP_FLAG
./mvnw -B -pl operator-core install $SKIP_FLAG

# 1. Operator controller
if should_build "operator"; then
  echo "--- [1] operator-controller"
  HELM_FLAGS=""
  $HELM && HELM_FLAGS="-Dquarkus.helm.version=${IMAGE_TAG} -Dquarkus.helm.create-tar-file=true"
  if $NATIVE; then
    ./mvnw -B -pl operator-controller package $SKIP_FLAG -Dnative \
      -Dquarkus.native.container-build=false \
      $(image_flags) $HELM_FLAGS
  else
    ./mvnw -B -pl operator-controller package $SKIP_FLAG \
      $(image_flags) $HELM_FLAGS
  fi
  $HELM && echo "==> Helm chart: operator-controller/target/helm/kubernetes/kube-microvm-operator-${IMAGE_TAG}.tar.gz"
fi

# 2. CLI (kubectl-microvm)
if should_build "cli"; then
  echo "--- [2] operator-cli"
  if $NATIVE; then
    ./mvnw -B -pl operator-cli package $SKIP_FLAG -Dnative \
      -Dquarkus.native.container-build=false
    echo "==> CLI binary: $(find operator-cli/target -name '*-runner' -type f | head -1)"
  else
    ./mvnw -B -pl operator-cli package $SKIP_FLAG
    echo "==> CLI jar: operator-cli/target/quarkus-app/"
  fi
fi

# 3. Auth agent sidecar
if should_build "agent"; then
  echo "--- [3] operator-auth-agent"
  if $NATIVE; then
    AGENT_IMAGE_FLAGS="-Dquarkus.container-image.build=true -Dquarkus.container-image.push=${PUSH}"
    AGENT_IMAGE_FLAGS+=" -Dquarkus.container-image.tag=${IMAGE_TAG}"
    [[ -n "${REGISTRY:-}" ]] && AGENT_IMAGE_FLAGS+=" -Dquarkus.container-image.registry=${REGISTRY%%/*}"
    ./mvnw -B -pl operator-auth-agent package $SKIP_FLAG -Dnative \
      -Dquarkus.native.container-build=false \
      $AGENT_IMAGE_FLAGS
  else
    ./mvnw -B -pl operator-auth-agent package $SKIP_FLAG
    if $PUSH; then
      # JVM mode: build and push via Dockerfile
      AGENT_REPO="${REGISTRY:+${REGISTRY}/}codriverlabs/microvm-auth-agent"
      AGENT_IMAGE="${AGENT_REPO}:${IMAGE_TAG}"
      echo "==> Building auth-agent image: ${AGENT_IMAGE}"
      docker build -t "${AGENT_IMAGE}" -f operator-auth-agent/Dockerfile operator-auth-agent/
      docker push "${AGENT_IMAGE}"
      echo "==> Auth-agent image pushed: ${AGENT_IMAGE}"
    fi
  fi
fi

# 4. Integration tests
if should_build "tests"; then
  echo "--- [4] operator-tests"
  ./mvnw -B -pl operator-tests verify
fi

echo ""
echo "==> Build complete  (tag: ${IMAGE_TAG})"
