#!/usr/bin/env bash
# Deploy m80 + KubeMicroVM operator into an existing k3s-xpress cluster.
# Called by the Makefile k3s-xpress _cluster-up target.
#
# Required env vars (all set by the Makefile):
#   K3S_XPRESS_CLUSTER   kubectl context name for the target cluster
#   M80_IMAGE            m80 container image
#   CHART_VERSION        KubeMicroVM Helm chart version
#   REGION               AWS region passed to the operator
#   MAX_ACCOUNT_MEMORY_MIB  m80 memory ceiling
set -euo pipefail

: "${K3S_XPRESS_CLUSTER:?set K3S_XPRESS_CLUSTER=<kubectl context name>}"
: "${M80_IMAGE:?}"
: "${CHART_VERSION:?}"
: "${REGION:?}"
: "${MAX_ACCOUNT_MEMORY_MIB:?}"

NS="kube-microvm"

echo "==> Switching kubectl context to ${K3S_XPRESS_CLUSTER}"
kubectl config use-context "${K3S_XPRESS_CLUSTER}"

echo "==> Deploying m80 (${M80_IMAGE})"
kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f - <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: m80
  namespace: ${NS}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: m80
  template:
    metadata:
      labels:
        app: m80
    spec:
      containers:
        - name: m80
          image: ${M80_IMAGE}
          args:
            - -addr
            - :4290
            - -build-delay
            - 500ms
            - -max-account-memory-mib
            - "${MAX_ACCOUNT_MEMORY_MIB}"
            - -serve-sts
          ports:
            - containerPort: 4290
          readinessProbe:
            httpGet:
              path: /_m80/health
              port: 4290
            initialDelaySeconds: 2
---
apiVersion: v1
kind: Service
metadata:
  name: m80
  namespace: ${NS}
spec:
  selector:
    app: m80
  ports:
    - port: 4290
      targetPort: 4290
---
# NodePort for Robot Framework runner (container on the cluster network,
# not a pod, so *.svc.cluster.local does not resolve for it).
apiVersion: v1
kind: Service
metadata:
  name: m80-node
  namespace: ${NS}
spec:
  type: NodePort
  selector:
    app: m80
  ports:
    - port: 4290
      targetPort: 4290
      nodePort: 30429
YAML

kubectl -n "${NS}" rollout status deploy/m80 --timeout=300s

echo "==> Installing KubeMicroVM operator v${CHART_VERSION} (k3s-xpress — EKS Pod Identity)"
# k3s-xpress provides EKS Pod Identity, so no static credentials needed.
# AWS_ENDPOINT_URL_STS points at m80 so the startup connectivity gate passes.
helm upgrade --install kube-microvm-operator \
  "oci://ghcr.io/codriverlabs/helm/kube-microvm-operator" \
  --version "${CHART_VERSION}" -n "${NS}" \
  --set "app.envs.AWS_MICROVM_ENDPOINT=http://m80.${NS}.svc.cluster.local:4290" \
  --set "app.envs.AWS_REGION=${REGION}" \
  --set "app.envs.AWS_ENDPOINT_URL_STS=http://m80.${NS}.svc.cluster.local:4290" \
  --wait --timeout 6m

kubectl label namespace default lambda.aws.amazon.com/manage-microvms=true --overwrite

echo "==> Stack up on ${K3S_XPRESS_CLUSTER}"
