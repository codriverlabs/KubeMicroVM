# KubeMicroVM Operator — IAM Setup

CloudFormation templates for provisioning least-privilege IAM roles for the KubeMicroVM operator.

## Quick Deploy

### EKS Pod Identity (recommended)

```bash
# 1. Deploy the IAM role
aws cloudformation deploy \
  --template-file kube-microvm-operator-role.yaml \
  --stack-name kube-microvm-iam-<CLUSTER_NAME> \
  --parameter-overrides \
    ClusterName=<CLUSTER_NAME> \
    UsePodIdentity=true \
  --capabilities CAPABILITY_NAMED_IAM

# 2. Get the role ARN
ROLE_ARN=$(aws cloudformation describe-stacks \
  --stack-name kube-microvm-iam-<CLUSTER_NAME> \
  --query 'Stacks[0].Outputs[?OutputKey==`RoleArn`].OutputValue' \
  --output text)

# 3. Create the Pod Identity Association
aws eks create-pod-identity-association \
  --cluster-name <CLUSTER_NAME> \
  --namespace kube-microvm \
  --service-account kube-microvm-operator \
  --role-arn $ROLE_ARN
```

### IRSA

```bash
# 1. Get your OIDC provider ARN
OIDC_ARN=$(aws eks describe-cluster --name <CLUSTER_NAME> \
  --query 'cluster.identity.oidc.issuer' --output text | \
  sed 's|https://|arn:aws:iam::<ACCOUNT_ID>:oidc-provider/|')

# 2. Deploy the IAM role
aws cloudformation deploy \
  --template-file kube-microvm-operator-role.yaml \
  --stack-name kube-microvm-iam-<CLUSTER_NAME> \
  --parameter-overrides \
    ClusterName=<CLUSTER_NAME> \
    UsePodIdentity=false \
    OIDCProviderArn=$OIDC_ARN \
  --capabilities CAPABILITY_NAMED_IAM

# 3. Install operator with IRSA annotation
ROLE_ARN=$(aws cloudformation describe-stacks \
  --stack-name kube-microvm-iam-<CLUSTER_NAME> \
  --query 'Stacks[0].Outputs[?OutputKey==`RoleArn`].OutputValue' \
  --output text)

helm install kube-microvm-operator oci://ghcr.io/codriverlabs/helm/kube-microvm-operator \
  --set serviceAccount.irsaRoleArn=$ROLE_ARN
```

## Permissions Granted

| Permission | Purpose |
|-----------|---------|
| `lambda:CreateMicroVM` | Provision new MicroVM instances |
| `lambda:DescribeMicroVM` | Read MicroVM state for reconciliation |
| `lambda:StartMicroVM` | Resume stopped instances |
| `lambda:StopMicroVM` | Graceful stop |
| `lambda:PauseMicroVM` | Freeze execution |
| `lambda:ResumeMicroVM` | Unfreeze paused instances |
| `lambda:DeleteMicroVM` | Cleanup on CR deletion |
| `lambda:ListMicroVMs` | Drift detection and orphan cleanup |
| `ec2:Describe{Vpcs,Subnets,SecurityGroups}` | Validate MicroVMNetwork references |
| `sts:GetCallerIdentity` | Health check for AWS connectivity |

## Security Design

- **Resource-scoped**: MicroVM actions scoped to `arn:aws:lambda:*:<account>:microvm:*`
- **Region-locked**: EC2 describe calls restricted to the stack's region
- **No write to networking**: Read-only VPC/subnet/SG access for validation only
- **Session duration**: 1 hour maximum (operator refreshes automatically)
- **Tagged**: Role tagged with cluster name and service account for audit
