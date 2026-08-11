"use strict";

// Desktop static-asset bundle: scripts/build-public-bundle.js turns public/
// into a CommonJS module (public-bundle.js, gitignored) that server.js serves
// from memory when present. A compiled binary's __dirname points at the BUILD
// machine's source path, so desktop builds MUST NOT depend on the file system
// for public/ — this test proves the memory path serves identical content
// (user machines without a checkout would otherwise 404/500 on every page).

const assert = require("node:assert/strict");
const fs = require("node:fs");
const http = require("node:http");
const os = require("node:os");
const path = require("node:path");
const { once } = require("node:events");
const { after, before, test } = require("node:test");
const { spawnSync } = require("node:child_process");

const repoRoot = path.resolve(__dirname, "..", "..", "..");
const webDir = path.resolve(__dirname, "..");
const bundleFile = path.join(webDir, "public-bundle.js");
const publicDir = path.join(webDir, "public");

const localDir = fs.mkdtempSync(path.join(os.tmpdir(), "lanjing-web-bundle-"));
process.env.LANJING_LOCAL_DIR = localDir;
process.env.HOST = "127.0.0.1";
delete process.env.LANJING_BANK_DIR;

let server;
let port;
let bundle;

function walk(dir, prefix, out) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const rel = prefix ? `${prefix}/${entry.name}` : entry.name;
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) walk(full, rel, out);
    else out.push(rel);
  }
  return out;
}

before(async () => {
  // Generate the bundle exactly like the release workflow does.
  const result = spawnSync(process.execPath, [path.join(repoRoot, "scripts", "build-public-bundle.js")], { encoding: "utf8" });
  assert.equal(result.status, 0, result.stderr);
  bundle = require(bundleFile);
  const { startServer } = require("../server");
  server = startServer(0);
  await once(server, "listening");
  port = server.address().port;
});

after(async () => {
  if (server) {
    await new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
  }
  fs.rmSync(localDir, { recursive: true, force: true });
  fs.rmSync(bundleFile, { force: true });
});

function get(route) {
  return new Promise((resolve, reject) => {
    const req = http.request({ hostname: "127.0.0.1", port, path: route, method: "GET" }, (res) => {
      const chunks = [];
      res.on("data", (chunk) => chunks.push(chunk));
      res.on("end", () => resolve({ status: res.statusCode, headers: res.headers, body: Buffer.concat(chunks) }));
    });
    req.on("error", reject);
    req.end();
  });
}

test("bundle maps every public file with byte-identical content", () => {
  const expected = walk(publicDir, "", []);
  assert.deepEqual(Object.keys(bundle.files).sort(), expected.sort());
  for (const [name, content] of Object.entries(bundle.files)) {
    assert.ok(Buffer.isBuffer(content), `${name} is a Buffer`);
    assert.ok(content.equals(fs.readFileSync(path.join(publicDir, name))), `${name} content matches`);
  }
});

test("GET / serves index.html from memory", async () => {
  const response = await get("/");
  assert.equal(response.status, 200);
  assert.match(response.headers["content-type"], /^text\/html/);
  assert.ok(response.body.equals(bundle.files["index.html"]));
});

test("GET /styles.css serves CSS from memory", async () => {
  const response = await get("/styles.css");
  assert.equal(response.status, 200);
  assert.match(response.headers["content-type"], /^text\/css/);
  assert.ok(response.body.equals(bundle.files["styles.css"]));
});

test("GET /js/app.js serves JS from memory (subdirectory)", async () => {
  const response = await get("/js/app.js");
  assert.equal(response.status, 200);
  assert.match(response.headers["content-type"], /^text\/javascript/);
  assert.ok(response.body.equals(bundle.files["js/app.js"]));
});

test("GET /sw.js and /manifest.json serve from memory", async () => {
  for (const route of ["/sw.js", "/manifest.json", "/icon-192.png"]) {
    const response = await get(route);
    assert.equal(response.status, 200, `${route} serves`);
    const key = route.slice(1);
    assert.ok(response.body.equals(bundle.files[key]), `${route} content matches`);
  }
});

test("missing static path falls through to the SPA fallback (index.html)", async () => {
  const response = await get("/nonexistent-route");
  assert.equal(response.status, 200);
  assert.ok(response.body.equals(bundle.files["index.html"]));
});
