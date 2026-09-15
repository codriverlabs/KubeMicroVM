#!/usr/bin/env bash
# Generates the operator CA secret and injects the CA bundle into webhook configs.
# Must run AFTER helm install (so the namespace and webhook configs exist) but
# the ClusterIssuer waits for the secret — so helm install uses --wait=false
# and this script is called immediately after.
#
# On EKS/production the CA is generated once and stored; here we generate a
# throwaway self-signed CA that is only valid for the lifetime of the cluster.
#
# Called by the Makefile _cluster-up target (k3d provider).
# Environment variables (all set by Makefile):
#   NS          operator namespace  (default: kube-microvm)
#   REGION      unused here, passed through for consistency
set -euo pipefail

NS="${NS:-kube-microvm}"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

echo "==> Generating operator CA (throwaway, cluster-local)"
openssl genrsa -out "$TMPDIR/ca.key" 2048 2>/dev/null
openssl req -x509 -new -nodes -key "$TMPDIR/ca.key" \
    -sha256 -days 3650 -out "$TMPDIR/ca.crt" \
    -subj "/CN=kube-microvm-operator-ca" 2>/dev/null

# TLS cert for the webhook service
cat > "$TMPDIR/csr.conf" <<EOF
[req]
default_bits = 2048
prompt = no
distinguished_name = dn
req_extensions = v3_req
[dn]
CN = kube-microvm-operator.${NS}.svc
[v3_req]
keyUsage = keyEncipherment, digitalSignature
extendedKeyUsage = serverAuth
subjectAltName = @alt_names
[alt_names]
DNS.1 = kube-microvm-operator
DNS.2 = kube-microvm-operator.${NS}
DNS.3 = kube-microvm-operator.${NS}.svc
DNS.4 = kube-microvm-operator.${NS}.svc.cluster.local
EOF
openssl genrsa -out "$TMPDIR/tls.key" 2048 2>/dev/null
openssl req -new -key "$TMPDIR/tls.key" -out "$TMPDIR/tls.csr" -config "$TMPDIR/csr.conf" 2>/dev/null
openssl x509 -req -in "$TMPDIR/tls.csr" -CA "$TMPDIR/ca.crt" -CAkey "$TMPDIR/ca.key" \
    -CAcreateserial -out "$TMPDIR/tls.crt" -days 3650 \
    -extensions v3_req -extfile "$TMPDIR/csr.conf" 2>/dev/null

echo "==> Creating CA and TLS secrets in namespace ${NS}"
# CA secret: Opaque with ca.crt + ca.key (CaSecretReplicator and ClusterIssuer need ca.crt key)
kubectl create secret generic kube-microvm-operator-ca \
    --from-file=ca.crt="$TMPDIR/ca.crt" \
    --from-file=ca.key="$TMPDIR/ca.key" \
    -n "${NS}" --dry-run=client -o yaml | kubectl apply -f -

# TLS secret: for the webhook server
kubectl create secret tls kube-microvm-operator-webhook-tls \
    --cert="$TMPDIR/tls.crt" --key="$TMPDIR/tls.key" \
    -n "${NS}" --dry-run=client -o yaml | kubectl apply -f -

# Also copy CA to cert-manager namespace (ClusterIssuer looks there by default)
kubectl create secret generic kube-microvm-operator-ca \
    --from-file=ca.crt="$TMPDIR/ca.crt" \
    --from-file=ca.key="$TMPDIR/ca.key" \
    -n cert-manager --dry-run=client -o yaml | kubectl apply -f -

echo "==> Injecting CA bundle into webhook configurations"
CA_BUNDLE="$(base64 -w0 "$TMPDIR/ca.crt")"
kubectl patch validatingwebhookconfiguration kube-microvm-operator-validating \
    --type='json' \
    -p="[{\"op\":\"replace\",\"path\":\"/webhooks/0/clientConfig/caBundle\",\"value\":\"${CA_BUNDLE}\"}]" \
    2>/dev/null || true
kubectl patch mutatingwebhookconfiguration kube-microvm-operator-mutating \
    --type='json' \
    -p="[{\"op\":\"replace\",\"path\":\"/webhooks/0/clientConfig/caBundle\",\"value\":\"${CA_BUNDLE}\"}]" \
    2>/dev/null || true
kubectl patch mutatingwebhookconfiguration kube-microvm-operator-mutating \
    --type='json' \
    -p="[{\"op\":\"replace\",\"path\":\"/webhooks/1/clientConfig/caBundle\",\"value\":\"${CA_BUNDLE}\"}]" \
    2>/dev/null || true

echo "==> CA bootstrap complete"
