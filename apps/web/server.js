const express = require("express");
const crypto = require("crypto");
const fs = require("fs");
const os = require("os");
const path = require("path");
const {
  parsePreviousAnswers,
  parseExamHtml,
  parseResultHtml,
  detectSessionExpiry,
} = require("./lib/parsers");

const BASE_URL = "https://test.lanjingweike.com";
const UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36 Edg/149.0.0.0";
const REQUEST_TIMEOUT = 30000;
const LOCAL_DIR = path.resolve(process.env.LANJING_LOCAL_DIR || path.join(__dirname, ".local"));
const SESSION_FILE = path.join(LOCAL_DIR, "session_cookies.txt");

// ========== helpers ==========
function sha256(s) { return crypto.createHash("sha256").update(s).digest("hex"); }
function md5(s)    { return crypto.createHash("md5").update(s).digest("hex"); }

async function fetchWithTimeout(url, init = {}, timeoutMs = REQUEST_TIMEOUT) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try { return await fetch(url, { ...init, signal: controller.signal }); }
  finally { clearTimeout(timer); }
}

function httpError(status, message) {
  const error = new Error(message);
  error.status = status;
  error.expose = true;
  return error;
}

function setCookies(jar, headers) {
  const cookies = new Map();
  for (const part of String(jar||"").split(";")) {
    const pair = part.trim();
    const separator = pair.indexOf("=");
    if (separator > 0) cookies.set(pair.slice(0, separator), pair.slice(separator + 1));
  }
  const setCookie = headers.raw
    ? Object.entries(headers.raw).filter(([k]) => k.toLowerCase() === "set-cookie").flatMap(([, v]) => v)
    : headers.getSetCookie?.() ?? [];
  for (const c of setCookie) {
    const [nameVal] = c.split(";");
    const separator = nameVal.indexOf("=");
    if (separator > 0) {
      const name = nameVal.slice(0, separator);
      const value = nameVal.slice(separator + 1);
      if (!value||/;\s*max-age=0(?:;|$)/i.test(c)) cookies.delete(name);
      else cookies.set(name, value);
    }
  }
  return [...cookies].map(([name, value]) => `${name}=${value};`).join(" ");
}

async function fetchSessionText(url, init = {}, options = {}) {
  const { detectExpiry = true, includeCookies = true } = options;
  const generation = sessionGeneration;
  const jar = cookieJar;
  const headers = { ...(init.headers || {}) };
  if (includeCookies && jar && !headers.Cookie && !headers.cookie) {
    headers.Cookie = jar.replace(/\s+$/, "");
  }

  const response = await fetchWithTimeout(url, { ...init, headers });
  const text = await response.text();
  if (generation !== sessionGeneration) {
    throw httpError(409, "Session changed while the upstream request was in flight");
  }

  cookieJar = setCookies(cookieJar, response.headers);
  const redirectTargets = [];
  const location = response.headers.get("location");
  if (response.status >= 300 && response.status < 400 && location) {
    redirectTargets.push(location);
  }
  if (response.redirected && response.url) {
    redirectTargets.push(response.url);
  }
  if (detectExpiry && detectSessionExpiry(
    response.status,
    text,
    redirectTargets,
  )) {
    console.log("[auth] Session expired, clearing cookies");
    clearSession(generation);
    throw httpError(401, "Session expired");
  }

  return { response, text };
}

async function proxyRequest(path, opts = {}) {
  const { method = "GET", body, form, referer } = opts;
  const headers = {
    "User-Agent": UA, "X-Requested-With": "XMLHttpRequest",
    Origin: BASE_URL, Referer: referer || BASE_URL + "/exam",
    Accept: "application/json, text/javascript, */*; q=0.01",
    "sec-ch-ua": '"Microsoft Edge";v="149", "Chromium";v="149", "Not)A;Brand";v="24"',
    "sec-ch-ua-mobile": "?0", "sec-ch-ua-platform": '"Windows"',
  };
  if (form) headers["Content-Type"] = "application/x-www-form-urlencoded; charset=UTF-8";
  const init = { method, headers, redirect: "manual" };
  if (body) init.body = body;
  else if (form) init.body = new URLSearchParams(form).toString();
  const { response, text } = await fetchSessionText(BASE_URL + path, init);
  try { return { status: response.status, data: JSON.parse(text) }; }
  catch { return { status: response.status, data: text }; }
}

// ========== session & state ==========
let cookieJar = "";
let examCache = {};   // { examInfoId: { questionStates, testIds, uuid, examResultsId, examInfoId } }
let examsCache = null; // stored exam list with metadata
let sessionGeneration = 0;

function clearSession(expectedGeneration = null) {
  if (expectedGeneration !== null && expectedGeneration !== sessionGeneration) return false;
  sessionGeneration++;
  cookieJar = "";
  examCache = {};
  examsCache = null;
  try { fs.unlinkSync(SESSION_FILE); } catch {}
  return true;
}

function saveSession() {
  fs.mkdirSync(LOCAL_DIR, { recursive: true, mode: 0o700 });
  fs.chmodSync(LOCAL_DIR, 0o700);
  fs.writeFileSync(SESSION_FILE, cookieJar, { encoding: "utf8", mode: 0o600 });
  fs.chmodSync(SESSION_FILE, 0o600);
}

(function loadCookies() {
  try {
    const c = fs.readFileSync(SESSION_FILE, "utf8").trim();
    if (c) { cookieJar = c; console.log("[init] Loaded saved session"); }
  } catch {}
})();

// ========== Express app ==========
const app = express();

// Hosts accepted by the /api boundary. Loopback is always allowed. When the
// server binds to a non-loopback address (HOST=0.0.0.0 or an interface IP),
// local interface addresses are added so LAN clients can reach it by IP.
// TRUSTED_HOSTS additionally allows explicit hostnames (e.g. my-mac.local)
// in any mode.
const LOCAL_HOSTNAMES = new Set(["127.0.0.1", "localhost"]);
let allowedHosts = new Set(LOCAL_HOSTNAMES);

function localHostname(host) {
  try { return new URL(`http://${host}`).hostname.toLowerCase(); }
  catch { return ""; }
}

function lanAddresses() {
  const addresses = [];
  for (const interfaces of Object.values(os.networkInterfaces())) {
    for (const iface of interfaces) {
      if (iface.family === "IPv4" && !iface.internal) addresses.push(iface.address);
    }
  }
  return addresses;
}

function refreshAllowedHosts(host) {
  const hosts = new Set(LOCAL_HOSTNAMES);
  if (!LOCAL_HOSTNAMES.has(localHostname(host))) {
    for (const address of lanAddresses()) hosts.add(address);
  }
  for (const name of String(process.env.TRUSTED_HOSTS || "").split(",")) {
    const trimmed = name.trim().toLowerCase();
    if (trimmed) hosts.add(trimmed);
  }
  allowedHosts = hosts;
}

app.use("/api", (req, res, next) => {
  const requestHost = req.get("host") || "";
  if (!allowedHosts.has(localHostname(requestHost))) {
    return res.status(403).json({ error: "Local API host is not allowed" });
  }

  const origin = req.get("origin");
  if (origin) {
    try {
      const parsedOrigin = new URL(origin);
      if (!allowedHosts.has(parsedOrigin.hostname.toLowerCase())
        || parsedOrigin.host.toLowerCase() !== requestHost.toLowerCase()) {
        return res.status(403).json({ error: "Cross-origin API requests are not allowed" });
      }
    } catch {
      return res.status(403).json({ error: "Cross-origin API requests are not allowed" });
    }
  }

  if (!["GET", "HEAD", "OPTIONS"].includes(req.method) && !req.is("application/json")) {
    return res.status(415).json({ error: "API writes require application/json" });
  }
  next();
});
app.use(express.json({ limit: "100kb" }));
app.use(express.static(path.join(__dirname, "public")));

// Check proxy result for auth expiry
function isAuthError(result) {
  return result && (
    result.status === 401
    || result.data?.onlineStatus === "0"
    || result.data?.onlineStatus === 0
    || (result.data && result.data.error && result.data.error.includes("Session expired"))
  );
}

function requireUpstreamResult(result, operation, options = {}) {
  const { allowBusinessFailure = false, allowedCodes = [] } = options;
  if (isAuthError(result)) {
    clearSession();
    throw httpError(401, "Session expired");
  }
  if (!result || result.status < 200 || result.status >= 300) {
    throw httpError(502, `${operation} failed upstream`);
  }
  const code = result.data?.code == null ? "" : String(result.data.code);
  if (!allowBusinessFailure
    && result.data
    && typeof result.data === "object"
    && result.data.success === false
    && !allowedCodes.includes(code)) {
    throw httpError(502, result.data.desc || `${operation} was rejected upstream`);
  }
  return result.data;
}

function requireUpstreamResponse(response, operation) {
  if (!response || response.status < 200 || response.status >= 400) {
    throw httpError(502, `${operation} failed upstream`);
  }
}

// Auth middleware — skip login and status
app.use((req, res, next) => {
  if (["/api/login", "/api/status", "/api/logout"].includes(req.path) || !req.path.startsWith("/api/")) return next();
  if (!cookieJar.includes("sessionId=")) return res.status(401).json({ error: "Not logged in" });
  next();
});

// SPA fallback — serve index.html for all non-API routes
app.get(/^(?!\/api(?:\/|$)).*/, (req, res) => {
  res.sendFile(path.join(__dirname, "public", "index.html"));
});

// ========== API routes ==========

// GET  /api/status — check if logged in
app.get("/api/status", (req, res) => {
  const loggedIn = cookieJar.includes("sessionId=");
  res.json({ loggedIn, hasSavedSession: !!cookieJar });
});

// POST /api/login — login with phone + password
app.post("/api/login", async (req, res) => {
  const { phone, password } = req.body;
  if (!phone || !password) return res.status(400).json({ error: "phone and password required" });

  // get JSESSIONID if not present — go to login page
  if (!cookieJar.includes("JSESSIONID=")) {
    const { response: r } = await fetchSessionText(BASE_URL + "/login/account/login/1", {
      headers: { "User-Agent": UA },
      redirect: "manual",
    }, { detectExpiry: false, includeCookies: false });
    console.log("[login] status:", r.status);
    if (!cookieJar.includes("JSESSIONID="))
      return res.status(500).json({ error: "Failed to get JSESSIONID" });
  }

  // login
  const form = {
    userName: phone + "@1", userNameInput: phone,
    password: sha256(password), passwordMD5: md5(password),
    companyId: "1", newCompanyId: "1", remember: "false",
    phoneAccount: "", authCode: "", captchaText: "", nextUrl: "",
  };
  const loginResult = await proxyRequest("/login/account/login", { method: "POST", form });
  const data = requireUpstreamResult(loginResult, "Login", { allowBusinessFailure: true });
  if (!data?.success) {
    clearSession();
    return res.status(401).json({ error: data?.desc || "Login failed" });
  }
  if (!cookieJar.includes("sessionId=")) {
    clearSession();
    throw httpError(502, "Login succeeded without a session cookie");
  }

  // save session
  sessionGeneration++;
  saveSession();
  examCache = {};
  examsCache = null;
  res.json({ success: true });
});

// GET  /api/exams — list all exams
app.get("/api/exams", async (req, res) => {
  if (!cookieJar.includes("sessionId=")) return res.status(401).json({ error: "Not logged in" });

  const result = await proxyRequest("/exam/current_exam_list", {
    method: "POST",
    form: { examStyle: "0", timeSort: "", status: "", setProcess: "-1", page: "1", firstVisit: "true", name: "", rowCount: "100", participation: "" },
  });
  const data = requireUpstreamResult(result, "Loading exams", { allowBusinessFailure: true });
  if (!data.success) return res.status(500).json({ error: data.desc });

  const { total, styles, examInfoModelList } = data.bizContent||{};
  if (!Array.isArray(styles)||!Array.isArray(examInfoModelList)) {
    throw httpError(502, "Upstream returned an invalid exam list");
  }
  const styleMap = {};
  for (const s of styles) styleMap[s.id] = s.name;

  const exams = examInfoModelList.map(e => ({
    id: e.id, name: e.examName,
    style: styleMap[e.examStyle] || e.examStyleName || "unknown",
    practiceMode: e.practiceMode, examMode: e.examMode,
    totalTime: e.examTime, paperInfoId: e.paperInfoId,
    examTimes: e.examTimesNum || 0,
    examTimesRestrict: e.examTimesRestrict,
    paid: e.paid || false,
    timeRestrict: e.examTimeRestrict,
    wfs: e.wfs, timeLeft: e.timeLeft || 0,
  }));

  examsCache = { total, styles: styleMap, exams };
  res.json(examsCache);
});

// POST /api/exams/:id/enter — enter exam (handles new + continue)
app.post("/api/exams/:id/enter", async (req, res) => {
  const examInfoId = req.params.id;
  if (!cookieJar.includes("sessionId=")) return res.status(401).json({ error: "Not logged in" });

  // Check if wfs=1 (new exam) from cache
  const exam = examsCache?.exams?.find(e => String(e.id) === String(examInfoId));
  const isNew = exam?.wfs === 1;

  let result;
  if (isNew) {
    result = await startNewExam(examInfoId);
  } else {
    result = await enterExamDirect(examInfoId);
  }

  if (!result.questionStates.length) {
    return res.status(500).json({ error: "Failed to enter exam", examResultsId: result.examResultsId });
  }

  // cache
  examCache[examInfoId] = result;
  const { sectionMap, ...rest } = result;
  res.json({ ...rest, sections: sectionMap });
});

// GET  /api/exams/:id/questions — get all questions with answers
app.get("/api/exams/:id/questions", async (req, res) => {
  const examInfoId = req.params.id;
  const cached = examCache[examInfoId];
  if (!cached) return res.status(400).json({ error: "Exam not entered yet" });

  const questions = await fetchAllQuestions(cached.examResultsId, cached.examInfoId, cached.testIds, cached.uuid);
  res.json({ questions, states: cached.questionStates, sections: cached.sectionMap });
});

// POST /api/exams/:id/submit — finish exam and get results
app.post("/api/exams/:id/submit", async (req, res) => {
  let cached = examCache[req.params.id];
  // Lightweight enter if not cached — just get examResultsId
  if (!cached) {
    console.log("[submit] Quick enter for exam", req.params.id);
    const { response, text: html } = await fetchSessionText(BASE_URL + `/exam/exam_start/${req.params.id}`, {
      headers: { "User-Agent": UA, Referer: `${BASE_URL}/exam` },
      redirect: "manual",
    });
    requireUpstreamResponse(response, "Loading exam before submission");

    const parsed = parseExamHtml(html, req.params.id, null);
    if (!parsed.examResultsId) {
      return res.status(400).json({ error: "Cannot find exam_results_id" });
    }
    cached = {
      examResultsId: parsed.examResultsId,
      examInfoId: parsed.examInfoId,
    };
  }

  // Step 1: get remain time
  const remainResult = await proxyRequest("/exam/get_remian_time", {
    method: "POST", form: { examResultId: cached.examResultsId },
  });
  requireUpstreamResult(remainResult, "Loading remaining exam time");

  // Step 2: end exam (follow redirect, it goes to result page)
  const endUrl = `${BASE_URL}/exam/exam_ending?examInfoId=${encodeURIComponent(cached.examInfoId)}&examResultsId=${encodeURIComponent(cached.examResultsId)}&isForce=0&switchScreen=0&noOpsAutoCommit=0`;
  const { response: endResponse, text: html } = await fetchSessionText(endUrl, {
    headers: { "User-Agent": UA, Referer: `${BASE_URL}/exam/exam_start/${cached.examInfoId}` },
    redirect: "follow",
  });
  requireUpstreamResponse(endResponse, "Finishing exam");

  const result = parseResultHtml(html);
  if (!result) {
    return res.status(502).json({ error: "考试未能结束，请刷新后重试" });
  }

  delete examCache[req.params.id];
  delete examCache[cached.examInfoId];
  examsCache = null;
  res.json({ success: true, ...result });
});

// POST /api/exams/:id/answer — submit answer to upstream
app.post("/api/exams/:id/answer", async (req, res) => {
  const { testId, testAns, correct } = req.body;
  if (!testId||typeof testAns!=="string"||!testAns||typeof correct!=="boolean") {
    return res.status(400).json({ error: "testId, testAns and boolean correct are required" });
  }
  const cached = examCache[req.params.id];
  if (!cached) return res.status(400).json({ error: "Exam not entered" });

  const item = {
    exam_results_id: cached.examResultsId,
    test_id: testId,
    test_ans: testAns,
    exam_info_id: cached.examInfoId,
    correct: correct,
  };
  const form = {
    examTestList: JSON.stringify([item]),
    timeStamp: String(Date.now()),
  };
  const result = await proxyRequest("/exam/exam_start_ing_multi", {
    method: "POST", form,
    referer: `${BASE_URL}/exam/exam_start/${req.params.id}`,
  });
  const data = requireUpstreamResult(result, "Saving answer", { allowBusinessFailure: true });
  res.json({ success: !!data?.success, code: data?.code });
});

// POST /api/exams/:id/mark — toggle mark on a question
app.post("/api/exams/:id/mark", async (req, res) => {
  const { testId, isMark } = req.body;
  if (!testId||typeof isMark!=="boolean") {
    return res.status(400).json({ error: "testId and boolean isMark are required" });
  }
  const cached = examCache[req.params.id];
  if (!cached) return res.status(400).json({ error: "Exam not entered" });

  const result = await proxyRequest("/exam/exam_question_mark", {
    method: "POST",
    form: {
      test_id: testId,
      exam_results_id: cached.examResultsId,
      exam_info_id: cached.examInfoId,
      isMark: isMark ? "1" : "0",
      timeStamp: String(Date.now()),
    },
    referer: `${BASE_URL}/exam/exam_start/${req.params.id}`,
  });
  requireUpstreamResult(result, "Saving question mark", { allowBusinessFailure: true });
  res.json({ success: !!result.data?.success });
});

// POST /api/logout — clear session
app.post("/api/logout", (req, res) => {
  clearSession();
  res.json({ success: true });
});

// GET  /api/exams/:id/states — refresh answer card states
app.get("/api/exams/:id/states", async (req, res) => {
  const examInfoId = req.params.id;
  const result = await enterExamDirect(examInfoId);
  if (!result.questionStates.length) return res.status(500).json({ error: "Failed to get states" });
  examCache[examInfoId] = result;
  const { sectionMap, ...rest } = result;
  res.json({ ...rest, sections: sectionMap });
});

// ========== exam logic (from tools/login-demo.js) ==========

// ---- continue exam flow ----
async function enterExamDirect(examInfoId) {
  const { response, text } = await fetchSessionText(BASE_URL + `/exam/exam_start/${examInfoId}`, {
    headers: { "User-Agent": UA, Referer: `${BASE_URL}/exam` },
    redirect: "manual",
  });
  requireUpstreamResponse(response, "Entering exam");
  return parseExamHtml(text, examInfoId, null);
}

// ---- new exam flow ----
async function startNewExam(examInfoId) {
  // Step 0: enter_exam → follow redirect
  const { response: entryResponse } = await fetchSessionText(BASE_URL + `/exam/enter_exam/1/${examInfoId}`, {
    headers: { "User-Agent": UA, Referer: `${BASE_URL}/exam` },
    redirect: "follow",
  });
  requireUpstreamResponse(entryResponse, "Opening new exam");
  const referer = `${BASE_URL}/exam/before_answer_notice/${examInfoId}`;
  const examId = String(examInfoId);

  // Step 1: faceCheckCondition
  const faceResult = await proxyRequest("/exam/faceCheckCondition", { method: "POST", form: { examInfoId: examId }, referer });
  requireUpstreamResult(faceResult, "Checking exam entry conditions");
  // Step 2: start_exam_queue (uses examId!)
  const sequenceResult = await proxyRequest("/exam/start_exam_queue", { method: "POST", form: { examId }, referer });
  const seq = requireUpstreamResult(sequenceResult, "Starting exam queue", { allowedCodes: ["60011"] });
  let queueOk = Boolean(seq?.bizContent?.isOk || String(seq?.code||"") === "60011");
  // Step 3: poll check_queue_status if needed
  if (!queueOk) {
    for (let i = 0; i < 30; i++) {
      const queueResult = await proxyRequest("/exam/check_queue_status", { method: "POST", form: { examId }, referer });
      const cqs = requireUpstreamResult(queueResult, "Checking exam queue");
      if (cqs?.bizContent?.isOk) { queueOk = true; break; }
      await new Promise(r => setTimeout(r, 2000));
    }
  }
  if (!queueOk) throw httpError(504, "Timed out waiting for the exam queue");
  // Step 4: poll test_complete until ready
  let testReady = false;
  for (let i = 0; i < 30; i++) {
    const completeResult = await proxyRequest("/exam/test_complete", { method: "POST", form: { examId }, referer });
    const tc = requireUpstreamResult(completeResult, "Preparing exam questions");
    if (tc === true || tc === "true") { testReady = true; break; }
    await new Promise(r => setTimeout(r, 2000));
  }
  if (!testReady) throw httpError(504, "Timed out waiting for exam questions");
  // Step 5: GET exam_start
  const { response: examResponse, text } = await fetchSessionText(BASE_URL + `/exam/exam_start/${examInfoId}`, {
    headers: { "User-Agent": UA, Referer: referer },
    redirect: "manual",
  });
  requireUpstreamResponse(examResponse, "Loading prepared exam");
  return parseExamHtml(text, examInfoId, null);
}

// ---- fetch questions ----
async function fetchAllQuestions(examResultsId, examInfoId, testIds, uuid) {
  const BATCH = 50;
  const all = [];
  for (let i = 0; i < testIds.length; i += BATCH) {
    const batch = testIds.slice(i, i + BATCH);
    const uuids = Array(batch.length).fill(uuid).join(",");
    const result = await proxyRequest("/exam/get_question_info/", {
      method: "POST",
      form: { examResultsId, examInfoId, testIds: batch.join(","), uuids },
    });
    const data = requireUpstreamResult(result, "Loading questions", { allowBusinessFailure: true });
    if (!Array.isArray(data)) throw httpError(502, "Upstream returned an invalid question batch");
    for (const q of data) {
      const map = { key1: "A", key2: "B", key3: "C", key4: "D" };
      const correctKeys = [];
      for (const [k, v] of Object.entries(map)) {
        if (q[k] === "1") correctKeys.push(v);
      }
      q._isMulti = correctKeys.length > 1;
      q._answers = correctKeys;
      q._answer = correctKeys[0] || q.test_ans_right || "?";
      q._previousAnswers = parsePreviousAnswers(q.test_ans);
      if (correctKeys.length > 0) {
        const idx = (l) => ({A:1,B:2,C:3,D:4}[l]||0);
        q._answerHtml = correctKeys.map(k => q[`answer${idx(k)}`]).join("<br>");
      }
      if (q.analysis) q._analysis = q.analysis;
      all.push(q);
    }
  }
  return all;
}

app.use("/api", (req, res) => {
  res.status(404).json({ error: "API route not found" });
});

app.use((error, req, res, next) => {
  if (res.headersSent) return next(error);
  const timedOut = error?.name === "AbortError";
  const status = timedOut ? 504 : Number.isInteger(error?.status) ? error.status : 500;
  if (status >= 500 || !error?.expose) console.error("[server]", error);
  return res.status(status).json({
    error: timedOut ? "Upstream request timed out" : error?.expose ? error.message : "Internal server error",
  });
});

const PORT = process.env.PORT || 3000;
const HOST = process.env.HOST || "127.0.0.1";

function startServer(port = PORT, host = HOST) {
  refreshAllowedHosts(host);
  const server = app.listen(port, host, () => {
    console.log(`Server: http://${host}:${server.address().port}`);
    if (!LOCAL_HOSTNAMES.has(localHostname(host))) {
      for (const address of lanAddresses()) {
        console.log(`LAN:    http://${address}:${server.address().port}`);
      }
      console.warn(
        "[warning] Listening beyond loopback exposes one shared upstream session to the LAN. "
        + "There is no TLS, per-user session isolation, CSRF protection or rate limiting, "
        + "and upstream cookies are stored in cleartext on disk. Only run this on a trusted network.",
      );
    }
    console.log(`Session: ${cookieJar ? "loaded" : "none (login required)"}`);
  });
  return server;
}

if (require.main === module) startServer();

module.exports = { app, startServer };
