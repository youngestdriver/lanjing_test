"use strict";

// Direct upstream client for the question-bank collector. Replaces the former
// arrangement where the collector CLI booted the local web proxy
// (apps/web/server.js) and reused its session: this module talks to the
// upstream platform (lanjingweike.com) directly with its own cookie jar,
// login flow, session persistence and page parsing, so the bank tool has no
// runtime dependency on the web app.
//
// The client implements the same `api` contract the collector's runCollection
// drives (status/login/getExams/enter/getQuestions/submit — see
// lib/question-bank.js), and mirrors the proxy behavior previously found in
// apps/web/server.js:
//   - login needs a JSESSIONID from the login page first, then POSTs the form
//     (password as sha256 + md5, userName = phone + "@1");
//   - a session is valid while the jar carries "sessionId="; upstream
//     redirects to /login/account/login or an onlineStatus:"0" body mean it
//     expired — the jar is cleared and an ApiError(401) thrown;
//   - entering a wfs=1 paper runs the new-exam flow (enter_exam → face check
//     → start queue → poll readiness → exam_start); wfs=0 papers are entered
//     read-only via exam_start directly (never submitted by the collector);
//   - exam_ending for practice papers answers JSON {"code":10000,"success":true}
//     (not a result HTML page), so parseResultHtml returns null and the client
//     reports ApiError(502, "考试未能结束…") — the collector verifies the
//     attempt actually ended via a fresh exam-list refetch (wfs flip);
//   - questions come from /exam/get_question_info/ in batches of 50.
//
// The session is persisted to <sessionFile> (default apps/bank/data/
// session_cookies.txt, mode 0o600) after login and reused on later runs. No
// npm dependencies: node:crypto/fs/path + global fetch only. Tests stub
// global.fetch with upstream-shaped fixtures; LANJING_BASE_URL can point the
// client at a fake origin.

const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");

const {
  parsePreviousAnswers,
  parseExamHtml,
  parseResultHtml,
  detectSessionExpiry,
} = require("./parsers");
const { ApiError } = require("./question-bank");

const DEFAULT_BASE_URL = process.env.LANJING_BASE_URL || "https://test.lanjingweike.com";
const UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36 Edg/149.0.0.0";
const REQUEST_TIMEOUT = 30000;

function sha256(s) { return crypto.createHash("sha256").update(s).digest("hex"); }
function md5(s)    { return crypto.createHash("md5").update(s).digest("hex"); }

/**
 * Create the collector's upstream api. Options:
 *   { baseUrl, sessionFile, retries=2, retryDelayMs=3000, requestTimeoutMs }
 * Returns { status, login, getExams, enter, getQuestions, submit } — the same
 * contract the old web-server-backed client exposed. getExams/getQuestions
 * (idempotent reads) retry transient failures; enter/submit/login never do
 * (they create real upstream attempts).
 */
function createUpstreamApi(opts = {}) {
  const baseUrl = String(opts.baseUrl || DEFAULT_BASE_URL).replace(/\/+$/, "");
  const sessionFile = opts.sessionFile
    ? path.resolve(opts.sessionFile)
    : path.resolve(path.join(__dirname, "..", "data", "session_cookies.txt"));
  const retries = opts.retries ?? 2;
  const retryDelayMs = opts.retryDelayMs ?? 3000;
  const requestTimeoutMs = opts.requestTimeoutMs ?? REQUEST_TIMEOUT;

  let cookieJar = "";
  let examCache = {}; // { examInfoId: { questionStates, testIds, uuid, examResultsId, examInfoId, sectionMap } }

  try {
    const saved = fs.readFileSync(sessionFile, "utf8").trim();
    if (saved) { cookieJar = saved; console.log("[bank] Loaded saved session"); }
  } catch {}

  // ========== low-level HTTP (ported from apps/web/server.js) ==========

  async function fetchWithTimeout(url, init = {}) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), requestTimeoutMs);
    try { return await fetch(url, { ...init, signal: controller.signal }); }
    finally { clearTimeout(timer); }
  }

  function setCookies(jar, headers) {
    const cookies = new Map();
    for (const part of String(jar || "").split(";")) {
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
        if (!value || /;\s*max-age=0(?:;|$)/i.test(c)) cookies.delete(name);
        else cookies.set(name, value);
      }
    }
    return [...cookies].map(([name, value]) => `${name}=${value};`).join(" ");
  }

  function clearSession() {
    cookieJar = "";
    examCache = {};
    try { fs.unlinkSync(sessionFile); } catch {}
  }

  function saveSession() {
    fs.mkdirSync(path.dirname(sessionFile), { recursive: true, mode: 0o700 });
    fs.writeFileSync(sessionFile, cookieJar, { encoding: "utf8", mode: 0o600 });
    try { fs.chmodSync(sessionFile, 0o600); } catch {}
  }

  async function fetchSessionText(url, init = {}, options = {}) {
    const { detectExpiry = true, includeCookies = true } = options;
    const headers = { ...(init.headers || {}) };
    if (includeCookies && cookieJar && !headers.Cookie && !headers.cookie) {
      headers.Cookie = cookieJar.replace(/\s+$/, "");
    }

    const response = await fetchWithTimeout(url, { ...init, headers });
    const text = await response.text();
    cookieJar = setCookies(cookieJar, response.headers);

    const redirectTargets = [];
    const location = response.headers.get("location");
    if (response.status >= 300 && response.status < 400 && location) {
      redirectTargets.push(location);
    }
    if (response.redirected && response.url) {
      redirectTargets.push(response.url);
    }
    if (detectExpiry && detectSessionExpiry(response.status, text, redirectTargets)) {
      console.log("[bank] Session expired, clearing saved session");
      clearSession();
      throw new ApiError(401, "Session expired");
    }

    return { response, text };
  }

  async function proxyRequest(reqPath, opts = {}) {
    const { method = "GET", body, form, referer } = opts;
    const headers = {
      "User-Agent": UA, "X-Requested-With": "XMLHttpRequest",
      Origin: baseUrl, Referer: referer || baseUrl + "/exam",
      Accept: "application/json, text/javascript, */*; q=0.01",
      "sec-ch-ua": '"Microsoft Edge";v="149", "Chromium";v="149", "Not)A;Brand";v="24"',
      "sec-ch-ua-mobile": "?0", "sec-ch-ua-platform": '"Windows"',
    };
    if (form) headers["Content-Type"] = "application/x-www-form-urlencoded; charset=UTF-8";
    const init = { method, headers, redirect: "manual" };
    if (body) init.body = body;
    else if (form) init.body = new URLSearchParams(form).toString();
    const { response, text } = await fetchSessionText(baseUrl + reqPath, init);
    try { return { status: response.status, data: JSON.parse(text) }; }
    catch { return { status: response.status, data: text }; }
  }

  function requireUpstreamResult(result, operation, options = {}) {
    const { allowBusinessFailure = false, allowedCodes = [] } = options;
    if (isAuthError(result)) {
      clearSession();
      throw new ApiError(401, "Session expired");
    }
    if (!result || result.status < 200 || result.status >= 300) {
      throw new ApiError(502, `${operation} failed upstream`);
    }
    const code = result.data?.code == null ? "" : String(result.data.code);
    if (!allowBusinessFailure
      && result.data
      && typeof result.data === "object"
      && result.data.success === false
      && !allowedCodes.includes(code)) {
      throw new ApiError(502, result.data.desc || `${operation} was rejected upstream`);
    }
    return result.data;
  }

  function requireUpstreamResponse(response, operation) {
    if (!response || response.status < 200 || response.status >= 400) {
      throw new ApiError(502, `${operation} failed upstream`);
    }
  }

  function isAuthError(result) {
    return result && (
      result.status === 401
      || result.data?.onlineStatus === "0"
      || result.data?.onlineStatus === 0
      || (result.data && result.data.error && result.data.error.includes("Session expired"))
    );
  }

  // Idempotent reads retry on network errors / 5xx; POSTs never auto-retry
  // (enter/submit create real upstream attempts — non-idempotent).
  async function withRetry(fn) {
    let lastError;
    for (let attempt = 0; attempt <= retries; attempt += 1) {
      try {
        return await fn();
      } catch (err) {
        lastError = err;
        if (err instanceof ApiError && err.status < 500 && err.status !== 408 && err.status !== 429) throw err;
        if (attempt < retries) await new Promise((resolve) => setTimeout(resolve, retryDelayMs));
      }
    }
    throw lastError;
  }

  // ========== exam flows (ported from apps/web/server.js) ==========

  function requireLoggedIn() {
    if (!cookieJar.includes("sessionId=")) throw new ApiError(401, "Not logged in");
  }

  // ---- continue exam flow ----
  async function enterExamDirect(examInfoId) {
    const { response, text } = await fetchSessionText(baseUrl + `/exam/exam_start/${examInfoId}`, {
      headers: { "User-Agent": UA, Referer: `${baseUrl}/exam` },
      redirect: "manual",
    });
    requireUpstreamResponse(response, "Entering exam");
    return parseExamHtml(text, examInfoId, null);
  }

  // ---- new exam flow ----
  async function startNewExam(examInfoId) {
    // Step 0: enter_exam → follow redirect
    const { response: entryResponse } = await fetchSessionText(baseUrl + `/exam/enter_exam/1/${examInfoId}`, {
      headers: { "User-Agent": UA, Referer: `${baseUrl}/exam` },
      redirect: "follow",
    });
    requireUpstreamResponse(entryResponse, "Opening new exam");
    const referer = `${baseUrl}/exam/before_answer_notice/${examInfoId}`;
    const examId = String(examInfoId);

    // Step 1: faceCheckCondition
    const faceResult = await proxyRequest("/exam/faceCheckCondition", { method: "POST", form: { examInfoId: examId }, referer });
    requireUpstreamResult(faceResult, "Checking exam entry conditions");
    // Step 2: start_exam_queue (uses examId!)
    const sequenceResult = await proxyRequest("/exam/start_exam_queue", { method: "POST", form: { examId }, referer });
    const seq = requireUpstreamResult(sequenceResult, "Starting exam queue", { allowedCodes: ["60011"] });
    let queueOk = Boolean(seq?.bizContent?.isOk || String(seq?.code || "") === "60011");
    // Step 3: poll check_queue_status if needed
    if (!queueOk) {
      for (let i = 0; i < 30; i++) {
        const queueResult = await proxyRequest("/exam/check_queue_status", { method: "POST", form: { examId }, referer });
        const cqs = requireUpstreamResult(queueResult, "Checking exam queue");
        if (cqs?.bizContent?.isOk) { queueOk = true; break; }
        await new Promise((resolve) => setTimeout(resolve, 2000));
      }
    }
    if (!queueOk) throw new ApiError(504, "Timed out waiting for the exam queue");
    // Step 4: poll test_complete until ready
    let testReady = false;
    for (let i = 0; i < 30; i++) {
      const completeResult = await proxyRequest("/exam/test_complete", { method: "POST", form: { examId }, referer });
      const tc = requireUpstreamResult(completeResult, "Preparing exam questions");
      if (tc === true || tc === "true") { testReady = true; break; }
      await new Promise((resolve) => setTimeout(resolve, 2000));
    }
    if (!testReady) throw new ApiError(504, "Timed out waiting for exam questions");
    // Step 5: GET exam_start
    const { response: examResponse, text } = await fetchSessionText(baseUrl + `/exam/exam_start/${examInfoId}`, {
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
      if (!Array.isArray(data)) throw new ApiError(502, "Upstream returned an invalid question batch");
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
          const idx = (l) => ({ A: 1, B: 2, C: 3, D: 4 }[l] || 0);
          q._answerHtml = correctKeys.map((k) => q[`answer${idx(k)}`]).join("<br>");
        }
        if (q.analysis) q._analysis = q.analysis;
        all.push(q);
      }
    }
    return all;
  }

  // ========== api contract (same as the old web-server-backed client) ==========

  return {
    async status() {
      return { loggedIn: cookieJar.includes("sessionId="), hasSavedSession: !!cookieJar };
    },

    async login(phone, password) {
      if (!phone || !password) throw new ApiError(400, "phone and password required");

      // get JSESSIONID if not present — go to login page
      if (!cookieJar.includes("JSESSIONID=")) {
        const { response } = await fetchSessionText(baseUrl + "/login/account/login/1", {
          headers: { "User-Agent": UA },
          redirect: "manual",
        }, { detectExpiry: false, includeCookies: false });
        if (!cookieJar.includes("JSESSIONID=")) {
          throw new ApiError(500, `Failed to get JSESSIONID (login page status ${response.status})`);
        }
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
        throw new ApiError(401, data?.desc || "Login failed");
      }
      if (!cookieJar.includes("sessionId=")) {
        clearSession();
        throw new ApiError(502, "Login succeeded without a session cookie");
      }

      // save session for later runs
      saveSession();
      examCache = {};
      return { success: true };
    },

    async getExams() {
      requireLoggedIn();
      return withRetry(async () => {
        const result = await proxyRequest("/exam/current_exam_list", {
          method: "POST",
          form: { examStyle: "0", timeSort: "", status: "", setProcess: "-1", page: "1", firstVisit: "true", name: "", rowCount: "100", participation: "" },
        });
        const data = requireUpstreamResult(result, "Loading exams", { allowBusinessFailure: true });
        if (!data.success) throw new ApiError(502, data.desc || "Loading exams failed");

        const { total, styles, examInfoModelList } = data.bizContent || {};
        if (!Array.isArray(styles) || !Array.isArray(examInfoModelList)) {
          throw new ApiError(502, "Upstream returned an invalid exam list");
        }
        const styleMap = {};
        for (const s of styles) styleMap[s.id] = s.name;

        return examInfoModelList.map((e) => ({
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
      });
    },

    async enter(id) {
      requireLoggedIn();
      const examInfoId = String(id);

      // wfs=1 means a fresh attempt (new-exam flow); wfs=0 means the user's
      // in-progress attempt (read-only continue flow). The web server used a
      // cached list; the standalone client refetches so the decision is always
      // based on the current upstream state.
      const exams = await this.getExams();
      const exam = exams.find((e) => String(e.id) === examInfoId);
      const isNew = exam?.wfs === 1;

      let result;
      if (isNew) {
        result = await startNewExam(examInfoId);
      } else {
        result = await enterExamDirect(examInfoId);
      }

      if (!result.questionStates.length) {
        throw new ApiError(500, "Failed to enter exam");
      }

      // cache for getQuestions/submit
      examCache[examInfoId] = result;
      const { sectionMap, ...rest } = result;
      return { ...rest, sections: sectionMap };
    },

    async getQuestions(id) {
      requireLoggedIn();
      return withRetry(async () => {
        const examInfoId = String(id);
        const cached = examCache[examInfoId];
        if (!cached) throw new ApiError(400, "Exam not entered yet");

        const questions = await fetchAllQuestions(cached.examResultsId, cached.examInfoId, cached.testIds, cached.uuid);
        return { questions, states: cached.questionStates, sections: cached.sectionMap };
      });
    },

    async submit(id) {
      requireLoggedIn();
      const examInfoId = String(id);
      let cached = examCache[examInfoId];
      // Lightweight enter if not cached — just get examResultsId.
      if (!cached) {
        const { response, text: html } = await fetchSessionText(baseUrl + `/exam/exam_start/${examInfoId}`, {
          headers: { "User-Agent": UA, Referer: `${baseUrl}/exam` },
          redirect: "manual",
        });
        requireUpstreamResponse(response, "Loading exam before submission");

        const parsed = parseExamHtml(html, examInfoId, null);
        if (!parsed.examResultsId) {
          throw new ApiError(400, "Cannot find exam_results_id");
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
      const endUrl = `${baseUrl}/exam/exam_ending?examInfoId=${encodeURIComponent(cached.examInfoId)}&examResultsId=${encodeURIComponent(cached.examResultsId)}&isForce=0&switchScreen=0&noOpsAutoCommit=0`;
      const { response: endResponse, text: html } = await fetchSessionText(endUrl, {
        headers: { "User-Agent": UA, Referer: `${baseUrl}/exam/exam_start/${cached.examInfoId}` },
        redirect: "follow",
      });
      requireUpstreamResponse(endResponse, "Finishing exam");

      const result = parseResultHtml(html);
      if (!result) {
        // Practice papers answer with JSON success instead of a result page;
        // the collector verifies the attempt ended via a fresh exam list.
        throw new ApiError(502, "考试未能结束，请刷新后重试");
      }

      delete examCache[examInfoId];
      return { success: true, ...result };
    },
  };
}

module.exports = { createUpstreamApi };
