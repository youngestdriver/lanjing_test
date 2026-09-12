"use strict";

// Question-bank collector tests. Unit tests drive the collector with a fake
// `api` object; the integration test drives it with the real upstream client
// (lib/upstream.js) against a stubbed global.fetch shaped like the live
// platform (fixed per-paper pools, category in the paper name, JSON-success
// exam_ending). No test ever touches the real upstream (unmatched URLs throw).

const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { after, before, test } = require("node:test");

const {
  TARGET_CATEGORIES,
  ApiError,
  cleanSection,
  matchCategory,
  isTargetExam,
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

// One paper per category, matching the live platform naming; e3 is the user's
// in-progress attempt (wfs=0); e4/e5 are out-of-scope papers.
const EXAMS = [
  { id: "e1", name: "【言语理解（二）】机考题库", style: "【机考题库（2027年度）】", wfs: 1, examTimes: 1, examTimesRestrict: "1" },
  { id: "e2", name: "【数字运算（一）】机考题库", style: "【机考题库（2027年度）】", wfs: 1, examTimes: 1, examTimesRestrict: "1" },
  { id: "e3", name: "【逻辑推理（一）】机考题库", style: "【机考题库（2027年度）】", wfs: 0, examTimes: 1, examTimesRestrict: "1" },
  { id: "e4", name: "中国石化2027年度校园招聘考试模拟卷（四）", style: "【中石化模考套餐（2027年度）】", wfs: 1, examTimes: 2, examTimesRestrict: "0" },
  { id: "e5", name: "【常识判断（一）】机考题库（往年仅石油、海油、管网考）", style: "【机考题库（2027年度）】", wfs: 1, examTimes: 1, examTimesRestrict: "1" },
];

function baseCtx(overrides = {}) {
  return {
    targets: TARGET_CATEGORIES,
    examState: {},
    seenIds: new Set(),
    singleExamId: null,
    collectInProgress: true,
    verifyDelayMs: 10,
    round: 1,
    log: quietLog,
    ...overrides,
  };
}

// ---------- Pure helpers ----------

test("matchCategory maps paper names onto the 5 target categories", () => {
  assert.equal(matchCategory("【言语理解（二）】机考题库"), "言语理解");
  assert.equal(matchCategory("【数字运算（一）】机考题库"), "数字运算");
  assert.equal(matchCategory("【逻辑推理（三）】机考题库"), "逻辑推理");
  assert.equal(matchCategory("【资料分析（二）】机考题库"), "资料分析");
  assert.equal(matchCategory("【特有题型（一）】机考题库"), "特有题型");
  // out-of-scope papers
  assert.equal(matchCategory("【常识判断（一）】机考题库（往年仅石油、海油、管网考）"), null);
  assert.equal(matchCategory("中国石化2027年度校园招聘考试模拟卷（四）"), null);
  assert.equal(matchCategory(""), null);
});

test("cleanSection strips the point-count suffix but keeps notes", () => {
  assert.equal(cleanSection("逻辑填空(共200题,每题1分,合计200.0分)"), "逻辑填空");
  assert.equal(cleanSection("统计表(共10题,合计50.0分)"), "统计表");
  assert.equal(cleanSection("长篇阅读（仅中国石油和国家管网考）(共10题,合计50.0分)"), "长篇阅读（仅中国石油和国家管网考）");
  assert.equal(cleanSection("综合"), "综合");
  assert.equal(cleanSection(""), "(无分类)");
});

test("isTargetExam requires 机考题库 style and a category in the name", () => {
  assert.equal(isTargetExam(EXAMS[0]), true);
  assert.equal(isTargetExam(EXAMS[3]), false); // mock style
  assert.equal(isTargetExam(EXAMS[4]), false); // 常识判断 name
});

test("joinQuestions matches by questionsId with positional fallback", () => {
  const states = [
    { questionsId: "q1", section: "逻辑填空(共200题,每题1分,合计200.0分)" },
    { questionsId: "q2", section: "逻辑填空(共200题,每题1分,合计200.0分)" },
    { questionsId: "q3", section: "语句表达(共100题,每题1分,合计100.0分)" },
  ];
  const joined = joinQuestions([{ _id: "q1" }, { _id: "q2" }, { _id: "q3" }], states);
  assert.equal(joined.length, 3);
  assert.equal(joined[0].section, "逻辑填空(共200题,每题1分,合计200.0分)");

  const fallback = joinQuestions([{ _id: "x1" }], [{ questionsId: "nope", section: "综合" }]);
  assert.equal(fallback[0].section, "综合");

  assert.equal(joinQuestions([{ _id: "x1" }], [])[0].section, "(无分类)");

  const short = joinQuestions([{ _id: "a" }, { _id: "b" }], [{ questionsId: "a", section: "综合" }]);
  assert.equal(short.length, 2);
  assert.equal(short[1].section, "(无分类)");
});

test("buildRecord produces the bank schema with a cleaned section", () => {
  const ctx = { sourceExamId: "E1", sourceExamName: "【言语理解（二）】机考题库", round: 1, collectedAt: "2026-08-06T00:00:00.000Z" };
  const single = buildRecord(
    { _id: "q1", question: "<p>题干</p>", answer1: "<p>A</p>", answer2: "", answer3: "", answer4: "", _answers: ["A"], test_ans_right: "A", analysis: "<p>解析</p>" },
    "逻辑填空(共200题,每题1分,合计200.0分)", "言语理解", ctx,
  );
  assert.deepEqual(single, {
    _id: "q1", category: "言语理解", section: "逻辑填空",
    question: "<p>题干</p>", stem: "", options: ["<p>A</p>", "", "", ""], answer: "A", analysis: "<p>解析</p>",
    sourceExamId: "E1", sourceExamName: "【言语理解（二）】机考题库", round: 1, collectedAt: "2026-08-06T00:00:00.000Z",
  });

  // Comb (资料分析) questions carry the shared material in stem.
  const comb = buildRecord(
    { _id: "q5", question: "<p>小题</p>", parent_info: "<p>材料</p>", answer1: "<p>A</p>", answer2: "", answer3: "", answer4: "", _answers: ["A"], test_ans_right: "A", analysis: "" },
    "文字资料(共15题,合计75.0分)", "资料分析", ctx,
  );
  assert.equal(comb.stem, "<p>材料</p>");

  const multi = buildRecord({ _id: "q2", _answers: ["A", "C"], test_ans_right: "" }, "综合", "言语理解", ctx);
  assert.deepEqual(multi.answer, ["A", "C"]);

  const fallback = buildRecord({ _id: "q3", _answers: [], test_ans_right: "B" }, "综合", "言语理解", ctx);
  assert.equal(fallback.answer, "B");

  const none = buildRecord({ _id: "q4", _answers: [], test_ans_right: "" }, "综合", "言语理解", ctx);
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

test("pickExam filters to target papers and prefers fresh attempts", () => {
  const empty = { examState: {}, singleExamId: null, collectInProgress: true };
  assert.equal(pickExam(EXAMS, empty).exam.id, "e1"); // first target wfs=1

  // wfs=0 in-progress picked read-only only after all wfs=1 targets are done
  const drained1 = pickExam(EXAMS, { ...empty, examState: { e1: { status: "drained" }, e2: { status: "drained" } } });
  assert.equal(drained1.exam.id, "e3");
  assert.equal(drained1.reason, "inProgress");

  // collectInProgress=false skips the user's attempts entirely
  const drained2 = pickExam(EXAMS, { ...empty, examState: { e1: { status: "drained" }, e2: { status: "drained" } }, collectInProgress: false });
  assert.equal(drained2.exam, null);
  assert.equal(drained2.reason, "exhausted");

  // pendingSubmit (our own crashed attempt) wins regardless of wfs
  const pending = pickExam(EXAMS, { examState: { e3: { status: "pendingSubmit", createdByUs: true } }, singleExamId: null, collectInProgress: true });
  assert.equal(pending.exam.id, "e3");
  assert.equal(pending.reason, "pendingSubmit");

  // drained skipped
  const drained = pickExam(EXAMS, { examState: { e1: { status: "drained" } }, singleExamId: null, collectInProgress: true });
  assert.equal(drained.exam.id, "e2");

  // stale pendingSubmit (exam no longer listed) is marked drained
  const stale = { examState: { gone: { status: "pendingSubmit" } }, singleExamId: null, collectInProgress: true };
  assert.equal(pickExam(EXAMS, stale).exam.id, "e1");
  assert.equal(stale.examState.gone.status, "drained");

  // --exam overrides all filters (mock paper included)
  assert.equal(pickExam(EXAMS, { examState: {}, singleExamId: "e4", collectInProgress: true }).exam.id, "e4");
  assert.equal(pickExam(EXAMS, { examState: {}, singleExamId: "nope", collectInProgress: true }).exam, null);
});

// ---------- Round ----------

test("collectRound runs enter→questions→submit on a fresh paper", async () => {
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
        { questionsId: "q1", section: "逻辑填空(共200题,每题1分,合计200.0分)" },
        { questionsId: "q2", section: "逻辑填空(共200题,每题1分,合计200.0分)" },
      ],
    }),
    submit: async () => { calls.push("submit"); return { success: true, score: "0" }; },
  });
  const ctx = baseCtx();
  const result = await collectRound(api, ctx);

  assert.deepEqual(calls, ["enter", "submit"]);
  assert.equal(result.newQuestions.length, 2);
  assert.equal(result.newQuestions[0].section, "逻辑填空");
  assert.equal(result.newQuestions[0].category, "言语理解");
  assert.deepEqual([...ctx.seenIds], ["q1", "q2"]);
  assert.equal(result.drained, false);
  assert.equal(ctx.examState.e1.status, "collected");
  assert.equal(ctx.examState.e1.createdByUs, true);
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
  assert.equal(ctx.examState.e1.createdByUs, true);
});

test("collectRound treats a 502 submit as success when the exam list shows wfs=1", async () => {
  let submitCalls = 0;
  const api = fakeApi({
    getExams: async () => [EXAMS[0]], // wfs stays 1 — the attempt ended (JSON success)
    getQuestions: async () => ({
      questions: [{ _id: "q1", question: "<p>1</p>", answer1: "<p>A</p>", _answers: ["A"] }],
      states: [{ questionsId: "q1", section: "综合" }],
    }),
    submit: async () => { submitCalls += 1; throw new ApiError(502, "考试未能结束，请刷新后重试"); },
  });
  const ctx = baseCtx();
  const result = await collectRound(api, ctx);
  assert.equal(submitCalls, 1);
  assert.deepEqual(result.submitResult, { success: true, score: null });
  assert.equal(result.drained, false);
  assert.equal(ctx.examState.e1.status, "collected");
});

test("collectRound keeps pendingSubmit when the 502 cannot be verified as ended", async () => {
  let listCalls = 0;
  let submitted = false; // wfs=1 until the submit attempt, then the attempt sticks open
  const api = fakeApi({
    getExams: async () => {
      listCalls += 1;
      return [{ ...EXAMS[0], wfs: submitted ? 0 : 1 }];
    },
    getQuestions: async () => ({
      questions: [{ _id: "q1", question: "<p>1</p>", answer1: "<p>A</p>", _answers: ["A"] }],
      states: [{ questionsId: "q1", section: "综合" }],
    }),
    submit: async () => { submitted = true; throw new ApiError(502, "考试未能结束，请刷新后重试"); },
  });
  const ctx = baseCtx();
  const result = await collectRound(api, ctx);
  assert.equal(listCalls, 3); // round start + two verification refetches
  assert.equal(result.submitResult, null);
  assert.equal(result.drained, false);
  assert.equal(ctx.examState.e1.status, "pendingSubmit");
});

test("collectRound does not submit the user's in-progress attempt (read-only)", async () => {
  const calls = [];
  const api = fakeApi({
    getExams: async () => [EXAMS[2]], // e3 wfs=0
    enter: async () => { calls.push("enter"); return {}; },
    getQuestions: async () => ({
      questions: [{ _id: "q1", question: "<p>1</p>", answer1: "<p>A</p>", _answers: ["A"] }],
      states: [{ questionsId: "q1", section: "图形推理(共300题,每题1分,合计300.0分)" }],
    }),
    submit: async () => { calls.push("submit"); return {}; },
  });
  const ctx = baseCtx();
  const result = await collectRound(api, ctx);
  assert.deepEqual(calls, ["enter"]); // no submit
  assert.equal(result.newQuestions.length, 1);
  assert.equal(result.drained, true);
  assert.equal(ctx.examState.e3.status, "drained");
});

test("collectRound never submits a resumed attempt that was not created by us", async () => {
  const calls = [];
  const api = fakeApi({
    getExams: async () => [{ ...EXAMS[2], wfs: 0 }],
    enter: async () => { calls.push("enter"); return {}; },
    getQuestions: async () => ({
      questions: [{ _id: "q1", question: "<p>1</p>", answer1: "<p>A</p>", _answers: ["A"] }],
      states: [{ questionsId: "q1", section: "综合" }],
    }),
    submit: async () => { calls.push("submit"); return {}; },
  });
  const ctx = baseCtx({ examState: { e3: { status: "pendingSubmit" } } }); // no createdByUs
  const result = await collectRound(api, ctx);
  assert.deepEqual(calls, ["enter"]);
  assert.equal(result.drained, true);
  assert.equal(ctx.examState.e3.status, "drained");
});

test("collectRound with a forced non-target exam collects nothing but still ends our attempt", async () => {
  const calls = [];
  const api = fakeApi({
    getExams: async () => [EXAMS[4]], // 常识判断 — forced via --exam
    getQuestions: async () => ({
      questions: [{ _id: "q1", question: "<p>1</p>", answer1: "<p>A</p>", _answers: ["A"] }],
      states: [{ questionsId: "q1", section: "综合" }],
    }),
    submit: async () => { calls.push("submit"); return { success: true, score: "0" }; },
  });
  const ctx = baseCtx({ singleExamId: "e5" });
  const result = await collectRound(api, ctx);
  assert.deepEqual(calls, ["submit"]);
  assert.equal(result.newQuestions.length, 0); // category null → nothing recorded
  assert.equal(ctx.examState.e5.status, "drained");
});

// ---------- Main loop ----------

test("runCollection dedupes across rounds, stops exhausted on fixed pools", async () => {
  const bankDir = tmpBankDir();
  let submitCalls = 0;
  const api = fakeApi({
    getExams: async () => [EXAMS[0]],
    getQuestions: async () => ({
      questions: [
        { _id: "q1", question: "<p>单选</p>", answer1: "<p>A</p>", _answers: ["A"], analysis: "<p>解析一</p>" },
        { _id: "q2", question: "<p>多选</p>", answer1: "<p>A</p>", answer3: "<p>C</p>", _answers: ["A", "C"], analysis: "" },
        { _id: "q4", question: "<p>填空</p>", _answers: [], test_ans_right: "B", analysis: "<p>解析四</p>" },
      ],
      states: [
        { questionsId: "q1", section: "逻辑填空(共200题,每题1分,合计200.0分)" },
        { questionsId: "q2", section: "逻辑填空(共200题,每题1分,合计200.0分)" },
        { questionsId: "q4", section: "逻辑填空(共200题,每题1分,合计200.0分)" },
      ],
    }),
    submit: async () => { submitCalls += 1; return { success: true, score: "0" }; },
  });

  const summary = await runCollection(api, { bankDir, log: quietLog, roundDelayMs: 1 });

  assert.equal(summary.stoppedBy, "exhausted");
  const records = readJsonl(path.join(bankDir, "言语理解.jsonl"));
  assert.equal(records.length, 3);
  assert.equal(submitCalls, 2); // collect round + drain round

  const byId = new Map(records.map((r) => [r._id, r]));
  assert.deepEqual(byId.get("q2").answer, ["A", "C"]);
  assert.equal(byId.get("q4").answer, "B");
  assert.equal(byId.get("q1").analysis, "<p>解析一</p>");
  assert.equal(byId.get("q1").section, "逻辑填空");
  assert.equal(byId.get("q1").category, "言语理解");
  assert.equal(byId.get("q1").sourceExamId, "e1");
  assert.equal(byId.get("q1").round, 1);

  assert.equal(summary.countsByCategory["言语理解"], 3);
  assert.equal(summary.stats.totalRounds, 2);
  // out-of-scope papers never produce files
  assert.equal(fs.existsSync(path.join(bankDir, "常识判断.jsonl")), false);
});

test("runCollection collects in-progress papers read-only after fresh ones drain", async () => {
  const bankDir = tmpBankDir();
  const submitCalls = [];
  // Each paper has its own fixed pool: e1→q1, e2→q2, e3→q3.
  const pools = {
    e1: "q1", e2: "q2", e3: "q3",
  };
  const api = fakeApi({
    getExams: async () => EXAMS.slice(0, 3), // e1 (wfs=1), e2 (wfs=1), e3 (wfs=0)
    getQuestions: async (id) => {
      const qid = pools[id] || "q1";
      return {
        questions: [{ _id: qid, question: `<p>${qid}</p>`, answer1: "<p>A</p>", _answers: ["A"] }],
        states: [{ questionsId: qid, section: "综合" }],
      };
    },
    submit: async (id) => { submitCalls.push(id); return { success: true, score: "0" }; },
  });

  const summary = await runCollection(api, { bankDir, log: quietLog, roundDelayMs: 1 });

  assert.equal(summary.stoppedBy, "exhausted");
  // e1: collect + drain (2 submits); e2: collect + drain (2); e3: read-only (0)
  assert.deepEqual(submitCalls, ["e1", "e1", "e2", "e2"]);
  assert.equal(readJsonl(path.join(bankDir, "言语理解.jsonl")).length, 1);
  assert.equal(readJsonl(path.join(bankDir, "数字运算.jsonl")).length, 1);
  assert.equal(readJsonl(path.join(bankDir, "逻辑推理.jsonl")).length, 1);
  assert.equal(summary.examsProcessed, 3);
  assert.equal(summary.round, 5); // e1×2 + e2×2 + e3×1, then the exhausted probe
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
            { questionsId: "q1", section: "综合" },
            { questionsId: "q2", section: "综合" },
          ],
        };
      }
      return {
        questions: [{ _id: "q3", question: "<p>同内容</p>", answer1: "<p>A</p>", _answers: ["A"] }],
        states: [{ questionsId: "q3", section: "综合" }],
      };
    },
  });

  const summary = await runCollection(api, { bankDir, log: quietLog, maxRounds: 2, roundDelayMs: 1 });

  assert.equal(summary.stoppedBy, "maxRounds");
  assert.equal(summary.stats.answerUnknown, 1); // q1
  assert.equal(summary.stats.contentDupes, 1); // q3 duplicates q2's content
  assert.equal(readJsonl(path.join(bankDir, "言语理解.jsonl")).length, 3); // both stored
});

test("runCollection stops on idle when submits keep failing unverified", async () => {
  const bankDir = tmpBankDir();
  let submitted = false; // wfs=1 until the first submit attempt, then the attempt sticks open
  const api = fakeApi({
    getExams: async () => [{ ...EXAMS[0], wfs: submitted ? 0 : 1 }],
    getQuestions: async () => ({
      questions: [{ _id: "q1", question: "<p>1</p>", answer1: "<p>A</p>", _answers: ["A"] }],
      states: [{ questionsId: "q1", section: "综合" }],
    }),
    submit: async () => { submitted = true; throw new ApiError(502, "考试未能结束，请刷新后重试"); },
  });

  const summary = await runCollection(api, { bankDir, log: quietLog, idleLimit: 3, roundDelayMs: 1, verifyDelayMs: 10 });
  assert.equal(summary.stoppedBy, "idle");
  assert.equal(summary.stats.totalRounds, 4); // 1 new round + 3 empty rounds
  assert.equal(summary.countsByCategory["言语理解"], 1);
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
        { questionsId: "q1", section: "综合" },
        { questionsId: "q2", section: "综合" },
      ],
    }),
  });

  const first = await runCollection(api, { bankDir, log: quietLog, maxRounds: 1, roundDelayMs: 1 });
  assert.equal(first.stoppedBy, "maxRounds");
  assert.equal(first.round, 1);
  assert.equal(readJsonl(path.join(bankDir, "言语理解.jsonl")).length, 2);

  const second = await runCollection(api, { bankDir, log: quietLog, maxRounds: 10, roundDelayMs: 1 });
  assert.equal(second.stoppedBy, "exhausted");
  assert.equal(second.round, 2); // continued from meta.round=1
  assert.equal(readJsonl(path.join(bankDir, "言语理解.jsonl")).length, 2); // no dupes
  const meta = JSON.parse(fs.readFileSync(path.join(bankDir, "meta.json"), "utf8"));
  assert.equal(meta.round, 2);
  assert.equal(meta.examState.e1.status, "drained");
});

test("loadBank drops a truncated trailing line", () => {
  const dir = tmpBankDir();
  fs.mkdirSync(dir, { recursive: true });
  const file = path.join(dir, "言语理解.jsonl");
  fs.writeFileSync(
    file,
    JSON.stringify({ _id: "q1", category: "言语理解", section: "综合", question: "", options: ["", "", "", ""] }) + "\n"
    + '{"_id": "q9", "category": "言语理解", "question": "<p>trunc',
    "utf8",
  );
  const bank = loadBank(dir, TARGET_CATEGORIES);
  assert.equal(bank.counts["言语理解"], 1);
  assert.equal(bank.seenIds.has("q1"), true);
  assert.equal(bank.seenIds.has("q9"), false);
});

// ---------- Integration: direct upstream client, stubbed upstream ----------

const localDir = fs.mkdtempSync(path.join(os.tmpdir(), "lanjing-qbank-integration-"));
const sessionFile = path.join(localDir, "session_cookies.txt");

// E1: fresh paper (wfs=1). E0: the user's in-progress attempt (wfs=0).
// E2: fresh 资料分析 paper with comb (insert-list) questions.
// E9: out-of-scope 常识判断 paper. E8: out-of-scope mock style.
const EXAM_LIST = {
  success: true,
  bizContent: {
    total: 5,
    styles: [
      { id: "1052372", name: "【机考题库（2027年度）】" },
      { id: "1052373", name: "【中石化模考套餐（2027年度）】" },
    ],
    examInfoModelList: [
      { id: "E1", examName: "【言语理解（二）】机考题库", examStyle: "1052372", practiceMode: 2, examMode: 1, examTime: 90, paperInfoId: "p1", examTimesNum: "1", examTimesRestrict: "1", paid: true, examTimeRestrict: null, wfs: 1, timeLeft: 0 },
      { id: "E2", examName: "【资料分析（一）】机考题库", examStyle: "1052372", practiceMode: 2, examMode: 1, examTime: 90, paperInfoId: "p2", examTimesNum: "1", examTimesRestrict: "1", paid: true, examTimeRestrict: null, wfs: 1, timeLeft: 0 },
      { id: "E0", examName: "【言语理解（一）】机考题库", examStyle: "1052372", practiceMode: 2, examMode: 1, examTime: 90, paperInfoId: "p0", examTimesNum: "1", examTimesRestrict: "1", paid: true, examTimeRestrict: null, wfs: 0, timeLeft: 0 },
      { id: "E9", examName: "【常识判断（一）】机考题库（往年仅石油、海油、管网考）", examStyle: "1052372", practiceMode: 2, examMode: 1, examTime: 90, paperInfoId: "p9", examTimesNum: "1", examTimesRestrict: "1", paid: true, examTimeRestrict: null, wfs: 1, timeLeft: 0 },
      { id: "E8", examName: "中国石化2027年度校园招聘考试模拟卷（四）", examStyle: "1052373", practiceMode: 0, examMode: 1, examTime: 90, paperInfoId: "p8", examTimesNum: "2", examTimesRestrict: "0", paid: true, examTimeRestrict: null, wfs: 1, timeLeft: 0 },
    ],
  },
};

// E1's answer card: one section 逻辑填空 with q1/q2/q4.
const EXAM_START_E1_HTML = `
  <script>
    var exam_results_id = '87380582';
    var exam_info_id = 'E1';
  </script>
  <div class="card-content-title">逻辑填空(共200题,每题1分,合计200.0分)</div>
  <a href="#q1"><div class="question_cbox" questionsId="q1" uuId="u1"><span>1</span></div></a>
  <a href="#q2"><div class="question_cbox" questionsId="q2" uuId="u1"><span>2</span></div></a>
  <a href="#q4"><div class="question_cbox" questionsId="q4" uuId="u1"><span>3</span></div></a>
`;

// E0's answer card (user's in-progress attempt): one section 片段阅读 with q5/q6.
const EXAM_START_E0_HTML = `
  <script>
    var exam_results_id = '87380591';
    var exam_info_id = 'E0';
  </script>
  <div class="card-content-title">片段阅读(共100题,每题1分,合计100.0分)</div>
  <a href="#q5"><div class="question_cbox" questionsId="q5" uuId="u5"><span>1</span></div></a>
  <a href="#q6"><div class="question_cbox" questionsId="q6" uuId="u5"><span>2</span></div></a>
`;

// E2's answer card (资料分析): a comb section (trailing-space class,
// insert-list wrapper) with q7/q8, followed by a regular section with q9.
const EXAM_START_E2_HTML = `
  <script>
    var exam_results_id = '87380592';
    var exam_info_id = 'E2';
  </script>
  <div class="card-content-title ">文字资料(共15题,合计75.0分)</div>
  <div class="box-list ">
    <div class="insert-list inline-insert-list " questionsId="comb_wa ">
      <a href="#q7">
        <div class="box insert-box question_cbox s1 practice-mode-2 ">
          <span class="iconBox" questionsId="q7" uuId="u7" num="questions_q7">1.1</span>
        </div>
      </a>
      <a href="#q8">
        <div class="box insert-box question_cbox s1 practice-mode-2 ">
          <span class="iconBox" questionsId="q8" uuId="u7" num="questions_q8">1.2</span>
        </div>
      </a>
    </div>
  </div>
  <div class="card-content-title">简单计算</div>
  <a href="#q9"><div class="question_cbox" questionsId="q9" uuId="u7"><span>3</span></div></a>
`;

const QUESTIONS_E1 = [
  { _id: "q1", question: "<p>单选</p>", answer1: "<p>A</p>", answer2: "<p>B</p>", answer3: "<p>C</p>", answer4: "<p>D</p>", key1: "1", key2: "0", key3: "0", key4: "0", test_ans: "", test_ans_right: "A", analysis: "<p>解析一</p>" },
  { _id: "q2", question: "<p>多选</p>", answer1: "<p>A</p>", answer2: "<p>B</p>", answer3: "<p>C</p>", answer4: "<p>D</p>", key1: "1", key2: "0", key3: "1", key4: "0", test_ans: "", test_ans_right: "A", analysis: "<p>解析二</p>" },
  { _id: "q4", question: "<p>填空</p>", answer1: "", answer2: "", answer3: "", answer4: "", key1: "0", key2: "0", key3: "0", key4: "0", test_ans: "", test_ans_right: "B", analysis: "<p>解析四</p>" },
];
const QUESTIONS_E0 = [
  { _id: "q5", question: "<p>进行中卷题目</p>", answer1: "<p>A</p>", answer2: "<p>B</p>", answer3: "<p>C</p>", answer4: "<p>D</p>", key1: "0", key2: "1", key3: "0", key4: "0", test_ans: "key2,", test_ans_right: "B", analysis: "<p>解析五</p>" },
  { _id: "q6", question: "<p>进行中卷题目二</p>", answer1: "<p>A</p>", answer2: "<p>B</p>", answer3: "<p>C</p>", answer4: "<p>D</p>", key1: "1", key2: "0", key3: "0", key4: "0", test_ans: "", test_ans_right: "A", analysis: "" },
];
const QUESTIONS_E2 = [
  { _id: "q7", question: "<p>材料小题一</p>", parent_info: "<p>共享材料</p>", answer1: "<p>A</p>", answer2: "<p>B</p>", answer3: "<p>C</p>", answer4: "<p>D</p>", key1: "1", key2: "0", key3: "0", key4: "0", test_ans: "", test_ans_right: "A", analysis: "<p>解析七</p>" },
  { _id: "q8", question: "<p>材料小题二</p>", parent_info: "<p>共享材料</p>", answer1: "<p>A</p>", answer2: "<p>B</p>", answer3: "<p>C</p>", answer4: "<p>D</p>", key1: "0", key2: "1", key3: "0", key4: "0", test_ans: "", test_ans_right: "B", analysis: "<p>解析八</p>" },
  { _id: "q9", question: "<p>普通题</p>", answer1: "<p>A</p>", answer2: "<p>B</p>", answer3: "<p>C</p>", answer4: "<p>D</p>", key1: "0", key2: "0", key3: "1", key4: "0", test_ans: "", test_ans_right: "C", analysis: "<p>解析九</p>" },
];

// Practice papers answer exam_ending with JSON success, not a result page.
const END_JSON = { code: 10000, desc: "成功", englishDesc: "Success", success: true };

let originalFetch;
let endCalls; // examInfoIds ended via exam_ending
let enterCalls; // examInfoIds entered via the new-exam flow
let questionCalls; // /exam/get_question_info/ request bodies

before(async () => {
  // Pre-seed a session so the collector needs no login (the upstream client
  // loads session_cookies.txt from its sessionFile at construction).
  fs.mkdirSync(localDir, { recursive: true, mode: 0o700 });
  fs.writeFileSync(sessionFile, "sessionId=TEST_SESSION; JSESSIONID=js1;", { mode: 0o600 });

  endCalls = [];
  enterCalls = [];
  questionCalls = [];
  originalFetch = global.fetch;
  global.fetch = async (url, init = {}) => {
    const u = new URL(url);
    const body = init.body ? String(init.body) : "";
    const json = (data, status = 200) => new Response(JSON.stringify(data), {
      status,
      headers: { "Content-Type": "application/json" },
    });
    switch (u.pathname) {
      case "/exam/current_exam_list":
        return json(EXAM_LIST);
      case "/exam/enter_exam/1/E1":
        enterCalls.push("E1");
        return json({ success: true });
      case "/exam/enter_exam/1/E2":
        enterCalls.push("E2");
        return json({ success: true });
      case "/exam/faceCheckCondition":
      case "/exam/get_remian_time":
        return json({ success: true });
      case "/exam/start_exam_queue":
        return json({ success: true, code: "10000", bizContent: { isOk: true } });
      case "/exam/test_complete":
        return new Response("true", { status: 200, headers: { "Content-Type": "application/json" } });
      case "/exam/exam_start/E1":
        return new Response(EXAM_START_E1_HTML, { status: 200, headers: { "Content-Type": "text/html" } });
      case "/exam/exam_start/E2":
        return new Response(EXAM_START_E2_HTML, { status: 200, headers: { "Content-Type": "text/html" } });
      case "/exam/exam_start/E0":
        return new Response(EXAM_START_E0_HTML, { status: 200, headers: { "Content-Type": "text/html" } });
      case "/exam/get_question_info/":
        questionCalls.push(body);
        if (body.includes("q7") || body.includes("q8")) return json(QUESTIONS_E2);
        return json(body.includes("q5") ? QUESTIONS_E0 : QUESTIONS_E1);
      case "/exam/exam_ending": {
        const infoId = u.searchParams.get("examInfoId");
        endCalls.push(infoId);
        return json(END_JSON);
      }
      default:
        throw new Error(`Unexpected upstream fixture URL: ${url}${body ? ` body=${body}` : ""}`);
    }
  };
});

after(async () => {
  global.fetch = originalFetch;
  fs.rmSync(localDir, { recursive: true, force: true });
});

test("integration: the collector drives the direct upstream client against stubbed upstream", async () => {
  const { createUpstreamApi } = require("../lib/upstream");
  const { runCollection } = require("../lib/question-bank");
  const bankDir = path.join(localDir, "bank");
  const api = createUpstreamApi({ baseUrl: "https://upstream.fixture.test", sessionFile, retries: 0 });
  const summary = await runCollection(api, { bankDir, log: quietLog, roundDelayMs: 1 });

  assert.equal(summary.stoppedBy, "exhausted");
  assert.equal(summary.round, 5);

  const records = readJsonl(path.join(bankDir, "言语理解.jsonl"));
  assert.equal(records.length, 5); // q1/q2/q4 from E1 + q5/q6 from E0
  const byId = new Map(records.map((r) => [r._id, r]));
  assert.equal(byId.get("q1").answer, "A");
  assert.deepEqual(byId.get("q2").answer, ["A", "C"]);
  assert.equal(byId.get("q4").answer, "B");
  assert.equal(byId.get("q1").analysis, "<p>解析一</p>");
  assert.equal(byId.get("q1").category, "言语理解");
  assert.equal(byId.get("q1").section, "逻辑填空");
  assert.equal(byId.get("q5").section, "片段阅读");
  assert.equal(byId.get("q5").sourceExamId, "E0");
  assert.equal(byId.get("q1").round, 1);
  assert.equal(byId.get("q5").round, 5); // in-progress paper collected after E1/E2 drained

  // E2 (资料分析): comb questions carry the shared material in stem, the
  // regular one does not.
  const ziliao = readJsonl(path.join(bankDir, "资料分析.jsonl"));
  assert.equal(ziliao.length, 3); // q7/q8 (comb) + q9 (regular)
  const byZiliaoId = new Map(ziliao.map((r) => [r._id, r]));
  assert.equal(byZiliaoId.get("q7").stem, "<p>共享材料</p>");
  assert.equal(byZiliaoId.get("q8").stem, "<p>共享材料</p>");
  assert.equal(byZiliaoId.get("q9").stem, "");
  assert.equal(byZiliaoId.get("q7").section, "文字资料");

  // Comb questions are requested together with their combId; the regular
  // batch of the same paper (and every other paper) has no combId. Form
  // encoding is URLSearchParams, so commas arrive as %2C.
  const combRequest = questionCalls.find((b) => b.includes("combId="));
  assert.ok(combRequest, "a comb request with combId is made");
  assert.ok(combRequest.includes("testIds=q7%2Cq8"), "comb sub-questions share one request");
  assert.ok(questionCalls.some((b) => b.includes("testIds=q9") && !b.includes("combId")), "regular batch has no combId");
  assert.ok(questionCalls.every((b) => b.includes("testIds=q1%2Cq2%2Cq4") ? !b.includes("combId") : true), "E1 batches have no combId");

  // E1/E2 fresh attempts ended exactly twice each (collect + drain); the
  // user's E0 attempt was never submitted; out-of-scope papers never entered.
  assert.deepEqual(endCalls, ["E1", "E1", "E2", "E2"]);
  assert.deepEqual(enterCalls, ["E1", "E1", "E2", "E2"]);

  const meta = JSON.parse(fs.readFileSync(path.join(bankDir, "meta.json"), "utf8"));
  assert.equal(meta.round, 5);
  assert.equal(meta.examState.E1.status, "drained");
  assert.equal(meta.examState.E2.status, "drained");
  assert.equal(meta.examState.E0.status, "drained");
  assert.equal(meta.examState.E0.createdByUs, false);
  assert.deepEqual(meta.counts, { 言语理解: 5, 资料分析: 3 });
  assert.equal(meta.stats.totalRounds, 5);

  // the client's saved session was not disturbed by the collection (no login
  // happened; the collector's own session file is untouched)
  assert.equal(fs.readFileSync(sessionFile, "utf8"), "sessionId=TEST_SESSION; JSESSIONID=js1;");
});
