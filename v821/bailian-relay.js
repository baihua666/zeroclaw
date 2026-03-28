#!/usr/bin/env node

const http = require('http');
const { URL } = require('url');

const apiKey =
  process.env.BAILIAN_API_KEY ||
  process.env.DASHSCOPE_API_KEY ||
  process.env.ZEROCLAW_API_KEY;

if (!apiKey) {
  console.error('BAILIAN_API_KEY or DASHSCOPE_API_KEY or ZEROCLAW_API_KEY is required');
  process.exit(1);
}

const listenHost = process.env.RELAY_HOST || '0.0.0.0';
const listenPort = Number(process.env.RELAY_PORT || '19091');
const upstreamBase = process.env.BAILIAN_BASE_URL || 'https://coding.dashscope.aliyuncs.com';

function collect(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on('data', chunk => chunks.push(chunk));
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

const server = http.createServer(async (req, res) => {
  try {
    const body = await collect(req);
    const upstreamUrl = new URL(req.url, upstreamBase);
    const headers = { ...req.headers };

    delete headers.host;
    delete headers.connection;
    delete headers['content-length'];
    headers.authorization = `Bearer ${apiKey}`;

    const upstream = await fetch(upstreamUrl, {
      method: req.method,
      headers,
      body: body.length > 0 ? body : undefined,
    });

    res.writeHead(upstream.status, Object.fromEntries(upstream.headers.entries()));
    const arrayBuffer = await upstream.arrayBuffer();
    res.end(Buffer.from(arrayBuffer));
  } catch (error) {
    res.writeHead(502, { 'content-type': 'application/json' });
    res.end(
      JSON.stringify({
        error: 'relay_upstream_error',
        message: String(error && error.message ? error.message : error),
      }),
    );
  }
});

server.listen(listenPort, listenHost, () => {
  console.log(`Bailian relay listening on http://${listenHost}:${listenPort}`);
  console.log(`Upstream: ${upstreamBase}`);
});
