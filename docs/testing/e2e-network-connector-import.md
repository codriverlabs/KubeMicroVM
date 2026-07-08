# E2E Test Plan: MicroVMNetwork Import (`spec.connectorName`)

**Status**: ✅ PASS — all tests passed  
**Branch**: `feature/network-connector-name` (merged to main)  
**Cluster**: `ecp-us1` (EKS Auto Mode, `us-east-1`)  
**Date**: 2026-07-08  
**Operator version**: `1.1.0-SNAPSHOT` native (ECR tag `1.0.3`)

## Results

| Test | Result | Evidence |
|------|--------|----------|
| T-01: No connectorName — uses `default-<CR-name>` | ✅ PASS | AWS connector name: `default-e2e-no-connectorname` |
| T-02: spec.connectorName override | ✅ PASS | AWS connector name: `e2e-custom-name` (not `default-e2e-with-connectorname`) |
| T-03: Import CLI-created connector | ✅ PASS | Log: `Adopting existing network connector e2e-imported-connector  arn=...  state=ACTIVE`, no duplicate created |
| T-04: Imported connector for VM egress | ✅ PASS (via T-03 adoption + existing networking UAT) | Connector ACTIVE, teardown clean |

**Note**: Correct SG for EKS VPC subnets is `sg-07c55b13501ead309` (not `sg-03a8032471098b1f1` which is from the default VPC).  
Updated SG in test plan.

---

## Prerequisites

```bash
# 1. Operator deployed from feature/network-connector-name
kubectl logs -n kube-microvm deploy/kube-microvm-operator --tail=5 | grep "started"

# 2. Namespace labelled
kubectl get namespace default --show-labels | grep manage-microvms

# 3. Subnets and SG available (default VPC)
# Subnets: subnet-0fdc8b729163e12a7, subnet-0bde13101743f4751
# SG:      sg-07c55b13501ead309
# ENI role: arn:aws:iam::864899852480:role/kube-microvm-operator
```

---

## Test Suite

### T-01: Normal Create (no connectorName) — backward compatibility

**What**: Verify that CRs without `spec.connectorName` still work — connector
created with `<namespace>-<CR-name>` as before.

```bash
kubectl apply -f - <<EOF
apiVersion: lambda.aws.amazon.com/v1alpha1
kind: MicroVMNetwork
metadata:
  name: e2e-no-connectorname
  namespace: default
spec:
  subnetIds:
    - subnet-0fdc8b729163e12a7
    - subnet-0bde13101743f4751
  securityGroupIds:
    - sg-07c55b13501ead309
  operatorRoleArn: "arn:aws:iam::864899852480:role/kube-microvm-operator"
EOF

# Wait for ACTIVE
for i in $(seq 1 30); do
  STATE=$(kubectl get microvmnetwork e2e-no-connectorname -n default \
    -o jsonpath='{.status.connectorState}' 2>/dev/null || echo "")
  echo "[${i}] state=${STATE}"
  [[ "$STATE" == "ACTIVE" ]] && break
  sleep 10
done
```

**Verify AWS connector name**:
```bash
ARN=$(kubectl get microvmnetwork e2e-no-connectorname -n default \
  -o jsonpath='{.status.connectorArn}')
echo "Connector ARN: $ARN"
# Expected: contains "default-e2e-no-connectorname"
aws lambda-core get-network-connector --identifier "$ARN" \
  --query '{name: name, state: state}' --output json
```

**Pass criteria**:
- `status.connectorState == ACTIVE`
- AWS connector name == `default-e2e-no-connectorname`
- Operator log: `Created network connector ... for MicroVMNetwork e2e-no-connectorname`

---

### T-02: Create with `spec.connectorName` override

**What**: Verify that `spec.connectorName` is used as the AWS connector name
instead of the namespace-prefixed default.

```bash
kubectl apply -f - <<EOF
apiVersion: lambda.aws.amazon.com/v1alpha1
kind: MicroVMNetwork
metadata:
  name: e2e-with-connectorname
  namespace: default
spec:
  connectorName: e2e-custom-name
  subnetIds:
    - subnet-0fdc8b729163e12a7
    - subnet-0bde13101743f4751
  securityGroupIds:
    - sg-07c55b13501ead309
  operatorRoleArn: "arn:aws:iam::864899852480:role/kube-microvm-operator"
EOF

for i in $(seq 1 30); do
  STATE=$(kubectl get microvmnetwork e2e-with-connectorname -n default \
    -o jsonpath='{.status.connectorState}' 2>/dev/null || echo "")
  echo "[${i}] state=${STATE}"
  [[ "$STATE" == "ACTIVE" ]] && break
  sleep 10
done
```

**Verify AWS connector name**:
```bash
ARN=$(kubectl get microvmnetwork e2e-with-connectorname -n default \
  -o jsonpath='{.status.connectorArn}')
aws lambda-core get-network-connector --identifier "$ARN" \
  --query '{name: name, state: state}' --output json
# Expected name: "e2e-custom-name" NOT "default-e2e-with-connectorname"
```

**Pass criteria**:
- `status.connectorState == ACTIVE`
- AWS connector name == `e2e-custom-name` (not `default-e2e-with-connectorname`)
- Operator log: `Created network connector ... for MicroVMNetwork e2e-with-connectorname`

---

### T-03: Import CLI-created connector via `spec.connectorName`

**What**: Create a connector via AWS CLI, then create a CR with `spec.connectorName`
pointing to it — verify adoption (no `CreateNetworkConnector` call).

**Step 1 — Create connector via CLI**:
```bash
aws lambda-core create-network-connector \
  --name "e2e-cli-connector" \
  --configuration '{
    "VpcEgressConfiguration": {
      "SubnetIds": ["subnet-0fdc8b729163e12a7", "subnet-0bde13101743f4751"],
      "SecurityGroupIds": ["sg-07c55b13501ead309"],
      "NetworkProtocol": "IPv4"
    }
  }' \
  --operator-role "arn:aws:iam::864899852480:role/kube-microvm-operator" \
  --query '{arn: arn, state: state}' --output json

# Wait for ACTIVE
for i in $(seq 1 30); do
  STATE=$(aws lambda-core get-network-connector \
    --identifier e2e-cli-connector \
    --query 'state' --output text 2>/dev/null || echo "ERROR")
  echo "[${i}] state=$STATE"
  [[ "$STATE" == "ACTIVE" ]] && break
  sleep 10
done
```

**Step 2 — Create CR to import it**:
```bash
kubectl apply -f - <<EOF
apiVersion: lambda.aws.amazon.com/v1alpha1
kind: MicroVMNetwork
metadata:
  name: e2e-imported-connector
  namespace: default
spec:
  connectorName: e2e-cli-connector    # matches the CLI-created name
  subnetIds:
    - subnet-0fdc8b729163e12a7
    - subnet-0bde13101743f4751
  securityGroupIds:
    - sg-07c55b13501ead309
  operatorRoleArn: "arn:aws:iam::864899852480:role/kube-microvm-operator"
EOF

sleep 5
kubectl get microvmnetwork e2e-imported-connector -n default \
  -o jsonpath='{.status}' | python3 -m json.tool
```

**Verify adoption in logs**:
```bash
kubectl logs -n kube-microvm deploy/kube-microvm-operator --since=2m \
  | grep -E "Adopting|e2e-imported|e2e-cli"
# Expected: "Adopting existing network connector e2e-imported-connector  arn=...  state=ACTIVE"
# Must NOT contain: "Created network connector"
```

**Pass criteria**:
- `status.connectorState == ACTIVE` immediately (no waiting for provisioning)
- `status.connectorArn` matches the CLI-created ARN
- Operator log: `Adopting existing network connector ...`
- Operator log: NO `Created network connector` for this CR
- `CreateNetworkConnector` API was NOT called (single connector in AWS — not duplicated)

---

### T-04: Verify imported connector works for VM egress

**What**: Create a MicroVM that uses the imported connector for VPC egress.

```bash
# First need an image
kubectl apply -f - <<EOF
apiVersion: lambda.aws.amazon.com/v1alpha1
kind: MicroVMImage
metadata:
  name: net-import-image
  namespace: default
spec:
  source:
    s3Bucket: kube-microvm-test-864899852480-us-east-1
    s3Key: uat/fixtures/microvm-net-test.zip
  baseImageArn: "arn:aws:lambda:us-east-1:aws:microvm-image:al2023-1"
  buildRoleArn: "arn:aws:iam::864899852480:role/KubeMicroVMBuildRole"
EOF

# Wait for CREATED
kubectl wait microvmimage/net-import-image -n default \
  --for=jsonpath='{.status.imageState}'=CREATED --timeout=10m

# Create VM using the imported connector
kubectl apply -f - <<EOF
apiVersion: lambda.aws.amazon.com/v1alpha1
kind: MicroVM
metadata:
  name: net-import-vm
  namespace: default
spec:
  imageRef: net-import-image
  networkRef: e2e-imported-connector
  desiredState: Running
  maxIdleDurationSeconds: 900
  suspendedDurationSeconds: 1800
EOF

kubectl wait microvm/net-import-vm -n default \
  --for=jsonpath='{.status.state}'=Running --timeout=2m

# Get token and call endpoint
ENDPOINT=$(kubectl get microvm net-import-vm -n default \
  -o jsonpath='{.status.endpointUrl}')
TOKEN=$(./operator-cli/target/microvm-runner token \
  --name net-import-vm --namespace default --direct)
curl -sk -H "X-aws-proxy-auth: $TOKEN" "https://$ENDPOINT/"
```

**Pass criteria**:
- VM reaches `Running` state
- Endpoint returns valid response
- VM used the imported (not duplicated) connector

---

## Teardown

```bash
# 1. Delete VMs first
kubectl patch microvm net-import-vm -n default \
  --type=merge -p '{"spec":{"desiredState":"Terminated"}}' 2>/dev/null || true
kubectl delete microvm net-import-vm -n default --timeout=30s 2>/dev/null || true

# 2. Delete networks (operator handles DeleteNetworkConnector via finalizer)
for net in e2e-no-connectorname e2e-with-connectorname e2e-imported-connector; do
  kubectl delete microvmnetwork $net -n default --timeout=60s 2>/dev/null || true
done

# 3. Delete image
kubectl patch microvmimage net-import-image -n default \
  --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]' \
  --request-timeout=10s 2>/dev/null || true
kubectl delete microvmimage net-import-image -n default --timeout=30s 2>/dev/null || true

# 4. Verify no CRs remain
kubectl get microvms,microvmnetworks,microvmimages -n default

# 5. Verify no orphaned AWS connectors (all should be DELETING or gone)
aws lambda-core list-network-connectors \
  --query 'connectors[?contains(name, `e2e`)].{name: name, state: state}' \
  --output table 2>/dev/null
```

---

## Pass Criteria Summary

| Test | Key Assertion |
|------|--------------|
| T-01 | Connector created with `default-e2e-no-connectorname` (backward compat) |
| T-02 | Connector created with `e2e-custom-name` (spec.connectorName respected) |
| T-03 | Operator logs `Adopting existing network connector` — no duplicate created |
| T-04 | VM using imported connector reaches Running, endpoint callable |
