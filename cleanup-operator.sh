#!/usr/bin/env bash
# cleanup-operator.sh — full operator teardown for development redeployment
#
# Removes webhooks, patches out finalizers on all CRs, deletes CRs,
# uninstalls the Helm release, and cleans up cert-manager resources.
#
# Usage:
#   ./cleanup-operator.sh                    # default namespace: kube-microvm
#   ./cleanup-operator.sh --namespace foo    # custom namespace
#
# Safe to run when operator is already gone (all operations are idempotent).
#
set -euo pipefail

NAMESPACE="kube-microvm"
RELEASE="kube-microvm-operator"

while [[ $# -gt 0 ]]; do
  case $1 in
    --namespace) NAMESPACE="$2"; shift ;;
    --release)   RELEASE="$2"; shift ;;
    --help)
      echo "Usage: ./cleanup-operator.sh [--namespace <ns>] [--release <name>]"
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

echo "==> [1/4] Deleting webhook configurations"
kubectl delete validatingwebhookconfiguration kube-microvm-operator-validating --ignore-not-found
kubectl delete mutatingwebhookconfiguration kube-microvm-operator-mutating --ignore-not-found

echo "==> [2/4] Force-removing all custom resources (patching finalizers)"
for cr in microvmimages microvms microvmreplicasets microvmnetworks; do
  kubectl get $cr -A -o json 2>/dev/null | \
    python3 -c "import json,sys; items=json.load(sys.stdin).get('items',[]); [print(i['metadata']['namespace']+'/'+i['metadata']['name']) for i in items]" 2>/dev/null | \
    while read ns_name; do
      ns="${ns_name%%/*}"; name="${ns_name##*/}"
      kubectl patch $cr "$name" -n "$ns" --type=json \
        -p='[{"op":"remove","path":"/metadata/finalizers"}]' --request-timeout=10s 2>/dev/null || true
      kubectl delete $cr "$name" -n "$ns" --force --grace-period=0 --timeout=30s 2>/dev/null || true
    done
done

echo "==> [3/4] Uninstalling Helm release: ${RELEASE}"
helm uninstall "$RELEASE" -n "$NAMESPACE" --wait --timeout=60s 2>/dev/null || true

echo "==> [4/4] Cleaning up cert-manager resources"
kubectl delete secret kube-microvm-operator-webhook-tls kube-microvm-operator-ca \
  -n "$NAMESPACE" --ignore-not-found
kubectl delete certificate,issuer --all -n "$NAMESPACE" --ignore-not-found

echo "==> Cleanup complete"
