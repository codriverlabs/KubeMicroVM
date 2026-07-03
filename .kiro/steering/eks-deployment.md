# EKS Deployment Guidelines

## Development Testing Workflow

When deploying to the EKS test cluster during development:

1. **Delete webhook configurations first** (they block CR edits when operator is down):
   ```bash
   kubectl delete validatingwebhookconfiguration kube-microvm-operator-validating --ignore-not-found
   kubectl delete mutatingwebhookconfiguration kube-microvm-operator-mutating --ignore-not-found
   ```

2. **Force-remove all custom resources** (finalizers block deletion without operator):
   ```bash
   # Patch out finalizers and delete
   for cr in microvmimages microvms microvmreplicasets microvmnetworks; do
     kubectl get $cr -A -o json 2>/dev/null | \
       python3 -c "import json,sys; items=json.load(sys.stdin).get('items',[]); [print(i['metadata']['namespace']+'/'+i['metadata']['name']) for i in items]" 2>/dev/null | \
       while read ns_name; do
         ns="${ns_name%%/*}"; name="${ns_name##*/}"
         kubectl patch $cr "$name" -n "$ns" --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null
         kubectl delete $cr "$name" -n "$ns" --force 2>/dev/null
       done
   done
   ```

3. **Force-uninstall the Helm chart**:
   ```bash
   helm uninstall kube-microvm-operator -n kube-microvm --wait
   # Clean up cert-manager resources
   kubectl delete secret kube-microvm-operator-webhook-tls kube-microvm-operator-ca -n kube-microvm --ignore-not-found
   kubectl delete certificate,issuer --all -n kube-microvm --ignore-not-found
   ```

4. **Only then install the new chart** (never `helm upgrade` during dev iteration):
   ```bash
   helm install kube-microvm-operator <chart> -n kube-microvm \
     --set app.image=<ecr-image> \
     --set app.envs.AWS_REGION=us-east-1 \
     --timeout 4m --wait
   ```

4. **Always use `imagePullPolicy: Always`** to ensure the latest image is pulled,
   even when reusing the same tag (e.g. `0.0.1-rc1`). This is set in application.properties.

## Avoiding Blocked Operations

Any `kubectl delete` or `kubectl patch` that targets a CR with finalizers can block
indefinitely if the operator is not running or not watching that namespace.

**Always use `--timeout=30s` on delete operations:**

```bash
# Safe delete pattern — never blocks longer than 30s
kubectl delete microvm my-vm -n default --force --grace-period=0 --timeout=30s 2>/dev/null || true

# Safe finalizer removal + delete
kubectl patch microvm my-vm -n default \
  --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]' \
  --request-timeout=10s 2>/dev/null || true
kubectl delete microvm my-vm -n default --force --grace-period=0 --timeout=30s 2>/dev/null || true
```

**Rule**: All delete and patch operations in scripts, teardown steps, and
development workflows must include `--timeout=30s` (or `--request-timeout=10s`
for patch). Never issue a bare `kubectl delete` on a CR without a timeout.

## When to Delete the ValidatingWebhookConfiguration

**During operator redeployment only** — not during normal VM teardown.

The webhook has `FailurePolicy: Fail`. When the operator pod is down (between
`helm uninstall` and `helm install`), any CR admission request goes to the
webhook, gets no response, and fails. This blocks CR deletes and patches.

```
Normal VM teardown (operator running):
  → No need to delete webhook config
  → Set desiredState: Terminated → delete MicroVM → delete MicroVMImage

Operator redeployment (dev workflow):
  → Delete webhook configs first (operator going down)
  → Patch out finalizers + delete CRs
  → helm uninstall
  → helm install
```

## Namespace Watching

The operator watches **only namespaces labelled** with
`lambda.aws.amazon.com/manage-microvms=true`. This is enforced at the watch
level via JOSDK namespace label selector — unlabelled namespaces are completely
ignored (no finalizers, no reconciliation, no stuck-delete risk).

See `docs/design/namespace-watching.md` for full design.

**Label a namespace to enable MicroVMs:**
```bash
kubectl label namespace my-team lambda.aws.amazon.com/manage-microvms=true
```

**Remove management (stop watching):**
```bash
kubectl label namespace my-team lambda.aws.amazon.com/manage-microvms-
# Terminate all VMs in that namespace first!
```

**Default at install**: `default` namespace is labelled automatically by Helm.

**To restrict which namespaces the operator watches**, configure in
`application.properties`:

```properties
# Watch specific namespaces only (comma-separated)
quarkus.operator-sdk.namespaces=default,production,staging

# Or watch all (not recommended — use label selector instead)
quarkus.operator-sdk.namespaces=*
```

For multi-tenant clusters, restricting namespaces reduces the operator's blast
radius and limits the RBAC surface. For single-tenant or dev clusters, all-
namespace watching is fine.


- Custom resources with finalizers cannot be deleted without a running operator.
  Always patch out finalizers before uninstalling the chart.
- `helm upgrade` during development often leaves stale resources (old secrets, CRDs, finalizers)
  that conflict with the new deployment. Always uninstall + install.
- With a fixed tag like `0.0.1-rc1`, Kubernetes defaults to `IfNotPresent` and won't
  pull the updated image unless `imagePullPolicy: Always` is explicitly set.
- cert-manager Certificates and Secrets must be re-created when the issuer chain changes.

## VPC Endpoint Requirements

The operator running in private subnets requires these VPC endpoints:
- `com.amazonaws.<region>.eks-auth` — Pod Identity credential resolution
- `com.amazonaws.<region>.lambda-microvm` — Lambda MicroVMs API (private DNS: `lambda-microvm.<region>.on.aws`)
- `com.amazonaws.<region>.sts` — STS for credential validation
- `com.amazonaws.<region>.ecr.api` + `com.amazonaws.<region>.ecr.dkr` — image pulls
- `com.amazonaws.<region>.s3` (Gateway) — ECR layers + S3 code artifacts

**Do NOT set `AWS_MICROVM_ENDPOINT`** — the SDK resolves the service endpoint automatically.
The VPC endpoint's private DNS maps the service hostname to the VPCE IPs transparently.
Setting an explicit endpoint override causes TLS certificate mismatches because the VPCE
cert SANs don't include the `.on.aws` hostname.
