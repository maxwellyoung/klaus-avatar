import { createServer } from 'http';
import { readFile } from 'fs/promises';
import { extname, join } from 'path';
import { existsSync } from 'fs';

const PORT = 8888;
const ROOT = new URL('.', import.meta.url).pathname;

const MIME = {
  '.html': 'text/html',
  '.js': 'application/javascript',
  '.mjs': 'application/javascript',
  '.json': 'application/json',
  '.css': 'text/css',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.svg': 'image/svg+xml',
  '.vrm': 'application/octet-stream',
  '.glb': 'model/gltf-binary',
  '.gltf': 'model/gltf+json',
  '.fbx': 'application/octet-stream',
};

const server = createServer(async (req, res) => {
  let path = decodeURIComponent(new URL(req.url, `http://localhost:${PORT}`).pathname);
  if (path === '/') path = '/viewer/index.html';
  if (path.endsWith('/')) path += 'index.html';

  const filePath = join(ROOT, path);
  if (!existsSync(filePath)) {
    res.writeHead(404);
    res.end('Not found');
    return;
  }

  const ext = extname(filePath).toLowerCase();
  const contentType = MIME[ext] || 'application/octet-stream';

  try {
    const data = await readFile(filePath);
    res.writeHead(200, {
      'Content-Type': contentType,
      'Content-Length': data.length,
      'Access-Control-Allow-Origin': '*',
    });
    res.end(data);
  } catch (err) {
    res.writeHead(500);
    res.end(err.message);
  }
});

server.listen(PORT, () => {
  console.log(`Klaus Avatar → http://localhost:${PORT}`);
});
