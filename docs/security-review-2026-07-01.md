# Security Review Findings (2026-07-01)

## Scope
- Repository-wide review with focus on:
  - shell entrypoints (`setup-test-env.sh`, `test-image.sh`, `deploy-local.sh`)
  - API and webhook input handling in `operator-controller` and `operator-webhook`
- This revision classifies findings by exposure:
  - **Production runtime path**
  - **Developer/local-only scripts**
  - **Test-only scripts**

## Baseline Validation
- Ran `./mvnw verify` before changes.
- Result: **failed due to environment/toolchain mismatch**, not code regression:
  - `error: release version 25 not supported`

## Findings

### A) Production runtime path

#### 1) High — Admission validation checks wrong fields
- **File:** `/home/runner/work/KubeMicroVM/KubeMicroVM/operator-webhook/src/main/java/ai/codriverlabs/microvm/operator/webhook/validation/MicroVMValidatingWebhook.java` (lines 140, 154, 164, 177)
- **What happens:** Validation methods and messages are mismatched with actual spec fields (e.g., memory/vCPU/runtime validations are tied to unrelated `MicroVMSpec` properties).
- **Risk:** Intended admission policy checks can be bypassed or misapplied, allowing invalid operational values into the controller path.
- **Recommendation:**
  - Align each validation with the correct `MicroVMSpec` field and error message.
  - Add unit tests that assert each validated field maps to the intended CR spec property.

#### 2) Medium — Missing lower-bound validation for token expiry
- **File:** `/home/runner/work/KubeMicroVM/KubeMicroVM/operator-controller/src/main/java/ai/codriverlabs/microvm/operator/controller/rest/MicroVMTokenResource.java` (lines 96-97)
- **What happens:** `expirationInMinutes` is capped by `maxExpiryMinutes` but does not reject `<= 0`.
- **Risk:** Invalid values can trigger backend errors or unstable behavior, increasing noisy failure paths and potential request-amplification patterns.
- **Recommendation:**
  - Validate request value is within an explicit safe range (e.g. `1..maxExpiryMinutes`).
  - Return HTTP 400 on invalid input.

#### 3) Low — Internal exception details returned to callers
- **File:** `/home/runner/work/KubeMicroVM/KubeMicroVM/operator-controller/src/main/java/ai/codriverlabs/microvm/operator/controller/rest/MicroVMTokenResource.java` (line 113)
- **What happens:** API returns raw exception text in response body (`failed to create token: ...`).
- **Risk:** May leak backend implementation/service details to clients.
- **Recommendation:**
  - Return a generic error message to clients.
  - Log full exception details server-side only.

### B) Developer/local-only scripts

#### 4) Low-Medium (context-adjusted) — Helm argument injection in deployment script
- **File:** `/home/runner/work/KubeMicroVM/KubeMicroVM/deploy-local.sh` (lines 22, 56, 177-183)
- **What happens:** Repeatable `--set` values are concatenated into a single string (`EXTRA_SET_ARGS`) and expanded unquoted in `helm upgrade`.
- **Risk:** Crafted input containing spaces can inject additional helm flags/arguments.
- **Context note:** This script is local/development deploy tooling; effective production exposure is lower.
- **Recommendation:**
  - Store extra args in a bash array (`EXTRA_SET_ARGS+=(--set "$value")`).
  - Pass as `"${EXTRA_SET_ARGS[@]}"` to preserve argument boundaries.

### C) Test-only scripts

#### 5) Low (context-adjusted) — Command execution via sourced generated env file
- **Files:** `/home/runner/work/KubeMicroVM/KubeMicroVM/setup-test-env.sh` (lines 21-23, 137-143), `/home/runner/work/KubeMicroVM/KubeMicroVM/test-image.sh` (line 22)
- **What happens:** User-controlled `--bucket` / `--region` values are written into `.test-env`, then loaded with `source`.
- **Risk:** Command substitution embedded in values (e.g. `$(...)`) executes when `test-image.sh` sources `.test-env`.
- **Context note:** This path is test-only and intended for local validation workflows.
- **Recommendation:**
  - Stop using `source` for generated files.
  - Parse explicit keys safely (`KEY=...` parsing without shell evaluation).
  - Enforce strict allowlists for bucket/region formats before writing.

## Positive Controls Observed
- Token issuance endpoint performs Kubernetes `TokenReview` + `SubjectAccessReview` authorization checks before minting tokens:
  - `/home/runner/work/KubeMicroVM/KubeMicroVM/operator-controller/src/main/java/ai/codriverlabs/microvm/operator/controller/rest/MicroVMTokenResource.java` (lines 147-190)
- Key shell scripts use strict mode (`set -euo pipefail`) to reduce unsafe execution defaults.
