#!/usr/bin/env bash
# Wrapper around m80's uat/up.sh that supports a CHART_REF override.
#
# m80's up.sh always installs from the OCI registry. When a locally-built
# chart tgz is available (e.g. operator-controller/target/helm/...) this
# wrapper injects it by redefining `helm` temporarily with a shim.
#
# Required environment (set by Makefile):
#   M80_DIR       path to the m80 checkout
#   M80_IMAGE     m80 container image
#   CHART_VERSION KubeMicroVM chart version
#   CHART_REF     OCI ref or absolute path to a local .tgz
#   REGION        AWS region
#   MAX_ACCOUNT_MEMORY_MIB  m80 memory ceiling
set -euo pipefail

: "${M80_DIR:?set M80_DIR}"
: "${CHART_VERSION:?set CHART_VERSION}"
: "${CHART_REF:?set CHART_REF}"

# If CHART_REF is a local file path, shim `helm` to rewrite the install
# command so it uses our local tgz instead of the OCI ref.
if [ -f "${CHART_REF}" ]; then
    SHIM_DIR="$(mktemp -d)"
    trap 'rm -rf "$SHIM_DIR"' EXIT

    # Write a shim that intercepts `helm install kube-microvm-operator oci://...`
    # and replaces the OCI ref with the local tgz path.
    cat > "${SHIM_DIR}/helm" <<SHIM
#!/usr/bin/env bash
ARGS=()
for arg in "\$@"; do
    if [[ "\$arg" == oci://ghcr.io/codriverlabs/helm/kube-microvm-operator ]]; then
        ARGS+=("${CHART_REF}")
    else
        ARGS+=("\$arg")
    fi
done
exec "$(command -v helm)" "\${ARGS[@]}"
SHIM
    chmod +x "${SHIM_DIR}/helm"
    export PATH="${SHIM_DIR}:${PATH}"
fi

exec "${M80_DIR}/uat/up.sh"
