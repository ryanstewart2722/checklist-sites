const http = require('http');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const arg = name => { const i = process.argv.indexOf('--' + name); return i > -1 ? process.argv[i + 1] : undefined; };

const PORT = Number(arg('port') || process.env.PORT || 8091);
const ROOT = __dirname;
const DATA_FILE = path.resolve(ROOT, arg('data') || 'data/store.json');
const DATA_DIR = path.dirname(DATA_FILE);
const UPLOAD_DIR = path.join(DATA_DIR, 'uploads');
const KEY_RE = /^[\w-]{1,64}$/;
const MAX_BODY = 10 * 1024 * 1024;
const MAX_UPLOAD = 20 * 1024 * 1024;
const ALLOWED_HOSTS = new Set([`localhost:${PORT}`, `127.0.0.1:${PORT}`, `[::1]:${PORT}`]);

const mime = {
  '.html': 'text/html',
  '.css': 'text/css',
  '.js': 'application/javascript',
  '.otf': 'font/otf',
  '.ttf': 'font/ttf',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
  '.json': 'application/json',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.svg': 'image/svg+xml',
};

function readStore() {
  try { return JSON.parse(fs.readFileSync(DATA_FILE, 'utf8')); } catch (e) { return {}; }
}

function writeStore(store) {
  fs.mkdirSync(DATA_DIR, { recursive: true });
  if (fs.existsSync(DATA_FILE)) fs.copyFileSync(DATA_FILE, DATA_FILE.replace(/\.json$/, '.backup.json'));
  const tmp = DATA_FILE + '.tmp';
  fs.writeFileSync(tmp, JSON.stringify(store, null, 2));
  fs.renameSync(tmp, DATA_FILE);
}

function json(res, status, body) {
  res.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
  res.end(JSON.stringify(body));
}

function handleApi(req, res, urlPath) {
  // Rejects DNS-rebinding requests from other sites pointed at this port.
  if (!ALLOWED_HOSTS.has(req.headers.host)) return json(res, 403, { error: 'forbidden' });

  if (urlPath === '/api/store' && req.method === 'GET') return json(res, 200, readStore());

  // Saves an event picture (already resized to JPEG by the page) into data/uploads.
  if (urlPath === '/api/upload' && req.method === 'POST') {
    if (req.headers['content-type'] !== 'image/jpeg') return json(res, 415, { error: 'jpeg only' });
    const chunks = [];
    let size = 0;
    req.on('data', chunk => {
      size += chunk.length;
      if (size > MAX_UPLOAD) { json(res, 413, { error: 'too large' }); req.destroy(); return; }
      chunks.push(chunk);
    });
    req.on('end', () => {
      if (res.writableEnded) return;
      const name = Date.now().toString(36) + '-' + crypto.randomBytes(4).toString('hex') + '.jpg';
      fs.mkdirSync(UPLOAD_DIR, { recursive: true });
      fs.writeFileSync(path.join(UPLOAD_DIR, name), Buffer.concat(chunks));
      json(res, 200, { url: '/uploads/' + name });
    });
    return;
  }

  const m = urlPath.match(/^\/api\/store\/([^/]+)$/);
  if (!m || req.method !== 'PUT') return json(res, 404, { error: 'not found' });
  if (!KEY_RE.test(m[1])) return json(res, 400, { error: 'bad key' });

  let body = '';
  let size = 0;
  req.on('data', chunk => {
    size += chunk.length;
    if (size > MAX_BODY) { json(res, 413, { error: 'too large' }); req.destroy(); return; }
    body += chunk;
  });
  req.on('end', () => {
    if (res.writableEnded) return;
    let value;
    try { value = JSON.parse(body); } catch (e) { return json(res, 400, { error: 'bad json' }); }
    const store = readStore();
    store[m[1]] = value;
    writeStore(store);
    json(res, 200, { ok: true });
  });
}

function handle(req, res) {
  let urlPath;
  try { urlPath = decodeURIComponent(req.url.split('?')[0]); }
  catch (e) { res.writeHead(400); res.end('Bad request'); return; }

  if (urlPath.startsWith('/api/')) return handleApi(req, res, urlPath);

  const upload = urlPath.match(/^\/uploads\/([\w-]+\.jpg)$/);
  if (upload) {
    return fs.readFile(path.join(UPLOAD_DIR, upload[1]), (err, data) => {
      if (err) { res.writeHead(404); res.end('Not found'); return; }
      res.writeHead(200, { 'Content-Type': 'image/jpeg', 'Cache-Control': 'max-age=31536000, immutable' });
      res.end(data);
    });
  }

  if (urlPath === '/') urlPath = '/index.html';
  const filePath = path.join(ROOT, urlPath);
  const blocked = !filePath.startsWith(ROOT + path.sep)
    || filePath.startsWith(DATA_DIR + path.sep)
    || filePath.split(path.sep).some(part => part.startsWith('.'));
  if (blocked) { res.writeHead(404); res.end('Not found'); return; }

  const ext = path.extname(filePath).toLowerCase();
  fs.readFile(filePath, (err, data) => {
    if (err) { res.writeHead(404); res.end('Not found'); return; }
    res.writeHead(200, { 'Content-Type': mime[ext] || 'application/octet-stream', 'Cache-Control': 'no-store' });
    res.end(data);
  });
}

http.createServer(handle).listen(PORT, '127.0.0.1', () =>
  console.log(`Checklist server on http://localhost:${PORT} (data: ${path.relative(ROOT, DATA_FILE)})`));
http.createServer(handle).listen(PORT, '::1').on('error', () => {});
