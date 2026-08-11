"use strict";

// Practice API tests: a stub upstream (LANJING_BASE_URL) serves the minimal
// exam HTML the parsers need, so the full crawl flow runs against the real
// server with a fake session.

const assert = require("node:assert/strict");
const fs = require("node:fs");
const http = require("node:http");
const os = require("node:os");
const path = require("node:path");
const { once } = require("node:events");
const { after, before, test } = require("node:test");

const EXAM_HTML = `<script>var exam_results_id='er1';var exam_info_id='1';var uuId='u1';</script>
<div class="card-content-title">逻辑填空</div>
<a href="#q1"><div class="question_cbox" questionsId="q1" uuId="u1"><span>1</span></div></a>`;

// ---- stub upstream ----
const stubState = { questionAnswer: "1", questionText: "<p>题干</p>", endingHits: 0 };
const stub = http.createServer((req, res) => {
  const url = new URL(req.url, "http://127.0.0.1");
  if (req.method === "GET" && url.pathname === "/login/account/login/1") {
    res.writeHead(302, { Location: "/login/account/login", "Set-Cookie": "JSESSIONID=j1; Path=/" });
    return res.end();
  }
  if (req.method === "POST" && url.pathname === "/login/account/login") {
    res.writeHead(200, { "Content-Type": "application/json", "Set-Cookie": "sessionId=sess1; Path=/" });
    return res.end(JSON.stringify({ success: true, code: 10000 }));
  }
  if (req.method === "POST" && url.pathname === "/exam/current_exam_list") {
    res.writeHead(200, { "Content-Type": "application/json" });
    return res.end(JSON.stringify({
      success: true,
      bizContent: {
        styles: [{ id: 1, name: "机考题库" }],
        examInfoModelList: [{ id: 1, examName: "【言语理解（二）】机考题库", examStyle: 1, wfs: 1 }],
      },
    }));
  }
  if (req.method === "GET" && url.pathname.startsWith("/exam/enter_exam/1/")) {
    res.writeHead(302, { Location: "/exam/exam_start/1" });
    return res.end();
  }
  if (req.method === "POST" && url.pathname === "/exam/faceCheckCondition") {
    res.writeHead(200, { "Content-Type": "application/json" });
    return res.end(JSON.stringify({ success: true }));
  }
  if (req.method === "POST" && url.pathname === "/exam/start_exam_queue") {
    res.writeHead(200, { "Content-Type": "application/json" });
    return res.end(JSON.stringify({ success: true, code: "60011" }));
  }
  if (req.method === "POST" && url.pathname === "/exam/test_complete") {
    res.writeHead(200, { "Content-Type": "application/json" });
    return res.end("true");
  }
  if (req.method === "GET" && url.pathname.startsWith("/exam/exam_start/")) {
    res.writeHead(200, { "Content-Type": "text/html" });
    return res.end(EXAM_HTML);
  }
  if (req.method === "POST" && url.pathname === "/exam/get_question_info/") {
    res.writeHead(200, { "Content-Type": "application/json" });
    return res.end(JSON.stringify([{
      _id: "q1", key1: stubState.questionAnswer, key2: "0", key3: "0", key4: "0",
      question: stubState.questionText, answer1: "选项A", answer2: "选项B", answer3: "选项C", answer4: "选项D",
      analysis: "解析", parent_info: "", test_ans_right: "",
    }]));
  }
  if (req.method === "POST" && url.pathname === "/exam/get_remian_time") {
    res.writeHead(200, { "Content-Type": "application/json" });
    return res.end(JSON.stringify({ success: true }));
  }
  if (req.method === "GET" && url.pathname.startsWith("/exam/exam_ending")) {
    stubState.endingHits += 1;
    res.writeHead(200, { "Content-Type": "application/json" });
    return res.end(JSON.stringify({ code: 10000, success: true }));
  }
  res.writeHead(404, { "Content-Type": "application/json" });
  res.end(JSON.stringify({ error: `stub 404 ${req.method} ${url.pathname}` }));
});

const localDir = fs.mkdtempSync(path.join(os.tmpdir(), "lanjing-web-practice-"));
process.env.LANJING_LOCAL_DIR = localDir;
process.env.LANJING_BASE_URL = "http://127.0.0.1:0"; // overwritten below after stub listens
process.env.HOST = "127.0.0.1";
delete process.env.LANJING_BANK_DIR;

let server;
let port;
let stubPort;
let baseUrl;

function request(route, options = {}) {
  return new Promise((resolve, reject) => {
    const body = options.body || "";
    const req = http.request({
      hostname: "127.0.0.1", port,
      path: route,
      method: options.method || "GET",
      headers: {
        ...(body ? { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(body) } : {}),
        ...(options.headers || {}),
      },
    }, (res) => {
      let text = "";
      res.setEncoding("utf8");
      res.on("data", (chunk) => { text += chunk; });
      res.on("end", () => resolve({ status: res.statusCode, headers: res.headers, text }));
    });
    req.on("error", reject);
    if (body) req.write(body);
    req.end();
  });
}

async function login() {
  const response = await request("/api/login", { method: "POST", body: JSON.stringify({ phone: "13800000000", password: "secret" }) });
  assert.equal(response.status, 200);
}

async function waitForTaskDone() {
  for (let i = 0; i < 100; i += 1) {
    const status = JSON.parse((await request("/api/practice/status")).text);
    if (!status.task.running) return status;
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new Error("crawl task did not finish");
}

before(async () => {
  await new Promise((resolve) => stub.listen(0, "127.0.0.1", resolve));
  stubPort = stub.address().port;
  baseUrl = `http://127.0.0.1:${stubPort}`;
  process.env.LANJING_BASE_URL = baseUrl;
  const { startServer } = require("../server");
  server = startServer(0);
  await once(server, "listening");
  port = server.address().port;
});

after(async () => {
  if (server) await new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
  stub.close();
  fs.rmSync(localDir, { recursive: true, force: true });
});

test("unauthenticated practice mutations return 401; reads are open", async () => {
  assert.equal((await request("/api/practice/crawl", { method: "POST" })).status, 401);
  assert.equal((await request("/api/practice/update", { method: "POST" })).status, 401);
  assert.equal((await request("/api/practice/delete", { method: "POST" })).status, 401);
  const status = JSON.parse((await request("/api/practice/status")).text);
  assert.equal(status.loggedIn, false);
  assert.equal(status.isPopulated, false);
});

test("full crawl flow: login → crawl → populated bank → categories/log", async () => {
  await login();
  assert.equal((await request("/api/practice/crawl", { method: "POST" })).status, 202);

  const status = await waitForTaskDone();
  assert.equal(status.task.error, null);
  assert.equal(status.isPopulated, true);
  assert.deepEqual(status.meta.counts, { 言语理解: 1 });
  assert.equal(status.meta.papers, 1);
  assert.equal(stubState.endingHits, 1, "attempt ended upstream");

  const cat = await request("/api/practice/categories/" + encodeURIComponent("言语理解"));
  assert.equal(cat.status, 200);
  const record = JSON.parse(cat.text.trim());
  assert.equal(record.category, "言语理解");
  assert.equal(record.subCategory, "实词辨析");
  assert.equal(record.answer, "A");

  const unknown = await request("/api/practice/categories/" + encodeURIComponent("不存在"));
  assert.equal(unknown.status, 404);

  const logResponse = await request("/api/practice/log");
  assert.equal(logResponse.status, 200);
  assert.ok(logResponse.text.includes("题库爬取日志"));
  assert.match(logResponse.headers["content-disposition"] || "", /filename\*=UTF-8''/);
});

test("resume crawl skips crawled papers", async () => {
  await request("/api/practice/crawl", { method: "POST" });
  await waitForTaskDone();
  const status = JSON.parse((await request("/api/practice/status")).text);
  assert.equal(status.meta.counts["言语理解"], 1, "counts unchanged");
  assert.equal(stubState.endingHits, 1, "no new upstream attempt");
});

// 409 单飞行为由 Task 2 的 startCrawl 单测确定性覆盖(stub 响应太快、HTTP
// 层无法复现"任务进行中"竞态);此处只保留顺序启动的成功回归(resume 测试)。
test("update re-crawls and atomically replaces; delete wipes the bank", async () => {
  stubState.questionAnswer = "2";
  await request("/api/practice/update", { method: "POST" });
  const status = await waitForTaskDone();
  assert.equal(status.task.error, null);
  assert.equal(status.meta.round, 2);
  assert.equal(status.meta.counts["言语理解"], 1);
  const cat = await request("/api/practice/categories/" + encodeURIComponent("言语理解"));
  const record = JSON.parse(cat.text.trim());
  assert.equal(record.answer, "B", "record replaced");

  assert.equal((await request("/api/practice/delete", { method: "POST" })).status, 200);
  const after = JSON.parse((await request("/api/practice/status")).text);
  assert.equal(after.isPopulated, false);
  assert.equal((await request("/api/practice/categories/" + encodeURIComponent("言语理解"))).status, 404);
});
