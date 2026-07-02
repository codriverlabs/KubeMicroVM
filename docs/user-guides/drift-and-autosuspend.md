# User Guide: Drift Detection and Auto-Suspend

## Drift Detection

The operator reconciles the desired state of each `MicroVM` CR against its actual
state in AWS. If a MicroVM is terminated externally (e.g. via the AWS CLI or console)
while `spec.desiredState: Running`, the operator detects the drift and re-creates it.

### How it works

1. Every 60 seconds (default resync period), the reconciler calls `GetMicrovm` on AWS
2. If the VM is `TERMINATED` but desired is `Running` → operator re-creates it
3. New VM ID is reflected in `status.microVmId`

### Test drift detection

```bash
# Terminate externally
VMID=$(kubectl get microvm my-vm -o jsonpath='{.status.microVmId}')
aws lambda-microvms terminate-microvm --microvm-identifier "$VMID" --region us-east-1

# Watch operator re-create it (within ~60s)
microvm describe my-vm -w
```

---

## Auto-Suspend (Idle Policy)

MicroVMs can automatically suspend when idle and resume when traffic arrives.

### Configuration

```yaml
spec:
  maxIdleDurationSeconds: 60      # suspend after 60s of no traffic
  suspendedDurationSeconds: 300   # keep suspended for 5 min, then terminate
  autoResumeEnabled: true         # resume automatically on incoming request
```

### Behavior

| Setting | Behavior |
|---------|----------|
| `maxIdleDurationSeconds` | VM suspends after this many seconds of no traffic |
| `suspendedDurationSeconds` | Suspended VM is terminated after this duration |
| `autoResumeEnabled: true` | First request after suspension wakes the VM (caller waits) |
| `autoResumeEnabled: false` | Suspended VM returns error; caller must explicitly resume |

### Operator behavior with auto-suspend

When a VM auto-suspends due to idle policy:

- The operator updates `status.state` to `Suspended`
- The operator does **not** fight the idle policy — it does not auto-resume the VM
- If you want to resume: set `spec.desiredState: Running` explicitly, or send a
  request (if `autoResumeEnabled: true`)

This is intentional: `desiredState: Running` means "I want this VM running" but the
idle policy is a separate AWS-managed lifecycle, not operator-controlled drift.

### Manual resume

```bash
microvm resume my-vm
# or
kubectl patch microvm my-vm --type=merge -p '{"spec":{"desiredState":"Running"}}'
```

### Auto-resume flow

With `autoResumeEnabled: true`, the caller's request is held by AWS while the VM
boots (~1-2s), then served transparently. No special handling needed in the application.
