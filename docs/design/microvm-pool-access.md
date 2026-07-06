# Design: MicroVM Pool Access — Service Abstraction & Token Distribution

**Status**: Design / RFC  
**Branch**: `feature/token-burst-investigation`  
**Question**: Can MicroVMs backed by a MicroVMReplicaSet be exposed via a Kubernetes
Service with EndpointSlices? Headless or regular?

---

## Why Neither Standard Service Type Works Directly

A standard Kubernetes Service (regular or headless) assumes endpoints are in-cluster
pod IPs or stable external IPs reachable without per-request authentication.

MicroVMs break both assumptions:

| Kubernetes Service assumption | MicroVM reality |
|-------------------------------|----------------|
| Endpoints are pod IPs or stable IPs | Endpoints are AWS-managed HTTPS URLs (hostnames) |
| All backends are interchangeable | Each VM requires a unique per-request JWE auth token |
| kube-proxy/iptables can route transparently | Auth token must be injected per request per VM |
| Endpoint health = TCP reachability | VM health = AWS state (Running/Suspended/Failed) |

### Regular Service (ClusterIP)
Routes to a pool via iptables/IPVS. Cannot inject per-VM auth headers.
Even if you registered the MicroVM endpoints, the client would hit them
without the correct `X-aws-proxy-auth` token and get 401.

### Headless Service (clusterIP: None)
DNS returns individual A records for each endpoint. Useful when the client
wants to talk to specific backends directly. Problems:
- MicroVM endpoints are hostnames, not IPs — you'd need CNAME records, not A records
- Each endpoint still needs a different auth token — the DNS layer can't help with that
- Token lifecycle (expiry, refresh) is not modelled by DNS TTL

### EndpointSlice with external hostnames
`EndpointSlice` supports `FQDN` addresses, so you could register each
MicroVM's endpoint hostname as a slice entry. But:
- The cluster DNS would not know how to resolve them (they're `*.amazonaws.com` hostnames)
- Each request still needs a different bearer token — the service layer is the wrong place for this

---

## The Right Abstraction: Pool Proxy

The correct pattern for a pool of auth-gated backends is a **proxy/gateway** that sits
between the caller and the MicroVM pool, handling:

1. VM selection (load balancing within the pool)
2. Token acquisition and caching per VM
3. Request proxying with correct auth header
4. Health-aware routing (skip Suspended/Failed VMs)

This maps to two deployment patterns depending on the use case:

---

## Pattern A: 1 Pod per VM (current sidecar injection)

**When to use**: Each workload unit owns its VM exclusively. Strict 1:1 mapping.

```
Pod-A (SA-A) ──sidecar──→ token for VM-A ──→ VM-A endpoint
Pod-B (SA-B) ──sidecar──→ token for VM-B ──→ VM-B endpoint
...
Pod-N (SA-N) ──sidecar──→ token for VM-N ──→ VM-N endpoint
```

Each pod has `lambda.microvm.auth: <vm-name>` annotation. The injected sidecar
handles token refresh. The pod reads token + endpoint from the shared volume.

**RBAC at scale**: The current design requires `resourceNames: [<vm-name>]` on the
Role — one VM name per pod's SA. At 1000 pods this requires either:
- 1000 individual Roles (impractical manually, needs Option B auto-provisioning)
- One Role listing all 1000 names in `resourceNames` (hits etcd object size limits ~1.5MB)
- One wildcard Role (no `resourceNames`) scoped to the namespace — acceptable if namespace
  is single-tenant

**Scale concern**: 1000 sidecars start simultaneously and all hit the operator token
endpoint. The operator serialises AWS `CreateMicrovmAuthToken` calls (thread pool=10).
At ~1s per call: 1000 / 10 = 100s to service all sidecars at startup. The sidecars
will retry — but this is the burst problem we are investigating.

---

## Pattern B: Pool Proxy (new component — `MicroVMGateway`)

**When to use**: Many clients share access to a pool of VMs. Clients do not own
specific VMs. Standard load-balancing semantics.

```
Many clients
     │
     ▼
┌─────────────────────────────────────┐
│  ClusterIP Service                  │  ← standard k8s Service
│  (kube-proxy routes here)           │
└─────────────────────────────────────┘
     │
     ▼
┌─────────────────────────────────────┐
│  MicroVMGateway Deployment          │  ← new operator component
│  - Watches MicroVMReplicaSet        │
│  - Token cache per VM (in-memory)   │
│  - Load-balances across Running VMs │
│  - Proxies HTTPS with auth header   │
└─────────────────────────────────────┘
     │        │        │
     ▼        ▼        ▼
   VM-A     VM-B  ...  VM-N            ← MicroVM endpoints (AWS-managed HTTPS)
```

The gateway pod:
- Has its own ServiceAccount with a wildcard Role (access to all VMs in namespace)
- Caches tokens per VM, refreshes before expiry
- On incoming request: pick a Running VM (round-robin / least-connections), fetch
  token from cache, proxy to `https://{endpoint}/` with `X-aws-proxy-auth` header
- On VM health change (operator updates MicroVM status): remove from pool
- Exposes a standard HTTP endpoint on a ClusterIP Service

This is the **standard reverse proxy / gateway pattern**, similar to Envoy sidecar
in service mesh, but purpose-built for MicroVM token management.

**Headless or regular for the gateway ClusterIP?**

Use **regular ClusterIP** for the gateway service — single stable in-cluster IP,
kube-proxy handles load balancing across gateway replicas (2-3 gateway pods for HA).

**Do not use headless** for the gateway — headless gives you DNS-based client-side
load balancing which is fine for stateless pods, but the gateway itself needs to be
a stable single endpoint from the client's perspective.

---

## Pattern C: EndpointSlice with Hostname Entries + Client-Side Token

**When to use**: Clients are smart enough to handle per-backend tokens.
The service layer does discovery only, not auth.

```yaml
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: microvm-pool
  labels:
    kubernetes.io/service-name: microvm-pool
addressType: FQDN
endpoints:
- addresses:
  - "abc123.lambda-microvm.us-east-1.on.aws"   # VM-A endpoint
  conditions:
    ready: true
  hints:
    forZones:
    - name: us-east-1a
- addresses:
  - "def456.lambda-microvm.us-east-1.on.aws"   # VM-B endpoint
  conditions:
    ready: true
```

The operator (or a new controller) maintains this EndpointSlice:
- Adds entries as VMs reach Running state
- Marks `ready: false` when VMs are Suspended/Failed
- Removes entries when VMs are Terminated

The client discovers endpoints via DNS (headless service) or reads the
EndpointSlice directly, then must:
1. Call the operator token endpoint for the chosen VM
2. Add the `X-aws-proxy-auth` header on each request

**Problem**: FQDN endpoints in EndpointSlice are not supported by kube-proxy
for iptables-mode routing. They work only with Envoy/eBPF-capable dataplanes
(Cilium, Istio). Not portable.

---

## Recommendation

| Use case | Pattern | Service type |
|----------|---------|--------------|
| 1:1 pod-to-VM ownership | A — sidecar injection | No service needed |
| Pool of shared VMs, dumb clients | B — MicroVMGateway | Regular ClusterIP |
| Pool discovery, smart clients | C — EndpointSlice | Headless (FQDN, Cilium/Istio only) |

**For the 1000-VM test scenario**: Pattern A works but requires solving the
startup burst. Pattern B is the right long-term architecture and avoids the
burst problem (the gateway pre-warms a token cache independently of client pods).

---

## What Needs to be Built

### For Pattern A at scale (near-term)
1. Staggered sidecar startup — add a random `initialDelaySeconds` (0–60s) to
   the auth-agent to spread the token burst across a minute
2. Wildcard RBAC option — operator webhook optionally creates a namespace-wide
   Role when injecting, removing the per-VM `resourceNames` constraint
3. Operator token endpoint concurrency — increase thread pool or add request
   queuing with backpressure

### For Pattern B (MicroVMGateway — longer term)
New CRD:
```yaml
apiVersion: lambda.aws.amazon.com/v1alpha1
kind: MicroVMGateway
metadata:
  name: agent-pool-gateway
  namespace: default
spec:
  replicaSetRef: agent-pool-rs        # watches this MicroVMReplicaSet
  replicas: 2                         # gateway pod replicas (HA)
  loadBalancing: RoundRobin           # or LeastConnections, Random
  tokenCacheTtlSeconds: 1800          # pre-warm tokens this far before expiry
```

The operator creates:
- A Deployment for the gateway pods
- A ClusterIP Service in front of them
- A ServiceAccount with wildcard Role over the namespace's MicroVMs
