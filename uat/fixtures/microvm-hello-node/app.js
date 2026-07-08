// Minimal HTTP server — listens on port 8080
const http = require('http');

const server = http.createServer((req, res) => {
  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ status: 'ok', path: req.url, ts: new Date().toISOString() }));
});

server.listen(8080, () => {
  console.log('Listening on port 8080');
});
