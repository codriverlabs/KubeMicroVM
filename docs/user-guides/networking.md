# User Guide: Networking

KubeMicroVM supports three networking modes for MicroVMs.

## Modes

| Mode | Ingress | Egress | Use case |
|------|---------|--------|----------|
| Internet egress only | No inbound | Public internet | Batch jobs, outbound-only agents |
| Full connectivity | Inbound + outbound internet | Public internet | Interactive agents, API servers |
| VPC egress | Inbound | Private VPC | Agents accessing RDS, internal APIs |
| No egress | Inbound | Blocked | Sandboxed execution |

---

## AWS-Managed Connectors

AWS provides built-in connectors for common patterns:

```
ALL_INGRESS     — allows inbound connections from callers
INTERNET_EGRESS — allows outbound to public internet
NO_INGRESS      — blocks inbound (use for batch jobs)
```

Reference them in your `MicroVM` spec:

```yaml
spec:
  ingressNetworkConnectors:
    - "arn:aws:lambda:us-east-1:aws:network-connector:aws-network-connector:ALL_INGRESS"
  egressNetworkConnectors:
    - "arn:aws:lambda:us-east-1:aws:network-connector:aws-network-connector:INTERNET_EGRESS"
```

---

## VPC Egress (MicroVMNetwork)

For private VPC access, create a `MicroVMNetwork` that provisions a VPC network connector:

```yaml
apiVersion: lambda.aws.amazon.com/v1alpha1
kind: MicroVMNetwork
metadata:
  name: my-vpc-egress
  namespace: default
spec:
  vpcId: vpc-0abc123
  subnetIds:
    - subnet-0abc123
    - subnet-0def456
  securityGroupIds:
    - sg-0abc123
  operatorRoleArn: "arn:aws:iam::123456789012:role/kube-microvm-operator"
```

Wait for the connector to become `ACTIVE`:

```bash
kubectl get microvmnetwork my-vpc-egress -w
# NAME            STATE    CONNECTOR-ARN
# my-vpc-egress   ACTIVE   arn:aws:lambda:us-east-1:...
```

Reference it by name in your `MicroVM`:

```yaml
spec:
  networkRef: my-vpc-egress    # operator resolves to connector ARN
  ingressNetworkConnectors:
    - "arn:aws:lambda:us-east-1:aws:network-connector:aws-network-connector:ALL_INGRESS"
```

---

## No Egress (sandboxed)

For fully isolated execution:

```yaml
spec:
  ingressNetworkConnectors:
    - "arn:aws:lambda:us-east-1:aws:network-connector:aws-network-connector:ALL_INGRESS"
  # no egressNetworkConnectors — outbound blocked
```

---

## Using MicroVMClass for networking

Define connectors once in a `MicroVMClass` so developers don't need to know ARNs:

```yaml
apiVersion: lambda.aws.amazon.com/v1alpha1
kind: MicroVMClass
metadata:
  name: vpc-agent
  namespace: default
spec:
  ingressNetworkConnectors:
    - "arn:aws:lambda:us-east-1:aws:network-connector:aws-network-connector:ALL_INGRESS"
  egressNetworkConnectors:
    - "arn:aws:lambda:us-east-1:123456789012:network-connector:my-vpc-connector"
```

Then in the MicroVM:

```yaml
spec:
  imageRef: my-agent
  className: vpc-agent    # connectors inherited from class
```

---

## Listing network connectors

```bash
microvm network list
kubectl get microvmnetworks -n default
```
