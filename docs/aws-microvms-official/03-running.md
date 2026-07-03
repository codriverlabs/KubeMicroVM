# Running and Using MicroVMs
Source: https://docs.aws.amazon.com/lambda/latest/dg/microvms-launching.html
Downloaded: 2026-07-03T14:32:00Z

## Starting a MicroVM

```bash
aws lambda-microvms run-microvm \
  --image-identifier arn:aws:lambda:us-east-1:123456789012:microvm-image:my-image \
  --ingress-network-connectors "arn:aws:lambda:us-east-1:aws:network-connector:aws-network-connector:ALL_INGRESS" \
  --egress-network-connectors "arn:aws:lambda:us-east-1:aws:network-connector:aws-network-connector:INTERNET_EGRESS" \
  --idle-policy '{"autoResumeEnabled":true,"maxIdleDurationSeconds":900,"suspendedDurationSeconds":1800}' \
  --maximum-duration-in-seconds 14400
```

Only required parameter: `--image-identifier`. All others optional.

### Key parameters

| Parameter | Description |
|-----------|-------------|
| `--image-identifier` | (Required) ARN of the MicroVM image to run |
| `--image-version` | Version to run (defaults to latest active) |
| `--execution-role-arn` | IAM role for runtime AWS service access |
| `--idle-policy` | Auto suspend/resume behavior |
| `--maximum-duration-in-seconds` | Max lifetime (running + suspended). Range: 1–28,800s (8h) |
| `--run-hook-payload` | String payload (max 16 KB) for /run hook |
| `--logging` | CloudWatch log group/stream config |
| `--ingress-network-connectors` | Inbound HTTPS connector ARN(s) |
| `--egress-network-connectors` | Outbound connector ARN(s) |

### Idle policy configuration

| Field | Description |
|-------|-------------|
| `autoResumeEnabled` | Auto-resume when traffic arrives while suspended |
| `maxIdleDurationSeconds` | Seconds without traffic before suspend. Max: 28,800 (8h) |
| `suspendedDurationSeconds` | Seconds in suspended state before Lambda terminates |

### Runtime payloads (runHookPayload)

Per-MicroVM config (max 16 KB string) delivered to /run hook. Unique per MicroVM (unlike
env vars which are per-image). Use for tenant IDs, session tokens, signed URLs.

/run hook receives:
```json
{
  "microvmId": "mvm-01234567-abcd-ef01-2345-6789abcdef01",
  "runHookPayload": "tenant-specific-string"
}
```

## Connecting to a MicroVM

Every MicroVM gets a unique public HTTPS endpoint URL assigned at `run-microvm`.

### Authentication

All requests require JWE auth token in `X-aws-proxy-auth` header.
No unauthenticated access option.

```bash
aws lambda-microvms create-microvm-auth-token \
  --microvm-identifier microvm-id \
  --expiration-in-minutes 30 \
  --allowed-ports '[{"allPorts":{}}]'
```

Port scoping: `{"port": N}`, `{"range": {"startPort": N, "endPort": N}}`, `{"allPorts": {}}`

### Port routing

Priority: 1) `X-aws-proxy-port` header, 2) WebSocket subprotocol `lambda-microvms.port.N`,
3) Default port 8080.

### Protocols supported

- HTTP/1.1, HTTP/2, WebSockets, gRPC, Server-Sent Events (SSE)

### WebSocket subprotocols

```javascript
const protocols = [
  "lambda-microvms",                             // Required base
  "lambda-microvms.authentication.<auth-token>", // Auth
  "lambda-microvms.port.9000"                    // Target port
];
const ws = new WebSocket('wss://<endpoint>/path', protocols);
```

## Lifecycle hooks

| Hook | When | Purpose |
|------|------|---------|
| /run | After start from snapshot | Init per-tenant state. Traffic begins after 200. |
| /resume | After resume from suspended | Re-establish connections, refresh creds |
| /suspend | Before suspend | Flush data, close connections gracefully |
| /terminate | Before terminate | Clean up resources |

Hooks listen on `/aws/lambda-microvms/runtime/v1/<hook-name>` on configured port.
