const crypto = require("crypto");
const readline = require("readline");
const fs = require("fs");

const BASE_URL = "https://test.lanjingweike.com";
const UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36 Edg/149.0.0.0";
const REQUEST_TIMEOUT = 30000; // 30 seconds

// ---------- helpers ----------
function sha256(s) {
  return crypto.createHash("sha256").update(s).digest("hex");
}
function md5(s) {
  return crypto.createHash("md5").update(s).digest("hex");
}

async function fetchWithTimeout(url, init = {}, timeoutMs = REQUEST_TIMEOUT) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const resp = await fetch(url, { ...init, signal: controller.signal });
    return resp;
  } finally {
    clearTimeout(timer);
  }
}

async function getInput(prompt) {
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  return new Promise(resolve => rl.question(prompt, ans => { rl.close(); resolve(ans.trim()); }));
}

// ---------- session state ----------
let cookieJar = "";

function setCookies(jar, headers) {
  const setCookie = headers.raw
    ? Object.entries(headers.raw)
        .filter(([k]) => k.toLowerCase() === "set-cookie")
        .flatMap(([, v]) => v)
    : headers.getSetCookie?.() ?? [];
  for (const c of setCookie) {
    const [nameVal] = c.split(";");
    const [name, val] = nameVal.split("=");
    // update or add
    const re = new RegExp(`${name}=[^;]*;?`);
    if (re.test(jar)) jar = jar.replace(re, `${name}=${val};`);
    else jar += `${name}=${val}; `;
  }
  return jar;
}

async function request(path, opts = {}) {
  const { method = "GET", body, form, referer } = opts;
  const headers = {
    "User-Agent": UA,
    "X-Requested-With": "XMLHttpRequest",
    Origin: BASE_URL,
    Referer: referer || BASE_URL + "/exam",
    Accept: "application/json, text/javascript, */*; q=0.01",
    "sec-ch-ua": '"Microsoft Edge";v="149", "Chromium";v="149", "Not)A;Brand";v="24"',
    "sec-ch-ua-mobile": "?0",
    "sec-ch-ua-platform": '"Windows"',
  };
  if (cookieJar) headers.Cookie = cookieJar.replace(/\s+$/, "");
  if (form) headers["Content-Type"] = "application/x-www-form-urlencoded; charset=UTF-8";

  const init = { method, headers, redirect: "manual" };
  if (body) init.body = body;
  else if (form) init.body = new URLSearchParams(form).toString();

  const resp = await fetchWithTimeout(BASE_URL + path, init);
  cookieJar = setCookies(cookieJar, resp.headers);
  const text = await resp.text();
  try {
    return { status: resp.status, data: JSON.parse(text) };
  } catch {
    return { status: resp.status, data: text };
  }
}

// ---------- login flow ----------
async function getSessionId() {
  const { data } = await request("/");
  const m = cookieJar.match(/JSESSIONID=([^;]+)/);
  const jsession = m?.[1] ?? null;
  console.log(`[*] JSESSIONID: ${jsession}`);
  return jsession;
}

async function login(phone, passwordPlain) {
  const form = {
    userName: phone + "@1",
    userNameInput: phone,
    password: sha256(passwordPlain),
    passwordMD5: md5(passwordPlain),
    companyId: "1",
    newCompanyId: "1",
    remember: "false",
    phoneAccount: "",
    authCode: "",
    captchaText: "",
    nextUrl: "",
  };

  const { status, data } = await request("/login/account/login", { method: "POST", form });

  if (data.success) {
    const m = cookieJar.match(/sessionId=([^;]+)/);
    console.log(`[+] Login OK`);
    console.log(`    sessionId: ${m?.[1] ?? "N/A"}`);
    console.log(`    redirect:  ${data.bizContent.url}`);
    console.log(`    role:      ${data.bizContent.role}`);
  } else {
    console.log(`[-] Login failed: ${data.desc} (code=${data.code})`);
  }

  return { status, data };
}

// ---------- exam API ----------
async function listExams() {
  const form = {
    examStyle: "0",
    timeSort: "",
    status: "",
    setProcess: "-1",
    page: "1",
    firstVisit: "true",
    name: "",
    rowCount: "100",
    participation: "",
  };
  const { data } = await request("/exam/current_exam_list", { method: "POST", form });
  if (!data.success) {
    console.log("[-] listExams failed:", data.desc);
    return { total: 0, styles: {}, exams: [] };
  }
  const { styles, examInfoModelList } = data.bizContent;
  // build style lookup
  const styleMap = {};
  for (const s of styles) styleMap[s.id] = s.name;

  const exams = examInfoModelList.map(e => ({
    id: e.id,
    name: e.examName,
    style: styleMap[e.examStyle] || e.examStyleName || "unknown",
    practiceMode: e.practiceMode, // 0=模拟考试, 1=mock, 2=练习
    examMode: e.examMode,
    totalTime: e.examTime,        // 0=unlimited (minutes)
    paperInfoId: e.paperInfoId,
    examTimes: e.examTimesNum || 0,     // 允许考试次数
    examTimesRestrict: e.examTimesRestrict, // 0=不限次, 1=限制次数
    paid: e.paid || false,
    timeRestrict: e.examTimeRestrict,   // 0=不限时, 1=限时
    wfs: e.wfs,                         // 0=已作答(继续考试), 1=未开始(新试卷)
    timeLeft: e.timeLeft || 0,          // 剩余可用时间(秒), 0=无限制/未开始
  }));
  return { total: data.bizContent.total, styles: styleMap, exams };
}

// ---- new exam flow: replicate browser JS logic ----
async function startNewExam(examInfoId) {
  console.log("[*] Starting new exam flow...");

  // Step 0: GET enter_exam → follow 302 to before_answer_notice
  const r0 = await fetchWithTimeout(BASE_URL + `/exam/enter_exam/1/${examInfoId}`, {
    headers: { "User-Agent": UA, Cookie: cookieJar.replace(/\s+$/, ""), Referer: `${BASE_URL}/exam` },
    redirect: "follow",
  });
  cookieJar = setCookies(cookieJar, r0.headers);
  console.log(`[*] enter_exam → ${r0.url}`);

  const referer = `${BASE_URL}/exam/before_answer_notice/${examInfoId}`;
  const examId = String(examInfoId); // queue endpoints use "examId", not "examInfoId"

  // Step 1: faceCheckCondition (examInfoId)
  console.log(`    [1/5] POST faceCheckCondition...`);
  const { data: fcc } = await request("/exam/faceCheckCondition", {
    method: "POST", form: { examInfoId: examId }, referer,
  });
  console.log(`         → ${JSON.stringify(fcc).slice(0, 120)}`);

  // Step 2: start_exam_queue (examId)
  console.log(`    [2/5] POST start_exam_queue...`);
  const { data: seq } = await request("/exam/start_exam_queue", {
    method: "POST", form: { examId }, referer,
  });
  console.log(`         → ${JSON.stringify(seq).slice(0, 200)}`);
  const queueOk = seq?.bizContent?.isOk || seq?.code === "60011";

  // Step 3: poll check_queue_status until isOk (examId)
  if (!queueOk) {
    console.log(`    [3/5] Polling check_queue_status...`);
    for (let i = 0; i < 30; i++) {
      const { data: cqs } = await request("/exam/check_queue_status", {
        method: "POST", form: { examId }, referer,
      });
      if (cqs?.bizContent?.isOk) {
        console.log(`         → isOk=true (attempt ${i + 1})`);
        break;
      }
      await new Promise(r => setTimeout(r, 2000));
    }
  } else {
    console.log(`    [3/5] check_queue_status → skipped (already ok)`);
  }

  // Step 4: poll test_complete until ready (examId)
  console.log(`    [4/5] Polling test_complete...`);
  let ready = false;
  for (let i = 0; i < 30; i++) {
    const { data: tc } = await request("/exam/test_complete", {
      method: "POST", form: { examId }, referer,
    });
    // response is plain text "true" → JSON.parse gives boolean true
    if (tc === true || tc === "true") {
      console.log(`         → ready (attempt ${i + 1})`);
      ready = true;
      break;
    }
    await new Promise(r => setTimeout(r, 2000));
  }
  if (!ready) {
    console.log("[-] Exam generation timed out");
    return { examResultsId: null, examInfoId: examId, uuid: null, testIds: [], questionStates: [] };
  }

  // Step 5: GET exam_start
  console.log(`    [5/5] GET exam_start...`);
  const examResp = await fetchWithTimeout(BASE_URL + `/exam/exam_start/${examInfoId}`, {
    headers: { "User-Agent": UA, Cookie: cookieJar.replace(/\s+$/, ""), Referer: referer },
    redirect: "manual",
  });
  cookieJar = setCookies(cookieJar, examResp.headers);
  const html = await examResp.text();
  console.log(`         → ${html.length} bytes`);

  return parseExamHtml(html, examInfoId, null);
}

// ---- continue exam flow: direct access ----
async function enterExam(examInfoId, followRedirects = false) {
  const resp = await fetchWithTimeout(BASE_URL + `/exam/exam_start/${examInfoId}`, {
    headers: {
      "User-Agent": UA,
      Cookie: cookieJar.replace(/\s+$/, ""),
      Referer: `${BASE_URL}/exam`,
    },
    redirect: followRedirects ? "follow" : "manual",
  });
  cookieJar = setCookies(cookieJar, resp.headers);
  const html = await resp.text();
  return parseExamHtml(html, examInfoId, null);
}

// ---- shared HTML parser ----
function parseExamHtml(html, examInfoId, knownResultsId) {
  const extract = (name) => {
    const m = html.match(new RegExp(`var ${name}\\s*=\\s*['"]([^'"]+)['"]`));
    return m?.[1] ?? null;
  };

  const examResultsId = knownResultsId || extract("exam_results_id");
  const examInfoId_   = extract("exam_info_id") || String(examInfoId);

  // Parse section titles (e.g. "科技常识(共50题,每题1分,合计50.0分)")
  const sectionMatches = [...html.matchAll(/<div class="card-content-title">([^<]+)<\/div>/g)];
  const sectionBounds = sectionMatches.map(m => ({ title: m[1], pos: m.index }));

  // Split HTML by card boundary, process each card individually
  const cards = html.split(/<a\s+href="#[^"]*">\s*/);
  const questionStates = [];
  const seen = new Set();

  for (let i = 1; i < cards.length; i++) {
    const chunk = cards[i];
    const qId = chunk.match(/questionsId="([^"]+)"/)?.[1];
    if (!qId || seen.has(qId)) continue;
    seen.add(qId);

    const uId  = chunk.match(/uuId="([^"]+)"/)?.[1] ?? null;
    const num  = parseInt(chunk.match(/>\s*(\d+)\s*<\/span>/)?.[1] ?? "0", 10);
    const stateMatch = chunk.match(/question_cbox\s+(s\d+)\s+practice-mode-\d+\s*(right|error)?/);

    // Determine which section this card belongs to
    const cardPos = html.indexOf(`questionsId="${qId}"`);
    let section = "";
    for (let s = sectionBounds.length - 1; s >= 0; s--) {
      if (cardPos > sectionBounds[s].pos) { section = sectionBounds[s].title; break; }
    }

    questionStates.push({
      questionsId: qId,
      uuId: uId,
      num: num,
      state: stateMatch?.[2] || "unanswered",
      section: section,
    });
  }

  const testIds = questionStates.map(s => s.questionsId);
  const uuid = questionStates[0]?.uuId || extract("uuId");

  // stats
  const rightCount = questionStates.filter(s => s.state === "right").length;
  const errorCount = questionStates.filter(s => s.state === "error").length;
  const unansweredCount = questionStates.filter(s => s.state === "unanswered").length;

  // per-section breakdown
  const sectionMap = {};
  for (const q of questionStates) {
    const key = q.section || "(无分类)";
    if (!sectionMap[key]) sectionMap[key] = { total: 0, right: 0, error: 0, unanswered: 0 };
    sectionMap[key].total++;
    if (q.state === "right") sectionMap[key].right++;
    else if (q.state === "error") sectionMap[key].error++;
    else sectionMap[key].unanswered++;
  }

  console.log(`    Per section:`);
  for (const [title, st] of Object.entries(sectionMap)) {
    console.log(`      ${title}: ${st.total}题 ✅${st.right} ❌${st.error} ⬜${st.unanswered}`);
  }

  console.log(`[*] examResultsId: ${examResultsId}`);
  console.log(`[*] examInfoId:   ${examInfoId_}`);
  console.log(`[*] uuid:         ${uuid}`);
  console.log(`[*] testIds:      ${testIds.length} questions`);
  console.log(`    ✅${rightCount} ❌${errorCount} ⬜${unansweredCount}`);

  return { examResultsId, examInfoId: examInfoId_, uuid, testIds, questionStates, sectionMap };
}

async function getQuestions(examResultsId, examInfoId, testIds, uuid) {
  // batch size: the API accepts many testIds at once
  const BATCH = 50;
  const allQuestions = [];

  for (let i = 0; i < testIds.length; i += BATCH) {
    const batch = testIds.slice(i, i + BATCH);
    const uuids = Array(batch.length).fill(uuid).join(",");
    const form = {
      examResultsId,
      examInfoId,
      testIds: batch.join(","),
      uuids,
    };

    console.log(`[*] Fetching batch ${Math.floor(i / BATCH) + 1}/${Math.ceil(testIds.length / BATCH)}...`);
    const { data } = await request("/exam/get_question_info/", { method: "POST", form });
    if (Array.isArray(data)) {
      for (const q of data) {
        q._answers = extractAnswers(q);
      }
      allQuestions.push(...data);
    }
  }

  return allQuestions;
}

function extractAnswers(q) {
  const map = { key1: "A", key2: "B", key3: "C", key4: "D" };
  for (const [k, v] of Object.entries(map)) {
    if (q[k] === "1") return { key: k, letter: v, html: q[`answer${k.slice(-1)}`] };
  }
  return { key: null, letter: q.test_ans_right || "?", html: "" };
}

function summarize(questions) {
  const byDifficulty = {};
  for (const q of questions) {
    const d = q.difficult || "unknown";
    byDifficulty[d] = (byDifficulty[d] || 0) + 1;
  }
  return {
    total: questions.length,
    byDifficulty,
    answers: questions.map((q, i) => ({
      index: i + 1,
      id: q._id,
      answer: q._answers.letter,
      question: q.question.replace(/<[^>]+>/g, "").slice(0, 80),
      difficult: q.difficult,
    })),
  };
}

// ---------- main ----------
(async () => {
  const mode = process.argv[2];

  await getSessionId();

  if (mode === "cached") {
    console.log("[*] Loading cookies from session_cookies.txt");
    cookieJar = fs.readFileSync("session_cookies.txt", "utf-8").trim();
  } else {
    console.log("-".repeat(40));
    const user = await getInput("Phone: ");
    const pwd  = await getInput("Password: ");
    const result = await login(user, pwd);
    if (!result.data.success) { console.log("[-] Abort."); return; }
    fs.writeFileSync("session_cookies.txt", cookieJar, "utf-8");
    console.log("[*] Cookies saved to session_cookies.txt");
  }

  // ---- step 1: list exams ----
  console.log("\n[*] Fetching exam list...");
  const { total, styles, exams } = await listExams();
  if (!exams.length) { console.log("[-] No exams found."); return; }

  console.log(`\n[+] Total: ${total} exams across ${Object.keys(styles).length} categories`);

  console.log(`\nCategories:`);
  for (const [id, name] of Object.entries(styles)) {
    const count = exams.filter(e => e.style === name).length;
    console.log(`  [${id}] ${name} (${count} exams)`);
  }

  console.log(`\nAvailable exams:`);
  const grouped = {};
  for (const e of exams) {
    (grouped[e.style] ??= []).push(e);
  }
  for (const [style, list] of Object.entries(grouped)) {
    console.log(`\n  ==== ${style} ====`);
    for (const e of list) {
      const modeLabel = { 0: "模拟考试", 1: "MOCK", 2: "练习" }[e.practiceMode] ?? "?";
      const timeLabel = e.totalTime === 0 ? "不限时" : `${e.totalTime}分钟`;
      const statusLabel = e.wfs === 1 ? "🆕新试卷" : "▶继续考试";
      console.log(`  [${e.id}] ${e.name}`);
      console.log(`       ${modeLabel} | ${timeLabel} | ${statusLabel}`);
    }
  }

  // ---- step 2: select exam ----
  const examInfoId = await getInput("\nExamInfoId to fetch: ");
  const selected = exams.find(e => String(e.id) === String(examInfoId));
  const isNew = selected?.wfs === 1;
  // try direct first; fall back to new-exam chain if empty
  let exam = await enterExam(examInfoId);
  if (isNew && !exam.testIds.length) {
    console.log("[*] Direct access returned 0 questions, trying new-exam flow...");
    exam = await startNewExam(examInfoId);
  }
  if (!exam.examResultsId) {
    console.log("[-] Failed to enter exam. Check examInfoId.");
    return;
  }

  // ---- step 3: fetch all questions ----
  console.log("\n[*] Fetching all questions...");
  const questions = await getQuestions(exam.examResultsId, exam.examInfoId, exam.testIds, exam.uuid);
  if (!questions.length) { console.log("[-] No questions returned."); return; }

  // ---- step 4: save ----
  const summary = summarize(questions);

  // merge states (num, state, section) into summary and questions
  const stateMap = {};
  for (const s of exam.questionStates) {
    stateMap[s.questionsId] = { num: s.num, state: s.state, section: s.section };
  }
  for (const a of summary.answers) {
    const st = stateMap[a.id];
    if (st) Object.assign(a, st);
  }
  // also tag each question in questions.json with its section
  for (const q of questions) {
    const st = stateMap[q._id] || stateMap[String(q._id)];
    if (st) q._section = st.section;
  }
  summary.states = {
    right:      exam.questionStates.filter(s => s.state === "right").length,
    error:      exam.questionStates.filter(s => s.state === "error").length,
    unanswered: exam.questionStates.filter(s => s.state === "unanswered").length,
  };
  summary.sections = exam.sectionMap || {};

  const dir = `${examInfoId}_${new Date().toISOString().slice(0, 10)}`;
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(`${dir}/questions.json`, JSON.stringify(questions, null, 2), "utf-8");
  fs.writeFileSync(`${dir}/answers.json`, JSON.stringify(summary, null, 2), "utf-8");
  fs.writeFileSync(`${dir}/states.json`, JSON.stringify({ states: exam.questionStates, sections: exam.sectionMap || {} }, null, 2), "utf-8");

  console.log(`\n[+] Got ${summary.total} questions`);
  console.log(`    Difficulty: ${JSON.stringify(summary.byDifficulty)}`);
  console.log(`[+] Saved to ./${dir}/`);
})();
