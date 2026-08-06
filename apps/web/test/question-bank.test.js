"use strict";

// Question-bank collector tests. Unit tests drive the collector with a fake
// `api` object; the integration test spawns the real server and stubs
// global.fetch with upstream fixtures. No test ever touches the real upstream
// (LANJING_BASE_URL points at a fixture host; unmatched URLs throw).

const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { once } = require("node:events");
const { after, before, test } = require("node:test");

const {
  TARGET_CATEGORIES,
  ApiError,
  matchCategory,
  joinQuestions,
  contentHash,
  buildRecord,
  pickExam,
  collectRound,
  runCollection,
  loadBank,
} = require("../lib/question-bank");

const quietLog = { info() {}, warn() {}, error() {} };

function tmpBankDir() {
  return path.join(fs.mkdtempSync(path.join(os.tmpdir(), "lanjing-qbank-")), "bank");
}

function readJsonl(file) {
  let text;
  try {
    text = fs.readFileSync(file, "utf8");
  } catch {
    return [];
  }
  return text.split("\n").filter(Boolean).map((line) => JSON.parse(line));
}

function fakeApi(overrides = {}) {
  return {
    status: async () => ({ loggedIn: true }),
    getExams: async () => [],
    enter: async () => ({}),
    getQuestions: async () => ({ questions: [], states: [], sections: {} }),
    submit: async () => ({ success: true, score: "0", beatRate: "?", rank: "?" }),
    ...overrides,
  };
}

const EXAMS = [
  { id: "e1", name: "机考卷1", style: "机考题库", wfs: 1, examTimes: 0, examTimesRestrict: "0" },
  { id: "e2", name: "其他卷", style: "练习", wfs: 1, examTimes: 0, examTimesRestrict: "0" },
  { id: "e3", name: "进行中", style: "机考题库", wfs: 0, examTimes: 0, examTimesRestrict: "0" },
];

function baseCtx(overrides = {}) {
  return {
    targets: TARGET_CATEGORIES,
    examState: {},
    seenIds: new Set(),
    singleExamId: null,
    submitRetryDelayMs: 10,
    round: 1,
    log: quietLog,
    ...overrides,
  };
}

// ---------- Pure helpers ----------

test("matchCategory maps section titles onto the 5 target categories", () => {
  assert.equal(matchCategory("语言理解"), "语言理解");
  assert.equal(matchCategory("一、语言理解（单选）"), "语言理解");
  assert.equal(matchCategory("  数字运算  "), "数字运算");
  assert.equal(matchCategory("逻辑推理"), "逻辑推理");
  assert.equal(matchCategory("资料分析"), "资料分析");
  assert.equal(matchCategory("特有题型"), "特有题型");
  assert.equal(matchCategory("判断推理"), null);
  assert.equal(matchCategory(""), null);
  assert.equal(matchCategory("(无分类)"), null);
  // first target in order wins
  assert.equal(matchCategory("语言理解与逻辑推理", ["语言理解", "逻辑推理"]), "语言理解");
});

test("joinQuestions matches by questionsId with positional fallback", () => {
  const states = [
    { questionsId: "q1", section: "语言理解" },
    { questionsId: "q2", section: "语言理解" },
    { questionsId: "q3", section: "判断推理" },
  ];
  const joined = joinQuestions([{ _id: "q1" }, { _id: "q2" }, { _id: "q3" }], states);
  assert.equal(joined.length, 3);
  assert.equal(joined[0].section, "语言理解");
  assert.equal(joined[2].section, "判断推理");

  // positional fallback when ids don't match
  const fallback = joinQuestions([{ _id: "x1" }], [{ questionsId: "nope", section: "逻辑推理" }]);
  assert.equal(fallback[0].section, "逻辑推理");

  // missing states → placeholder section
  assert.equal(joinQuestions([{ _id: "x1" }], [])[0].section, "(无分类)");

  // fewer states than questions
  const short = joinQuestions([{ _id: "a" }, { _id: "b" }], [{ questionsId: "a", section: "语言理解" }]);
  assert.equal(short.length, 2);
  assert.equal(short[1].section, "(无分类)");
});

test("buildRecord produces the bank schema for single/multi/fallback/unknown answers", () => {
  const ctx = { sourceExamId: "E1", sourceExamName: "卷1", round: 1, collectedAt: "2026-08-06T00:00:00.000Z" };
  const single = buildRecord(
    { _id: "q1", question: "<p>题干</p>", answer1: "<p>A</p>", answer2: "", answer3: "", answer4: "", _answers: ["A"], test_ans_right: "A", analysis: "<p>解析</p>" },
    "语言理解", "语言理解", ctx,
  );
  assert.deepEqual(single, {
    _id: "q1", category: "语言理解", question: "<p>题干</p>",
    options: ["<p>A</p>", "", "", ""], answer: "A", analysis: "<p>解析</p>",
    sourceExamId: "E1", sourceExamName: "卷1", round: 1, collectedAt: "2026-08-06T00:00:00.000Z",
  });

  const multi = buildRecord({ _id: "q2", _answers: ["A", "C"], test_ans_right: "" }, "语言理解", "语言理解", ctx);
  assert.deepEqual(multi.answer, ["A", "C"]);

  const fallback = buildRecord({ _id: "q3", _answers: [], test_ans_right: "B" }, "语言理解", "语言理解", ctx);
  assert.equal(fallback.answer, "B");

  const none = buildRecord({ _id: "q4", _answers: [], test_ans_right: "" }, "语言理解", "语言理解", ctx);
  assert.equal(none.answer, null);
});

test("contentHash is stable across DTO and stored-record shapes", () => {
  const dto = { question: "<p>Hello</p>", answer1: "<b>A</b>", answer2: "", answer3: "", answer4: "" };
  const record = { question: "<p>  Hello  </p>", options: ["<b>A</b>", "", "", ""] };
  assert.equal(contentHash(dto), contentHash(record));
  const different = { question: "<p>Hello</p>", answer1: "<b>B</b>", answer2: "", answer3: "", answer4: "" };
  assert.notEqual(contentHash(dto), contentHash(different));
});

// ---------- Exam selection ----------

test("pickExam prioritises pendingSubmit, then 机考题库, skips wfs=0 attempts", () => {
  const empty = { examState: {}, singleExamId: null };
  assert.equal(pickExam(EXAMS, empty).exam.id, "e1"); // 机考题库 before 练习

  // wfs=0 non-pending never picked
  const onlyLive = pickExam([EXAMS[2]], empty);
  assert.equal(onlyLive.exam, null);
  assert.equal(onlyLive.reason, "exhausted");

  // pendingSubmit wins even with wfs=0
  const pending = pickExam(EXAMS, { examState: { e3: { status: "pendingSubmit" } }, singleExamId: null });
  assert.equal(pending.exam.id, "e3");

  // drained skipped
  const drained = pickExam(EXAMS, { examState: { e1: { status: "drained" } }, singleExamId: null });
  assert.equal(drained.exam.id, "e2");

  // attempt quota exhausted
  const restricted = [{ id: "e1", style: "机考题库", wfs: 1, examTimes: 3, examTimesRestrict: "1" }];
  assert.equal(pickExam(restricted, { examState: { e1: { roundsCollected: 3 } }, singleExamId: null }).exam, null);
  assert.equal(pickExam(restricted, { examState: { e1: { roundsCollected: 2 } }, singleExamId: null }).exam.id, "e1");
  // unrestricted exams ignore the guard
  const unrestricted = [{ id: "e1", style: "机考题库", wfs: 1, examTimes: 0, examTimesRestrict: "0" }];
  assert.equal(pickExam(unrestricted, { examState: { e1: { roundsCollected: 99 } }, singleExamId: null }).exam.id, "e1");

  // stale pendingSubmit (exam no longer listed) is marked drained
  const stale = { examState: { gone: { status: "pendingSubmit" } }, singleExamId: null };
  assert.equal(pickExam(EXAMS, stale).exam.id, "e1");
  assert.equal(stale.examState.gone.status, "drained");

  // --exam override picks wfs=0 too
  assert.equal(pickExam(EXAMS, { examState: {}, singleExamId: "e3" }).exam.id, "e3");
  assert.equal(pickExam(EXAMS, { examState: {}, singleExamId: "nope" }).exam, null);
});

// ---------- Round ----------

test("collectRound runs enter→questions→submit and only collects target sections", async () => {
  const calls = [];
  const api = fakeApi({
    getExams: async () => [EXAMS[0]],
    enter: async () => { calls.push("enter"); return {}; },
    getQuestions: async () => ({
      questions: [
        { _id: "q1", question: "<p>1</p>", answer1: "<p>A</p>", _answers: ["A"], analysis: "<p>解析</p>" },
        { _id: "q2", question: "<p>2</p>", answer1: "<p>A</p>", _answers: ["A"], analysis: "" },
      ],
      states: [
        { questionsId: "q1", section: "语言理解" },
        { questionsId: "q2", section: "判断推理" }, // non-target
      ],
    }),
    submit: async () => { calls.push("submit"); return { success: true, score: "0" }; },
  });
  const ctx = baseCtx();
  const result = await collectRound(api, ctx);

  assert.deepEqual(calls, ["enter", "submit"]);
  assert.equal(result.newQuestions.length, 1);
  assert.equal(result.newQuestions[0]._id, "q1");
  assert.deepEqual([...ctx.seenIds], ["q1"]); // q2 never enters seenIds
  assert.equal(result.drained, false);
  assert.equal(ctx.examState.e1.status, "collected");
  assert.equal(ctx.examState.e1.roundsCollected, 1);
});

test("collectRound leaves pendingSubmit when questions fetch fails (no submit)", async () => {
  const calls = [];
  const api = fakeApi({
    getExams: async () => [EXAMS[0]],
    getQuestions: async () => { throw new ApiError(502, "upstream failed"); },
    submit: async () => { calls.push("submit"); return {}; },
  });
  const ctx = baseCtx();
  await assert.rejects(collectRound(api, ctx), /upstream failed/);
  assert.deepEqual(calls, []);
  assert.equal(ctx.examState.e1.status, "pendingSubmit");
});

test("collectRound retries a 502 submit once and succeeds", async () => {
  let submitCalls = 0;
  const api = fakeApi({
    getExams: async () => [EXAMS[0]],
    getQuestions: async () => ({
      questions: [{ _id: "q1", question: "<p>1</p>", answer1: "<p>A</p>", _answers: ["A"] }],
      states: [{ questionsId: "q1", section: "语言理解" }],
    }),
    submit: async () => {
      submitCalls += 1;
      if (submitCalls === 1) throw new ApiError(502, "考试未能结束，请刷新后重试");
      return { success: true, score: "0" };
    },
  });
  const ctx = baseCtx();
  const result = await collectRound(api, ctx);
  assert.equal(submitCalls, 2);
  assert.equal(result.submitResult.score, "0");
  assert.equal(ctx.examState.e1.status, "collected");
});

test("collectRound keeps pendingSubmit when submit keeps failing", async () => {
  let submitCalls = 0;
  const api = fakeApi({
    getExams: async () => [EXAMS[0]],
    getQuestions: async () => ({
      questions: [{ _id: "q1", question: "<p>1</p>", answer1: "<p>A</p>", _answers: ["A"] }],
      states: [{ questionsId: "q1", section: "语言理解" }],
    }),
    submit: async () => { submitCalls += 1; throw new ApiError(502, "考试未能结束，请刷新后重试"); },
  });
  const ctx = baseCtx();
  const result = await collectRound(api, ctx);
  assert.equal(submitCalls, 2); // initial + one retry
  assert.equal(result.submitResult, null);
  assert.equal(result.drained, false);
  assert.equal(ctx.examState.e1.status, "pendingSubmit");
});

test("collectRound does not retry non-502 submit failures", async () => {
  let submitCalls = 0;
  const api = fakeApi({
    getExams: async () => [EXAMS[0]],
    getQuestions: async () => ({
      questions: [{ _id: "q1", question: "<p>1</p>", answer1: "<p>A</p>", _answers: ["A"] }],
      states: [{ questionsId: "q1", section: "语言理解" }],
    }),
    submit: async () => { submitCalls += 1; throw new ApiError(500, "internal"); },
  });
  const ctx = baseCtx();
  const result = await collectRound(api, ctx);
  assert.equal(submitCalls, 1);
  assert.equal(result.submitResult, null);
});

// ---------- Main loop ----------

test("runCollection dedupes across rounds, excludes non-targets, stops exhausted", async () => {
  const bankDir = tmpBankDir();
  let submitCalls = 0;
  const api = fakeApi({
    getExams: async () => [EXAMS[0]],
    getQuestions: async () => ({
      questions: [
        { _id: "q1", question: "<p>单选</p>", answer1: "<p>A</p>", _answers: ["A"], analysis: "<p>解析一</p>" },
        { _id: "q2", question: "<p>多选</p>", answer1: "<p>A</p>", answer3: "<p>C</p>", _answers: ["A", "C"], analysis: "" },
        { _id: "q3", question: "<p>非目标</p>", answer1: "<p>A</p>", _answers: ["A"] }, // 判断推理
        { _id: "q4", question: "<p>填空</p>", _answers: [], test_ans_right: "B", analysis: "<p>解析四</p>" },
      ],
      states: [
        { questionsId: "q1", section: "语言理解" },
        { questionsId: "q2", section: "语言理解" },
        { questionsId: "q3", section: "判断推理" },
        { questionsId: "q4", section: "语言理解" },
      ],
    }),
    submit: async () => { submitCalls += 1; return { success: true, score: "0" }; },
  });

  const summary = await runCollection(api, { bankDir, log: quietLog, roundDelayMs: 1 });

  assert.equal(summary.stoppedBy, "exhausted");
  const records = readJsonl(path.join(bankDir, "语言理解.jsonl"));
  assert.equal(records.length, 3); // q1, q2, q4 — q3 excluded
  assert.equal(submitCalls, 2); // round 1 + round 2 (draining round)

  const byId = new Map(records.map((r) => [r._id, r]));
  assert.deepEqual(byId.get("q2").answer, ["A", "C"]);
  assert.equal(byId.get("q4").answer, "B");
  assert.equal(byId.get("q1").analysis, "<p>解析一</p>");
  assert.equal(byId.get("q1").sourceExamId, "e1");
  assert.equal(byId.get("q1").round, 1);

  assert.equal(summary.countsByCategory["语言理解"], 3);
  assert.equal(summary.stats.answerUnknown, 0); // q4 has test_ans_right
  assert.equal(summary.stats.totalRounds, 2);
  // no stray files for non-target categories
  assert.equal(fs.existsSync(path.join(bankDir, "判断推理.jsonl")), false);
});

test("runCollection counts answerUnknown and contentDupes", async () => {
  const bankDir = tmpBankDir();
  let round = 0;
  const api = fakeApi({
    getExams: async () => [EXAMS[0]],
    getQuestions: async () => {
      round += 1;
      if (round === 1) {
        return {
          questions: [
            { _id: "q1", question: "<p>无答案</p>", answer1: "<p>A</p>", _answers: [], test_ans_right: "" },
            { _id: "q2", question: "<p>同内容</p>", answer1: "<p>A</p>", _answers: ["A"] },
          ],
          states: [
            { questionsId: "q1", section: "语言理解" },
            { questionsId: "q2", section: "语言理解" },
          ],
        };
      }
      return {
        questions: [{ _id: "q3", question: "<p>同内容</p>", answer1: "<p>A</p>", _answers: ["A"] }],
        states: [{ questionsId: "q3", section: "语言理解" }],
      };
    },
  });

  const summary = await runCollection(api, { bankDir, log: quietLog, maxRounds: 2, roundDelayMs: 1 });

  assert.equal(summary.stoppedBy, "maxRounds");
  assert.equal(summary.stats.answerUnknown, 1); // q1
  assert.equal(summary.stats.contentDupes, 1); // q3 duplicates q2's content
  assert.equal(readJsonl(path.join(bankDir, "语言理解.jsonl")).length, 3); // both stored
});

test("runCollection stops on idle when nothing new keeps failing to submit", async () => {
  const bankDir = tmpBankDir();
  const api = fakeApi({
    getExams: async () => [EXAMS[0]],
    getQuestions: async () => ({
      questions: [{ _id: "q1", question: "<p>1</p>", answer1: "<p>A</p>", _answers: ["A"] }],
      states: [{ questionsId: "q1", section: "语言理解" }],
    }),
    submit: async () => { throw new ApiError(502, "考试未能结束，请刷新后重试"); },
  });

  const summary = await runCollection(api, { bankDir, log: quietLog, idleLimit: 3, roundDelayMs: 1, submitRetryDelayMs: 10 });
  assert.equal(summary.stoppedBy, "idle");
  assert.equal(summary.stats.totalRounds, 4); // 1 new round + 3 empty rounds
  assert.equal(summary.countsByCategory["语言理解"], 1);
});

test("runCollection stops on auth failure and persists meta", async () => {
  const bankDir = tmpBankDir();
  const api = fakeApi({
    getExams: async () => { throw new ApiError(401, "Not logged in"); },
  });
  const summary = await runCollection(api, { bankDir, log: quietLog, roundDelayMs: 1 });
  assert.equal(summary.stoppedBy, "auth");
  const meta = JSON.parse(fs.readFileSync(path.join(bankDir, "meta.json"), "utf8"));
  assert.equal(meta.stats.consecutiveFailures, 1);
});

test("runCollection resumes: dedupe and round counter survive a second run", async () => {
  const bankDir = tmpBankDir();
  const api = fakeApi({
    getExams: async () => [EXAMS[0]],
    getQuestions: async () => ({
      questions: [
        { _id: "q1", question: "<p>1</p>", answer1: "<p>A</p>", _answers: ["A"] },
        { _id: "q2", question: "<p>2</p>", answer1: "<p>A</p>", _answers: ["A"] },
      ],
      states: [
        { questionsId: "q1", section: "语言理解" },
        { questionsId: "q2", section: "语言理解" },
      ],
    }),
  });

  const first = await runCollection(api, { bankDir, log: quietLog, maxRounds: 1, roundDelayMs: 1 });
  assert.equal(first.stoppedBy, "maxRounds");
  assert.equal(first.round, 1);
  assert.equal(readJsonl(path.join(bankDir, "语言理解.jsonl")).length, 2);

  const second = await runCollection(api, { bankDir, log: quietLog, maxRounds: 10, roundDelayMs: 1 });
  assert.equal(second.stoppedBy, "exhausted");
  assert.equal(second.round, 2); // continued from meta.round=1
  // no duplicate lines despite the same questions on resume
  assert.equal(readJsonl(path.join(bankDir, "语言理解.jsonl")).length, 2);
  const meta = JSON.parse(fs.readFileSync(path.join(bankDir, "meta.json"), "utf8"));
  assert.equal(meta.round, 2);
  assert.equal(meta.examState.e1.status, "drained");
});

test("loadBank drops a truncated trailing line", () => {
  const dir = tmpBankDir();
  fs.mkdirSync(dir, { recursive: true });
  const file = path.join(dir, "语言理解.jsonl");
  fs.writeFileSync(
    file,
    JSON.stringify({ _id: "q1", category: "语言理解", question: "", options: ["", "", "", ""] }) + "\n"
    + '{"_id": "q9", "category": "语言理解", "question": "<p>trunc',
    "utf8",
  );
  const bank = loadBank(dir, TARGET_CATEGORIES);
  assert.equal(bank.counts["语言理解"], 1);
  assert.equal(bank.seenIds.has("q1"), true);
  assert.equal(bank.seenIds.has("q9"), false);
});

// ---------- Integration: real server, stubbed upstream ----------

const localDir = fs.mkdtempSync(path.join(os.tmpdir(), "lanjing-qbank-integration-"));
process.env.LANJING_LOCAL_DIR = localDir;
process.env.LANJING_BASE_URL = "https://upstream.fixture.test"; // tests never hit the real service
process.env.HOST = "127.0.0.1";

const EXAM_LIST = {
  success: true,
  bizContent: {
    total: 1,
    styles: [{ id: "1052373", name: "机考题库" }],
    examInfoModelList: [{
      id: "E1", examName: "机考测试", examStyle: "1052373", practiceMode: 2, examMode: 1,
      examTime: 90, paperInfoId: "p1", examTimesNum: "0", examTimesRestrict: "0",
      paid: false, examTimeRestrict: null, wfs: 1, timeLeft: 0,
    }],
  },
};

// Two sections: 语言理解 (Q1 single, Q2 multi, Q4 fill-in) and 判断推理 (Q3, non-target).
const EXAM_START_HTML = `
  <script>
    var exam_results_id = '87380582';
    var exam_info_id = 'E1';
  </script>
  <div class="card-content-title">语言理解</div>
  <a href="#question-1"><div class="question_cbox" questionsId="q1" uuId="u1"><span>1</span></div></a>
  <a href="#question-2"><div class="question_cbox" questionsId="q2" uuId="u1"><span>2</span></div></a>
  <a href="#question-4"><div class="question_cbox" questionsId="q4" uuId="u1"><span>3</span></div></a>
  <div class="card-content-title">判断推理</div>
  <a href="#question-3"><div class="question_cbox" questionsId="q3" uuId="u1"><span>4</span></div></a>
`;

const QUESTIONS = [
  { _id: "q1", question: "<p>单选</p>", answer1: "<p>A</p>", answer2: "<p>B</p>", answer3: "<p>C</p>", answer4: "<p>D</p>", key1: "1", key2: "0", key3: "0", key4: "0", test_ans: "", test_ans_right: "A", analysis: "<p>解析一</p>" },
  { _id: "q2", question: "<p>多选</p>", answer1: "<p>A</p>", answer2: "<p>B</p>", answer3: "<p>C</p>", answer4: "<p>D</p>", key1: "1", key2: "0", key3: "1", key4: "0", test_ans: "", test_ans_right: "A", analysis: "<p>解析二</p>" },
  { _id: "q4", question: "<p>填空</p>", answer1: "", answer2: "", answer3: "", answer4: "", key1: "0", key2: "0", key3: "0", key4: "0", test_ans: "", test_ans_right: "B", analysis: "<p>解析四</p>" },
  { _id: "q3", question: "<p>非目标</p>", answer1: "<p>A</p>", answer2: "<p>B</p>", answer3: "<p>C</p>", answer4: "<p>D</p>", key1: "0", key2: "1", key3: "0", key4: "0", test_ans: "", test_ans_right: "B", analysis: "" },
];

const RESULT_HTML = `
  <div class="score">0</div>
  <div class="exam-result-percentage">50%</div>
`;

let startServer;
let server;
let port;
let originalFetch;

before(async () => {
  // Pre-seed a session so the collector needs no login (server.js restores
  // session_cookies.txt at startup, before this require).
  fs.mkdirSync(localDir, { recursive: true, mode: 0o700 });
  fs.writeFileSync(path.join(localDir, "session_cookies.txt"), "sessionId=TEST_SESSION; JSESSIONID=js1;", { mode: 0o600 });
  ({ startServer } = require("../server"));
  server = startServer(0);
  await once(server, "listening");
  port = server.address().port;

  originalFetch = global.fetch;
  global.fetch = async (url, init = {}) => {
    const u = new URL(url);
    // The collector talks to the local server over loopback — pass through.
    if (u.hostname === "127.0.0.1") return originalFetch(url, init);

    const body = init.body ? String(init.body) : "";
    const json = (data, status = 200) => new Response(JSON.stringify(data), {
      status,
      headers: { "Content-Type": "application/json" },
    });
    switch (u.pathname) {
      case "/exam/current_exam_list":
        return json(EXAM_LIST);
      case "/exam/enter_exam/1/E1":
      case "/exam/faceCheckCondition":
      case "/exam/get_remian_time":
        return json({ success: true });
      case "/exam/start_exam_queue":
        return json({ success: true, code: "10000", bizContent: { isOk: true } });
      case "/exam/test_complete":
        return new Response("true", { status: 200, headers: { "Content-Type": "application/json" } });
      case "/exam/exam_start/E1":
        return new Response(EXAM_START_HTML, { status: 200, headers: { "Content-Type": "text/html" } });
      case "/exam/get_question_info/":
        return json(QUESTIONS);
      case "/exam/exam_ending":
        return new Response(RESULT_HTML, { status: 200, headers: { "Content-Type": "text/html" } });
      default:
        throw new Error(`Unexpected upstream fixture URL: ${url}${body ? ` body=${body}` : ""}`);
    }
  };
});

after(async () => {
  global.fetch = originalFetch;
  if (server) {
    await new Promise((resolve, reject) => {
      server.close((error) => error ? reject(error) : resolve());
    });
  }
  fs.rmSync(localDir, { recursive: true, force: true });
});

test("integration: the collector drives the real server against stubbed upstream", async () => {
  const { createHttpApi, runCollection } = require("../lib/question-bank");
  const bankDir = path.join(localDir, "bank");
  const api = createHttpApi(`http://127.0.0.1:${port}`);
  const summary = await runCollection(api, { bankDir, log: quietLog, roundDelayMs: 1 });

  assert.equal(summary.stoppedBy, "exhausted");

  const records = readJsonl(path.join(bankDir, "语言理解.jsonl"));
  assert.equal(records.length, 3);
  const byId = new Map(records.map((r) => [r._id, r]));
  assert.equal(byId.get("q1").answer, "A");
  assert.deepEqual(byId.get("q2").answer, ["A", "C"]);
  assert.equal(byId.get("q4").answer, "B");
  assert.equal(byId.get("q1").analysis, "<p>解析一</p>");
  assert.equal(byId.get("q1").category, "语言理解");
  assert.equal(byId.get("q1").sourceExamId, "E1");
  assert.equal(byId.get("q1").round, 1);
  assert.equal(byId.get("q1").collectedAt.includes("T"), true);

  // non-target section never persisted
  assert.equal(fs.existsSync(path.join(bankDir, "判断推理.jsonl")), false);

  const meta = JSON.parse(fs.readFileSync(path.join(bankDir, "meta.json"), "utf8"));
  assert.equal(meta.round, 2);
  assert.equal(meta.examState.E1.status, "drained");
  assert.equal(meta.examState.E1.roundsCollected, 2);
  assert.deepEqual(meta.counts, { 语言理解: 3 });

  // the running server session was not disturbed by the collection
  const status = await fetch(`http://127.0.0.1:${port}/api/status`).then((r) => r.json());
  assert.deepEqual(status, { loggedIn: true, hasSavedSession: true });
});
