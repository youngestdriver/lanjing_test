"use strict";

// Tests for the /bank static download endpoint used by the iOS practice
// client. The bank directory is pointed at a tmp dir via LANJING_BANK_DIR
// (never the real apps/bank); the CI-without-bank case is covered by
// removing the tmp contents and asserting 404s.

const assert = require("node:assert/strict");
const fs = require("node:fs");
const http = require("node:http");
const os = require("node:os");
const path = require("node:path");
const { once } = require("node:events");
const { after, before, test } = require("node:test");

const localDir = fs.mkdtempSync(path.join(os.tmpdir(), "lanjing-web-bank-"));
const bankDir = path.join(localDir, "bank");
process.env.LANJING_LOCAL_DIR = localDir;
process.env.LANJING_BANK_DIR = bankDir;
process.env.HOST = "127.0.0.1";
const { startServer } = require("../server");

let server;
let port;

before(async () => {
  fs.mkdirSync(bankDir, { recursive: true });
  fs.writeFileSync(path.join(bankDir, "meta.json"), JSON.stringify({ version: 1, round: 26, counts: { 言语理解: 500 } }), "utf8");
  fs.writeFileSync(path.join(bankDir, "言语理解.jsonl"), "{\"_id\":\"q1\"}\n{\"_id\":\"q2\"}\n", "utf8");
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

function get(route) {
  return new Promise((resolve, reject) => {
    const req = http.request({ hostname: "127.0.0.1", port, path: route, method: "GET" }, (res) => {
      let text = "";
      res.setEncoding("utf8");
      res.on("data", (chunk) => { text += chunk; });
      res.on("end", () => resolve({ status: res.statusCode, text }));
    });
    req.on("error", reject);
    req.end();
  });
}

test("GET /bank/meta.json serves the bank file", async () => {
  const response = await get("/bank/meta.json");
  assert.equal(response.status, 200);
  assert.deepEqual(JSON.parse(response.text), { version: 1, round: 26, counts: { 言语理解: 500 } });
});

test("GET /bank serves Chinese file names via percent-encoding", async () => {
  const response = await get("/bank/" + encodeURIComponent("言语理解.jsonl"));
  assert.equal(response.status, 200);
  assert.deepEqual(response.text.split("\n").filter(Boolean).map(JSON.parse), [{ _id: "q1" }, { _id: "q2" }]);
});

test("missing /bank files return 404 JSON, not the SPA fallback", async () => {
  const response = await get("/bank/missing.jsonl");
  assert.equal(response.status, 404);
  assert.deepEqual(JSON.parse(response.text), { error: "Bank file not found" });
});

test("an empty bank dir 404s while the API keeps working (CI without bank)", async () => {
  fs.rmSync(bankDir, { recursive: true, force: true });
  const missing = await get("/bank/meta.json");
  assert.equal(missing.status, 404);
  assert.deepEqual(JSON.parse(missing.text), { error: "Bank file not found" });

  const status = await get("/api/status");
  assert.equal(status.status, 200);
  assert.deepEqual(JSON.parse(status.text), { loggedIn: false, hasSavedSession: false });
});
