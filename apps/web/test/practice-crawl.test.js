"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const crawl = require("../lib/practice-crawl");

const CATEGORIES = ["言语理解", "数字运算", "逻辑推理", "资料分析", "特有题型"];

function tmpBankDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), "lanjing-practice-"));
}

function fakePapers() {
  return [
    { id: 1, name: "【言语理解（二）】机考题库", style: "机考题库", wfs: 1 },
    { id: 2, name: "【数字运算】机考题库", style: "机考题库", wfs: 1 },
    { id: 3, name: "【言语理解（一）】机考题库", style: "机考题库", wfs: 0 },
    { id: 4, name: "模拟考试", style: "模拟", wfs: 1 },
  ];
}

function fakeApi(options = {}) {
  const { failEnter = [], slow = false } = options;
  const ended = [];
  const api = {
    ended,
    async getExams() { return fakePapers(); },
    async enter(exam) {
      if (slow) await new Promise((resolve) => setTimeout(resolve, 50));
      if (failEnter.includes(exam.id)) throw new Error(`enter ${exam.id} failed`);
      return {
        examResultsId: `er${exam.id}`,
        examInfoId: String(exam.id),
        testIds: [`q${exam.id}`],
        uuid: `u${exam.id}`,
        questionStates: [{ questionsId: `q${exam.id}`, uuId: `u${exam.id}`, section: "逻辑填空", combId: null, state: "unanswered" }],
      };
    },
    async fetchQuestions(entered) {
      return [{
        _id: `q${entered.examInfoId}`, key1: "1", key2: "0", key3: "0", key4: "0",
        question: "<p>题干</p>", answer1: "选项A", answer2: "选项B", answer3: "选项C", answer4: "选项D",
        analysis: "解析文字", parent_info: "", test_ans_right: "",
      }];
    },
    async endAttempt(exam) { ended.push(exam.id); },
  };
  return api;
}

test("first crawl stores all target papers per category with meta and log", async () => {
  const dir = tmpBankDir();
  const api = fakeApi();
  await crawl.crawlAllPapers(api, { bankDir: dir });

  const meta = crawl.loadMeta(dir);
  assert.ok(meta, "meta written");
  assert.equal(meta.round, 1);
  assert.deepEqual(Object.keys(meta.papers).sort(), ["1", "2", "3"]);
  assert.equal(meta.counts["言语理解"], 2);
  assert.equal(meta.counts["数字运算"], 1);
  assert.equal(meta.counts["逻辑推理"], undefined);

  const text = fs.readFileSync(path.join(dir, "言语理解.jsonl"), "utf8");
  const records = text.trim().split("\n").map((line) => JSON.parse(line));
  assert.equal(records.length, 2);
  const first = records[0];
  assert.equal(first.category, "言语理解");
  assert.equal(first.subCategory, "实词辨析"); // 逻辑填空 fallback
  assert.equal(first.answer, "A");
  assert.deepEqual(first.options, ["选项A", "选项B", "选项C", "选项D"]);
  assert.equal(first.sourceExamName, "【言语理解（二）】机考题库");

  // wfs=1 papers only get their attempt ended.
  assert.deepEqual(api.ended.sort(), [1, 2]);

  const log = crawl.loadCrawlLog(dir);
  assert.ok(log.length >= 3 * 3, `log has entries per step: ${log.length}`);
  assert.ok(log.some((e) => e.step === "paperList" && e.outcome === "success"));
  assert.ok(log.some((e) => e.step === "enter" && e.outcome === "success"));
  assert.ok(log.some((e) => e.step === "endAttempt" && e.outcome === "success"));
});

test("resume crawl skips papers already in meta.papers", async () => {
  const dir = tmpBankDir();
  const api = fakeApi();
  await crawl.crawlAllPapers(api, { bankDir: dir });
  api.ended.length = 0;

  await crawl.crawlAllPapers(api, { bankDir: dir });

  const meta = crawl.loadMeta(dir);
  assert.equal(meta.round, 1, "round unchanged on resume");
  assert.equal(meta.counts["言语理解"], 2, "counts unchanged");
  assert.equal(api.ended.length, 0, "no attempt re-ended");
  const log = crawl.loadCrawlLog(dir);
  assert.equal(log.filter((e) => e.step === "skip").length, 3);
});

test("refresh re-crawls every paper and atomically replaces the bank", async () => {
  const dir = tmpBankDir();
  const api = fakeApi();
  await crawl.crawlAllPapers(api, { bankDir: dir });

  // The second round answers every question differently (record format change).
  api.fetchQuestions = async () => [{
    _id: "q-new", key1: "0", key2: "1", key3: "0", key4: "0",
    question: "<p>新题干</p>", answer1: "新A", answer2: "新B", answer3: "新C", answer4: "新D",
    analysis: "新解析", parent_info: "", test_ans_right: "",
  }];
  api.ended.length = 0; // count only this round's endAttempt calls
  await crawl.crawlAllPapers(api, { bankDir: dir, refresh: true });

  const meta = crawl.loadMeta(dir);
  assert.equal(meta.round, 2);
  assert.equal(meta.counts["言语理解"], 2, "two papers × one new question each");
  const text = fs.readFileSync(path.join(dir, "言语理解.jsonl"), "utf8");
  assert.equal(text.trim().split("\n").length, 2);
  assert.ok(text.includes("q-new"), "old records replaced");
  assert.ok(!text.includes("q1"), "old record gone");
  assert.equal(api.ended.sort().join(","), "1,2", "attempts ended again");
});

test("refresh failure keeps the old bank intact (atomic commit)", async () => {
  const dir = tmpBankDir();
  const api = fakeApi();
  await crawl.crawlAllPapers(api, { bankDir: dir });
  const before = fs.readFileSync(path.join(dir, "言语理解.jsonl"), "utf8");

  const failing = fakeApi({ failEnter: [1] });
  await assert.rejects(
    crawl.crawlAllPapers(failing, { bankDir: dir, refresh: true }),
    /1 份试卷爬取失败/,
  );
  assert.equal(fs.readFileSync(path.join(dir, "言语理解.jsonl"), "utf8"), before, "bank unchanged");
  assert.equal(crawl.loadMeta(dir).round, 1, "meta unchanged");
});

test("incremental crawl stops after 3 consecutive failures", async () => {
  const dir = tmpBankDir();
  const api = fakeApi({ failEnter: [1, 2, 3] });
  await assert.rejects(crawl.crawlAllPapers(api, { bankDir: dir }));
});

test("startCrawl is single-flight and emits progress/done/error events", async () => {
  const dir = tmpBankDir();
  const api = fakeApi({ slow: true });
  const events = [];
  const unsubscribe = crawl.subscribe((event) => events.push(event));

  const task = crawl.startCrawl(api, { bankDir: dir });
  assert.ok(task && task.running);
  assert.equal(crawl.startCrawl(api, { bankDir: dir }), null, "second start rejected");

  for (let i = 0; i < 50 && crawl.currentTaskState().running; i += 1) {
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  assert.equal(crawl.currentTaskState().running, false);
  assert.equal(crawl.currentTaskState().error, null);
  assert.equal(events.filter((e) => e.type === "progress").length, 3);
  assert.ok(events.some((e) => e.type === "done"));
  unsubscribe();

  // A failed task emits error. The bank is already fully crawled above, so the
  // failing run must refresh — a non-refresh run would skip every paper and
  // emit nothing.
  const failing = fakeApi({ failEnter: [1, 2, 3] });
  const events2 = [];
  const unsub2 = crawl.subscribe((event) => events2.push(event));
  crawl.startCrawl(failing, { bankDir: dir, refresh: true });
  for (let i = 0; i < 50 && crawl.currentTaskState().running; i += 1) {
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  assert.equal(crawl.currentTaskState().running, false);
  assert.ok(crawl.currentTaskState().error);
  assert.ok(events2.some((e) => e.type === "error"));
  unsub2();
});

test("exportLogText summarizes and lists every entry; exportFileName is dated", () => {
  const entries = [
    { timestamp: "2026-08-11T00:00:00.000Z", paperId: null, paperName: "全部试卷", step: "paperList", outcome: "success", message: "共 2 份试卷" },
    { timestamp: "2026-08-11T00:00:01.000Z", paperId: "1", paperName: "【言语理解（二）】机考题库", step: "enter", outcome: "failure", message: "超时" },
  ];
  const text = crawl.exportLogText(entries);
  assert.ok(text.includes("共 2 条"));
  assert.ok(text.includes("成功 1 · 失败 1 · 跳过 0"));
  assert.ok(text.includes("获取试卷列表 — 成功（共 2 份试卷）"));
  assert.ok(text.includes("进入试卷 — 失败（超时）"));
  assert.match(crawl.exportFileName(new Date(2026, 7, 11, 14, 30)), /^爬取日志_20260811_1430\.txt$/);
});
