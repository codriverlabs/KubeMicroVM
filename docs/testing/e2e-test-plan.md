# E2E Testing Plan — MicroVMNetwork & Full Integration

## Overview

End-to-end testing of the KubeMicroVM operator on a live EKS cluster,
covering network connector lifecycle and integration with MicroVM workloads.

**Cluster**: `ecp-us1` (EKS Auto Mode, us-east-1)  
**VPC**: `vpc-0e40b0159e24f935e`  
**Subnets**: `subnet-0fdc8b729163e12a7` (us-east-1a), `subnet-0bde13101743f4751` (us-east-1b)  
**Security Group**: `sg-01032cc226cb1615d`

---

## Test Cases

### 1. MicroVMNetwork Lifecycle

| ID | Test | Expected |
|----|------|----------|
| NET-01 | Create MicroVMNetwork with valid VPC config | Connector created, state → ACTIVE |
| NET-02 | Describe MicroVMNetwork status after creation | Shows connectorArn, connectorId, state=ACTIVE |
| NET-03 | Update MicroVMNetwork (add security group) | Connector updated, state → ACTIVE |
| NET-04 | Delete MicroVMNetwork (no VMs attached) | Connector deleted, CR finalizer removed |
| NET-05 | Delete MicroVMNetwork (VMs still attached) | Deletion blocked until VMs terminated |
| NET-06 | Create MicroVMNetwork with invalid subnet | Error surfaced in status conditions |

### 2. MicroVM with Network

| ID | Test | Expected |
|----|------|----------|
| VM-NET-01 | Create MicroVM with `networkRef` pointing to active MicroVMNetwork | VM starts with VPC networking |
| VM-NET-02 | Create MicroVM with `egressNetworkConnectors` (connector ARN) | VM starts with egress connectivity |
| VM-NET-03 | Verify VM can reach internet via network connector | curl from VM endpoint succeeds |
| VM-NET-04 | Terminate MicroVM, then delete MicroVMNetwork | Both cleaned up successfully |

### 3. MicroVMImage Lifecycle (already validated)

| ID | Test | Status |
|----|------|--------|
| IMG-01 | Create MicroVMImage from S3 | ✅ Passed (hello-node-e2e) |
| IMG-02 | Image builds to ACTIVE version | ✅ Passed (v1.0 SUCCESSFUL) |
| IMG-03 | Create MicroVM from image | ✅ Passed (Running) |
| IMG-04 | Obtain auth token and call endpoint | ✅ Passed ({"status":"ok"}) |

### 4. MicroVM Lifecycle

| ID | Test | Expected |
|----|------|----------|
| VM-01 | Create MicroVM (Running) | ✅ Passed |
| VM-02 | Suspend MicroVM | State → Suspended |
| VM-03 | Resume MicroVM | State → Running, endpoint responds |
| VM-04 | Terminate MicroVM | State → Terminated, CR cleaned up |
| VM-05 | Create MicroVM with `maxIdleDurationSeconds` | Auto-suspends after idle timeout |

### 5. MicroVMReplicaSet

| ID | Test | Expected |
|----|------|----------|
| RS-01 | Create MicroVMReplicaSet with replicas=2 | 2 MicroVMs created |
| RS-02 | Scale up replicas=3 | 1 new MicroVM created |
| RS-03 | Scale down replicas=1 | 2 MicroVMs terminated |
| RS-04 | Delete MicroVMReplicaSet | All child MicroVMs terminated |

### 6. Auth Token (operator sub-resource)

| ID | Test | Expected |
|----|------|----------|
| TOK-01 | `kubectl microvm token --direct` | Token obtained via AWS SDK |
| TOK-02 | `kubectl microvm token` (via operator endpoint) | Token obtained via operator REST |
| TOK-03 | Token with `--port` scope | Token scoped to specific port |
| TOK-04 | Expired token rejected by endpoint | 401 response |

---

## Prerequisites

```bash
# Operator deployed and healthy
kubectl get pods -n kube-microvm

# MicroVMImage available
kubectl get microvmimage hello-node-e2e -n default

# VPC endpoints (if no NAT gateway)
# - com.amazonaws.us-east-1.lambda-microvm
# - com.amazonaws.us-east-1.eks-auth
```

---

## Test Execution Order

1. NET-01 → NET-02 (create and verify network)
2. VM-NET-01 or VM-NET-02 (create VM with network)
3. VM-NET-03 (verify connectivity)
4. VM-02 → VM-03 (suspend/resume)
5. VM-NET-04 → NET-04 (cleanup)
6. VM-04 (terminate standalone VM)

---

## Environment Variables

```bash
export VPC_ID="vpc-0e40b0159e24f935e"
export SUBNET_1="subnet-0fdc8b729163e12a7"
export SUBNET_2="subnet-0bde13101743f4751"
export SECURITY_GROUP="sg-01032cc226cb1615d"
export IMAGE_ARN="arn:aws:lambda:us-east-1:<ACCOUNT_ID>:microvm-image:hello-node-e2e"
```
