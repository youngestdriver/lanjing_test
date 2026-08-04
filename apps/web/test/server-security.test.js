"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const http = require("node:http");
const os = require("node:os");
const path = require("node:path");
const { once } = require("node:events");
const { after, before, test } = require("node:test");

const localDir = fs.mkdtempSync(path.join(os.tmpdir(), "lanjing-web-security-"));
process.env.LANJING_LOCAL_DIR = localDir;
const { startServer } = require("../server");

let server;
let port;
let origin;

before(async () => {
  server = startServer(0);
  await once(server, "listening");
  port = server.address().port;
  origin = `http://127.0.0.1:${port}`;
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
        contentType: res.headers["content-type"] || "",
        body: text ? JSON.parse(text) : null,
      }));
    });
    req.on("error", reject);
    req.end(body);
  });
}

test("local status requests remain available without a session", async () => {
  assert.equal(server.address().address, "127.0.0.1");
  const response = await request("/api/status");
  assert.equal(response.status, 200);
  assert.match(response.contentType, /^application\/json/);
  assert.deepEqual(response.body, { loggedIn: false, hasSavedSession: false });
});

test("API rejects untrusted Host and cross-origin requests before route handlers", async () => {
  const badHost = await request("/api/status", { headers: { Host: "attacker.example" } });
  assert.equal(badHost.status, 403);
  assert.match(badHost.body.error, /host/i);

  const badOrigin = await request("/api/login", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Origin: "https://attacker.example",
    },
    body: JSON.stringify({ phone: "fixture", password: "fixture" }),
  });
  assert.equal(badOrigin.status, 403);
  assert.match(badOrigin.body.error, /cross-origin/i);
});

test("API rejects form-encoded writes without contacting the upstream service", async () => {
  const response = await request("/api/login", {
    method: "POST",
    headers: {
      "Content-Type": "application/x-www-form-urlencoded",
      Origin: origin,
    },
    body: "phone=fixture&password=fixture",
  });
  assert.equal(response.status, 415);
  assert.match(response.body.error, /application\/json/);
});

test("logout is an idempotent JSON POST and unknown API routes stay JSON", async () => {
  const legacyGet = await request("/api/logout");
  assert.equal(legacyGet.status, 404);
  assert.match(legacyGet.contentType, /^application\/json/);

  const logout = await request("/api/logout", {
    method: "POST",
    headers: { "Content-Type": "application/json", Origin: origin },
    body: "{}",
  });
  assert.equal(logout.status, 200);
  assert.deepEqual(logout.body, { success: true });

  const missing = await request("/api");
  assert.equal(missing.status, 404);
  assert.match(missing.contentType, /^application\/json/);
});

test("a stale upstream response cannot overwrite a newly logged-in session", async () => {
  const originalFetch = global.fetch;
  let sessionNumber = 0;
  let releaseExam;
  let notifyExamStarted;
  const examStarted = new Promise((resolve) => { notifyExamStarted = resolve; });
  const examGate = new Promise((resolve) => { releaseExam = resolve; });

  global.fetch = async (url) => {
    const pathname = new URL(url).pathname;
    if (pathname === "/login/account/login/1") {
      sessionNumber += 1;
      return new Response("", {
        status: 200,
        headers: { "Set-Cookie": `JSESSIONID=fixture-${sessionNumber}; Path=/` },
      });
    }
    if (pathname === "/login/account/login") {
      return new Response(JSON.stringify({ success: true }), {
        status: 200,
        headers: { "Content-Type": "application/json", "Set-Cookie": `sessionId=session-${sessionNumber}; Path=/` },
      });
    }
    if (pathname === "/exam/current_exam_list") {
      notifyExamStarted();
      await examGate;
      return new Response(JSON.stringify({ success: true, bizContent: {} }), {
        status: 200,
        headers: { "Content-Type": "application/json", "Set-Cookie": "sessionId=stale-session; Path=/" },
      });
    }
    throw new Error(`Unexpected upstream fixture URL: ${url}`);
  };

  const login = () => request("/api/login", {
    method: "POST",
    headers: { "Content-Type": "application/json", Origin: origin },
    body: JSON.stringify({ phone: "fixture", password: "fixture" }),
  });
  const logout = () => request("/api/logout", {
    method: "POST",
    headers: { "Content-Type": "application/json", Origin: origin },
    body: "{}",
  });

  try {
    assert.equal((await login()).status, 200);
    const staleExamRequest = request("/api/exams");
    await examStarted;
    assert.equal((await logout()).status, 200);
    assert.equal((await login()).status, 200);
    releaseExam();

    const staleResponse = await staleExamRequest;
    assert.equal(staleResponse.status, 409);
    assert.match(staleResponse.body.error, /session changed/i);

    const status = await request("/api/status");
    assert.deepEqual(status.body, { loggedIn: true, hasSavedSession: true });
  } finally {
    releaseExam();
    await logout();
    global.fetch = originalFetch;
  }
});
