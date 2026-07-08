// microvm-net-test — MicroVM test fixture for verifying outbound connectivity
// Endpoints:
//   GET /             — health check
//   GET /fetch?url=X  — fetches URL and returns status + body
//   GET /dns?host=X   — resolves DNS for host
//   GET /env          — returns environment variables
const http = require('http');
const https = require('https');
const dns = require('dns');
const { URL } = require('url');

const server = http.createServer((req, res) => {
  const url = new URL(req.url, `http://${req.headers.host || 'localhost:8080'}`);

  if (url.pathname === '/fetch') {
    const target = url.searchParams.get('url');
    if (!target) {
      res.writeHead(400, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify({ error: 'url query param required' }));
    }
    const client = target.startsWith('https') ? https : http;
    const request = client.get(target, { timeout: 5000 }, (resp) => {
      let data = '';
      resp.on('data', d => data += d);
      resp.on('end', () => {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({
          status: resp.statusCode,
          headers: resp.headers,
          body: data.slice(0, 2000)
        }));
      });
    });
    request.on('error', (e) => {
      res.writeHead(502, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: e.message, code: e.code }));
    });
    request.on('timeout', () => {
      request.destroy();
      res.writeHead(504, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'timeout', code: 'ETIMEDOUT' }));
    });
  } else if (url.pathname === '/dns') {
    const host = url.searchParams.get('host') || 'httpbin.org';
    dns.resolve4(host, (err, addresses) => {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ host, addresses: addresses || [], error: err?.message || null }));
    });
  } else if (url.pathname === '/env') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    const safe = { ...process.env };
    // Redact sensitive values
    for (const k of Object.keys(safe)) {
      if (k.includes('SECRET') || k.includes('TOKEN') || k.includes('KEY')) {
        safe[k] = '***REDACTED***';
      }
    }
    res.end(JSON.stringify(safe, null, 2));
  } else {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: 'ok', path: url.pathname, ts: new Date().toISOString() }));
  }
});

server.listen(8080, () => {
  console.log('microvm-net-test listening on port 8080');
});
