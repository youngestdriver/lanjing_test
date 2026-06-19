const express = require("express");
const crypto = require("crypto");
const fs = require("fs");
const path = require("path");

const BASE_URL = "https://test.lanjingweike.com";
const UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36 Edg/149.0.0.0";
const REQUEST_TIMEOUT = 30000;

// ========== helpers ==========
function sha256(s) { return crypto.createHash("sha256").update(s).digest("hex"); }
function md5(s)    { return crypto.createHash("md5").update(s).digest("hex"); }

async function fetchWithTimeout(url, init = {}, timeoutMs = REQUEST_TIMEOUT) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try { return await fetch(url, { ...init, signal: controller.signal }); }
  finally { clearTimeout(timer); }
}

function setCookies(jar, headers) {
  const setCookie = headers.raw
    ? Object.entries(headers.raw).filter(([k]) => k.toLowerCase() === "set-cookie").flatMap(([, v]) => v)
    : headers.getSetCookie?.() ?? [];
  for (const c of setCookie) {
    const [nameVal] = c.split(";");
    const [name, val] = nameVal.split("=");
    const re = new RegExp(`${name}=[^;]*;?`);
    if (re.test(jar)) jar = jar.replace(re, `${name}=${val};`);
    else jar += `${name}=${val}; `;
  }
  return jar;
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
  if (cookieJar) headers.Cookie = cookieJar.replace(/\s+$/, "");
  if (form) headers["Content-Type"] = "application/x-www-form-urlencoded; charset=UTF-8";
  const init = { method, headers, redirect: "manual" };
  if (body) init.body = body;
  else if (form) init.body = new URLSearchParams(form).toString();
  const resp = await fetchWithTimeout(BASE_URL + path, init);
  cookieJar = setCookies(cookieJar, resp.headers);
  const text = await resp.text();

  // Detect upstream session expiry
  const isExpired = resp.status === 302 && (resp.headers.get("location")||"").includes("/login/account/login")
    || (typeof text === "string" && text.includes("/login/account/login") && text.includes("<!DOCTYPE"))
    || (typeof text === "string" && /"onlineStatus"\s*:\s*"?0"?/.test(text));
  if (isExpired) {
    console.log("[auth] Session expired, clearing cookies");
    clearSession();
    return { status: 401, data: { error: "Session expired" } };
  }
  try { return { status: resp.status, data: JSON.parse(text) }; }
  catch { return { status: resp.status, data: text }; }
}

// ========== session & state ==========
let cookieJar = "";
let examCache = {};   // { examInfoId: { questionStates, testIds, uuid, examResultsId, examInfoId } }
let examsCache = null; // stored exam list with metadata

function clearSession() {
  cookieJar = "";
  examCache = {};
  examsCache = null;
  try { fs.unlinkSync("session_cookies.txt"); } catch {}
}

(function loadCookies() {
  try {
    const c = fs.readFileSync("session_cookies.txt", "utf-8").trim();
    if (c) { cookieJar = c; console.log("[init] Loaded saved session"); }
  } catch {}
})();

// ========== Express app ==========
const app = express();
app.use(express.json());
app.use(express.urlencoded({ extended: true }));
app.use(express.static(path.join(__dirname, "frontend")));

// Check proxy result for auth expiry
function isAuthError(result) {
  return result && (
    result.status === 401
    || result.data?.onlineStatus === "0"
    || result.data?.onlineStatus === 0
    || (result.data && result.data.error && result.data.error.includes("Session expired"))
  );
}

// Auth middleware — skip login and status
app.use((req, res, next) => {
  if (req.path === "/api/login" || req.path === "/api/status" || !req.path.startsWith("/api/")) return next();
  if (!cookieJar.includes("sessionId=")) return res.status(401).json({ error: "Not logged in" });
  next();
});

// SPA fallback — serve index.html for all non-API routes
app.get(/^(?!\/api\/).*/, (req, res) => {
  res.sendFile(path.join(__dirname, "frontend", "index.html"));
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
    const r = await fetchWithTimeout(BASE_URL + "/login/account/login/1", {
      headers: { "User-Agent": UA },
      redirect: "manual",
    });
    cookieJar = setCookies(cookieJar, r.headers);
    console.log("[login] status:", r.status, "cookieJar:", cookieJar.slice(0, 120));
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
  const { data } = await proxyRequest("/login/account/login", { method: "POST", form });
  if (!data.success) return res.status(401).json({ error: data.desc || "Login failed" });

  // save session
  fs.writeFileSync("session_cookies.txt", cookieJar, "utf-8");
  examsCache = null; // invalidate exam cache
  res.json({ success: true });
});

// GET  /api/exams — list all exams
app.get("/api/exams", async (req, res) => {
  if (!cookieJar.includes("sessionId=")) return res.status(401).json({ error: "Not logged in" });

  const result = await proxyRequest("/exam/current_exam_list", {
    method: "POST",
    form: { examStyle: "0", timeSort: "", status: "", setProcess: "-1", page: "1", firstVisit: "true", name: "", rowCount: "100", participation: "" },
  });
  if (isAuthError(result)) return res.status(401).json(result.data);
  const { data } = result;
  if (!data.success) return res.status(500).json({ error: data.desc });

  const { total, styles, examInfoModelList } = data.bizContent;
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
    const r = await fetchWithTimeout(BASE_URL + `/exam/exam_start/${req.params.id}`, {
      headers: { "User-Agent": UA, Cookie: cookieJar.replace(/\s+$/, ""), Referer: `${BASE_URL}/exam` },
      redirect: "manual",
    });
    const html = await r.text();
    const m = html.match(/var\s+exam_results_id\s*=\s*['"](\d+)['"]/);
    if (!m) return res.status(400).json({ error: "Cannot find exam_results_id" });
    const eid = html.match(/var\s+exam_info_id\s*=\s*['"](\d+)['"]/)?.[1]||req.params.id;
    cached = { examResultsId: m[1], examInfoId: eid };
  }

  // Step 1: get remain time
  await proxyRequest("/exam/get_remian_time", {
    method: "POST", form: { examResultId: cached.examResultsId },
  });

  // Step 2: end exam (follow redirect, it goes to result page)
  const endUrl = `${BASE_URL}/exam/exam_ending?examInfoId=${req.params.id}&examResultsId=${cached.examResultsId}&isForce=0&switchScreen=0&noOpsAutoCommit=0`;
  const endResp = await fetchWithTimeout(endUrl, {
    headers: { "User-Agent": UA, Cookie: cookieJar.replace(/\s+$/, ""), Referer: `${BASE_URL}/exam/exam_start/${req.params.id}` },
    redirect: "follow",
  });
  cookieJar = setCookies(cookieJar, endResp.headers);
  const html = await endResp.text();

  // Parse: score, beat rate, rank (more flexible patterns)
  const scoreM = html.match(/class="score"[^>]*>\s*([\d.]+)\s*</);
  const nums = [...html.matchAll(/exam-result-percentage[^>]*>\s*(\d+)/g)];
  // First percentage = beat rate, second (if different color) = rank
  const beatM = nums[0];
  const rankM = nums.length > 1 ? nums[1] : beatM;
  res.json({
    success: true,
    score: scoreM?.[1] || "0",
    beatRate: beatM?.[1] || "?",
    rank: rankM?.[1] || "?",
  });
});

// POST /api/exams/:id/answer — submit answer to upstream
app.post("/api/exams/:id/answer", async (req, res) => {
  const { testId, testAns, correct } = req.body;
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
  if (isAuthError(result)) return res.status(401).json(result.data);
  const { data } = result;
  res.json({ success: !!data?.success, code: data?.code });
});

// POST /api/exams/:id/mark — toggle mark on a question
app.post("/api/exams/:id/mark", async (req, res) => {
  const { testId, isMark } = req.body;
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
  if (isAuthError(result)) return res.status(401).json(result.data);
  res.json({ success: !!result.data?.success });
});

// GET  /api/logout — clear session
app.get("/api/logout", (req, res) => {
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

// ========== exam logic (from login_demo.js) ==========

// ---- shared HTML parser ----
function parseExamHtml(html, examInfoId, knownResultsId) {
  const extract = (name) => {
    const m = html.match(new RegExp(`var ${name}\\s*=\\s*['"]([^'"]+)['"]`));
    return m?.[1] ?? null;
  };
  const examResultsId = knownResultsId || extract("exam_results_id");
  const examInfoId_ = extract("exam_info_id") || String(examInfoId);

  // Parse section titles
  const sectionMatches = [...html.matchAll(/<div class="card-content-title">([^<]+)<\/div>/g)];
  const sectionBounds = sectionMatches.map(m => ({ title: m[1], pos: m.index }));

  const cards = html.split(/<a\s+href="#[^"]*">\s*/);
  const questionStates = [];
  const seen = new Set();

  for (let i = 1; i < cards.length; i++) {
    const chunk = cards[i];
    const qId = chunk.match(/questionsId="([^"]+)"/)?.[1]?.trim();
    if (!qId || seen.has(qId)) continue;
    seen.add(qId);
    const uId = chunk.match(/uuId="([^"]+)"/)?.[1]?.trim() ?? null;
    const num = parseInt(chunk.match(/>\s*(\d+)\s*<\/span>/)?.[1] ?? "0", 10);
    const boxClass = chunk.match(/<div\b[^>]*class=["']([^"']*\bquestion_cbox\b[^"']*)["'][^>]*>/)?.[1] ?? "";
    const boxClasses = new Set(boxClass.trim().split(/\s+/).filter(Boolean));
    const state = boxClasses.has("right") ? "right" : boxClasses.has("error") ? "error" : "unanswered";
    const marked = boxClasses.has("marked");

    const cardPos = html.indexOf(`questionsId="${qId}`);
    let section = "";
    for (let s = sectionBounds.length - 1; s >= 0; s--) {
      if (cardPos > sectionBounds[s].pos) { section = sectionBounds[s].title; break; }
    }

    questionStates.push({
      questionsId: qId, uuId: uId, num, section,
      state,
      marked,
    });
  }

  const testIds = questionStates.map(s => s.questionsId);
  const uuid = questionStates[0]?.uuId || extract("uuId");

  // Per-section breakdown
  const sectionMap = {};
  for (const q of questionStates) {
    const key = q.section || "(无分类)";
    if (!sectionMap[key]) sectionMap[key] = { total: 0, right: 0, error: 0, unanswered: 0 };
    sectionMap[key].total++;
    if (q.state === "right") sectionMap[key].right++;
    else if (q.state === "error") sectionMap[key].error++;
    else sectionMap[key].unanswered++;
  }

  return { examResultsId, examInfoId: examInfoId_, uuid, testIds, questionStates, sectionMap };
}

// ---- continue exam flow ----
async function enterExamDirect(examInfoId) {
  const resp = await fetchWithTimeout(BASE_URL + `/exam/exam_start/${examInfoId}`, {
    headers: { "User-Agent": UA, Cookie: cookieJar.replace(/\s+$/, ""), Referer: `${BASE_URL}/exam` },
    redirect: "manual",
  });
  cookieJar = setCookies(cookieJar, resp.headers);
  return parseExamHtml(await resp.text(), examInfoId, null);
}

// ---- new exam flow ----
async function startNewExam(examInfoId) {
  // Step 0: enter_exam → follow redirect
  const r0 = await fetchWithTimeout(BASE_URL + `/exam/enter_exam/1/${examInfoId}`, {
    headers: { "User-Agent": UA, Cookie: cookieJar.replace(/\s+$/, ""), Referer: `${BASE_URL}/exam` },
    redirect: "follow",
  });
  cookieJar = setCookies(cookieJar, r0.headers);
  const referer = `${BASE_URL}/exam/before_answer_notice/${examInfoId}`;
  const examId = String(examInfoId);

  // Step 1: faceCheckCondition
  await proxyRequest("/exam/faceCheckCondition", { method: "POST", form: { examInfoId: examId }, referer });
  // Step 2: start_exam_queue (uses examId!)
  const { data: seq } = await proxyRequest("/exam/start_exam_queue", { method: "POST", form: { examId }, referer });
  const queueOk = seq?.bizContent?.isOk || seq?.code === "60011";
  // Step 3: poll check_queue_status if needed
  if (!queueOk) {
    for (let i = 0; i < 30; i++) {
      const { data: cqs } = await proxyRequest("/exam/check_queue_status", { method: "POST", form: { examId }, referer });
      if (cqs?.bizContent?.isOk) break;
      await new Promise(r => setTimeout(r, 2000));
    }
  }
  // Step 4: poll test_complete until ready
  for (let i = 0; i < 30; i++) {
    const { data: tc } = await proxyRequest("/exam/test_complete", { method: "POST", form: { examId }, referer });
    if (tc === true || tc === "true") break;
    await new Promise(r => setTimeout(r, 2000));
  }
  // Step 5: GET exam_start
  const examResp = await fetchWithTimeout(BASE_URL + `/exam/exam_start/${examInfoId}`, {
    headers: { "User-Agent": UA, Cookie: cookieJar.replace(/\s+$/, ""), Referer: referer },
    redirect: "manual",
  });
  cookieJar = setCookies(cookieJar, examResp.headers);
  return parseExamHtml(await examResp.text(), examInfoId, null);
}

// ---- fetch questions ----
async function fetchAllQuestions(examResultsId, examInfoId, testIds, uuid) {
  const BATCH = 50;
  const all = [];
  for (let i = 0; i < testIds.length; i += BATCH) {
    const batch = testIds.slice(i, i + BATCH);
    const uuids = Array(batch.length).fill(uuid).join(",");
    const { data } = await proxyRequest("/exam/get_question_info/", {
      method: "POST",
      form: { examResultsId, examInfoId, testIds: batch.join(","), uuids },
    });
    if (Array.isArray(data)) {
      for (const q of data) {
        const map = { key1: "A", key2: "B", key3: "C", key4: "D" };
        const correctKeys = [];
        for (const [k, v] of Object.entries(map)) {
          if (q[k] === "1") correctKeys.push(v);
        }
        q._isMulti = correctKeys.length > 1;
        q._answers = correctKeys;
        q._answer = correctKeys[0] || q.test_ans_right || "?";
        if (correctKeys.length > 0) {
          const idx = (l) => ({A:1,B:2,C:3,D:4}[l]||0);
          q._answerHtml = correctKeys.map(k => q[`answer${idx(k)}`]).join("<br>");
        }
        if (q.analysis) q._analysis = q.analysis;
        all.push(q);
      }
    }
  }
  return all;
}

const PORT = process.env.PORT || 3000;
app.listen(PORT, () => {
  console.log(`Server: http://localhost:${PORT}`);
  console.log(`Session: ${cookieJar ? "loaded" : "none (login required)"}`);
});
