# CLI Design — kubectl-microvm

## Overview

`kubectl-microvm` is a kubectl plugin providing a streamlined UX for managing MicroVM resources. Distributed as a GraalVM native binary (ARM64/AMD64).

## Installation

```bash
# From GitHub Release
curl -Lo kubectl-microvm https://github.com/codriverlabs/KubeMicroVM/releases/latest/download/kubectl-microvm-linux-arm64
chmod +x kubectl-microvm
mv kubectl-microvm /usr/local/bin/

# Verify
kubectl microvm --help
```

## Commands

### Resource Management

```bash
# Create a MicroVM from inline spec
kubectl microvm create my-vm \
  --image python-sandbox \
  --memory 2048 \
  --network private-vpc \
  --namespace team-alpha

# Create from YAML
kubectl microvm create -f microvm.yaml

# List MicroVMs
kubectl microvm list [-n namespace | --all-namespaces]
kubectl microvm list --pool ci-runners

# Describe (detailed view)
kubectl microvm describe my-vm [-n namespace]

# Delete
kubectl microvm delete my-vm [-n namespace]
kubectl microvm delete --pool ci-runners --all
```

### Lifecycle Control

```bash
# Suspend a running MicroVM (preserves state, reduces cost)
kubectl microvm suspend my-vm

# Resume a suspended MicroVM
kubectl microvm resume my-vm

# Terminate (release all resources)
kubectl microvm terminate my-vm
```

### Pool Management

```bash
# Create a pool
kubectl microvm pool create ci-runners \
  --replicas 5 \
  --image ci-runner-image \
  --memory 4096

# Scale
kubectl microvm pool scale ci-runners --replicas 10

# Suspend all MicroVMs in a pool (cost saving)
kubectl microvm pool suspend ci-runners

# Resume all
kubectl microvm pool resume ci-runners

# Status
kubectl microvm pool status ci-runners
```

### Connectivity

```bash
# Get endpoint URL and auth token
kubectl microvm connect my-vm [--port 8080] [--duration 30m]

# Stream logs (via MicroVM endpoint)
kubectl microvm logs my-vm [--follow] [--since 5m]

# Exec into MicroVM shell (via WebSocket)
kubectl microvm exec my-vm -- /bin/bash
```

### Image Management

```bash
# Trigger a new image build
kubectl microvm image build python-sandbox --s3-key images/v4.zip

# List image versions
kubectl microvm image versions python-sandbox

# Activate a specific version
kubectl microvm image activate python-sandbox --version 3
```

## Output Formats

```bash
# Table (default)
kubectl microvm list
NAME            STATE     MEMORY   IMAGE             AGE
dev-sandbox-01  Running   2048MB   python-sandbox    2h
dev-sandbox-02  Suspended 2048MB   python-sandbox    5h
ci-runner-abc   Running   4096MB   ci-runner-image   30m

# JSON
kubectl microvm list -o json

# YAML
kubectl microvm describe my-vm -o yaml

# Wide (includes endpoint URL)
kubectl microvm list -o wide
```

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | General error |
| 2 | Resource not found |
| 3 | Validation error (invalid arguments) |
| 4 | AWS API error |
| 5 | Timeout |

## Configuration

The CLI uses the same kubeconfig as kubectl. AWS credentials are not needed by the CLI — it operates on Kubernetes resources only. The operator handles all AWS interactions.

```bash
# Context selection (same as kubectl)
kubectl microvm list --context production

# Namespace
kubectl microvm list -n team-alpha
```

## Implementation

- Built with **Picocli** for command parsing
- Uses **fabric8 Kubernetes client** for K8s API access
- Compiled to native binary via **GraalVM** (sub-10ms startup)
- Single binary, no JVM required at runtime
