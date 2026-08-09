# CA Certificate Distribution for Auth-Agent Sidecars

## Status: Design

## Context

### Why cert-manager?

The operator exposes an HTTPS endpoint (port 8443) serving two functions:
1. **Admission webhooks** — Kubernetes API server calls our validating/mutating webhooks over TLS
2. **Token endpoint** — auth-agent sidecars call the operator to fetch MicroVM auth tokens over TLS

Both require a TLS certificate with a SAN matching the Service DNS name
(`kube-microvm-operator.kube-microvm.svc`). Kubernetes requires the webhook's
`caBundle` to verify the certificate presented by our endpoint.

We use **cert-manager** because:
- It is the de-facto standard for in-cluster certificate lifecycle on Kubernetes
- It handles issuance, rotation, and renewal automatically
- It integrates with the webhook configuration via the `cert-manager.io/inject-ca-from` annotation
- It eliminates the need for us to implement CA generation, rotation, and secret management
- It is already present in the majority of production clusters (~60-70% adoption)

We do **not** self-sign certificates because:
- In production, clusters should have a single centralized PKI (cert-manager, Vault PKI, AWS Private CA, OpenShift service-ca)
- Self-signing per operator creates N independent trust roots in the cluster — no central governance, no auditability, compliance failure
- Our operator should consume certs from whatever infrastructure exists, not replace it

### The problem

The auth-agent sidecar runs in **user workload namespaces** (e.g. `default`, `production`).
It connects to the operator's HTTPS token endpoint and must verify the TLS certificate.
To verify, it needs the CA certificate that signed the operator's TLS cert.

The CA cert lives in the `kube-microvm` namespace (in the cert-manager-issued Secret
`kube-microvm-operator-webhook-tls`, field `ca.crt`). Pods in other namespaces cannot
read Secrets across namespace boundaries.

### Requirements

1. The auth-agent sidecar must verify TLS when connecting to the operator (no trust-all)
2. The CA cert must be available in every namespace that has managed MicroVMs
3. Rotation must be handled — when cert-manager renews the CA, sidecars must get the new CA
4. No additional dependencies beyond cert-manager (no trust-manager)
5. RBAC must be least-privilege — the operator should only be able to write the specific CA Secret

## Decision

The operator itself distributes the CA certificate to managed namespaces:

1. On startup and periodically, read `ca.crt` from the operator's TLS Secret (`kube-microvm-operator-webhook-tls` in `kube-microvm` namespace)
2. For each namespace labelled `lambda.aws.amazon.com/manage-microvms=true`, ensure a Secret named `kube-microvm-operator-ca` exists containing only `ca.crt`
3. When the source CA changes (cert-manager rotation), detect via watch and update all copies
4. The `PodMutatingWebhook` injects a volume mount from `kube-microvm-operator-ca` into the auth-agent sidecar at `/var/run/secrets/microvm/ca.crt`

### Why not trust-manager?

trust-manager (cert-manager sub-project) solves exactly this — distributing CA bundles
across namespaces. However:
- It is a separate controller, separate Helm chart, separate CRD
- Most clusters that have cert-manager do NOT also have trust-manager
- Adding it increases our install prerequisites
- Our use case is trivial (one CA cert, replicated to N namespaces) — not worth an extra dependency

### Why not fetch from API at runtime?

The sidecar could read the CA Secret from the Kubernetes API at startup. However:
- Requires granting the **workload's service account** read access to Secrets in the operator namespace (cross-namespace read)
- Widens the blast radius — every pod with MicroVM access can read operator Secrets
- Fails if API server is temporarily unavailable during pod startup

Mounting the CA as a volume is simpler, more reliable, and follows Kubernetes conventions.

## RBAC Design

### Principle: resource-name-restricted RBAC

Kubernetes RBAC supports `resourceNames` to restrict access to specific named resources.
The operator only needs to write **one specific Secret** (`kube-microvm-operator-ca`)
in managed namespaces.

```yaml
# ClusterRole: allows writing ONLY the specific CA Secret by name
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kube-microvm-operator-ca-distributor
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    resourceNames: ["kube-microvm-operator-ca"]
    verbs: ["get", "create", "update", "patch"]
```

**Important limitation**: `resourceNames` does not apply to `create` in Kubernetes RBAC
(you can't restrict which name a new resource will have). To handle this properly:

```yaml
# ClusterRole: two rules — create restricted by namespace label, get/update by name
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kube-microvm-operator-ca-distributor
rules:
  # Read/update the specific CA Secret by name
  - apiGroups: [""]
    resources: ["secrets"]
    resourceNames: ["kube-microvm-operator-ca"]
    verbs: ["get", "update", "patch"]
  # Create secrets — controller logic ensures only kube-microvm-operator-ca is created
  # The namespace label selector in the operator limits WHERE this is used
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["create"]
```

### Why this is safe

1. **`resourceNames` on get/update/patch** — the operator can only read and modify the
   one named Secret, not arbitrary Secrets in workload namespaces
2. **`create` is unrestricted by name** (Kubernetes RBAC limitation) — but the operator
   code only ever creates `kube-microvm-operator-ca`. This is auditable via the controller code.
3. **Namespace scope** — the operator only processes namespaces with the
   `lambda.aws.amazon.com/manage-microvms=true` label. Unlabelled namespaces are never touched.
4. **Secret content** — the Secret contains only `ca.crt` (a public certificate).
   It is not sensitive material — it's the same value in the webhook configuration's `caBundle`.

### Alternative: namespace-scoped Role per namespace

For maximum restriction, the Helm chart could create a Role + RoleBinding in each
managed namespace instead of a ClusterRole:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: kube-microvm-ca-writer
  namespace: production  # per-namespace
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    resourceNames: ["kube-microvm-operator-ca"]
    verbs: ["get", "update", "patch", "create"]
```

Trade-off: more Roles to manage, but tighter blast radius. Suitable for multi-tenant
environments where a ClusterRole granting `create secrets` is not acceptable.

**Recommendation for Community edition**: Use ClusterRole (simpler, works with dynamic
namespace labelling). PRO edition can offer namespace-scoped Roles for regulated environments.

## CA Rotation Flow

```
cert-manager rotates CA
    → Secret kube-microvm-operator-webhook-tls in kube-microvm updated
    → Operator watches this Secret (informer)
    → Operator reads new ca.crt
    → For each managed namespace:
        → Update Secret kube-microvm-operator-ca with new ca.crt
    → Running sidecars pick up new CA via volume mount refresh
        (Kubernetes updates projected Secret volumes within ~60s)
```

Sidecars do NOT need to restart — Kubernetes propagates Secret changes to mounted
volumes automatically (kubelet sync period, typically 60-120 seconds).

## Sidecar Injection Changes

The `PodMutatingWebhook` adds to injected pods:

```yaml
# Additional volume
volumes:
  - name: microvm-ca
    secret:
      secretName: kube-microvm-operator-ca
      items:
        - key: ca.crt
          path: ca.crt

# Additional volume mount in the auth-agent sidecar
volumeMounts:
  - name: microvm-ca
    mountPath: /var/run/secrets/microvm
    readOnly: true
```

The auth-agent reads `/var/run/secrets/microvm/ca.crt` for TLS verification (already
implemented in the security fix — it loads from this path by default).

## Implementation Plan

1. Add `SecretReplicator` component to `operator-controller` — watches the operator TLS
   Secret, replicates `ca.crt` to managed namespaces
2. Add RBAC (ClusterRole + ClusterRoleBinding) to Helm chart
3. Update `PodMutatingWebhook` to inject the CA volume + mount
4. Update auth-agent `application.properties` default path
5. Integration tests: verify CA Secret is created/updated/deleted with namespace lifecycle
6. UAT: verify sidecar TLS verification works end-to-end

## Files to Change

| File | Change |
|------|--------|
| `operator-controller/.../SecretReplicator.java` | New — watches TLS Secret, replicates CA |
| `operator-controller/src/main/helm/templates/operator-extra-rbac.yaml` | Add CA distributor ClusterRole |
| `operator-webhook/.../mutation/PodMutatingWebhook.java` | Inject CA volume + mount |
| `operator-auth-agent/src/main/resources/application.properties` | Already done — reads from `/var/run/secrets/microvm/ca.crt` |
| `operator-tests/...` | Integration tests for replication |
| `uat/tests/04_pod_token_injection.robot` | Update to verify TLS works |
