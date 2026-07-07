# KubeMicroVM — Robot Framework UAT

Automated User Acceptance Tests that validate every step in the user guides works
exactly as documented.

## Prerequisites

```bash
pip install robotframework
```

The cluster must have:
- KubeMicroVM operator installed and running (`helm install ...` or via install script)
- Pod Identity association for the operator SA
- `microvm` CLI in PATH
- AWS credentials with access to Lambda MicroVMs API

> **VPC endpoints are not required.** The UAT suites work against any EKS cluster
> with outbound internet access to the Lambda MicroVMs API. VPC endpoints are only
> needed for clusters in private subnets with no internet egress — that is a
> deployment configuration, not a UAT prerequisite.

## Recommended run order

The suites are independent (each creates and cleans up its own resources), but
running **Quick Start first** (`01_quick_start.robot`) is recommended because:

1. It validates the complete operator install — operator running, webhooks active,
   namespace labelled, image build works end-to-end
2. It exercises the baseline that all other guides assume (working operator + image)
3. If `01_quick_start.robot` fails, the remaining suites will likely also fail

```bash
cd uat-robot

# 1. Validate cluster prerequisites
robot --outputdir results tests/00_cluster_setup.robot

# 2. Run Quick Start first (recommended baseline validation)
robot --outputdir results tests/01_quick_start.robot

# 3. Run remaining suites
robot --outputdir results tests/02_rbac.robot tests/03_networking.robot \
      tests/04_pod_token_injection.robot tests/05_replicaset.robot \
      tests/06_microvm_class.robot tests/07_drift_autosuspend.robot \
      tests/08_memory_sizing.robot

# OR: run all suites at once (includes setup + cleanup)
robot --outputdir results tests/
```

## Quick Start (single command)

```bash
cd uat-robot
robot --outputdir results tests/
```

## Structure

```
uat-robot/
├── resources/
│   ├── variables.robot          # Account, region, bucket, versions
│   ├── common.resource          # Shared keywords (kubectl, wait, token, curl)
│   └── cluster_setup.resource   # Prerequisite verification + auto-setup
├── tests/
│   ├── __init__.robot           # Directory-level setup (installs operator if missing)
│   ├── 00_cluster_setup.robot   # Standalone cluster validation (run first)
│   ├── 01_quick_start.robot     # Quick Start guide (9 tests)
│   ├── 02_rbac.robot            # RBAC guide (8 tests)
│   ├── 03_networking.robot      # Networking guide (5 tests)
│   ├── 04_pod_token_injection.robot  # Pod Token Injection (9 tests)
│   ├── 05_replicaset.robot      # ReplicaSet guide (5 tests)
│   ├── 06_microvm_class.robot   # MicroVMClass guide (6 tests)
│   ├── 07_drift_autosuspend.robot    # Drift & Auto-Suspend (5 tests)
│   └── 08_memory_sizing.robot   # Memory Sizing guide (6 tests)
└── results/                     # Generated reports (gitignored)
```

## Dependency Chain

Each suite depends on cluster infrastructure being ready:

```
__init__.robot (Setup Cluster If Needed)
    └── 00_cluster_setup.robot (validate prerequisites)
    └── 01_quick_start.robot   (recommended baseline — run first)
    └── 02_rbac.robot          (independent — creates own resources)
    └── ...
```

- `__init__.robot` runs `Setup Cluster If Needed` once when you run the full `tests/` directory
- Each individual suite also calls `Verify Cluster Ready` to fail fast with a clear message
- Suites are independent — each creates and cleans up its own test resources
- `01_quick_start.robot` is the recommended first suite as it validates the complete baseline

## Customization

Override variables for a different cluster:

```bash
robot --variable REGION:eu-west-1 \
      --variable ACCOUNT_ID:<ACCOUNT_ID> \
      --variable CHART_VERSION:1.0.2 \
      --variable CODEBASE_PATH:/path/to/KubeMicroVM \
      --outputdir results tests/
```

## Tags

| Tag | Meaning |
|-----|---------|
| `smoke` | Minimal subset — 1 key test per guide |
| `setup` | Cluster prerequisite checks |
| `critical` | Must-pass for any testing to proceed |
| `destructive` | Terminates VMs externally or scales down |
| `quick-start`, `rbac`, `networking`, etc. | Per-guide tags |
