# External Dependencies

## AWS Services over Third-Party

When testing or implementing functionality that requires external endpoints, prefer
official AWS services over third-party alternatives:

- **IP checking**: `https://checkip.amazonaws.com/` (not httpbin.org, ifconfig.me, etc.)
- **HTTP testing**: Use AWS-owned endpoints or deploy your own test targets
- **Time sync**: AWS NTP endpoints
- **DNS resolution**: Route 53 resolver endpoints

Rationale: AWS endpoints are always available in-region, have no rate limits for
reasonable usage, and don't introduce external dependencies that could break tests.

## Container Images from Public ECR

When choosing base images for test fixtures, operator containers, or build tools,
prefer `public.ecr.aws` over Docker Hub or other registries:

- **Node.js**: `public.ecr.aws/eks-distro-build-tooling/eks-distro-minimal-base-nodejs:16-al23`
- **Amazon Linux**: `public.ecr.aws/amazonlinux/amazonlinux:2023`
- **AWS CLI**: `public.ecr.aws/aws-cli/aws-cli:latest`
- **Lambda MicroVM base**: `public.ecr.aws/lambda/microvms:al2023-minimal`

Rationale:
- No Docker Hub pull rate limits
- Available via VPC endpoints (`com.amazonaws.<region>.ecr.api`)
- Maintained by AWS with security patches
- Consistent availability across all AWS regions

## Private ECR for Operator Images

The operator and auth-agent images are pushed to private ECR for deployment:
```
<ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/plasticity-of-cloud/kube-microvm-operator
```

EKS nodes pull from private ECR via VPC endpoints — no internet egress required for image pulls.
