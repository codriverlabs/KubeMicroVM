# Review Notes

## Consistency Check ✅

All documentation files are internally consistent:
- Module names and counts match across codebase_info, components, and architecture
- CRD field names match between interfaces.md and data_models.md
- State machine transitions in architecture.md match data_models.md
- Workflow diagrams reference correct component names
- Token auth two-step flow is consistent across architecture.md, components.md, and workflows.md
- ReplicaSet rolling update fields consistent between interfaces.md and data_models.md

## Changes in This Run (2026-07-12)

- **codebase_info.md**: Updated latest stable release to v1.0.5; corrected integration test count to 76; added exact dependency versions (Quarkus 3.36.3, Fabric8 7.7.0, JOSDK 5.0.4, AWS SDK 2.44.6); added `operator-spi` to module table
- **architecture.md**: Added explicit two-step token auth flow (TokenReview → SubjectAccessReview); added SPI design principle
- **components.md**: Token endpoint now documents TokenReview security step; PodMutatingWebhook notes Helm registration with `failurePolicy: Ignore`; auth agent documents `.ready` sentinel file; ReplicaSet reconciler mentions rolling update; added QuotaGuard and SPI sections
- **interfaces.md**: Added ReplicaSet new fields (`updateStrategyType`, `maxUnavailable`, `updatedReplicas`, `currentTemplateHash`); added pod annotation table for sidecar injection; added health/metrics endpoints; added K8s API usage table; expanded AWS operations list
- **data_models.md**: Added `MicroVMReplicaSet` and `MicroVMReplicaSetSpec/Status` to class diagram; added rolling update fields section; added webhook deserialization note
- **workflows.md**: Token flow now shows TokenReview step; added ReplicaSet rolling update workflow; release workflow notes multi-arch targets
- **dependencies.md**: Updated all dependency versions from pom.xml; added GitHub Actions workflows table; corrected UAT test count to 62/10 suites
- **AGENTS.md**: Refreshed consolidated file with all above changes; preserved Custom Instructions section

## Completeness Check

### Well Covered
- Core reconciler logic and state machine
- CRD specifications and field semantics
- Token auth flow (two-step TokenReview + SubjectAccessReview)
- Sidecar injection (namespace label, pod annotations, `.ready` file)
- ReplicaSet rolling update strategy
- Deployment and development workflows
- Memory sizing feature
- Testing strategy (integration + Robot Framework UAT)
- CLA and contribution workflow
- Quota guard and rate limiting
- SPI extension points

### Remaining Gaps

| Gap | Impact | Recommendation |
|-----|--------|---------------|
| `MicroVMPoolReconciler` not in user guides | Low — internal/experimental | Document when promoted to user-facing |
| SDK code generation process not documented | Low — build infra | Add note in dependencies.md about codegen from service model |
| Logging configuration not documented | Low | Document `%test` profile properties for test isolation |
| `docs/testing/load-test.sh` and `regression-test.sh` not covered | Low | Add to workflows.md if promoted to standard usage |

## Recommendations

1. **Add MicroVMPool to user guides** when it graduates from internal use.
2. **Document SDK codegen** process for contributors who need to add new AWS API operations.
3. **Add load-test and regression-test scripts** to workflows.md once their usage is standardized.
