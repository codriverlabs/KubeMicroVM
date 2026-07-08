# Design: kubectl microvm exec (ShellAuthToken) — Integration Tests + E2E

**Status**: Code exists, no tests, no E2E  
**Branch**: `feature/exec-shellauth`  
**Priority**: P2

---

## What Exists

`ExecCommand.java` implements `microvm exec <name>` — calls `CreateMicrovmShellAuthToken` and prints the shell credentials. The AWS client method `createShellAuthToken()` is implemented in `DefaultMicroVMClient`. `QuotaGuard` wraps it with rate limiting.

## What Is Missing

1. **Integration test** — no test for `ExecCommand` or the `createShellAuthToken` code path
2. **E2E verification** — never tested on a real cluster with a real VM

## Shell Token Response

`CreateMicrovmShellAuthToken` returns credentials for SSH-like access into the MicroVM:
```json
{
  "accessToken": "...",
  "endpoint": "shell.lambda-microvm.us-east-1.on.aws",
  "expiresAt": "..."
}
```

The user connects using the token as an auth credential. The exact protocol and client tool are documented in the AWS docs.

## Implementation Plan

### Integration Test (`operator-tests`)

New test class: `ExecCommandIT` or add to `DefaultMicroVMClientIT`:

```java
@Test
@DisplayName("createShellAuthToken: calls AWS and returns token + endpoint")
void createShellAuthToken_returnsCredentials() throws Exception {
    when(mockLambda.createMicrovmShellAuthToken(any()))
        .thenReturn(CompletableFuture.completedFuture(
            CreateMicrovmShellAuthTokenResponse.builder()
                .accessToken("shell-token-abc")
                .endpoint("shell.lambda-microvm.us-east-1.on.aws")
                .build()));

    var result = client.createShellAuthToken("mvm-abc123", 30, null).get(5, SECONDS);
    assertEquals("shell-token-abc", result.get("accessToken"));
}
```

### E2E Test Plan

#### EX-01: microvm exec returns shell credentials
```bash
# Requires a Running VM
TOKEN_OUTPUT=$(./operator-cli/target/microvm-runner exec <vm-name> -n default)
echo "$TOKEN_OUTPUT"
# Expected: JSON with accessToken and endpoint fields
# Pass: exit code 0, accessToken non-empty
```

#### EX-02: QuotaGuard rate-limits shell token requests
```bash
# Fire 10 concurrent exec requests
seq 1 10 | xargs -P 10 -I{} \
  ./operator-cli/target/microvm-runner exec <vm-name> -n default \
  2>/dev/null | grep -c "accessToken"
# Pass: all succeed (rate limit is 5/s, 10 requests should complete within 2s)
```

## Implementation Checklist

- [ ] Integration test: `createShellAuthToken` client method
- [ ] Integration test: `ExecCommand` parses response correctly
- [ ] Verify `ExecCommand` output format (JSON vs human-readable)
- [ ] E2E: `microvm exec` returns credentials for a running VM
- [ ] E2E: credentials are valid (can connect to shell endpoint)
- [ ] Document in `docs/user-guides/cli-reference.md`
