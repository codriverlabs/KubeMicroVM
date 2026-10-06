#!/usr/bin/env bash
# Patches m80's uat/Dockerfile to use a locally-provided microvm CLI binary
# instead of downloading one from GitHub releases/latest.
#
# m80's Dockerfile (the container that runs the Robot Framework suite) fetches
# the microvm CLI with:
#   curl -fsSL -o /usr/local/bin/microvm \
#     "https://github.com/codriverlabs/KubeMicroVM/releases/latest/download/microvm-linux-${TARGETARCH}"
#
# This creates a hard circular dependency when running the UAT suite as a
# release gate for a NEW tag: releases/latest only becomes complete once our
# own release job runs, but the release job needs this UAT run to pass first.
# If a prior tag's release happens to still be "latest" at the moment this
# runs, the build silently succeeds against stale content; if releases/latest
# is incomplete or in flux (e.g. mid-release, or a just-created tag with no
# assets yet), this curl 404s and the whole UAT run fails before a single
# test executes — fast, deterministic, and reproducing on every retry.
#
# Fix: if a locally-built CLI binary is available (from this same workflow
# run's native-cli job, or a local `build-local.sh` build), copy it into
# m80's build context and rewrite the Dockerfile's RUN line to COPY it in
# instead of downloading. If no local binary is found, the Dockerfile is left
# untouched (falls back to the original releases/latest behavior) — this
# keeps plain `make full` working for anyone who hasn't built a local CLI.
#
# Usage: patch-m80-dockerfile.sh <m80-dir>
# Env:   MICROVM_CLI_AMD64, MICROVM_CLI_ARM64 — explicit binary paths (optional)
set -euo pipefail

M80_DIR="${1:?usage: patch-m80-dockerfile.sh <m80-dir>}"
DOCKERFILE="${M80_DIR}/uat/Dockerfile"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/.." && pwd)"

[ -f "${DOCKERFILE}" ] || { echo "==> No ${DOCKERFILE} found, nothing to patch"; exit 0; }

# Only patch once — re-running make m80-run should not re-patch an
# already-patched Dockerfile (idempotent against repeated invocations
# within the same m80 checkout).
if grep -q "COPY microvm-linux-" "${DOCKERFILE}" 2>/dev/null; then
  echo "==> ${DOCKERFILE} already patched"
  exit 0
fi

find_cli() {
  local arch_suffix="$1"   # amd64 | arm64
  local override_var="$2"  # MICROVM_CLI_AMD64 | MICROVM_CLI_ARM64
  if [ -n "${!override_var:-}" ] && [ -f "${!override_var}" ]; then
    echo "${!override_var}"
    return 0
  fi
  # CI: binaries downloaded as workflow artifacts (actions/download-artifact)
  for candidate in \
    "${REPO_ROOT}/microvm-linux-${arch_suffix}" \
    "${REPO_ROOT}/dist/microvm-linux-${arch_suffix}"
  do
    [ -f "${candidate}" ] && { echo "${candidate}"; return 0; }
  done
  # Local dev: build-local.sh / mvnw package -Pnative output (single-arch,
  # whatever the host is — only useful when TARGETARCH matches the host)
  for candidate in \
    "${REPO_ROOT}/operator-cli/target/microvm-runner"
  do
    [ -f "${candidate}" ] && { echo "${candidate}"; return 0; }
  done
  return 1
}

CLI_AMD64="$(find_cli amd64 MICROVM_CLI_AMD64 || true)"
CLI_ARM64="$(find_cli arm64 MICROVM_CLI_ARM64 || true)"

if [ -z "${CLI_AMD64}" ] && [ -z "${CLI_ARM64}" ]; then
  echo "==> No local microvm CLI binary found — leaving ${DOCKERFILE} unpatched (will use releases/latest)"
  exit 0
fi

echo "==> Patching ${DOCKERFILE} to use a local microvm CLI binary (avoids releases/latest)"
[ -n "${CLI_AMD64}" ] && cp "${CLI_AMD64}" "${M80_DIR}/uat/microvm-linux-amd64" && chmod +x "${M80_DIR}/uat/microvm-linux-amd64"
[ -n "${CLI_ARM64}" ] && cp "${CLI_ARM64}" "${M80_DIR}/uat/microvm-linux-arm64" && chmod +x "${M80_DIR}/uat/microvm-linux-arm64"

python3 - "${DOCKERFILE}" <<'PYEOF'
import re, sys
path = sys.argv[1]
with open(path) as f:
    content = f.read()
pattern = re.compile(
    r'RUN curl -fsSL -o /usr/local/bin/microvm \\\s*\n\s*"https://github\.com/codriverlabs/KubeMicroVM/releases/latest/download/microvm-linux-\$\{TARGETARCH\}" \\\s*\n\s*&& chmod \+x /usr/local/bin/microvm\n'
)
replacement = (
    'COPY microvm-linux-${TARGETARCH} /usr/local/bin/microvm\n'
    'RUN chmod +x /usr/local/bin/microvm\n'
)
new_content, count = pattern.subn(replacement, content)
if count == 0:
    print(f"WARNING: pattern not found in {path} — Dockerfile format may have changed upstream; leaving as-is", file=sys.stderr)
    sys.exit(0)
with open(path, 'w') as f:
    f.write(new_content)
print(f"Patched {count} occurrence(s)")
PYEOF
