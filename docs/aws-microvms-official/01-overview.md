# AWS Lambda MicroVMs — Overview
Source: https://docs.aws.amazon.com/lambda/latest/dg/lambda-microvms-guide.html
Downloaded: 2026-07-03T14:32:00Z

AWS Lambda MicroVMs are purpose-built serverless compute environments that provide VM-level
isolation with full operating system capabilities (installing system packages, mounting
filesystems), snapshot-based rapid startup speeds, and fine-grained control over ingress
networking (port access, HTTP/2, gRPC, WebSockets) and egress networking (public internet
access and VPC access).

## How Lambda MicroVMs work

1. Package application code + Dockerfile into a zip archive, upload to S3.
2. Call the Lambda API to create a MicroVM image. Lambda runs the Dockerfile, starts the app,
   captures a snapshot of the fully initialized environment.
3. Call `run-microvm` to launch a MicroVM from the snapshot with rapid startup times.
4. Clients connect through the MicroVM's dedicated HTTPS endpoint.
5. When idle, the MicroVM suspends (preserving memory + disk state, reducing costs).
   Resumes when traffic returns. Configurable via idle policies or API.
6. Terminate the MicroVM to release all resources.

## Use cases

- Interactive code environments (IDEs)
- AI code execution sandboxes
- Data analytics applications (Jupyter notebooks)
- Security scanning
- Reinforcement learning environments
- Multi-tenant CI/CD task executors
- Game servers

## Key features

- **Rapid startup** — resume from pre-initialized snapshots
- **Lifecycle control** — suspend, resume, terminate programmatically or via idle policies
- **Flexible networking** — inbound HTTPS on configurable ports, outbound internet or VPC
- **Flexible resource allocation** — baseline-peak model, scale to 4x baseline during peak.
  Pay baseline rate while running, only pay for active use above baseline.
