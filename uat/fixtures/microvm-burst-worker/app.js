// microvm-burst-worker — Lightweight compute fixture for burst scale testing
// Simulates a minimal stateless worker that responds to health checks
// and performs trivial computation on request.
const http = require('http');

let requestCount = 0;

const server = http.createServer((req, res) => {
  requestCount++;
  if (req.url === '/health') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: 'healthy', requests: requestCount }));
  } else if (req.url === '/compute') {
    // Trivial CPU work — Fibonacci(30)
    const fib = (n) => n <= 1 ? n : fib(n - 1) + fib(n - 2);
    const result = fib(30);
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ result, ts: new Date().toISOString() }));
  } else {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({
      worker: 'burst-worker',
      path: req.url,
      ts: new Date().toISOString(),
      uptime: process.uptime()
    }));
  }
});

server.listen(8080, () => {
  console.log('microvm-burst-worker listening on port 8080');
});
