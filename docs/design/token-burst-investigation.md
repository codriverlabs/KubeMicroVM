# Investigation: CreateMicrovmAuthToken Burst Failure

**Status**: In progress  
**Branch**: `feature/token-burst-investigation`  
**Observed**: 50 concurrent `microvm token --direct` calls → 0% success; 1 call → 100% success

---

## Observed Behaviour

During the 1000-VM load test (2026-07-06), 256 Running VMs were queried for tokens
in parallel (`xargs -P 50`). All 256 returned FAIL. A single token request in the
regression test immediately after worked correctly (token length=761, HTTP 200).

---

## Candidate Root Causes

### Hypothesis A — AWS rate limit on `CreateMicrovmAuthToken`

The Lambda MicroVMs API may enforce a per-account or per-VM burst limit on auth token
generation. At 50 concurrent calls, all requests could be throttled with a 429 response
before any succeed.

**Evidence for**: New service, auth token APIs commonly have strict rate limits.  
**Evidence against**: Rate limiting typically returns partial success (some OK, some FAIL),
not 0%. A pure rate limit causing 100% failure simultaneously is unusual.

**Test**: Issue 2, 5, 10, 20, 50 concurrent token requests for the same VM and observe
the failure threshold. If partial success appears, it's rate limiting.

### Hypothesis B — CLI kubeconfig not available in xargs subshell

`microvm token --direct` reads the MicroVM CR from Kubernetes to get the `status.microVmId`
before calling AWS. Inside `xargs -P 50` subshells, the kubeconfig may not be inherited
correctly (environment variable vs file path), causing all CR lookups to fail silently,
which the CLI reports as a token FAIL rather than a Kubernetes error.

**Evidence for**: 0% failure pattern matches a systematic environment issue rather than
partial throttling. The xargs subshell runs with `bash -c '...'` which may not inherit
`KUBECONFIG` or the default `~/.kube/config` path if the home directory differs.  
**Evidence against**: Standard xargs inherits the parent environment including `HOME`
and `KUBECONFIG`.

**Test**: Run `microvm token` from inside an explicit `bash -c` subshell manually and
check if CR lookup works. Also add `2>&1` to capture stderr in the token script to see
actual error messages.

### Hypothesis C — Stale VM status at query time (`microVmId` null)

The token collection runs immediately after the RS scale-up loop. VMs may show
`status.state == Running` in the ReplicaSet status rollup (which is eventually consistent)
while individual MicroVM CR `status.microVmId` is still null or stale. The CLI would
then attempt to call AWS with a null VM ID and fail.

**Evidence for**: The RS status `readyReplicas` count is derived from child CR states,
but there can be a reconcile lag between AWS state and CR status. 256 "Running" VMs
at the time of collection is a very large number to all have valid `microVmId`.  
**Evidence against**: The regression test VM also queried immediately after reaching
Running and succeeded — though that was a single VM with full reconcile time.

**Test**: Before token collection, verify that sampled VMs have non-null `status.microVmId`
in the CR. Log the microVmId presence rate before attempting token calls.

---

## Investigation Plan

### Step 1 — Capture actual error output

Re-run token collection with stderr captured:

```bash
microvm token --name <vm> --direct 2>&1
```

The load test script discarded stderr. Actual error messages will immediately distinguish
between Kubernetes lookup failure, AWS API error, and CLI crash.

### Step 2 — Verify microVmId presence

```bash
kubectl get microvms -n default \
  -o jsonpath='{range .items[?(@.status.state=="Running")]}{.metadata.name}{" "}{.status.microVmId}{"\n"}{end}' \
  | awk '$2==""' | wc -l   # count Running VMs with null microVmId
```

### Step 3 — Concurrency sweep (single VM, varying parallelism)

With one known-good Running VM:

```bash
for P in 1 2 5 10 20 50; do
  SUCCESS=0
  for i in $(seq 1 $P); do
    microvm token --name <vm> --direct 2>/dev/null && SUCCESS=$((SUCCESS+1)) &
  done
  wait
  echo "P=$P success=$SUCCESS/$P"
done
```

This isolates rate limiting from multi-VM issues.

### Step 4 — Subshell environment test

```bash
# Verify kubeconfig works inside xargs subshell
echo "test-vm" | xargs -P 5 -I{} bash -c '
  kubectl get microvm {} -n default -o jsonpath="{.status.microVmId}" 2>&1
  echo "exit: $?"
'
```

---

## Expected Outcomes

| Root cause | Expected test result |
|-----------|---------------------|
| Rate limit (A) | Concurrency sweep shows partial success at low P, 0% at high P |
| Kubeconfig (B) | Step 4 subshell fails to find CR; stderr shows kubectl error |
| Stale microVmId (C) | Step 2 shows many Running VMs with null microVmId |

---

## Fix Candidates (post-investigation)

| Root cause | Fix |
|-----------|-----|
| Rate limit (A) | Add exponential backoff + jitter in `TokenCommand.java`; reduce xargs -P to ≤5 |
| Kubeconfig (B) | Pass `--kubeconfig` explicitly or use operator endpoint instead of `--direct` |
| Stale microVmId (C) | In token collection, filter on `status.microVmId != null` before attempting call |
