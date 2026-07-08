# Design: Robot Framework UAT Integration

## Status

**Implementing** — automated UAT for all user guides.

## Motivation

The manual UAT walkthrough found 11 bugs across 8 user guides. To prevent regression
and enable repeatable GA validation, we automate all 52+ test cases using Robot Framework.

Robot Framework is chosen because:
- Keyword-driven: test cases read like the user guide steps they validate
- Built-in SSH/Process libraries for kubectl and AWS CLI execution
- Structured reporting (HTML, XML) for CI/CD integration
- Easy to extend with Python for complex assertions
- Human-readable `.robot` files serve as living documentation

## Architecture

```
uat/
├── resources/
│   ├── common.resource        # Shared keywords (kubectl, aws, microvm CLI)
│   ├── cluster_setup.resource # Image creation, namespace labelling
│   └── variables.robot        # Account ID, region, bucket, cluster name
├── tests/
│   ├── 01_quick_start.robot
│   ├── 02_rbac.robot
│   ├── 03_networking.robot
│   ├── 04_pod_token_injection.robot
│   ├── 05_replicaset.robot
│   ├── 06_microvm_class.robot
│   ├── 07_drift_autosuspend.robot
│   └── 08_memory_sizing.robot
├── results/                   # Generated test reports (gitignored)
└── requirements.txt           # robotframework, robotframework-kubelibrary
```

## Prerequisites

- Robot Framework installed: `pip install robotframework`
- kubectl configured with cluster access
- AWS CLI authenticated (Pod Identity or IRSA)
- `microvm` CLI in PATH
- S3 test fixtures uploaded
- Operator deployed and running on cluster

## Execution

```bash
# Run all UAT suites
cd uat
robot --outputdir results tests/

# Run a single suite
robot --outputdir results tests/02_rbac.robot

# Run with variables override (different cluster/region)
robot --variable CLUSTER:my-cluster --variable REGION:eu-west-1 tests/
```

## Test lifecycle

Each suite follows:
1. **Suite Setup**: Create test-specific resources (image, VM, SA, etc.)
2. **Test Cases**: Execute and verify each guide step
3. **Suite Teardown**: Force-cleanup all resources (patch finalizers + delete)

Teardown uses `Run Keyword And Ignore Error` to ensure cleanup even on test failure.

## CI/CD Integration

The robot tests run as a post-deploy validation step:

```yaml
# .github/workflows/uat.yml
- name: Run UAT
  run: |
    pip install robotframework
    cd uat
    robot --outputdir results --loglevel INFO tests/
- name: Upload results
  uses: actions/upload-artifact@v4
  with:
    name: uat-results
    path: uat/results/
```

## Tagging

Tests are tagged for selective execution:
- `quick-start`, `rbac`, `networking`, `injection`, `replicaset`, `class`, `drift`, `memory`
- `smoke` — minimal subset for quick validation (1 test per guide)
- `destructive` — tests that terminate VMs externally or scale down
