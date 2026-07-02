# User Guide: CLI Reference

The `microvm` CLI manages AWS Lambda MicroVMs on Kubernetes.

## Installation

```bash
# Download binary
curl -fsSL https://github.com/plasticity-of-cloud/KubeMicroVM/releases/latest/download/microvm-linux-amd64 \
  -o ~/bin/microvm && chmod +x ~/bin/microvm

# kubectl plugin symlink (optional)
ln -sf ~/bin/microvm ~/bin/kubectl-microvm

# Shell completion
source <(microvm completion bash)   # bash
source <(microvm completion zsh)    # zsh
```

Both `microvm <cmd>` and `kubectl microvm <cmd>` work — the symlink enables kubectl plugin discovery.

---

## MicroVM commands

### `microvm list`

List all MicroVMs in the current namespace.

```bash
microvm list
microvm list -n production
```

Output columns: `NAME`, `STATE`, `VM-ID`, `RUNTIME`, `MEMORY`, `AGE`

### `microvm describe <name>`

Show full details of a MicroVM including status, conditions, and spec.

```bash
microvm describe my-vm
microvm describe my-vm -n production
```

### `microvm create`

Create a new MicroVM.

```bash
microvm create --name my-vm --image my-app-image
microvm create --name my-vm --image my-app-image --namespace production
```

Options:
- `--name` — MicroVM name (required)
- `--image` — MicroVMImage name (required)
- `-n, --namespace` — namespace (default: `default`)
- `--max-duration` — maximum duration in seconds

### `microvm delete <name>`

Delete a MicroVM (sets `desiredState: Terminated`, then deletes the CR).

```bash
microvm delete my-vm
microvm delete my-vm --wait          # wait for termination
microvm delete my-vm --timeout 60    # timeout in seconds
```

### `microvm pause <name>`

Suspend a running MicroVM.

```bash
microvm pause my-vm
```

### `microvm resume <name>`

Resume a suspended MicroVM.

```bash
microvm resume my-vm
```

### `microvm token`

Get an auth token for connecting to a MicroVM endpoint.

```bash
# Via operator (in-cluster, no AWS creds needed — requires RBAC)
microvm token --name my-vm

# Directly via AWS SDK (requires AWS credentials)
microvm token --name my-vm --direct

# Custom expiry
microvm token --name my-vm --expires 60    # 60 minutes
```

The token is used as the `X-aws-proxy-auth` header when calling the MicroVM endpoint.

### `microvm exec <name>`

Get shell access credentials for a running MicroVM.

```bash
microvm exec my-vm
```

---

## Image commands

### `microvm image list`

```bash
microvm image list
microvm image list -n production
```

### `microvm image describe <name>`

```bash
microvm image describe my-image
microvm image describe --name my-image    # equivalent
```

### `microvm image create`

Create a MicroVM image from an S3 source.

```bash
microvm image create \
  --name my-image \
  --s3-bucket my-bucket \
  --s3-key path/to/app.zip \
  --base-image "arn:aws:lambda:us-east-1:aws:microvm-image:al2023-1" \
  --build-role-arn "arn:aws:iam::123456789012:role/KubeMicroVMBuildRole" \
  --wait
```

Options:
- `--name` — image name (required)
- `--s3-bucket` — S3 bucket with source zip (required)
- `--s3-key` — S3 key of the zip (required)
- `--base-image` — base image ARN
- `--build-role-arn` — IAM role for build
- `--auto-activate` — activate on successful build
- `--wait` — wait for build to complete
- `--wait-timeout` — timeout in seconds (default: 600)

### `microvm image update`

Trigger a rebuild with new S3 source.

```bash
microvm image update --name my-image --s3-key new/path/app.zip
```

### `microvm image delete <name>`

```bash
microvm image delete my-image
microvm image delete --name my-image    # equivalent
```

### `microvm image base-images`

List AWS-managed base images available for building.

```bash
microvm image base-images
microvm image base-images --region eu-west-1
microvm image base-images --arn arn:aws:lambda:us-east-1:aws:microvm-image:al2023-1
```

### `microvm image version-delete`

Delete a specific image version.

```bash
microvm image version-delete --name my-image --version 1.0
```

---

## ReplicaSet commands

### `microvm rs list`

```bash
microvm rs list
```

### `microvm rs describe <name>`

```bash
microvm rs describe my-replicaset
```

### `microvm rs scale`

```bash
microvm rs scale my-replicaset --replicas 5
```

---

## Network commands

### `microvm network list`

```bash
microvm network list
```

### `microvm network describe <name>`

```bash
microvm network describe my-vpc-egress
```

---

## Global options

| Option | Description |
|--------|-------------|
| `-n, --namespace` | Kubernetes namespace (default: `default`) |
| `--region` | AWS region (for commands that call AWS directly) |
| `-h, --help` | Show help |
| `-V, --version` | Print version |

---

## Environment variables

| Variable | Description |
|----------|-------------|
| `KUBECONFIG` | Path to kubeconfig (default: `~/.kube/config`) |
| `AWS_REGION` | Default AWS region |
| `AWS_PROFILE` | AWS credentials profile |
