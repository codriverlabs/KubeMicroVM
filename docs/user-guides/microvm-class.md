# User Guide: MicroVMClass

`MicroVMClass` defines a named runtime profile — idle policy, networking connectors,
and sizing — that platform admins create once and developers reference by name via
`spec.className` on a `MicroVM`.

This follows the Kubernetes `StorageClass` / `IngressClass` pattern:
- Admins define what classes are available cluster-wide or per-namespace
- Developers pick a class by name — no need to know the underlying ARNs or tuning values
- `spec.className` is **optional** — MicroVMs without a class use their own spec values directly

---

## Creating a MicroVMClass

```yaml
apiVersion: lambda.aws.amazon.com/v1alpha1
kind: MicroVMClass
metadata:
  name: agentic-standard
  namespace: default
spec:
  description: "AI coding assistants, interactive sessions"
  maxIdleDurationSeconds: 300        # suspend after 5 min idle
  suspendedDurationSeconds: 7200     # keep suspended for 2 hr, then terminate
  autoResumeEnabled: true            # wake on incoming traffic
  maximumDurationSeconds: 28800      # 8 hr hard cap
  ingressNetworkConnectors:
    - arn:aws:lambda:us-east-1:aws:network-connector:aws-network-connector:ALL_INGRESS
  egressNetworkConnectors:
    - arn:aws:lambda:us-east-1:aws:network-connector:aws-network-connector:INTERNET_EGRESS
```

---

## Built-in Profiles (recommended starting points)

### `agentic-standard` — AI agents and interactive sessions

| Setting | Value |
|---------|-------|
| Idle suspension | 5 min |
| Suspended TTL | 2 hr |
| Auto-resume | ✅ |
| Hard cap | 8 hr |
| Ingress | ALL_INGRESS |
| Egress | INTERNET_EGRESS |

Best for: coding assistants, interactive dev environments, agentic AI workloads.

### `batch-job` — CI/CD jobs, one-shot tasks

```yaml
spec:
  description: "Run-to-completion jobs — no suspend, hard 1 hr cap"
  autoResumeEnabled: false
  maximumDurationSeconds: 3600
  ingressNetworkConnectors:
    - arn:aws:lambda:us-east-1:aws:network-connector:aws-network-connector:NO_INGRESS
  egressNetworkConnectors:
    - arn:aws:lambda:us-east-1:aws:network-connector:aws-network-connector:INTERNET_EGRESS
```

Best for: security scans, build jobs, data pipelines.

### `vpc-agent` — agents needing private VPC access

```yaml
spec:
  description: "Agents that access RDS, ElastiCache, or internal APIs"
  maxIdleDurationSeconds: 300
  suspendedDurationSeconds: 3600
  autoResumeEnabled: true
  ingressNetworkConnectors:
    - arn:aws:lambda:us-east-1:aws:network-connector:aws-network-connector:ALL_INGRESS
  egressNetworkConnectors:
    - arn:aws:lambda:us-east-1:123456789012:network-connector:my-vpc-connector
```

Best for: agents that query internal databases or private APIs.

---

## Using a MicroVMClass

Reference by `spec.className`:

```yaml
apiVersion: lambda.aws.amazon.com/v1alpha1
kind: MicroVM
metadata:
  name: agent-session-1
  namespace: default
spec:
  imageRef: my-agent-image
  className: agentic-standard    # ← picks up idle policy + connectors
  desiredState: Running
```

---

## Field Precedence

Fields set explicitly on the `MicroVM` always win over the class:

```
MicroVM spec field explicitly set  →  wins
MicroVMClass spec field            →  applied if MicroVM field is null
Global webhook default             →  applied if both are null
```

Override a single field:

```yaml
spec:
  className: agentic-standard
  maxIdleDurationSeconds: 60    # override: suspend faster for this VM
```

---

## Listing Available Classes

```bash
kubectl get microvmclasses -n default
```

The validating webhook checks that the referenced class exists in the same namespace
before admitting a `MicroVM` create.

---

## Cost Implications

| Class | Cost model | Best for |
|-------|------------|----------|
| `agentic-standard` | Pay while active, ~$0 when suspended | < 13% utilization |
| `batch-job` | Pay for job duration only | Predictable run-to-completion |
| `vpc-agent` | Pay while active, suspend when idle | Private network workloads |

See [AWS Lambda MicroVMs pricing](../aws-microvms-official/01-overview.md) for details.
