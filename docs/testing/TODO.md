# E2E Testing TODO — Remaining for GA

Last updated: 2026-07-01

## Completed ✅

| Feature | Branch | UAT Doc | Result |
|---------|--------|---------|--------|
| MicroVMImage create/build | v1.0.0-rc1 | e2e-test-plan.md | ✅ All pass |
| MicroVM run + terminate | v1.0.0-rc1 | e2e-test-plan.md | ✅ All pass |
| Suspend / Resume | feature/e2e-suspend-resume | uat-suspend-resume.md | ✅ 4/4 core |
| Image Update (new version) | feature/e2e-image-update | uat-image-update.md | ✅ 5/5 |
| ReplicaSet scale | feature/e2e-replicaset | uat-replicaset.md | ✅ Fixed + merged |
| Drift Detection | feature/e2e-drift-autosuspend | uat-drift-autosuspend.md | ✅ All pass |
| Auto-Suspend / Auto-Resume | feature/e2e-drift-autosuspend | uat-drift-autosuspend.md | ✅ All pass |
| MicroVMNetwork (VPC egress) | feature/e2e-network-testing | e2e-test-plan.md | ✅ All pass |
| Networking modes (3 modes) | feature/outbound-connectivity-test | — | ✅ Internet + VPC + no-egress |
| imageRef resolution by CR name | feature/imageref-resolution | — | ✅ RBAC-enforced |
| networkRef resolution by CR name | feature/e2e-network-testing | — | ✅ Connector ARN resolved |
| Suspend / Resume | feature/e2e-suspend-resume | uat-suspend-resume.md | ✅ 4/4 core tests |
| Image Update (new version) | feature/e2e-image-update | uat-image-update.md | ✅ 5/5 tests |
| ReplicaSet scale + bug fix | feature/e2e-replicaset | uat-replicaset.md | ✅ Fixed + merged |
| kubectl microvm token --direct | v1.0.0-rc1 | — | ✅ Works |

## Remaining — Must Do for GA

### 0. Quota Guardrails E2E Burst Test

**What**: Validate that `QuotaGuard` correctly enforces rate limits on a live cluster.
Specific scenarios: token burst (50 concurrent), ReplicaSet suspend cascade pacing,
startup log verification.

**Code status**: Done (67 integration tests pass — `feature/quota-guardrails-replicaset`)

**Test plan**: [`docs/testing/burst-test-plan.md`](burst-test-plan.md)

**What to test on EKS**:
- T-01: `QuotaGuard initialised` log at startup with correct rates
- T-02: 50 concurrent token requests — verify `OK > 0` (was 0/256 on 2026-07-06)
- T-03: Suspend 20-VM ReplicaSet — verify cascade takes ≥ 10s (paced at 2 req/s)
- T-05: Operator healthy after burst (no crash, no 429s in logs)

**Effort**: ~30 min

**Dependency**: Token endpoint E2E (item #1 below) for T-02 full validation.
T-03 and T-01 are independent.

### 1. Token via Operator Endpoint (no --direct flag)

**What**: Pod calls operator REST endpoint → operator calls AWS → returns token.
In-cluster flow without AWS credentials on the caller.

**Code status**: Done (7 integration tests pass — MicroVMTokenResourceIT)

**What to test on EKS**:
- Create a ServiceAccount with `microvms/token` RBAC
- Create a pod using that SA
- Pod calls `https://kube-microvm-operator.kube-microvm.svc:443/...token` with its SA token
- Receives MicroVM auth token back
- Uses token to call MicroVM endpoint

**Effort**: ~15 min (operator HTTPS already working on 8443)

### 2. Validating Webhook

**What**: Rejects invalid CRs at admission time (missing required fields, invalid values).

**Code status**: Exists but endpoint returns 404 on cluster. Path mismatch.

**What to fix**:
- Debug webhook endpoint path (`/validate-microvm`) — verify Quarkus serves it
- Ensure the service port routing (443→8443) works for webhooks
- Test: apply invalid CR → expect rejection message

**Effort**: ~20 min (likely just a path issue in the webhook handler registration)

### 3. Pod Sidecar Injection (Mutating Webhook)

**What**: Annotate a pod with `lambda.microvm.auth: <vm-name>`, webhook injects
auth-agent sidecar that auto-refreshes tokens.

**Code status**: Done (5 integration tests pass — PodMutatingWebhookIT)

**What to test on EKS**:
- Deploy operator with mutating webhook active
- Create a pod with the annotation
- Verify sidecar container injected
- Verify token file refreshed at `/var/run/microvm/token`

**Effort**: ~30 min (requires auth-agent image in ECR, webhook path working)

**Dependency**: Requires #2 (webhook) to be working first

### 4. Drift Detection

**What**: Operator detects when AWS state doesn't match desired state (e.g. VM
terminated externally) and reconciles.

**Code status**: Done (mocked in MicroVMReconcilerIT)

**What to test on EKS**:
- Create MicroVM via operator (Running)
- Terminate it directly via AWS CLI (bypassing operator)
- Verify operator detects the drift and updates CR status

**Effort**: ~10 min

### 5. Auto-Suspend / Auto-Resume (idle policy)

**What**: VM suspends after N seconds of no traffic, resumes when traffic arrives.

**Code status**: `maxIdleDurationSeconds` passed to RunMicrovm, but never E2E tested.

**What to test on EKS**:
- Create VM with `maxIdleDurationSeconds: 60`
- Wait 90s without sending traffic
- Verify state → Suspended
- Send traffic → verify auto-resume (if `autoResumeEnabled: true`)

**Effort**: ~5 min (just waiting)

## Nice to Have (Post-GA)

| Feature | Notes |
|---------|-------|
| **CLI rename: `microvm` + `kubectl-microvm` symlink** | Fix shell completion interference. Design: `docs/design/cli-naming.md`. Branch: `feature/cli-rename-microvm` |
| **Installer script (`install_kube_microvm.sh`)** | See design below. Branch: `feature/installer-script` |
| **Namespace label selector** | Implement JOSDK label selector on all reconcilers — watch only `lambda.aws.amazon.com/manage-microvms=true` namespaces. See `docs/design/namespace-watching.md`. |
| **User guide: Authentication** | Document token endpoint, RBAC setup, TLS, --direct vs operator flow |
| `kubectl microvm exec` | Shell access via ShellAuthToken |
| ReplicaSet rolling update | Template change → gradual replacement |
| Cross-namespace imageRef | ClusterMicroVMImage resource |
| Build logs in CR status | Surface GetMicrovmImageBuild |
| `kubectl microvm image list-base` | ListManagedMicrovmImages in CLI |
| Krew manifest | kubectl plugin distribution |
| macOS native CLI | Darwin arm64 build |

## Priority Order for GA

1. **Token via operator** — enables in-cluster auth without AWS creds
2. **Validating webhook** — prevents invalid CRs from being created
3. **Drift detection** — quick win, ensures operator recovers from external changes
4. **Auto-suspend** — quick win, just needs waiting
5. **Pod sidecar injection** — depends on webhook fix

---

## Known Issues

### kubectl Plugin — Missing Space After Command

When typing `kubectl` and pressing Tab, there is no space inserted between `kubectl` and
the `microvm` subcommand. Users must explicitly type a space before `microvm`.

**Root cause**: The kubectl plugin binary is named `kubectl-microvm` but the shell completion
script may not be registering the `microvm` subcommand with proper spacing in bash/zsh.

**Fix needed**: Ensure `kubectl-microvm completion bash/zsh` output is correct and the
plugin registers itself with kubectl's plugin framework properly.

---

## Installer Script (install_kube_microvm.sh)

**Goal**: A single script customers run to install KubeMicroVM on their cluster.
Included as part of each GitHub Release and the official installer Docker image.

### Installer Docker Image

Published to GHCR as `ghcr.io/plasticity-of-cloud/kube-microvm-installer:<version>`:
- Contains: `kubectl`, `helm`, `aws` CLI, `install_kube_microvm.sh`, all Helm charts, CLI binaries (arm64 + amd64)
- Customer runs: `docker run --rm -it -v ~/.kube:/root/.kube ghcr.io/plasticity-of-cloud/kube-microvm-installer:1.0.0`

### Script Steps (`install_kube_microvm.sh`)

```
a. --registry <url>   Import images into private registry
                      - Accept region as parameter (for ECR auto-login)
                      - Create ECR repos if they don't exist
                      - Retag and push: kube-microvm-operator, microvm-auth-agent (both amd64 + arm64)
                      - Persist registry URL to ~/.kube-microvm/config

b. --iam              Create IAM role + policies (CloudFormation)
                      - Deploy iam/kube-microvm-operator-role.yaml
                      - Create Pod Identity association per cluster
                      - Output: role ARN passed to helm installs

c. helm install kube-microvm-operator
                      - From private registry (if --registry set) or GHCR
                      - Passes: image registry, role ARN, region

d. helm install microvm-auth-agent (if token injection needed)
                      - From private registry or GHCR
                      - Passes: operator endpoint, image registry

e. Install kubectl plugin
                      - Copies kubectl-microvm binary to $HOME/bin/
                      - Detects arch (arm64 / amd64), installs correct binary

f. Validate
                      - kubectl microvm --help  (verifies plugin installed + spacing works)
                      - kubectl microvm image list-base  (verifies AWS connectivity)
```

### Parameters

```bash
./install_kube_microvm.sh \
  --cluster my-cluster \
  --region us-east-1 \
  --registry 123456789.dkr.ecr.us-east-1.amazonaws.com \
  --iam \
  --auth-agent
```

### Feature Branches Needed

- `feature/installer-script` — `install_kube_microvm.sh` + installer Docker image
- `feature/kubectl-plugin-completion-fix` — fix missing space in kubectl tab completion
