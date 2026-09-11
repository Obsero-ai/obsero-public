/**
 * Static file server for the mock site.
 *
 * The AWS test site is S3 behind CloudFront. That shape does not port: a GCP
 * backend *bucket* has no logConfig at all, so a Cloud Storage origin behind
 * Cloud CDN emits no load-balancer request logs and there is nothing to ship.
 * The origin has to be a backend *service*, so the same static pages are served
 * from Cloud Run behind a serverless NEG instead.
 */
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { join, normalize, extname } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(fileURLToPath(new URL(".", import.meta.url)), "public");
const PORT = Number(process.env.PORT ?? 8080);

const CONTENT_TYPES = {
  ".html": "text/html; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".js": "application/javascript; charset=utf-8",
  ".svg": "image/svg+xml",
  ".ico": "image/x-icon",
  ".png": "image/png",
  ".jpg": "image/jpeg",
};

async function read(path) {
  try {
    return await readFile(path);
  } catch {
    return null;
  }
}

const server = createServer(async (req, res) => {
  const url = new URL(req.url ?? "/", `http://${req.headers.host ?? "localhost"}`);
  let path = decodeURIComponent(url.pathname);

  if (path === "/health") {
    res.writeHead(200, { "content-type": "text/plain" });
    return res.end("ok\n");
  }

  if (path.endsWith("/")) path += "index.html";

  // normalize() collapses ".." before it can escape ROOT.
  const file = join(ROOT, normalize(path));
  const body = file.startsWith(ROOT) ? await read(file) : null;

  if (body) {
    res.writeHead(200, {
      "content-type": CONTENT_TYPES[extname(file)] ?? "application/octet-stream",
      // Short TTL: long enough for Cloud CDN to be worth having in the path,
      // short enough that the harness still generates origin traffic.
      "cache-control": "public, max-age=60",
    });
    return res.end(body);
  }

  const notFound = await read(join(ROOT, "404.html"));
  res.writeHead(404, { "content-type": "text/html; charset=utf-8" });
  res.end(notFound ?? "not found");
});

server.listen(PORT, () => console.log(`site listening on :${PORT}`));
