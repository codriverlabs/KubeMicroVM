# Design: MicroVM Access Modes

**Status**: RFC  
**Branch**: `feature/token-burst-investigation`  
**Scope**: `MicroVM`, `MicroVMReplicaSet` CRD extensions + new `MicroVMGateway` CRD

---

## Problem

The current API has no concept of how clients access MicroVMs. Access patterns
are implied by how users configure RBAC and pod annotations. There are three
fundamentally different models, each with different operator behaviour needs:

| Model | Description | Current state |
|-------|-------------|---------------|
| Exclusive | 1 client pod owns 1 VM | Works via sidecar injection, but not enforced |
| Shared | N client pods share 1 VM | Works via RBAC, not documented as a mode |
| Pooled | N clients use any available VM from a ReplicaSet | Requires new MicroVMGateway component |

---

## Proposal: `spec.access.mode` on MicroVM and MicroVMReplicaSet

### On `MicroVM` (single VM)

```yaml
apiVersion: lambda.aws.amazon.com/v1alpha1
kind: MicroVM
metadata:
  name: my-agent
spec:
  imageRef: my-image
  desiredState: Running
  access:
    mode: Exclusive   # Exclusive | Shared
```

| Value | Meaning |
|-------|---------|
| `Exclusive` (default) | Operator enforces only one active token at a time. Second concurrent token request is rejected with 409 until the first expires. |
| `Shared` | Any number of pods with appropriate RBAC can request tokens concurrently. No concurrency enforcement. |

### On `MicroVMReplicaSet` (pool of VMs)

```yaml
apiVersion: lambda.aws.amazon.com/v1alpha1
kind: MicroVMReplicaSet
metadata:
  name: agent-pool
spec:
  replicas: 1000
  access:
    mode: Pooled      # Dedicated | Pooled
    gateway:          # only used when mode: Pooled
      replicas: 2
      loadBalancing: RoundRobin   # RoundRobin | LeastConnections | Random
      serviceType: ClusterIP      # ClusterIP | LoadBalancer
```

| Value | Meaning |
|-------|---------|
| `Dedicated` (default) | Each VM in the pool is bound 1:1 to a client pod via sidecar injection and automatic RBAC. Operator assigns VMs to pods via labels. |
| `Pooled` | Operator auto-creates a `MicroVMGateway` that proxies requests to any available Running VM. Clients use a single ClusterIP Service. |

---

## Mode Details

### Mode: Exclusive (1 pod : 1 VM)

The existing sidecar injection pattern, now explicit and optionally enforced.

```
Pod A (lambda.microvm.auth: vm-1) ──→ VM-1 (only Pod A can get tokens)
Pod B (lambda.microvm.auth: vm-2) ──→ VM-2 (only Pod B can get tokens)
```

**RBAC**: Each pod's SA gets a Role with `resourceNames: [<vm-name>]`.  
**Operator change needed**: Token enforcement (reject second concurrent token request).  
**Good for**: Stateful agents where a pod owns a session.

---

### Mode: Shared (N pods : 1 VM)

Multiple pods share access to the same VM. All pods get tokens for the same
MicroVM endpoint. The VM serves all callers concurrently.

```
Pod A ──→ token for vm-1 ──→ VM-1
Pod B ──→ token for vm-1 ──→ VM-1  (same VM, different token per caller)
Pod C ──→ token for vm-1 ──→ VM-1
```

**RBAC**: All pods' SAs get `resourceNames: [vm-1]`.  
**Operator change needed**: None — this already works. Just needs explicit documentation  
and an `access.mode: Shared` annotation that disables any future exclusive enforcement.  
**Good for**: Multiple workers calling the same stateless MicroVM.

---

### Mode: Dedicated (1 pod : 1 VM from pool, assignment managed by operator)

A smarter version of sidecar injection at pool scale. The operator assigns each
VM in the ReplicaSet to exactly one client pod, manages the binding lifecycle,
and auto-provisions RBAC per assignment.

```
Pod A ──assigned to──→ VM-pool-xkj87 ──→ VM endpoint
Pod B ──assigned to──→ VM-pool-zjxh6 ──→ VM endpoint
Pod C ──assigned to──→ VM-pool-z9rvf ──→ VM endpoint
```

Assignment mechanism (proposed):
- Operator watches pods with annotation `lambda.microvm.pool: agent-pool`
- For each unassigned pod, picks an unassigned Running VM from the pool
- Patches the pod annotation with the assigned VM name: `lambda.microvm.auth: <vm-name>`
- Auto-creates Role + RoleBinding for the assignment
- On pod deletion: releases VM back to the pool

This is analogous to `PersistentVolumeClaim` — the pod claims a VM from the pool.

**Operator changes needed**: New assignment controller, claim lifecycle management.  
**RBAC at scale**: Each assignment creates one Role + one RoleBinding. At 1000 pods:
1000 roles and 1000 bindings in the namespace. Manageable but verbose.  
**Good for**: Stateful workloads at scale where each worker owns a session.

---

### Mode: Pooled (N clients : M VMs via gateway)

The operator auto-creates a `MicroVMGateway` deployment and ClusterIP Service.
Clients hit a single stable endpoint. The gateway selects an available VM,
fetches/caches the token, and proxies the request.

```
Many clients
    │
    ▼
ClusterIP Service (agent-pool-gateway:80)
    │
    ▼
MicroVMGateway Deployment (2 replicas)
    │ maintains token cache per Running VM
    │ load-balances across Running VMs
    ├──→ VM-pool-abc (Running)
    ├──→ VM-pool-def (Running)
    ├──→ VM-pool-ghi (Suspended — skipped)
    └──→ VM-pool-... (Running)
```

**RBAC**: Gateway SA gets one wildcard Role (no `resourceNames`) scoped to namespace.  
**Token burst**: Gateway pre-warms token cache on startup and refreshes proactively.
No startup burst from client pods.  
**Operator changes needed**: `MicroVMGateway` controller, gateway deployment management.  
**Good for**: Stateless MicroVMs serving many clients, agentic pools, LLM inference pools.

---

## CRD Changes

### MicroVMSpec additions

```java
public class MicroVMSpec {
    // ... existing fields ...
    private MicroVMAccessSpec access;  // new
}

public class MicroVMAccessSpec {
    private String mode = "Exclusive";   // Exclusive | Shared
}
```

### MicroVMReplicaSetSpec additions

```java
public class MicroVMReplicaSetSpec {
    // ... existing fields ...
    private MicroVMReplicaSetAccessSpec access;  // new
}

public class MicroVMReplicaSetAccessSpec {
    private String mode = "Dedicated";   // Dedicated | Pooled
    private MicroVMGatewaySpec gateway;  // only used when mode=Pooled
}

public class MicroVMGatewaySpec {
    private Integer replicas = 2;
    private String loadBalancing = "RoundRobin";   // RoundRobin | LeastConnections | Random
    private String serviceType = "ClusterIP";       // ClusterIP | LoadBalancer
}
```

### New CRD: MicroVMGateway

Auto-created by operator when `MicroVMReplicaSet.spec.access.mode: Pooled`.
Can also be created manually against any ReplicaSet.

```yaml
apiVersion: lambda.aws.amazon.com/v1alpha1
kind: MicroVMGateway
metadata:
  name: agent-pool-gateway
  namespace: default
spec:
  replicaSetRef: agent-pool
  replicas: 2
  loadBalancing: RoundRobin
  serviceType: ClusterIP
  tokenCacheTtlSeconds: 1800
status:
  phase: Ready
  serviceClusterIP: 10.100.42.17
  activeVMs: 161
  cachedTokens: 161
  conditions: [...]
```

---

## Implementation Priority

| Mode | Complexity | Value | Priority |
|------|-----------|-------|----------|
| `Shared` on MicroVM | Trivial — documentation only | Low | P3 |
| `Exclusive` enforcement | Low — token count check in TokenResource | Medium | P2 |
| `Pooled` + MicroVMGateway | High — new controller + proxy component | High | P1 |
| `Dedicated` with assignment controller | High — claim lifecycle, RBAC automation | Medium | P2 |

**Recommended first implementation**: `Pooled` mode + `MicroVMGateway`.
It unlocks the highest-value use case (shared pool access), eliminates the
token burst problem, and requires no changes to how existing sidecar injection works.

---

## Open Questions

1. Should `Dedicated` mode use a `MicroVMClaim` CRD (like PVC) or implicit pod annotation assignment?
2. For `Pooled` mode, should the gateway proxy at HTTP level (L7) or forward raw TCP (L4)?  
   L7 is required to inject the `X-aws-proxy-auth` header.
3. Should `MicroVMGateway` support multiple ReplicaSets (fan-in from several pools)?
4. What is the token cache invalidation strategy when a VM is evicted/replaced mid-request?
5. Should the gateway expose per-VM metrics (requests routed, tokens refreshed) via Prometheus?
