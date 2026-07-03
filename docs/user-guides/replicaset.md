# User Guide: ReplicaSet

`MicroVMReplicaSet` manages a pool of identical MicroVM replicas — similar to
Kubernetes `ReplicaSet` but for MicroVMs.

## Creating a ReplicaSet

```yaml
apiVersion: lambda.aws.amazon.com/v1alpha1
kind: MicroVMReplicaSet
metadata:
  name: agent-pool
  namespace: default
spec:
  replicas: 3
  template:
    imageRef: my-agent-image
    className: agentic-standard
    maxIdleDurationSeconds: 900
    suspendedDurationSeconds: 1800
```

```bash
kubectl apply -f replicaset.yaml
microvm rs list
```

## Scaling

```bash
# via CLI
microvm rs scale agent-pool --replicas 5

# via kubectl
kubectl patch microvmreplicaset agent-pool \
  --type=merge -p '{"spec":{"replicas":5}}'
```

## Drift detection

If a MicroVM in the pool is terminated externally, the operator detects the drift
and creates a replacement within one reconcile cycle (default: 60s).

## Deleting a ReplicaSet

Deleting the `MicroVMReplicaSet` terminates all member VMs:

```bash
kubectl delete microvmreplicaset agent-pool
```

## Listing members

```bash
kubectl get microvms -n default -l microvm.lambda.aws.amazon.com/replicaset=agent-pool
```
