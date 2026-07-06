# Design: Outbound Connectivity Test Fixture

## Summary

Create a test MicroVM image (`microvm-net-test`) that can verify outbound network
connectivity from within the MicroVM. This enables automated E2E validation of
INTERNET_EGRESS and VPC_EGRESS network connector modes.

## Motivation

The current `microvm-hello-node` test fixture is a minimal echo server — it only
responds to inbound requests. It cannot verify that outbound networking works because
it never makes external HTTP calls.

## Test Fixture: `microvm-net-test`

A Node.js app with endpoints:

| Endpoint | Description |
|----------|-------------|
| `GET /` | Health check (same as hello-node) |
| `GET /fetch?url=<URL>` | Fetches the given URL and returns the status + body |
| `GET /dns?host=<HOST>` | Resolves DNS for the given host |
| `GET /env` | Returns environment variables (for debugging) |

### Implementation

```javascript
const http = require('http');
const https = require('https');
const dns = require('dns');
const { URL } = require('url');

const server = http.createServer((req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);
  
  if (url.pathname === '/fetch') {
    const target = url.searchParams.get('url');
    if (!target) {
      res.writeHead(400, {'Content-Type': 'application/json'});
      return res.end(JSON.stringify({error: 'url param required'}));
    }
    const client = target.startsWith('https') ? https : http;
    client.get(target, {timeout: 5000}, (resp) => {
      let data = '';
      resp.on('data', d => data += d);
      resp.on('end', () => {
        res.writeHead(200, {'Content-Type': 'application/json'});
        res.end(JSON.stringify({status: resp.statusCode, body: data.slice(0, 1000)}));
      });
    }).on('error', (e) => {
      res.writeHead(502, {'Content-Type': 'application/json'});
      res.end(JSON.stringify({error: e.message}));
    });
  } else if (url.pathname === '/dns') {
    const host = url.searchParams.get('host') || 'httpbin.org';
    dns.resolve4(host, (err, addresses) => {
      res.writeHead(200, {'Content-Type': 'application/json'});
      res.end(JSON.stringify({host, addresses: addresses || [], error: err?.message}));
    });
  } else if (url.pathname === '/env') {
    res.writeHead(200, {'Content-Type': 'application/json'});
    res.end(JSON.stringify(process.env));
  } else {
    res.writeHead(200, {'Content-Type': 'application/json'});
    res.end(JSON.stringify({status: 'ok', path: url.pathname, ts: new Date().toISOString()}));
  }
});

server.listen(8080, () => console.log('Listening on 8080'));
```

## Test Cases

| ID | Test | Expected |
|----|------|----------|
| NET-EGRESS-01 | MicroVM with INTERNET_EGRESS calls `GET /fetch?url=https://httpbin.org/get` | 200, response body contains `"origin"` |
| NET-EGRESS-02 | MicroVM with VPC_EGRESS calls `GET /dns?host=google.com` | DNS resolves (has addresses) |
| NET-EGRESS-03 | MicroVM without egress calls `GET /fetch?url=https://httpbin.org/get` | Timeout or connection refused |
| NET-EGRESS-04 | MicroVM with INTERNET_EGRESS calls `GET /fetch?url=https://sts.us-east-1.amazonaws.com` | 200 (AWS API reachable) |

## Build

```bash
cd test-fixtures/microvm-net-test
zip -r ../../microvm-net-test.zip .
aws s3 cp microvm-net-test.zip s3://kube-microvm-test-<ACCOUNT_ID>-us-east-1/test-fixtures/
```
