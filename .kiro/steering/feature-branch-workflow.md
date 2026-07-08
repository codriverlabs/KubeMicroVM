# Feature Branch Workflow

## Process

Every feature follows this sequence. Do not skip steps or merge without completing all of them.

```
main → feature branch → develop → test locally → deploy → E2E test → sign off → teardown → merge to main
```

### 1. Document

- Create design doc in `docs/design/` describing the feature, motivation, and implementation plan
- Commit to main before starting the feature branch
- Include testing strategy in the design doc

### 2. Create Feature Branch

```bash
git checkout main
git checkout -b feature/<name>
```

### 3. Develop

- Implement the feature
- Follow existing patterns (CDI injection, reconciler structure, status fields)
- Add/update integration tests covering all branches

### 4. Test Locally

Only required when there are **code changes** (Java, properties, Helm templates).
Skip for documentation-only branches.

```bash
./mvnw -B install -DskipTests -q && \
./mvnw -B -pl operator-tests verify
```

**All 49+ tests must pass before proceeding.** No exceptions when code has changed.

### 5. Deploy to EKS

Follow the [EKS deployment steering](./eks-deployment.md):

```bash
# Cleanup
kubectl delete validatingwebhookconfiguration kube-microvm-operator-validating --ignore-not-found
kubectl delete mutatingwebhookconfiguration kube-microvm-operator-mutating --ignore-not-found
# Force-remove CRs (patch finalizers first)
# Helm uninstall
# Fresh helm install with ECR image
```

### 6. E2E Test

- Create the required CRs (MicroVMImage, MicroVM, MicroVMNetwork, etc.)
- Verify operator logs show expected behavior
- Verify CR status fields are populated correctly
- Test the happy path end-to-end

### 7. Sign Off

- Verify the feature works as documented in the design doc
- Call the MicroVM endpoint if applicable (auth token + curl)
- Confirm no errors in operator logs
- Document the result (status output, log lines)

### 8. Teardown

- Terminate all MicroVMs (`desiredState: Terminated`)
- Delete all test CRs (MicroVM → MicroVMImage → MicroVMNetwork)
- Verify no resources remain: `kubectl get microvms,microvmimages,microvmnetworks -A`

### 9. Merge to Main

```bash
git checkout main
git merge feature/<name> --no-edit
git push
```

Only merge after all steps complete successfully.

## Rules

- **Never push with failing tests** — run the full suite before every push **with code changes**
- **Skip tests for doc-only changes** — `.md`, `.kiro/`, `docs/`, `uat/fixtures/`, `.github/`
- **Never use `helm upgrade` during dev** — always uninstall + install
- **Always delete webhooks before CRs** when operator is not running
- **Document results** of each step (logs, status output) in the PR or commit messages
- **One feature per branch** — keep branches focused and short-lived
