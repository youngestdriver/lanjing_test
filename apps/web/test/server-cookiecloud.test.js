"use strict";

// Endpoint tests for the CookieCloud sync feature. They run in their own
// child process (node --test runs each file separately), so the environment
// below is set before the server module is loaded and affects only this file.

const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const fs = require("node:fs");
const http = require("node:http");
const net = require("node:net");
const os = require("node:os");
const path = require("node:path");
const { spawn } = require("node:child_process");
const { once } = require("node:events");
const { after, before, test } = require("node:test");

const localDir = fs.mkdtempSync(path.join(os.tmpdir(), "lanjing-web-cc-"));
process.env.LANJING_LOCAL_DIR = localDir;
process.env.HOST = "127.0.0.1";
const cookiecloud = require("../lib/cookiecloud");
const { startServer } = require("../server");

const UUID = "test-uuid-1234";
const PASSWORD = "test-password-5678";

// ---------- minimal CookieCloud server replica ----------
// Stores {encrypted, crypto_type} per uuid, exactly like the real server
// (api/app.js): /update overwrites, /get/:uuid 404s when missing.
const mockBlobs = new Map();
let mockRequestCount = 0;
let mockServer;
let mockPort;

before(async () => {
  mockServer = http.createServer((req, res) => {
    mockRequestCount++;
    if (req.method === "POST" && req.url === "/update") {
      let body = "";
      req.on("data", (chunk) => { body += chunk; });
      req.on("end", () => {
        const { uuid, encrypted, crypto_type } = JSON.parse(body);
        mockBlobs.set(uuid, { encrypted, crypto_type });
        res.setHeader("content-type", "application/json");
        res.end(JSON.stringify({ action: "done" }));
      });
      return;
    }
    if (req.method === "GET" && req.url?.startsWith("/get/")) {
      const uuid = decodeURIComponent(req.url.slice("/get/".length));
      const blob = mockBlobs.get(uuid);
      res.setHeader("content-type", "application/json");
      if (!blob) { res.statusCode = 404; return res.end("Not Found"); }
      return res.end(JSON.stringify(blob));
    }
    res.statusCode = 404;
    res.end("Not Found");
  });
  mockServer.listen(0, "127.0.0.1");
  await once(mockServer, "listening");
  mockPort = mockServer.address().port;
});

after(async () => {
  if (mockServer) await new Promise((resolve) => mockServer.close(resolve));
  fs.rmSync(localDir, { recursive: true, force: true });
});

// Encrypt a cookie_data payload with the shared derived key, like a real
// writer (the extension or our own client) would.
function makeBlob(cookieData, uuid = UUID, password = PASSWORD, cryptoType = "aes-128-cbc-fixed") {
  const payload = JSON.stringify({ cookie_data: cookieData, local_storage_data: {} });
  return {
    encrypted: cookiecloud.encrypt(payload, uuid, password, cryptoType),
    crypto_type: cryptoType,
  };
}

function seedBlob(cookieData, ...rest) {
  const blob = makeBlob(cookieData, ...rest);
  mockBlobs.set(rest[0] || UUID, blob);
  return blob;
}

// ---------- app server ----------
// Each sync scenario restarts the app with fresh module state: the cookie jar
// and settings are module-level singletons, and writing the session file
// alone never touches the running server's in-memory jar.
const SESSION_PATH = path.join(localDir, "session_cookies.txt");
const SETTINGS_PATH = path.join(localDir, "settings.json");
let server;
let port;

function appServerPath() {
  return path.join(__dirname, "..", "server.js");
}

async function restartApp(options = {}) {
  const { sessionFile, settings } = options;
  if (server) {
    await new Promise((resolve, reject) => {
      server.close((error) => error ? reject(error) : resolve());
    });
    server = null;
  }
  // Reset module-level state (cookieJar, lastPushedHash, settings cache).
  for (const entry of Object.keys(require.cache)) {
    if (entry === require.resolve(appServerPath())) delete require.cache[entry];
  }
  if (sessionFile === undefined) { try { fs.unlinkSync(SESSION_PATH); } catch {} }
  else if (sessionFile !== null) fs.writeFileSync(SESSION_PATH, sessionFile, { mode: 0o600 });
  if (settings === undefined) { try { fs.unlinkSync(SETTINGS_PATH); } catch {} }
  else if (settings !== null) {
    fs.writeFileSync(SETTINGS_PATH, JSON.stringify({ lanEnabled: true, cookieCloud: settings }), { mode: 0o600 });
  }
  server = require(appServerPath()).startServer(0);
  await once(server, "listening");
  port = server.address().port;
}

before(async () => {
  await restartApp({ sessionFile: null, settings: null });
});

after(async () => {
  if (server) await new Promise((resolve, reject) => {
    server.close((error) => error ? reject(error) : resolve());
  });
});

function request(route, options = {}) {
  return new Promise((resolve, reject) => {
    const body = options.body || "";
    const req = http.request({
      hostname: "127.0.0.1",
      port,
      path: route,
      method: options.method || "GET",
      headers: {
        ...(body ? { "Content-Length": Buffer.byteLength(body) } : {}),
        ...(options.headers || {}),
      },
    }, (res) => {
      let text = "";
      res.setEncoding("utf8");
      res.on("data", (chunk) => { text += chunk; });
      res.on("end", () => resolve({
        status: res.statusCode,
        body: text ? JSON.parse(text) : null,
      }));
    });
    req.on("error", reject);
    req.end(body);
  });
}

function jsonRequest(route, method, body) {
  return request(route, {
    method,
    headers: { "Content-Type": "application/json" },
    body: typeof body === "string" ? body : JSON.stringify(body ?? {}),
  });
}

function readSessionFile() {
  try { return fs.readFileSync(path.join(localDir, "session_cookies.txt"), "utf8"); }
  catch { return ""; }
}

function configure(config) {
  return jsonRequest("/api/cookiecloud", "POST", config);
}

// ---------- config endpoint ----------

test("GET /api/cookiecloud never exposes the password", async () => {
  const r = await request("/api/cookiecloud");
  assert.equal(r.status, 200);
  assert.equal(r.body.enabled, false);
  assert.equal(r.body.hasPassword, false);
  assert.equal(r.body.server, "");
  assert.equal(r.body.uuid, "");
  assert.ok(!("password" in r.body));
});

test("POST /api/cookiecloud validates the server URL", async () => {
  for (const server of ["ftp://cc.example.com", "cc.example.com", "http://user:pw@cc.example.com", "x".repeat(2049)]) {
    const r = await jsonRequest("/api/cookiecloud", "POST", { server });
    assert.equal(r.status, 400, `server ${JSON.stringify(server.slice(0, 20))} should be rejected`);
  }
});

test("POST /api/cookiecloud validates uuid and password", async () => {
  let r = await jsonRequest("/api/cookiecloud", "POST", { uuid: "" });
  assert.equal(r.status, 400);
  r = await jsonRequest("/api/cookiecloud", "POST", { uuid: "x".repeat(129) });
  assert.equal(r.status, 400);
  r = await jsonRequest("/api/cookiecloud", "POST", { password: "x".repeat(257) });
  assert.equal(r.status, 400);
  // enabling without config is allowed; sync will report "not configured"
  r = await jsonRequest("/api/cookiecloud", "POST", { enabled: true });
  assert.equal(r.status, 200);
  assert.equal(r.body.enabled, true);
  await jsonRequest("/api/cookiecloud", "POST", { enabled: false });
});

test("POST /api/cookiecloud stores config, strips trailing slash, masks password", async () => {
  const r = await configure({
    server: `http://127.0.0.1:${mockPort}/`, // trailing slash must be stripped
    uuid: UUID,
    password: PASSWORD,
  });
  assert.equal(r.status, 200);
  assert.equal(r.body.server, `http://127.0.0.1:${mockPort}`);
  assert.equal(r.body.hasPassword, true);
  assert.ok(!("password" in r.body));
  // password stays saved when omitted on later updates
  const r2 = await jsonRequest("/api/cookiecloud", "POST", { uuid: UUID });
  assert.equal(r2.body.hasPassword, true);
  // empty string leaves the stored password untouched
  const r3 = await jsonRequest("/api/cookiecloud", "POST", { password: "" });
  assert.equal(r3.body.hasPassword, true);
});

test("cookieCloud config survives a server restart", async () => {
  // The running server wrote settings.json; a fresh process must reload it.
  const persisted = JSON.parse(fs.readFileSync(SETTINGS_PATH, "utf8"));
  assert.equal(persisted.cookieCloud.uuid, UUID);
  assert.equal(persisted.cookieCloud.password, PASSWORD);
  assert.equal(persisted.cookieCloud.enabled, false); // enabled is set later

  // Free port for the child process.
  const probe = net.createServer();
  probe.listen(0, "127.0.0.1");
  await once(probe, "listening");
  const childPort = probe.address().port;
  probe.close();
  await once(probe, "close");

  const child = spawn(process.execPath, [appServerPath()], {
    env: { ...process.env, LANJING_LOCAL_DIR: localDir, PORT: String(childPort), HOST: "127.0.0.1" },
    stdio: "ignore",
  });
  try {
    let childResponse = null;
    for (let attempt = 0; attempt < 30; attempt++) {
      childResponse = await rawGet(childPort).catch(() => null);
      if (childResponse?.status === 200) break;
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
    assert.ok(childResponse, "child server should come up");
    assert.equal(childResponse.status, 200);
    assert.equal(childResponse.body.uuid, UUID);
    assert.equal(childResponse.body.hasPassword, true);
    assert.equal(childResponse.body.enabled, false);
  } finally {
    child.kill();
  }
});

function rawGet(targetPort) {
  return new Promise((resolve, reject) => {
    const req = http.request({ hostname: "127.0.0.1", port: targetPort, path: "/api/cookiecloud" }, (res) => {
      let text = "";
      res.setEncoding("utf8");
      res.on("data", (c) => { text += c; });
      res.on("end", () => resolve({ status: res.statusCode, body: JSON.parse(text) }));
    });
    req.on("error", reject);
    req.end();
  });
}

// ---------- sync flow ----------
const SYNC_CONFIG = { enabled: true, uuid: UUID, password: PASSWORD };

test("sync imports a cloud session and does not push it back", async () => {
  seedBlob({
    "test.lanjingweike.com": [{ name: "sessionId", value: "CLOUD_SESSION" }],
    "www.baidu.com": [{ name: "BAIDUID", value: "B1" }],
  });
  await restartApp({ settings: { ...SYNC_CONFIG, server: `http://127.0.0.1:${mockPort}` } });
  const r = await jsonRequest("/api/cookiecloud/sync", "POST");
  assert.equal(r.status, 200);
  assert.equal(r.body.applied, true);
  assert.equal(r.body.pushed, false);
  assert.equal(r.body.lastError, null);
  assert.ok(readSessionFile().includes("sessionId=CLOUD_SESSION"));
  const status = await request("/api/status");
  assert.equal(status.body.loggedIn, true);

  // Echo guard: a second sync applies nothing and pushes nothing.
  const r2 = await jsonRequest("/api/cookiecloud/sync", "POST");
  assert.equal(r2.body.applied, false);
  assert.equal(r2.body.pushed, false);
});

test("first-time sync pushes the local session when the cloud is empty", async () => {
  mockBlobs.delete(UUID);
  const before = mockRequestCount;
  await restartApp({
    sessionFile: "sessionId=LOCAL_SESSION; JSESSIONID=js1;",
    settings: { ...SYNC_CONFIG, server: `http://127.0.0.1:${mockPort}` },
  });
  const r = await jsonRequest("/api/cookiecloud/sync", "POST");
  assert.equal(r.status, 200);
  assert.equal(r.body.applied, false);
  assert.equal(r.body.pushed, true);
  assert.equal(r.body.lastError, null);
  const blob = mockBlobs.get(UUID);
  assert.ok(blob, "a blob should exist after the push");
  const plain = cookiecloud.decrypt(blob.encrypted, UUID, PASSWORD, blob.crypto_type);
  const payload = JSON.parse(plain);
  assert.ok(payload.cookie_data["test.lanjingweike.com"].some((c) => c.name === "sessionId"));
  assert.ok(mockRequestCount > before);
});

test("push merges non-lanjingweike domains and keeps the local session intact", async () => {
  // Cloud holds a baidu cookie but no lanjingweike session; the local jar has
  // a session. The push must keep the baidu entry, and the local session must
  // not be clobbered (cloud has no sessionId to apply).
  seedBlob({ "www.baidu.com": [{ name: "BAIDUID", value: "B1" }] });
  await restartApp({
    sessionFile: "sessionId=LOCAL_SESSION; JSESSIONID=js1;",
    settings: { ...SYNC_CONFIG, server: `http://127.0.0.1:${mockPort}` },
  });
  const r = await jsonRequest("/api/cookiecloud/sync", "POST");
  assert.equal(r.body.applied, false);
  assert.equal(r.body.pushed, true);
  assert.equal(r.body.lastError, null);
  assert.ok(readSessionFile().includes("sessionId=LOCAL_SESSION"));
  const blob = mockBlobs.get(UUID);
  const payload = JSON.parse(cookiecloud.decrypt(blob.encrypted, UUID, PASSWORD, blob.crypto_type));
  assert.deepEqual(payload.cookie_data["www.baidu.com"], [{ name: "BAIDUID", value: "B1" }]);
  assert.ok(payload.cookie_data["test.lanjingweike.com"].some((c) => c.name === "sessionId"));
});

test("sync with wrong password fails closed and reports the error", async () => {
  seedBlob({ "test.lanjingweike.com": [{ name: "sessionId", value: "S" }] });
  await restartApp({
    sessionFile: "sessionId=LOCAL_SESSION; JSESSIONID=js1;",
    settings: { ...SYNC_CONFIG, password: "totally-wrong", server: `http://127.0.0.1:${mockPort}` },
  });
  const r = await jsonRequest("/api/cookiecloud/sync", "POST");
  assert.equal(r.status, 200);
  assert.equal(r.body.applied, false);
  assert.equal(r.body.pushed, false);
  assert.ok(r.body.lastError);
  // local session untouched
  assert.ok(readSessionFile().includes("sessionId=LOCAL_SESSION"));
});

test("sync against an unreachable server reports the error", async () => {
  await restartApp({
    settings: { ...SYNC_CONFIG, server: "http://127.0.0.1:1" }, // closed port
  });
  const r = await jsonRequest("/api/cookiecloud/sync", "POST");
  assert.equal(r.body.applied, false);
  assert.equal(r.body.pushed, false);
  assert.ok(r.body.lastError);
});

test("cookiecloud endpoints are reachable without login", async () => {
  // The endpoints are auth-exempt like /api/settings; an unauthenticated
  // request must not 401. (Also asserts the exact-match exemption list.)
  await restartApp({ sessionFile: null, settings: null });
  const r = await request("/api/cookiecloud");
  assert.notEqual(r.status, 401);
  const r2 = await jsonRequest("/api/cookiecloud/sync", "POST");
  assert.notEqual(r2.status, 401);
});
