#!/usr/bin/env bash
# deploy-local.sh — deploy KubeMicroVM operator to an EKS cluster
#
# Usage:
#   ./deploy-local.sh                              # build + deploy from local chart
#   ./deploy-local.sh --skip-build                 # helm upgrade only (reuse existing chart)
#   ./deploy-local.sh --from-registry              # deploy from GHCR OCI (no local build)
#   ./deploy-local.sh --region us-east-1           # target AWS region
#   ./deploy-local.sh --cluster my-cluster         # EKS cluster name
#   ./deploy-local.sh --profile my-aws-profile     # AWS CLI profile
#   ./deploy-local.sh --dry-run                    # helm upgrade --dry-run
#   ./deploy-local.sh --set key=val                # extra helm values (repeatable)
#
set -euo pipefail

SKIP_BUILD=false
FROM_REGISTRY=false
DRY_RUN=false
REGION="${AWS_REGION:-us-east-1}"
CLUSTER=""
AWS_PROFILE=""
EXTRA_SET_ARGS=""
NAMESPACE="kube-microvm"
RELEASE="kube-microvm-operator"

while [[ $# -gt 0 ]]; do
  case $1 in
    --help)
      echo "Usage: ./deploy-local.sh [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --skip-build          Skip Maven build; use existing chart tarball"
      echo "  --from-registry       Deploy from GHCR OCI (ignores local build)"
      echo "  --region <region>     AWS region (default: \$AWS_REGION or us-east-1)"
      echo "  --cluster <name>      EKS cluster name (updates kubeconfig)"
      echo "  --profile <name>      AWS CLI profile"
      echo "  --namespace <ns>      Kubernetes namespace (default: kube-microvm)"
      echo "  --dry-run             Helm dry-run (no actual deploy)"
      echo "  --set key=val         Extra helm --set values (repeatable)"
      echo "  --help                Show this help"
      echo ""
      echo "Examples:"
      echo "  ./deploy-local.sh --region us-east-1 --cluster my-cluster"
      echo "  ./deploy-local.sh --skip-build --dry-run"
      echo "  ./deploy-local.sh --from-registry --region us-east-2"
      echo "  ./deploy-local.sh --set 'app.envs.microvm\\.aws\\.region=us-west-2'"
      exit 0
      ;;
    --skip-build)    SKIP_BUILD=true ;;
    --from-registry) FROM_REGISTRY=true; SKIP_BUILD=true ;;
    --dry-run)       DRY_RUN=true ;;
    --region)        REGION="$2"; shift ;;
    --cluster)       CLUSTER="$2"; shift ;;
    --profile)       AWS_PROFILE="$2"; shift ;;
    --namespace)     NAMESPACE="$2"; shift ;;
    --set)           EXTRA_SET_ARGS="${EXTRA_SET_ARGS} --set $2"; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

PROFILE_FLAG=""; [[ -n "$AWS_PROFILE" ]] && PROFILE_FLAG="--profile $AWS_PROFILE"
IMAGE_TAG=$(git describe --tags 2>/dev/null | sed 's/^v//;s/-[0-9]*-g[0-9a-f]*$//' || echo "dev")
DRY_RUN_FLAG=""; $DRY_RUN && DRY_RUN_FLAG="--dry-run"

# Update kubeconfig if cluster specified
if [[ -n "$CLUSTER" ]]; then
  echo "==> Updating kubeconfig for cluster ${CLUSTER} in ${REGION}"
  aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER" $PROFILE_FLAG
fi

# Build if needed
if ! $SKIP_BUILD && ! $FROM_REGISTRY; then
  echo "==> Building operator (tag: ${IMAGE_TAG})"
  ./build-local.sh --helm --skip-tests
fi

# Resolve chart source
if $FROM_REGISTRY; then
  CHART="oci://ghcr.io/codriverlabs/helm/kube-microvm-operator"
  echo "==> Deploying from GHCR OCI registry"
else
  CHART=$(ls operator-controller/target/helm/kubernetes/kube-microvm-operator-*.tar.gz 2>/dev/null | head -1)
  if [[ -z "$CHART" ]]; then
    echo "ERROR: No chart tarball found. Run ./build-local.sh --helm first." >&2
    exit 1
  fi
  echo "==> Deploying from local chart: ${CHART}"
fi

# Ensure namespace exists
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Ensure Pod Identity association exists (idempotent)
if ! $DRY_RUN; then
  ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text $PROFILE_FLAG 2>/dev/null)
  ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/kube-microvm-operator"
  CLUSTER_NAME="${CLUSTER:-$(kubectl config current-context | sed 's|.*:cluster/||' 2>/dev/null || echo "")}"

  if [[ -n "$CLUSTER_NAME" ]]; then
    # Ensure IAM role exists with correct trust policy for Pod Identity
    if ! aws iam get-role --role-name kube-microvm-operator $PROFILE_FLAG &>/dev/null; then
      echo "==> Creating IAM role kube-microvm-operator"
      aws iam create-role \
        --role-name kube-microvm-operator \
        --assume-role-policy-document '{
          "Version": "2012-10-17",
          "Statement": [{
            "Effect": "Allow",
            "Principal": {"Service": "pods.eks.amazonaws.com"},
            "Action": ["sts:AssumeRole", "sts:TagSession"]
          }]
        }' \
        $PROFILE_FLAG --output text --query 'Role.Arn'
    else
      # Ensure trust policy includes pods.eks.amazonaws.com
      TRUST=$(aws iam get-role --role-name kube-microvm-operator $PROFILE_FLAG \
        --query 'Role.AssumeRolePolicyDocument' --output json 2>/dev/null)
      if ! echo "$TRUST" | grep -q "pods.eks.amazonaws.com"; then
        echo "==> Updating trust policy to include pods.eks.amazonaws.com"
        UPDATED=$(echo "$TRUST" | python3 -c "
import json, sys
doc = json.load(sys.stdin)
pod_id_stmt = {'Effect':'Allow','Principal':{'Service':'pods.eks.amazonaws.com'},'Action':['sts:AssumeRole','sts:TagSession']}
if not any('pods.eks.amazonaws.com' in json.dumps(s) for s in doc.get('Statement',[])):
    doc['Statement'].append(pod_id_stmt)
print(json.dumps(doc))
")
        aws iam update-assume-role-policy \
          --role-name kube-microvm-operator \
          --policy-document "$UPDATED" \
          $PROFILE_FLAG
      fi
    fi

    # Create Pod Identity association if not exists
    EXISTING=$(aws eks list-pod-identity-associations \
      --cluster-name "$CLUSTER_NAME" \
      --namespace "$NAMESPACE" \
      --service-account kube-microvm-operator \
      --region "$REGION" \
      $PROFILE_FLAG \
      --query 'associations[0].associationId' --output text 2>/dev/null || echo "None")

    if [[ "$EXISTING" == "None" || -z "$EXISTING" ]]; then
      echo "==> Creating Pod Identity association (role: ${ROLE_ARN})"
      aws eks create-pod-identity-association \
        --cluster-name "$CLUSTER_NAME" \
        --namespace "$NAMESPACE" \
        --service-account kube-microvm-operator \
        --role-arn "$ROLE_ARN" \
        --region "$REGION" \
        $PROFILE_FLAG \
        --query 'association.associationId' --output text
    else
      echo "==> Pod Identity association exists: ${EXISTING}"
    fi

    # Warn if EKS Auth VPC endpoint missing (required for private subnets)
    VPC_ID=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" $PROFILE_FLAG \
      --query 'cluster.resourcesVpcConfig.vpcId' --output text 2>/dev/null || echo "")
    if [[ -n "$VPC_ID" ]]; then
      EKS_AUTH_EP=$(aws ec2 describe-vpc-endpoints \
        --filters "Name=vpc-id,Values=${VPC_ID}" "Name=service-name,Values=com.amazonaws.${REGION}.eks-auth" \
        --region "$REGION" $PROFILE_FLAG \
        --query 'VpcEndpoints[0].State' --output text 2>/dev/null || echo "None")
      if [[ "$EKS_AUTH_EP" == "None" || -z "$EKS_AUTH_EP" ]]; then
        echo "    ⚠️  No eks-auth VPC endpoint found. Pod Identity requires it for private subnets."
        echo "    Create with: aws ec2 create-vpc-endpoint --vpc-id ${VPC_ID} --service-name com.amazonaws.${REGION}.eks-auth --vpc-endpoint-type Interface --private-dns-enabled --subnet-ids <SUBNETS> --security-group-ids <SG>"
      fi
    fi
  fi
fi

# Helm upgrade --install
echo "==> helm upgrade --install ${RELEASE} (namespace: ${NAMESPACE}, dry-run: ${DRY_RUN})"
helm upgrade --install "$RELEASE" "$CHART" \
  --namespace "$NAMESPACE" \
  --create-namespace \
  --set "app.envs.AWS_REGION=${REGION}" \
  $EXTRA_SET_ARGS \
  $DRY_RUN_FLAG \
  --wait \
  --timeout 5m

if ! $DRY_RUN; then
  echo ""
  echo "==> Deploy complete"
  echo "    Operator pod: $(kubectl get pods -n ${NAMESPACE} -l app.kubernetes.io/name=kube-microvm-operator -o name 2>/dev/null | head -1)"
  echo ""
  echo "    To install kubectl plugin:"
  echo "    ./install-kubectl-plugin.sh"
fi
