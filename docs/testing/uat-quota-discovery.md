# UAT: Quota Discovery (Runtime Mode)

**Status**: ✅ Pass  
**Branch**: `feature/e2e-quota-discovery`  
**Cluster**: `ecp-us1` (us-east-1)  
**Date**: 2026-07-08

---

## What Was Tested

Runtime quota discovery: operator queries AWS Service Quotas API at startup
when `AWS_QUOTA_DISCOVERY=true` (Helm: `--set-string app.envs.AWS_QUOTA_DISCOVERY=true`).

Requires IAM permission `service-quotas:GetServiceQuota` on the operator role.

---

## Setup

Added `service-quotas:GetServiceQuota` to `KubeMicroVMOperatorPolicy` inline policy
on the `kube-microvm-operator` IAM role.

Deployed with:
```bash
helm upgrade kube-microvm-operator <chart> \
  --set-string "app.envs.AWS_QUOTA_DISCOVERY=true"
```

---

## Result

Operator startup log:
```
INFO  [QuotaDiscovery] Quota discovery enabled — querying AWS Service Quotas
INFO  [QuotaDiscovery] Discovered quotas: run=5/s terminate=10/s suspend=2/s
                                          resume=5/s authToken=50/s imageBuilds=10
```

- No `QUOTA MISMATCH` warnings ✅
- Discovered values match configured defaults ✅

---

## Sign-Off

- [x] IAM permission added ✅
- [x] Runtime discovery log confirmed ✅
- [x] No QUOTA MISMATCH warnings ✅
