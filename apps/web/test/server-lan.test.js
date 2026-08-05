"use strict";

// LAN-mode tests run in their own child process (node --test runs each file
// separately), so the environment below is set before the server module is
// loaded and affects only this file.

const assert = require("node:assert/strict");
const fs = require("node:fs");
const http = require("node:http");
const os = require("node:os");
const path = require("node:path");
const { once } = require("node:events");
const { after, before, test } = require("node:test");

const localDir = fs.mkdtempSync(path.join(os.tmpdir(), "lanjing-web-lan-"));
process.env.LANJING_LOCAL_DIR = localDir;
process.env.TRUSTED_HOSTS = "quiz.local, quiz.lan";
// The server defaults to binding 0.0.0.0 with LAN access enabled, which is
// exactly what these tests exercise; no HOST override is set.
const { startServer } = require("../server");

let server;
let port;

before(async () => {
  server = startServer(0);
  await once(server, "listening");
  port = server.address().port;
});

after(async () => {
  if (server) {
    await new Promise((resolve, reject) => {
      server.close((error) => error ? reject(error) : resolve());
    });
  }
  fs.rmSync(localDir, { recursive: true, force: true });
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

function lanIpv4() {
  for (const interfaces of Object.values(os.networkInterfaces())) {
    for (const iface of interfaces) {
      if (iface.family === "IPv4" && !iface.internal) return iface.address;
    }
  }
  return null;
}

test("server binds to the configured non-loopback host", () => {
  assert.equal(server.address().address, "0.0.0.0");
});

test("loopback hosts remain allowed in LAN mode", async () => {
  for (const host of ["127.0.0.1", "localhost"]) {
    const response = await request("/api/status", { headers: { Host: host } });
    assert.equal(response.status, 200, `Host ${host} should be allowed`);
  }
});

test("local interface addresses are allowed as Host", async (t) => {
  const address = lanIpv4();
  if (!address) return t.skip("no non-internal IPv4 interface found");
  const response = await request("/api/status", { headers: { Host: `${address}:${port}` } });
  assert.equal(response.status, 200);
});

test("TRUSTED_HOSTS hostnames are allowed in LAN mode", async () => {
  const response = await request("/api/status", { headers: { Host: "quiz.local" } });
  assert.equal(response.status, 200);
});

test("untrusted hosts are still rejected in LAN mode", async () => {
  const response = await request("/api/status", { headers: { Host: "attacker.example" } });
  assert.equal(response.status, 403);
  assert.match(response.body.error, /host/i);
});

test("cross-origin requests stay rejected while same-origin LAN writes pass", async (t) => {
  const address = lanIpv4();
  if (!address) return t.skip("no non-internal IPv4 interface found");
  const lanHost = `${address}:${port}`;

  const badOrigin = await request("/api/logout", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Host: lanHost,
      Origin: "https://attacker.example",
    },
    body: "{}",
  });
  assert.equal(badOrigin.status, 403);
  assert.match(badOrigin.body.error, /cross-origin/i);

  const sameOrigin = await request("/api/logout", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Host: lanHost,
      Origin: `http://${lanHost}`,
    },
    body: "{}",
  });
  assert.equal(sameOrigin.status, 200);
  assert.deepEqual(sameOrigin.body, { success: true });
});

test("GET /api/settings reports LAN access enabled by default", async () => {
  const response = await request("/api/settings");
  assert.equal(response.status, 200);
  assert.deepEqual(response.body, { lanEnabled: true, host: "0.0.0.0", envHost: false });
});

test("POST /api/settings rejects a non-boolean lanEnabled", async () => {
  const response = await request("/api/settings", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ lanEnabled: "yes" }),
  });
  assert.equal(response.status, 400);
  assert.match(response.body.error, /boolean/i);
});

test("disabling LAN access blocks interface IPs immediately and persists", async (t) => {
  const address = lanIpv4();
  if (!address) return t.skip("no non-internal IPv4 interface found");
  const lanHost = `${address}:${port}`;

  const disable = await request("/api/settings", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ lanEnabled: false }),
  });
  assert.equal(disable.status, 200);
  assert.equal(disable.body.lanEnabled, false);
  assert.deepEqual(
    JSON.parse(fs.readFileSync(path.join(localDir, "settings.json"), "utf8")),
    { lanEnabled: false },
  );

  const blocked = await request("/api/status", { headers: { Host: lanHost } });
  assert.equal(blocked.status, 403);
  const loopback = await request("/api/status", { headers: { Host: "127.0.0.1" } });
  assert.equal(loopback.status, 200);
  const trusted = await request("/api/status", { headers: { Host: "quiz.local" } });
  assert.equal(trusted.status, 200, "TRUSTED_HOSTS stays independent of the LAN toggle");

  // A restart applies the persisted setting: the interface IP stays blocked.
  await new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
  server = startServer(0);
  await once(server, "listening");
  port = server.address().port;
  const stillBlocked = await request("/api/status", { headers: { Host: `${address}:${port}` } });
  assert.equal(stillBlocked.status, 403);

  // Restore LAN access for the remaining runs.
  const enable = await request("/api/settings", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ lanEnabled: true }),
  });
  assert.equal(enable.status, 200);
  assert.equal(enable.body.lanEnabled, true);
  const unblocked = await request("/api/status", { headers: { Host: `${address}:${port}` } });
  assert.equal(unblocked.status, 200);
});
