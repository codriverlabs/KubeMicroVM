#!/bin/bash
# cleanup-cluster.sh — Tear down operator and all CRs for fresh UAT run
set -euo pipefail

echo "=== Deleting webhook configurations ==="
kubectl delete validatingwebhookconfiguration kube-microvm-operator-validating --ignore-not-found
kubectl delete mutatingwebhookconfiguration kube-microvm-operator-mutating --ignore-not-found

echo "=== Force-removing all custom resources ==="
for cr in microvmimages microvms microvmreplicasets microvmnetworks; do
  kubectl get $cr -A -o json 2>/dev/null | \
    python3 -c "import json,sys; items=json.load(sys.stdin).get('items',[]); [print(i['metadata']['namespace']+'/'+i['metadata']['name']) for i in items]" 2>/dev/null | \
    while read ns_name; do
      ns="${ns_name%%/*}"; name="${ns_name##*/}"
      kubectl patch $cr "$name" -n "$ns" --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]' --request-timeout=10s 2>/dev/null || true
      kubectl delete $cr "$name" -n "$ns" --force --grace-period=0 --timeout=30s 2>/dev/null || true
    done
done

echo "=== Uninstalling Helm chart ==="
helm uninstall kube-microvm-operator -n kube-microvm --wait 2>/dev/null || true

echo "=== Cleaning cert-manager resources ==="
kubectl delete secret kube-microvm-operator-webhook-tls kube-microvm-operator-ca -n kube-microvm --ignore-not-found
kubectl delete certificate,issuer --all -n kube-microvm --ignore-not-found

echo "✓ Cluster cleaned — ready for fresh install"
