# Networking
Source: https://docs.aws.amazon.com/lambda/latest/dg/microvms-networking.html
Downloaded: 2026-07-03T14:32:00Z

Network access configured via Network Connector resources associated at run time.
Cannot be changed while MicroVM is running.

## Overview

- **Ingress connectors** — enable inbound HTTPS connectivity. AWS-managed, referenced by ARN.
- **Egress connectors** — enable outbound traffic. Default: public internet access.
  Create customer-managed VPC connector for private routing.

Single connector reusable across many MicroVMs.

## Inbound connectivity

Unique HTTPS endpoint URL per MicroVM. Lambda routes to ports inside VM.
Default target: port 8080.

### Port routing priority

1. `X-aws-proxy-port` header
2. WebSocket subprotocol `lambda-microvms.port.N`
3. Default: 8080

### Protocols

HTTP/1.1, HTTP/2, WebSockets, gRPC, SSE. TLS always between client and endpoint.

### Request/response bandwidth (scales with size)

| MicroVM size (baseline) | Max bandwidth |
|------------------------|---------------|
| 0.5 GB, 0.25 vCPU | 1 MB/s (8 Mbps) |
| 1 GB, 0.5 vCPU | 2 MB/s (16 Mbps) |
| 2 GB, 1 vCPU | 4 MB/s (32 Mbps) |
| 4 GB, 2 vCPU | 8 MB/s (64 Mbps) |
| 8 GB, 4 vCPU | 16 MB/s (128 Mbps) |

### Error responses from endpoint

| Code | Status | Cause |
|------|--------|-------|
| 400 | Bad Request | Malformed request or invalid port header |
| 403 | Forbidden | Missing/expired/invalid token or unauthorized port |
| 429 | Too Many Requests | Rate limit. Retry with backoff. |
| 500 | Internal Server Error | Retry |
| 502 | Bad Gateway | App not responding or auto-resume failed |

### HTTP/2 support

ALPN negotiation on TLS handshake. For plaintext HTTP apps inside VM, use
`X-aws-proxy-force-h2: true` header.

## Outbound connectivity

**By default, Lambda MicroVMs have public internet access on the egress path.**

To connect to private VPC resources (RDS, ElastiCache, internal APIs, on-premises via
Direct Connect/VPN): create a Lambda Network Connector with VPC configuration.

VPC egress subject to security group rules and network ACLs.

## Working with egress network connectors

### Prerequisites — IAM role for ENI creation

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "CreateENI",
      "Effect": "Allow",
      "Action": "ec2:CreateNetworkInterface",
      "Resource": [
        "arn:aws:ec2:*:*:network-interface/*",
        "arn:aws:ec2:*:*:subnet/*",
        "arn:aws:ec2:*:*:security-group/*"
      ]
    },
    {
      "Sid": "TagENI",
      "Effect": "Allow",
      "Action": "ec2:CreateTags",
      "Resource": "arn:aws:ec2:*:*:network-interface/*",
      "Condition": {
        "StringEquals": {
          "ec2:ManagedResourceOperator": "network-connectors.lambda.amazonaws.com"
        }
      }
    }
  ]
}
```

### Creating a network connector

```bash
aws lambda-core create-network-connector \
  --name my-connector \
  --configuration '{
    "VpcEgressConfiguration": {
      "SubnetIds": ["subnet-xxx"],
      "SecurityGroupIds": ["sg-xxx"],
      "NetworkProtocol": "IPv4",
      "AssociatedComputeResourceTypes": ["MicroVm"]
    }
  }' \
  --operator-role arn:aws:iam::123456789012:role/NetworkConnectorOperatorRole
```

### Network connector states

| State | Description |
|-------|-------------|
| PENDING | Being created (ENIs provisioning) |
| ACTIVE | Ready to use |
| INACTIVE | Temporarily inactive |
| FAILED | Provisioning failed. Check StateReason |
| DELETING | Being deleted (ENIs cleaned up) |
| DELETE_FAILED | Deletion failed |

### Running with network connector

```bash
aws lambda-microvms run-microvm \
  --image-identifier arn:aws:lambda:us-east-1:123456789012:microvm-image:my-image \
  --egress-network-connectors connector-arn \
  --idle-policy '{"maxIdleDurationSeconds":900,"suspendedDurationSeconds":1800,"autoResumeEnabled":false}'
```

Note: Terminate all MicroVMs using a connector before updating/deleting it.
