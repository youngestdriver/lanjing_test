"use strict";

// Direct upstream client (lib/upstream.js) tests. All upstream traffic is a
// stubbed global.fetch shaped like the live platform; no test ever touches
// the real service. Covers the client's own session machinery: login flow
// (JSESSIONID bootstrap + form encoding), cookie jar merge/invalidation,
// session persistence, the not-logged-in guard, and session-expiry handling
// (onlineStatus:"0" body and redirect-to-login).

const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { after, before, test } = require("node:test");

const { createUpstreamApi } = require("../lib/upstream");
const { ApiError } = require("../lib/question-bank");

const BASE = "https://upstream.fixture.test";
const sha256 = (s) => crypto.createHash("sha256").update(s).digest("hex");
const md5 = (s) => crypto.createHash("md5").update(s).digest("hex");

const EMPTY_LIST = { success: true, bizContent: { total: 0, styles: [], examInfoModelList: [] } };

let originalFetch;
let tempDir;

before(() => {
  originalFetch = global.fetch;
  tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "lanjing-upstream-"));
});

after(() => {
  global.fetch = originalFetch;
  fs.rmSync(tempDir, { recursive: true, force: true });
});

function sessionPath(name = "session_cookies.txt") {
  return path.join(tempDir, name);
}

/** Stub upstream from a pathname → Response factory map, recording calls. */
function stubUpstream(routes) {
  const calls = [];
  global.fetch = async (url, init = {}) => {
    const u = new URL(url);
    const body = init.body ? String(init.body) : "";
    calls.push({ pathname: u.pathname, body, cookie: init.headers?.Cookie || "" });
    const route = routes[u.pathname];
    if (!route) throw new Error(`Unexpected upstream fixture URL: ${u.pathname}`);
    return typeof route === "function" ? route({ body, cookie: init.headers?.Cookie || "" }) : route;
  };
  return calls;
}

const json = (data, status = 200, headers = {}) => new Response(JSON.stringify(data), {
  status,
  headers: { "Content-Type": "application/json", ...headers },
});

test("login: JSESSIONID bootstrap, form encoding, session saved to file", async () => {
  const calls = stubUpstream({
    "/login/account/login/1": new Response("<html>login page</html>", {
      status: 200,
      headers: { "Set-Cookie": "JSESSIONID=js1; Path=/; HttpOnly" },
    }),
    "/login/account/login": json({ code: 10000, success: true }, 200, {
      "Set-Cookie": "sessionId=SECRET; Path=/",
    }),
  });

  const api = createUpstreamApi({ baseUrl: BASE, sessionFile: sessionPath() });
  assert.equal((await api.status()).loggedIn, false);

  const result = await api.login("13800138000", "hunter2");
  assert.deepEqual(result, { success: true });
  assert.equal((await api.status()).loggedIn, true);

  // JSESSIONID fetched from the login page first, then the login form POST
  // carries the platform's exact encoding (password as sha256 + md5).
  assert.equal(calls[0].pathname, "/login/account/login/1");
  assert.equal(calls[1].pathname, "/login/account/login");
  const form = new URLSearchParams(calls[1].body);
  assert.equal(form.get("userName"), "13800138000@1");
  assert.equal(form.get("userNameInput"), "13800138000");
  assert.equal(form.get("password"), sha256("hunter2"));
  assert.equal(form.get("passwordMD5"), md5("hunter2"));
  assert.equal(form.get("companyId"), "1");

  // The jar is persisted for later runs (existing cookies first, then new).
  assert.equal(fs.readFileSync(sessionPath(), "utf8"), "JSESSIONID=js1; sessionId=SECRET;");
});

test("login failure throws ApiError(401) and clears any saved session", async () => {
  stubUpstream({
    "/login/account/login/1": new Response("<html>login page</html>", {
      status: 200,
      headers: { "Set-Cookie": "JSESSIONID=js2; Path=/" },
    }),
    "/login/account/login": json({ code: 10001, success: false, desc: "用户名或密码错误" }),
  });

  const api = createUpstreamApi({ baseUrl: BASE, sessionFile: sessionPath() });
  await assert.rejects(api.login("13800138000", "wrong"), (err) => {
    assert.ok(err instanceof ApiError);
    assert.equal(err.status, 401);
    assert.equal(err.message, "用户名或密码错误");
    return true;
  });
  assert.equal((await api.status()).loggedIn, false);
  assert.equal(fs.existsSync(sessionPath()), false);
});

test("api calls without a session throw ApiError(401) before touching upstream", async () => {
  const calls = stubUpstream({});
  const api = createUpstreamApi({ baseUrl: BASE, sessionFile: sessionPath("nope.txt") });
  await assert.rejects(api.getExams(), (err) => err instanceof ApiError && err.status === 401 && err.message === "Not logged in");
  await assert.rejects(api.enter("E1"), (err) => err instanceof ApiError && err.status === 401);
  await assert.rejects(api.getQuestions("E1"), (err) => err instanceof ApiError && err.status === 401);
  await assert.rejects(api.submit("E1"), (err) => err instanceof ApiError && err.status === 401);
  assert.equal(calls.length, 0);
});

test("session expiry (onlineStatus 0 body) clears the jar and the session file", async () => {
  stubUpstream({
    "/exam/current_exam_list": json({ code: 10000, success: false, onlineStatus: "0" }, 200),
  });
  fs.writeFileSync(sessionPath("stale.txt"), "sessionId=STALE;", { mode: 0o600 });

  const api = createUpstreamApi({ baseUrl: BASE, sessionFile: sessionPath("stale.txt") });
  await assert.rejects(api.getExams(), (err) => err instanceof ApiError && err.status === 401 && err.message === "Session expired");
  assert.equal((await api.status()).loggedIn, false);
  assert.equal(fs.existsSync(sessionPath("stale.txt")), false);
});

test("session expiry (redirect to login) throws ApiError(401)", async () => {
  stubUpstream({
    "/exam/current_exam_list": new Response("", {
      status: 302,
      headers: { Location: "https://upstream.fixture.test/login/account/login" },
    }),
  });
  fs.writeFileSync(sessionPath("stale2.txt"), "sessionId=STALE2;", { mode: 0o600 });

  const api = createUpstreamApi({ baseUrl: BASE, sessionFile: sessionPath("stale2.txt") });
  await assert.rejects(api.getExams(), (err) => err instanceof ApiError && err.status === 401);
  assert.equal((await api.status()).loggedIn, false);
});

test("cookie jar merges set-cookie updates and drops max-age=0 deletions", async () => {
  const calls = stubUpstream({
    "/exam/current_exam_list": ({ body }) => json(EMPTY_LIST, 200, { "Set-Cookie": "bad=1; Path=/" }),
  });
  fs.writeFileSync(sessionPath("jar.txt"), "sessionId=SECRET;JSESSIONID=js1;", { mode: 0o600 });
  const api = createUpstreamApi({ baseUrl: BASE, sessionFile: sessionPath("jar.txt") });

  await api.getExams();
  assert.equal(calls[0].cookie, "sessionId=SECRET;JSESSIONID=js1;");
  await api.getExams();
  assert.equal(calls[1].cookie, "sessionId=SECRET; JSESSIONID=js1; bad=1;");

  // Next response deletes the bad cookie; the jar drops it.
  global.fetch = async (url, init = {}) => {
    const u = new URL(url);
    calls.push({ pathname: u.pathname, body: "", cookie: init.headers?.Cookie || "" });
    assert.equal(u.pathname, "/exam/current_exam_list");
    return json(EMPTY_LIST, 200, { "Set-Cookie": "bad=; Path=/; Max-Age=0" });
  };
  await api.getExams();
  assert.equal(calls[2].cookie, "sessionId=SECRET; JSESSIONID=js1; bad=1;");
  await api.getExams();
  assert.equal(calls[3].cookie, "sessionId=SECRET; JSESSIONID=js1;");
});

test("getExams retries transient 5xx responses but not 401s", async () => {
  let attempts = 0;
  global.fetch = async (url, init = {}) => {
    const u = new URL(url);
    attempts += 1;
    assert.equal(u.pathname, "/exam/current_exam_list");
    if (attempts < 3) return json({ code: 10000, success: false, desc: "server hiccup" }, 502);
    return json(EMPTY_LIST);
  };
  fs.writeFileSync(sessionPath("retry.txt"), "sessionId=OK;", { mode: 0o600 });
  const api = createUpstreamApi({ baseUrl: BASE, sessionFile: sessionPath("retry.txt"), retries: 2, retryDelayMs: 1 });

  assert.deepEqual(await api.getExams(), []);
  assert.equal(attempts, 3);

  // A business failure surfaces as ApiError(502) — still retried like a 5xx
  // (same as the old web-server-backed client), then reported.
  let businessAttempts = 0;
  global.fetch = async () => {
    businessAttempts += 1;
    return json({ code: 10002, success: false, desc: "rejected" });
  };
  await assert.rejects(api.getExams(), (err) => err instanceof ApiError && err.status === 502 && err.message === "rejected");
  assert.equal(businessAttempts, 3);

  // A 401 (session expiry) is never retried — it surfaces immediately.
  let authAttempts = 0;
  global.fetch = async () => {
    authAttempts += 1;
    return json({ code: 10000, success: false, onlineStatus: "0" });
  };
  await assert.rejects(api.getExams(), (err) => err instanceof ApiError && err.status === 401);
  assert.equal(authAttempts, 1);
});
