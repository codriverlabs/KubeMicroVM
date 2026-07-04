# KubeMicroVM — Robot Framework UAT

Automated User Acceptance Tests that validate every step in the user guides works
exactly as documented.

## Prerequisites

```bash
pip install robotframework
```

The cluster must have:
- KubeMicroVM operator installed (`helm install ...`)
- Pod Identity association for the operator SA
- VPC endpoint for `com.amazonaws.<region>.lambda-microvm` (private subnets)
- `microvm` CLI in PATH

## Quick Start

```bash
cd uat-robot

# 1. Verify cluster is ready (run first)
robot --outputdir results tests/00_cluster_setup.robot

# 2. Run all UAT suites
robot --outputdir results tests/

# 3. Run a single suite
robot --outputdir results tests/02_rbac.robot

# 4. Smoke tests only (~1 test per guide, fast validation)
robot --outputdir results -i smoke tests/
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
│   ├── 01_quick_start.robot     # Quick Start guide (8 tests)
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
    └── 00_cluster_setup.robot (validate)
    └── 01_quick_start.robot (Verify Cluster Ready → Create Quick Start Resources)
    └── 02_rbac.robot (Verify Cluster Ready → Create RBAC Resources)
    └── ...
```

- `__init__.robot` runs `Setup Cluster If Needed` once when you run the full `tests/` directory
- Each individual suite also calls `Verify Cluster Ready` to fail fast with a clear message
- Suites are independent — each creates and cleans up its own test resources
- Running order doesn't matter (no inter-suite dependencies)

## Customization

Override variables for a different cluster:

```bash
robot --variable REGION:eu-west-1 \
      --variable ACCOUNT_ID:111222333444 \
      --variable CHART_VERSION:1.0.0 \
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
