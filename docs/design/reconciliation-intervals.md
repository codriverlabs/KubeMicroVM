# MicroVM Reconciliation Intervals

## Overview

The operator reconciles every `MicroVM` CR on a fixed schedule to detect state
drift between Kubernetes and AWS. This document describes the intervals, the
reasons for the current values, and the known limitation around operator
restarts.

## Intervals

| Situation | Reschedule interval | Why |
|-----------|--------------------|----|
| Stable state (Running, Suspended) | **60 s** | Polls AWS once per minute to detect external termination or state changes |
| State transition in progress | **5 s** | Picks up new state quickly after a Running→Suspended or resume transition |
| Error / transient failure | **10 s** | Retries cleanup or API calls without hammering AWS |
| Delete blocked (running VMs) | **10 s** | Retries image deletion once the VMs clear |

Source: `MicroVMReconciler.RESYNC_PERIOD = Duration.ofSeconds(60)`

## What this means in practice

### Detection lag after external termination

If AWS terminates a MicroVM externally (idle policy, lifetime limit, manual
API call), the operator detects it at the next 60-second reconcile. Worst-case
lag is **60 s**, average is **30 s**.

Once detected, the operator calls `GetMicrovm`, confirms `TERMINATED`, removes
the finalizer, and the CR deletes normally.

### Stale CRs after operator restart

When the operator restarts (upgrade, crash, pod eviction), JOSDK drops all
pending in-flight reschedules. After startup, the informer re-lists all CRs
and triggers a reconcile for each — but this initial sweep takes longer than
the steady-state 60 s interval because all CRs are queued simultaneously.

This means VMs that AWS terminated *while the operator was down* may have
their CRs sitting as `Terminating` with a finalizer for **several minutes**
after the operator restarts, until the initial reconcile sweep reaches them.

**This is the primary cause of "stale CRs with no matching AWS resource"**
seen after operator upgrades or pod restarts during UAT.

### Maximum VM lifetime and orphaned CRs

AWS Lambda MicroVMs have a hard maximum lifetime (typically 8 hours). A VM
that exceeds this is terminated by AWS regardless of the desired state. If the
operator is restarted around the same time as the expiry, the CR may remain
`Terminating` for several minutes until reconciliation catches up.

## Known gap: no startup reconciliation sweep

JOSDK does not currently provide a hook to immediately reconcile all existing
CRs on startup with elevated priority. The operator relies on the informer
re-list triggering events for each CR, which is serialised through the normal
reconciler work queue.

**Workaround**: after an operator restart, stale `Terminating` CRs will clear
automatically within a few minutes. If they do not clear within 5 minutes,
force-strip the finalizer:

```bash
kubectl patch microvm <name> -n <namespace> \
  --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]'
```

**Future improvement**: add a startup event that immediately requeues all CRs
in non-terminal states (not `TERMINATED` or `Failed`) with high priority. This
would reduce the post-restart drift window from several minutes to under 60 s.
Tracked as a backlog item — not a blocker for GA.

## Related

- `MicroVMReconciler.java` — `RESYNC_PERIOD`, `rescheduleAfter` call sites
- `MicroVMImageReconciler.java` — similar intervals for image reconciliation
- [image-arn-collision-prevention.md](image-arn-collision-prevention.md) — delete-blocked backoff (Layer 2)
