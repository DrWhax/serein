'use strict';
// Attach only to the disposable mock HTTPS server. Preserve the real client's
// headers/body and forward /callingService routes to the local upstream frontend.
const http2 = require('node:http2');
const http = require('node:http');
const { syncBuiltinESMExports } = require('node:module');
const target = new URL(process.env.SEREIN_TEST_LINK_FRONTEND);
if (target.protocol !== 'http:' || target.hostname !== '127.0.0.1' || !target.port) {
  throw new Error('the isolated join fixture requires a loopback frontend');
}
const original = http2.createSecureServer;
http2.createSecureServer = function (opts, handler) {
  return original.call(this, opts, function (req, res) {
    if (typeof req.url !== 'string' || !req.url.startsWith('/callingService/')) return handler.call(this, req, res);
    const path = req.url.slice('/callingService'.length);
    const headers = Object.fromEntries(Object.entries(req.headers).filter(([k]) => !k.startsWith(':') && !['host','connection'].includes(k)));
    const call = http.request({ hostname: target.hostname, port: target.port, method: req.method, path, headers }, upstream => {
      const clean = Object.fromEntries(Object.entries(upstream.headers).filter(([k]) => !['connection','transfer-encoding','keep-alive'].includes(k)));
      console.error('Loopback SFU', req.method, path.split('?')[0], upstream.statusCode);
      res.writeHead(upstream.statusCode, clean);
      upstream.pipe(res);
    });
    call.on('error', () => { res.writeHead(502); res.end(); });
    req.pipe(call);
  });
};
syncBuiltinESMExports();
