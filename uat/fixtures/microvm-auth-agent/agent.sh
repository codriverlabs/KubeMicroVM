#!/bin/sh
# microvm-auth-agent — minimal test implementation
# Polls the operator token endpoint using the pod's SA token,
# writes the auth token to the shared volume for the main container.

set -e

MICROVM_NAME="${MICROVM_NAME:-}"
MICROVM_NAMESPACE="${MICROVM_NAMESPACE:-default}"
MOUNT_PATH="${MOUNT_PATH:-/var/run/microvm}"
TOKEN_EXPIRY_MINUTES="${TOKEN_EXPIRY_MINUTES:-30}"
OPERATOR_SVC="${OPERATOR_SVC:-kube-microvm-operator.kube-microvm.svc:443}"
REFRESH_INTERVAL="${REFRESH_INTERVAL:-300}"  # refresh every 5 minutes

SA_TOKEN_PATH="/var/run/secrets/kubernetes.io/serviceaccount/token"

mkdir -p "$MOUNT_PATH"

echo "[auth-agent] Starting for vm=$MICROVM_NAME ns=$MICROVM_NAMESPACE"

fetch_token() {
    SA_TOKEN=$(cat "$SA_TOKEN_PATH" 2>/dev/null)
    if [ -z "$SA_TOKEN" ]; then
        echo "[auth-agent] ERROR: SA token not found at $SA_TOKEN_PATH"
        return 1
    fi

    RESP=$(curl -sk --max-time 10 \
        -X POST \
        -H "Authorization: Bearer $SA_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"expirationInMinutes\": $TOKEN_EXPIRY_MINUTES}" \
        "https://${OPERATOR_SVC}/apis/lambda.aws.amazon.com/v1alpha1/namespaces/${MICROVM_NAMESPACE}/microvms/${MICROVM_NAME}/token" \
        2>/dev/null)

    AUTH_TOKEN=$(echo "$RESP" | grep -o '"authToken":"[^"]*"' | cut -d'"' -f4)
    ENDPOINT=$(echo "$RESP" | grep -o '"endpoint":"[^"]*"' | cut -d'"' -f4)
    EXPIRES_AT=$(echo "$RESP" | grep -o '"expiresAt":"[^"]*"' | cut -d'"' -f4)

    if [ -z "$AUTH_TOKEN" ]; then
        echo "[auth-agent] ERROR: Failed to get token. Response: $RESP"
        return 1
    fi

    echo "$AUTH_TOKEN" > "$MOUNT_PATH/token"
    echo "$ENDPOINT"   > "$MOUNT_PATH/endpoint"
    echo "$EXPIRES_AT" > "$MOUNT_PATH/expires_at"
    echo "[auth-agent] Token written to $MOUNT_PATH (expires: $EXPIRES_AT)"
    return 0
}

# Initial fetch with retry
RETRIES=5
for i in $(seq 1 $RETRIES); do
    fetch_token && break
    echo "[auth-agent] Retry $i/$RETRIES in 10s..."
    sleep 10
done

# Refresh loop
while true; do
    sleep "$REFRESH_INTERVAL"
    fetch_token || echo "[auth-agent] Token refresh failed, will retry next cycle"
done
