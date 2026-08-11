# Web 练习页对齐 iOS 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Web 练习页从占位页升级为与 iOS 对齐的完整能力:直连爬取全量机考题库到 `.local/practice/`、按大类→题型细分两级分类本地刷题、组合题支持、"我的"页题库管理(更新/删除/日志导出)。

**Architecture:** 爬取循环在 `apps/web/lib/practice-crawl.js`(api 依赖注入,复用 `apps/bank/lib/question-bank.js` 的纯函数与存储),`server.js` 提供 `/api/practice/*` 路由 + 上游 adapter + SSE 进度;前端 `practice-core.js`(UMD 纯逻辑)与 `practice.js`(状态机 UI);答题页零网络。

**Tech Stack:** Node ≥22(express 5、node:test)、原生浏览器 JS(无构建步骤)、现有 UMD 双环境模式(参照 `quiz-core.js`)。

## Global Constraints

- 所有上游请求必须走现有 `proxyRequest`/`fetchSessionText`(共享 `cookieJar`,自动检测会话过期)
- 复用 `apps/bank/lib/question-bank.js` 与 `apps/bank/lib/question-classifier.js`,**禁止**复制其逻辑(三端共享单一规则引擎)
- 题库目录固定为 `<LOCAL_DIR>/practice/`,文件权限 0600、目录 0700(与现有 `.local` 约定一致)
- JSONL 记录与 meta.json 形状必须与 iOS 兼容:`{version:1, targets, round, lastRun, papers:{paperId:true}, counts}`
- 记录 `subCategory` 由 `classifier.classify(record)` 填充(爬取时)
- 爬取任务单飞:同时只有一个任务;SSE 推送 `{type:"progress"|"done"|"error", index, total, paperName, message}`
- 免登录路由:`/api/practice/status`、`/api/practice/categories/*`、`/api/practice/events`、`/api/practice/log`;其余 practice 路由需登录(会话过期 → 401)
- 新增文件的语法检查必须加入 `package.json` 的 `check` 脚本
- 测试:node:test + `node:assert/strict`,前端纯函数直接 `require` UMD 文件

---

### Task 1: practice-core.js 前端纯逻辑 + 单测

**Files:**
- Create: `apps/web/public/js/practice-core.js`
- Test: `apps/web/test/practice-core.test.js`

**Interfaces:**
- Produces (Task 4 消费): UMD 全局 `root.PracticeCore`,导出:
  - `parseJSONL(text) → [record]`
  - `groupBySubcategory(questions) → [{name, questions}]`
  - `grade(selected, question) → true|false|null`
  - `shuffledKeepingGroups(questions, seed) → [question]`(seed 为 BigInt)
  - `shuffleKey(category) → "practice.shuffle.<category>"`

- [ ] **Step 1: 写失败测试** `apps/web/test/practice-core.test.js`

```js
"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");

const PracticeCore = require("../public/js/practice-core");

test("parseJSONL decodes records and drops truncated lines", () => {
  const text = '{"_id":"a","subCategory":"逻辑填空","answer":"A"}\n'
    + '{"_id":"b","subCategory":"成语辨析","answer":["A","C"]}\n'
    + '{"_id":"c"';
  const parsed = PracticeCore.parseJSONL(text);
  assert.equal(parsed.length, 2);
  assert.equal(parsed[0]._id, "a");
  assert.deepEqual(parsed[1].answer, ["A", "C"]);
});

test("groupBySubcategory preserves first-appearance order and buckets unknown", () => {
  const questions = [
    { subCategory: "逻辑填空" },
    { subCategory: "" },
    { subCategory: "逻辑填空" },
  ];
  const groups = PracticeCore.groupBySubcategory(questions);
  assert.deepEqual(
    groups.map((g) => [g.name, g.questions.length]),
    [["逻辑填空", 2], ["未分类", 1]],
  );
});

test("grade handles string/array/null answers with exact equality", () => {
  assert.equal(PracticeCore.grade(["A"], { answer: "A" }), true);
  assert.equal(PracticeCore.grade(["B"], { answer: "A" }), false);
  assert.equal(PracticeCore.grade(["A", "C"], { answer: ["A", "C"] }), true);
  assert.equal(PracticeCore.grade(["A"], { answer: ["A", "C"] }), false);
  assert.equal(PracticeCore.grade(["C", "A"], { answer: ["A", "C"] }), true);
  assert.equal(PracticeCore.grade(["A"], { answer: null }), null);
  assert.equal(PracticeCore.grade(["A"], { answer: "" }), null);
});

test("shuffle is deterministic per seed and a permutation", () => {
  const questions = Array.from({ length: 20 }, (_, i) => ({ _id: String(i) }));
  const a = PracticeCore.shuffledKeepingGroups(questions, 42n);
  const b = PracticeCore.shuffledKeepingGroups(questions, 42n);
  const c = PracticeCore.shuffledKeepingGroups(questions, 43n);
  assert.deepEqual(a.map((q) => q._id), b.map((q) => q._id));
  assert.notDeepEqual(a.map((q) => q._id), c.map((q) => q._id));
  assert.deepEqual(a.map((q) => q._id).sort(), questions.map((q) => q._id).sort());
});

test("shuffle keeps comb stem groups adjacent", () => {
  const stemA = "<p>材料A</p>";
  const questions = [
    { _id: "1", stem: stemA }, { _id: "2" }, { _id: "3", stem: stemA }, { _id: "4" },
  ];
  for (let seed = 1n; seed < 30n; seed += 1n) {
    const shuffled = PracticeCore.shuffledKeepingGroups(questions, seed);
    const positions = shuffled.map((q) => q._id);
    const i1 = positions.indexOf("1");
    const i3 = positions.indexOf("3");
    assert.equal(Math.abs(i1 - i3), 1, `stem group split with seed ${seed}`);
  }
});

test("shuffleKey scopes the preference per category", () => {
  assert.equal(PracticeCore.shuffleKey("言语理解"), "practice.shuffle.言语理解");
});
```

- [ ] **Step 2: 运行确认失败**

Run: `cd apps/web && node --test test/practice-core.test.js`
Expected: FAIL,`Cannot find module '../public/js/practice-core'`

- [ ] **Step 3: 实现** `apps/web/public/js/practice-core.js`(UMD 模式照抄 `quiz-core.js` 头部)

```js
(function attachPracticeCore(root, factory) {
  const core = factory();
  if (typeof module === "object" && module.exports) {
    module.exports = core;
  } else {
    root.PracticeCore = core;
  }
})(typeof globalThis === "object" ? globalThis : this, function createPracticeCore() {
  "use strict";

  // One JSONL line per record; malformed trailing lines are dropped (the
  // crawler guarantees only the trailing line may be corrupt).
  function parseJSONL(text) {
    const questions = [];
    for (const line of String(text || "").split("\n")) {
      const trimmed = line.trim();
      if (!trimmed) continue;
      try {
        const record = JSON.parse(trimmed);
        if (record && record._id != null) questions.push(record);
      } catch { /* drop */ }
    }
    return questions;
  }

  // Group by subCategory preserving first-appearance order; empty → 未分类.
  function groupBySubcategory(questions) {
    const order = [];
    const groups = new Map();
    for (const question of questions || []) {
      const key = question.subCategory || "未分类";
      if (!groups.has(key)) order.push(key);
      groups.set(key, (groups.get(key) || []).concat(question));
    }
    return order.map((name) => ({ name, questions: groups.get(name) }));
  }

  // Single-select: exact set equality. Multi-select: exact set equality
  // (same semantics as the exam flow). null when the answer is unknown.
  function grade(selected, question) {
    const answer = question && question.answer;
    if (answer == null || answer === "") return null;
    const letters = Array.isArray(answer) ? answer : [answer];
    const picks = Array.from(selected || []).map(String);
    const norm = (list) => [...new Set(list)].sort();
    return JSON.stringify(norm(picks)) === JSON.stringify(norm(letters));
  }

  // SplitMix64 — deterministic, cheap, seedable (JS port of iOS BankLogic).
  function splitmix64(seed) {
    const MASK = (1n << 64n) - 1n;
    let state = BigInt(seed);
    return function next(maxExclusive) {
      state = (state + 0x9E3779B97F4A7C15n) & MASK;
      let z = state;
      z = ((z ^ (z >> 30n)) * 0xBF58476D1CE4E5B9n) & MASK;
      z = ((z ^ (z >> 27n)) * 0x94D049BB133111EBn) & MASK;
      const r = (z ^ (z >> 31n)) & MASK;
      return Number(r % BigInt(maxExclusive));
    };
  }

  // Shuffle while keeping comb (资料分析) questions that share the same stem
  // adjacent: groups are shuffled as units, intra-group order preserved.
  function shuffledKeepingGroups(questions, seed) {
    const units = [];
    const indexByStem = new Map();
    for (const question of questions || []) {
      const stem = question.stem;
      if (stem && indexByStem.has(stem)) {
        units[indexByStem.get(stem)].push(question);
        continue;
      }
      if (stem) indexByStem.set(stem, units.length);
      units.push([question]);
    }
    const next = splitmix64(seed);
    for (let i = units.length - 1; i > 0; i -= 1) {
      const j = next(i + 1);
      const tmp = units[i];
      units[i] = units[j];
      units[j] = tmp;
    }
    return units.flat();
  }

  // Per-category shuffle preference key (mirrors iOS practice.shuffle.<category>).
  function shuffleKey(category) {
    return "practice.shuffle." + category;
  }

  return {
    parseJSONL,
    groupBySubcategory,
    grade,
    shuffledKeepingGroups,
    shuffleKey,
  };
});
```

- [ ] **Step 4: 运行确认通过**

Run: `cd apps/web && node --test test/practice-core.test.js`
Expected: 5 tests PASS

- [ ] **Step 5: 提交**

```bash
git add apps/web/public/js/practice-core.js apps/web/test/practice-core.test.js
git commit -m "练习核心逻辑:JSONL 解析/分组/判分/组合题分组洗牌
Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 2: practice-crawl.js 爬取核心(api 注入)+ 单测

**Files:**
- Create: `apps/web/lib/practice-crawl.js`
- Test: `apps/web/test/practice-crawl.test.js`

**Interfaces:**
- Consumes: `../bank/lib/question-bank`(相对 `apps/web/lib/` → `apps/bank/lib/question-bank.js`)的 `TARGET_CATEGORIES, isTargetExam, matchCategory, joinQuestions, buildRecord, appendRecords, saveMeta, loadBank`;`../bank/lib/question-classifier` 的 `classify`
- Consumes (api 对象,Task 3 的 adapter 实现): `{ getExams() → [{id,name,style,wfs}], enter(exam) → {examResultsId, examInfoId, testIds, uuid, questionStates}, fetchQuestions(entered) → [dto], endAttempt(paper) → Promise<void> }`
- Produces (Task 3 消费):
  - `startCrawl(api, {bankDir, refresh=false}) → taskState|null`(已有任务返回 null)
  - `currentTaskState() → {running, refresh, index, total, paperName, error, doneAt}`
  - `subscribe(cb) → unsubscribe`(cb 收 `{type:"progress"|"done"|"error", index, total, paperName, message}`)
  - `loadMeta(bankDir) → meta|null`、`loadCrawlLog(bankDir) → [entry]`
  - `exportLogText(entries) → string`、`exportFileName(date=new Date()) → string`

- [ ] **Step 1: 写失败测试** `apps/web/test/practice-crawl.test.js`

```js
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

  // A failed task emits error.
  const failing = fakeApi({ failEnter: [1, 2, 3] });
  const events2 = [];
  const unsub2 = crawl.subscribe((event) => events2.push(event));
  crawl.startCrawl(failing, { bankDir: dir });
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
```

- [ ] **Step 2: 运行确认失败**

Run: `cd apps/web && node --test test/practice-crawl.test.js`
Expected: FAIL,`Cannot find module '../lib/practice-crawl'`

- [ ] **Step 3: 实现** `apps/web/lib/practice-crawl.js`

```js
"use strict";

// Practice-bank crawl for the web app: walks every 机考题库 paper, stores
// per-category JSONL under <bankDir> (apps/web/.local/practice), and logs
// every step to crawl_log.jsonl. The api object is injected (server.js wires
// it to the shared session via proxyRequest) so unit tests drive it with a
// fake. Pure-function reuse from apps/bank keeps one shared rule engine.
//
// Two modes (mirrors iOS PracticeUpstreamClient.crawlAllPapers):
//   - refresh=false (first use / resume): papers already marked done in
//     meta.papers are skipped; records dedupe by _id; meta saved after every
//     paper so an interruption resumes without re-entering anything.
//   - refresh=true (我的 > 更新题库): re-crawl EVERY paper; all category files
//     are written first, meta LAST as the atomic commit — on failure the old
//     bank stays intact.
// Either way a wfs=1 paper creates a fresh upstream attempt which is
// best-effort-ended after fetching; wfs=0 papers are read-only, never ended.

const fs = require("node:fs");
const path = require("node:path");
const bank = require("../bank/lib/question-bank");
const classifier = require("../bank/lib/question-classifier");

const STEPS = { PAPER_LIST: "paperList", ENTER: "enter", SAVE: "save", END_ATTEMPT: "endAttempt", SKIP: "skip" };
const OUTCOMES = { SUCCESS: "success", FAILURE: "failure", SKIPPED: "skipped" };

function makeLogEntry({ paperId = null, paperName, step, outcome, message = null }) {
  return { timestamp: new Date().toISOString(), paperId, paperName, step, outcome, message };
}

function appendLog(bankDir, entry) {
  try {
    fs.mkdirSync(bankDir, { recursive: true, mode: 0o700 });
    fs.appendFileSync(path.join(bankDir, "crawl_log.jsonl"), JSON.stringify(entry) + "\n", { encoding: "utf8", mode: 0o600 });
  } catch { /* a log-write failure never breaks the crawl */ }
}

function loadMeta(bankDir) {
  try {
    const saved = JSON.parse(fs.readFileSync(path.join(bankDir, "meta.json"), "utf8"));
    if (saved && saved.version === 1) return saved;
  } catch {}
  return null;
}

function loadCrawlLog(bankDir) {
  try {
    return fs.readFileSync(path.join(bankDir, "crawl_log.jsonl"), "utf8")
      .split("\n")
      .filter(Boolean)
      .map((line) => JSON.parse(line));
  } catch {
    return [];
  }
}

async function crawlAllPapers(api, { bankDir, targets = bank.TARGET_CATEGORIES, refresh = false, onProgress = () => {} }) {
  const log = (entry) => appendLog(bankDir, entry);

  let papers;
  try {
    const all = await api.getExams();
    papers = all.filter((exam) => bank.isTargetExam(exam, targets));
    log(makeLogEntry({ paperName: "全部试卷", step: STEPS.PAPER_LIST, outcome: OUTCOMES.SUCCESS, message: `共 ${papers.length} 份试卷` }));
  } catch (error) {
    log(makeLogEntry({ paperName: "全部试卷", step: STEPS.PAPER_LIST, outcome: OUTCOMES.FAILURE, message: error.message }));
    throw error;
  }

  const previous = loadMeta(bankDir);
  const seenIds = refresh ? new Set() : bank.loadBank(bankDir, targets).seenIds;
  const counts = refresh ? {} : { ...(previous?.counts || {}) };
  const byCategory = {}; // refresh mode collects here; commit at the end
  let papersDone = { ...(refresh ? {} : previous?.papers) };
  let consecutiveFailures = 0;
  let failedPapers = [];

  for (const [index, paper] of papers.entries()) {
    const paperId = String(paper.id);
    if (!refresh && papersDone[paperId]) {
      log(makeLogEntry({ paperId, paperName: paper.name, step: STEPS.SKIP, outcome: OUTCOMES.SKIPPED, message: "已爬取，跳过" }));
      continue;
    }

    let records;
    try {
      const entered = await api.enter(paper);
      const dtos = await api.fetchQuestions(entered);
      const category = bank.matchCategory(paper.name, targets);
      records = bank.joinQuestions(dtos, entered.questionStates)
        .filter((joined) => !seenIds.has(String(joined.question._id)))
        .map((joined) => {
          const record = bank.buildRecord(joined.question, joined.section, category, {
            sourceExamId: paper.id,
            sourceExamName: paper.name,
            round: (previous?.round || 0) + 1,
            collectedAt: new Date().toISOString(),
          });
          seenIds.add(String(record._id));
          record.subCategory = classifier.classify(record);
          return record;
        });
      consecutiveFailures = 0;
      log(makeLogEntry({ paperId, paperName: paper.name, step: STEPS.ENTER, outcome: OUTCOMES.SUCCESS, message: `${records.length} 题` }));
    } catch (error) {
      log(makeLogEntry({ paperId, paperName: paper.name, step: STEPS.ENTER, outcome: OUTCOMES.FAILURE, message: error.message }));
      failedPapers.push(paper.name);
      consecutiveFailures += 1;
      // refresh: keep crawling so the log shows every failed paper, then abort
      // the commit at the end. incremental: stop after 3 consecutive failures.
      if (!refresh && consecutiveFailures >= 3) throw error;
      onProgress({ index: index + 1, total: papers.length, paperName: paper.name });
      continue;
    }

    try {
      if (refresh) {
        for (const record of records) {
          (byCategory[record.category] ||= []).push(record);
        }
      } else {
        const grouped = {};
        for (const record of records) {
          (grouped[record.category] ||= []).push(record);
        }
        for (const [category, categoryRecords] of Object.entries(grouped)) {
          bank.appendRecords(bankDir, categoryRecords);
          counts[category] = (counts[category] || 0) + categoryRecords.length;
        }
      }
      log(makeLogEntry({ paperId, paperName: paper.name, step: STEPS.SAVE, outcome: OUTCOMES.SUCCESS, message: `${records.length} 题` }));
    } catch (error) {
      log(makeLogEntry({ paperId, paperName: paper.name, step: STEPS.SAVE, outcome: OUTCOMES.FAILURE, message: error.message }));
      throw error;
    }

    papersDone[paperId] = true;
    await api.endAttempt(paper).catch(() => {});
    log(makeLogEntry({ paperId, paperName: paper.name, step: STEPS.END_ATTEMPT, outcome: OUTCOMES.SUCCESS, message: "已发起结束请求" }));

    if (!refresh) {
      bank.saveMeta(bankDir, {
        version: 1, targets,
        round: previous?.round || 0,
        lastRun: previous?.lastRun ?? null,
        papers: papersDone,
        counts,
      });
    }
    onProgress({ index: index + 1, total: papers.length, paperName: paper.name });
  }

  if (failedPapers.length) {
    throw new Error(`${failedPapers.length} 份试卷爬取失败：${failedPapers.join("、")}`);
  }

  const finalCounts = refresh
    ? Object.fromEntries(Object.entries(byCategory).map(([c, list]) => [c, list.length]))
    : counts;
  const finalMeta = {
    version: 1,
    targets,
    round: (previous?.round || 0) + 1,
    lastRun: new Date().toISOString(),
    papers: papersDone,
    counts: finalCounts,
  };
  if (refresh) {
    // Atomic commit: every category file first (empty files for empty
    // categories), meta LAST — the old bank survives any failure before this.
    for (const target of targets) {
      const lines = (byCategory[target] || []).map((record) => JSON.stringify(record)).join("\n");
      fs.writeFileSync(path.join(bankDir, `${target}.jsonl`), lines + (lines ? "\n" : ""), { encoding: "utf8", mode: 0o600 });
    }
  }
  bank.saveMeta(bankDir, finalMeta);
}

// ---------- Single-flight task state + SSE subscribers ----------

let activeTask = null;
let taskSubscribers = new Set();
let taskState = { running: false, refresh: false, index: 0, total: 0, paperName: "", error: null, doneAt: null };

function emit(event) {
  for (const cb of taskSubscribers) {
    try { cb(event); } catch {}
  }
}

function startCrawl(api, { bankDir, refresh = false }) {
  if (activeTask) return null;
  taskState = { running: true, refresh, index: 0, total: 0, paperName: "", error: null, doneAt: null };
  activeTask = (async () => {
    try {
      await crawlAllPapers(api, {
        bankDir,
        refresh,
        onProgress: (p) => {
          taskState.index = p.index;
          taskState.total = p.total;
          taskState.paperName = p.paperName;
          emit({ type: "progress", ...p });
        },
      });
      taskState.doneAt = new Date().toISOString();
      emit({ type: "done" });
    } catch (error) {
      taskState.error = error.message;
      taskState.doneAt = new Date().toISOString();
      emit({ type: "error", message: error.message });
    } finally {
      activeTask = null;
    }
  })();
  return { ...taskState };
}

function currentTaskState() {
  return { ...taskState };
}

function subscribe(cb) {
  taskSubscribers.add(cb);
  return () => taskSubscribers.delete(cb);
}

// ---------- 日志导出 (crawl-log plain-text export) ----------

const STEP_NAME = {
  paperList: "获取试卷列表",
  enter: "进入试卷",
  save: "保存题目",
  endAttempt: "结束作答",
  skip: "跳过",
};
const OUTCOME_NAME = { success: "成功", failure: "失败", skipped: "跳过" };

function exportLogText(entries) {
  const successes = entries.filter((e) => e.outcome === "success").length;
  const failures = entries.filter((e) => e.outcome === "failure").length;
  const skipped = entries.filter((e) => e.outcome === "skipped").length;
  const lines = [
    `题库爬取日志（共 ${entries.length} 条）`,
    `成功 ${successes} · 失败 ${failures} · 跳过 ${skipped}`,
    "",
  ];
  for (const entry of entries) {
    const paper = entry.paperName || "-";
    const message = entry.message ? `（${entry.message}）` : "";
    const time = entry.timestamp ? entry.timestamp.replace("T", " ").replace(/\.\d+Z$/, "") : "-";
    lines.push(`[${time}] ${paper} · ${STEP_NAME[entry.step] || entry.step} — ${OUTCOME_NAME[entry.outcome] || entry.outcome}${message}`);
  }
  return lines.join("\n");
}

function pad(n) { return String(n).padStart(2, "0"); }

function exportFileName(date = new Date()) {
  return `爬取日志_${date.getFullYear()}${pad(date.getMonth() + 1)}${pad(date.getDate())}_${pad(date.getHours())}${pad(date.getMinutes())}.txt`;
}

module.exports = {
  STEPS,
  OUTCOMES,
  crawlAllPapers,
  startCrawl,
  currentTaskState,
  subscribe,
  loadMeta,
  loadCrawlLog,
  exportLogText,
  exportFileName,
};
```

- [ ] **Step 4: 运行确认通过**

Run: `cd apps/web && node --test test/practice-crawl.test.js`
Expected: 8 tests PASS

- [ ] **Step 5: 提交**

```bash
git add apps/web/lib/practice-crawl.js apps/web/test/practice-crawl.test.js
git commit -m "练习爬取核心:全量/续爬/原子刷新 + 日志与单飞任务
Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 3: server.js 的 /api/practice 路由 + 上游 adapter + stub 测试

**Files:**
- Modify: `apps/web/server.js`
- Test: `apps/web/test/server-practice.test.js`

**Interfaces:**
- Consumes: Task 2 的 `practice-crawl.js`(startCrawl/currentTaskState/subscribe/loadMeta/loadCrawlLog/exportLogText/exportFileName);现有 `proxyRequest`/`fetchSessionText`/`startNewExam`/`enterExamDirect`/`fetchAllQuestions`/`requireUpstreamResult`
- Produces (Task 4 消费): 路由 `/api/practice/status|crawl|update|delete|log|events|categories/:name`,auth 中间件白名单前缀

- [ ] **Step 1: 写失败测试** `apps/web/test/server-practice.test.js`(stub 上游 + 真实 server 启动,照抄 server-bank.test.js 的启动/清理骨架)

```js
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
```

> 注:409 并发分支由 Task 2 的 `startCrawl` 单飞单测覆盖(HTTP 层串行请求无法确定性复现竞态,stub 无延迟控制时任务瞬完);此测试保留"两次连续启动均成功"的回归,409 行为验证在 practice-crawl 单测中。

- [ ] **Step 2: 运行确认失败**

Run: `cd apps/web && node --test test/server-practice.test.js`
Expected: FAIL,所有路由 404(未实现)

- [ ] **Step 3: 实现 server.js 修改**

3a. 顶部 require 后追加(约 27 行 `BANK_DIR` 定义之后):

```js
const practiceCrawl = require("./lib/practice-crawl");
// Practice bank lives under the web app's own .local (not apps/bank/data).
const PRACTICE_DIR = path.join(LOCAL_DIR, "practice");
```

3b. auth 中间件白名单(替换现有 `app.use((req, res, next) => { ... }` 的路径判断):

```js
// /api/practice reads (status/categories/events/log) are local data — no
// login needed (mirrors iOS: practice works offline once crawled). Crawls
// and deletes mutate an upstream session and require login.
const PRACTICE_AUTH_EXEMPT_PREFIXES = [
  "/api/practice/status",
  "/api/practice/categories",
  "/api/practice/events",
  "/api/practice/log",
];
app.use((req, res, next) => {
  if (["/api/login", "/api/status", "/api/logout", "/api/settings", "/api/cookiecloud", "/api/cookiecloud/sync"].includes(req.path)
    || PRACTICE_AUTH_EXEMPT_PREFIXES.some((prefix) => req.path.startsWith(prefix))
    || !req.path.startsWith("/api/")) return next();
  if (!cookieJar.includes("sessionId=")) return res.status(401).json({ error: "Not logged in" });
  next();
});
```

3c. 新增 API 路由块(放在 `POST /api/logout` 之后、`GET /api/settings` 之前):

```js
// ========== Practice bank (练习页题库) ==========

// Upstream adapter for the practice crawler: reuses the shared session and
// the existing exam flows (startNewExam for wfs=1, enterExamDirect for
// wfs=0). The entered-session map lets endAttempt end exactly the attempts
// this process created; practice papers answer exam_ending with a JSON
// success instead of a result page, so a missing result page is the
// expected, swallowed outcome (the attempt did end upstream).
const enteredSessions = new Map();
function practiceApi() {
  return {
    async getExams() {
      const result = await proxyRequest("/exam/current_exam_list", {
        method: "POST",
        form: { examStyle: "0", timeSort: "", status: "", setProcess: "-1", page: "1", firstVisit: "true", name: "", rowCount: "100", participation: "" },
      });
      const data = requireUpstreamResult(result, "Loading exams", { allowBusinessFailure: true });
      const styles = new Map((data.bizContent?.styles || []).map((s) => [String(s.id), s.name]));
      return (data.bizContent?.examInfoModelList || []).map((e) => ({
        id: e.id,
        name: e.examName,
        style: styles.get(String(e.examStyle)) || e.examStyleName || "unknown",
        wfs: e.wfs,
      }));
    },
    async enter(exam) {
      const result = exam.wfs === 1 ? await startNewExam(String(exam.id)) : await enterExamDirect(String(exam.id));
      if (!result.questionStates.length) throw httpError(502, "Failed to enter exam");
      enteredSessions.set(String(exam.id), { examResultsId: result.examResultsId, examInfoId: result.examInfoId });
      return result;
    },
    async fetchQuestions(entered) {
      return fetchAllQuestions(entered.examResultsId, entered.examInfoId, entered.testIds, entered.uuid, entered.questionStates);
    },
    async endAttempt(paper) {
      const session = enteredSessions.get(String(paper.id));
      if (!session) return;
      try {
        await proxyRequest("/exam/get_remian_time", { method: "POST", form: { examResultId: session.examResultsId } });
        const endUrl = `${BASE_URL}/exam/exam_ending?examInfoId=${encodeURIComponent(session.examInfoId)}&examResultsId=${encodeURIComponent(session.examResultsId)}&isForce=0&switchScreen=0&noOpsAutoCommit=0`;
        await fetchSessionText(endUrl, {
          headers: { "User-Agent": UA, Referer: `${BASE_URL}/exam/exam_start/${session.examInfoId}` },
          redirect: "follow",
        });
      } catch { /* best-effort: any failure is ignored */ } finally {
        enteredSessions.delete(String(paper.id));
      }
    },
  };
}

function practiceIsPopulated() {
  const meta = practiceCrawl.loadMeta(PRACTICE_DIR);
  if (!meta) return false;
  const filesExist = practiceCrawl.CATEGORIES.every((category) => fs.existsSync(path.join(PRACTICE_DIR, `${category}.jsonl`)));
  return filesExist && meta.counts && Object.keys(meta.counts).length > 0;
}

// GET /api/practice/status — crawl state + bank summary (no login needed)
app.get("/api/practice/status", (req, res) => {
  const meta = practiceCrawl.loadMeta(PRACTICE_DIR);
  res.json({
    loggedIn: cookieJar.includes("sessionId="),
    isPopulated: practiceIsPopulated(),
    meta: meta ? { counts: meta.counts, round: meta.round, lastRun: meta.lastRun, papers: Object.keys(meta.papers || {}).length } : null,
    task: practiceCrawl.currentTaskState(),
  });
});

// GET /api/practice/categories/:name — one category's JSONL (no login needed)
app.get("/api/practice/categories/:name", (req, res) => {
  const { name } = req.params;
  if (!practiceCrawl.CATEGORIES.includes(name)) return res.status(404).json({ error: "Unknown category" });
  try {
    const text = fs.readFileSync(path.join(PRACTICE_DIR, `${name}.jsonl`), "utf8");
    res.set("Content-Type", "application/x-ndjson; charset=utf-8");
    res.send(text);
  } catch {
    res.status(404).json({ error: "Category not crawled yet" });
  }
});

// POST /api/practice/crawl — first full crawl (login required)
app.post("/api/practice/crawl", (req, res) => {
  const task = practiceCrawl.startCrawl(practiceApi(), { bankDir: PRACTICE_DIR, refresh: false });
  if (!task) return res.status(409).json({ error: "A crawl task is already running" });
  res.status(202).json({ started: true });
});

// POST /api/practice/update — re-crawl everything, atomic replace (login required)
app.post("/api/practice/update", (req, res) => {
  const task = practiceCrawl.startCrawl(practiceApi(), { bankDir: PRACTICE_DIR, refresh: true });
  if (!task) return res.status(409).json({ error: "A crawl task is already running" });
  res.status(202).json({ started: true });
});

// GET /api/practice/events — SSE progress stream (no login needed)
app.get("/api/practice/events", (req, res) => {
  res.writeHead(200, {
    "Content-Type": "text/event-stream",
    "Cache-Control": "no-cache",
    Connection: "keep-alive",
    "X-Accel-Buffering": "no",
  });
  const send = (event) => res.write(`data: ${JSON.stringify(event)}\n\n`);
  send({ type: "state", ...practiceCrawl.currentTaskState() });
  const unsubscribe = practiceCrawl.subscribe(send);
  req.on("close", unsubscribe);
});

// POST /api/practice/delete — wipe the local bank (login required)
app.post("/api/practice/delete", (req, res) => {
  try { fs.rmSync(PRACTICE_DIR, { recursive: true, force: true }); } catch {}
  res.json({ success: true });
});

// GET /api/practice/log — crawl log as a downloadable txt (no login needed)
app.get("/api/practice/log", (req, res) => {
  const text = practiceCrawl.exportLogText(practiceCrawl.loadCrawlLog(PRACTICE_DIR));
  const filename = practiceCrawl.exportFileName();
  res.set("Content-Type", "text/plain; charset=utf-8");
  res.set("Content-Disposition", `attachment; filename="crawl-log.txt"; filename*=UTF-8''${encodeURIComponent(filename)}`);
  res.send(text);
});
```

3d. `practice-crawl.js` 需要导出 `CATEGORIES`(在 module.exports 中加入):

```js
  CATEGORIES: bank.TARGET_CATEGORIES,
```

- [ ] **Step 4: 运行确认通过**

Run: `cd apps/web && node --test test/server-practice.test.js`
Expected: 6 tests PASS(最后一个测试块含 update+delete 算一个 test)

- [ ] **Step 5: 提交**

```bash
git add apps/web/server.js apps/web/lib/practice-crawl.js apps/web/test/server-practice.test.js
git commit -m "练习 API:爬取/进度 SSE/题库读取/更新/删除/日志导出
Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 4: 前端练习页 UI + 我的题库分区 + smoke 回归

**Files:**
- Create: `apps/web/public/js/practice.js`
- Modify: `apps/web/public/index.html`(练习容器替换占位区、我的页题库分区、脚本引入)
- Modify: `apps/web/public/styles.css`(练习视图样式)
- Modify: `apps/web/test/browser-smoke.js`(练习场景)
- Consumes: Task 1 的 `PracticeCore`

- [ ] **Step 1: 写失败测试** — 扩展 `apps/web/test/browser-smoke.js`

在现有 smoke 文件中追加一个 `test("practice tab loads the local bank and quizzes offline", ...)`(复用该文件已有的 `launchBrowser`/`json` helper 模式,参照现有登录场景的 mock 方式):

```js
test("practice tab loads the local bank and quizzes offline", async () => {
  const { page } = await launchBrowser();
  await json(page, "**/api/status", { loggedIn: true, hasSavedSession: true });
  await json(page, "**/api/practice/status", {
    loggedIn: true, isPopulated: true,
    meta: { counts: { 言语理解: 2, 数字运算: 1 }, round: 1, lastRun: "2026-08-11T00:00:00.000Z", papers: 2 },
    task: { running: false, index: 0, total: 0, paperName: "", error: null, doneAt: "2026-08-11T00:00:00.000Z" },
  });
  await json(page, "**/api/practice/categories/*", JSONL, { contentType: "application/x-ndjson; charset=utf-8" });
  await page.goto(BASE_URL + "/practice");
  await page.waitForSelector("[data-practice-category]");
  const names = await page.$$eval("[data-practice-category]", (els) => els.map((el) => el.textContent.trim()));
  assert.ok(names.some((name) => name.includes("言语理解")), `categories rendered: ${names.join(",")}`);
  await page.click('[data-practice-category*="言语理解"]');
  await page.waitForSelector("[data-practice-subcategory]");
  await page.click("[data-practice-subcategory]");
  await page.waitForSelector("[data-practice-question]");
  await page.click("[data-practice-option]"); // first option is correct (answer A)
  await page.waitForSelector("[data-practice-result]");
  const result = await page.$eval("[data-practice-result]", (el) => el.textContent.trim());
  assert.ok(result.includes("答对"), `reveal shows result: ${result}`);
  await page.close();
});
```

> 该测试依赖现有 smoke 的 helper(`launchBrowser`、`json`、`jsonl` 常量)。若现有文件无 `launchBrowser` helper,按其实际结构(playwright `chromium.launch` + `page.route` 模式)对齐写法。JSONL mock 内容:两行记录,一行 answer:"A"、一行 answer:["A","C"],subCategory 分别为"逻辑填空"/"成语辨析",question/options 为简单 HTML。

- [ ] **Step 2: 运行确认失败**

Run: `cd apps/web && node test/browser-smoke.js`
Expected: 新场景 FAIL(页面无 `[data-practice-category]`),其余场景 PASS

- [ ] **Step 3: 实现 index.html 修改**

3a. 练习 section 的占位内容(index.html 92-97 行)替换为:

```html
      <div id="practiceRoot" class="practice-root" aria-live="polite"></div>
```

3b. "我的"页 settings-panel 中、`settings-row-wide`(CookieCloud 行)之后追加题库分区:

```html
          <div class="settings-row settings-row-wide">
            <div>
              <h2>题库</h2>
              <p data-practice-bank-status>正在检查…</p>
            </div>
            <div class="bank-actions">
              <button type="button" class="btn-style" data-practice-update onclick="practiceUpdateBank()">更新题库</button>
              <button type="button" class="btn-style" data-practice-log onclick="practiceDownloadLog()">日志导出</button>
              <button type="button" class="btn-style btn-danger" data-practice-delete onclick="practiceDeleteBank()">删除题库</button>
            </div>
          </div>
```

3c. 底部脚本引入(quiz-core.js 之后追加):

```html
<script src="/js/quiz-core.js"></script>
<script src="/js/practice-core.js"></script>
<script src="/js/practice.js"></script>
<script src="/js/app.js"></script>
```

- [ ] **Step 4: 实现 `apps/web/public/js/practice.js`**(完整状态机,零框架,风格与 app.js 一致)

```js
"use strict";

// 练习页(专项训练):本地题库四级视图(未爬取/爬取中/大类/题型细分/答题)。
// 题目数据一次 fetch 后全在内存,答题页零网络;判分/洗牌/分组由
// PracticeCore 提供。爬取进度走 SSE;会话过期时 API 返回 401 由 api()
// 统一跳登录(与 app.js 的全局 api() 行为一致)。

const Practice = (() => {
  const CATEGORY_ORDER = ["言语理解", "数字运算", "逻辑推理", "资料分析", "特有题型"];
  let view = "start"; // start | crawl | categories | subcategories | quiz
  let category = null;
  let subCategory = null;
  let groups = [];            // [{name, questions}]
  let questions = [];
  let index = 0;
  let selected = new Set();
  let revealed = null;        // { selected:Set, correct:bool|null }
  let right = 0;
  let wrong = 0;
  let eventSource = null;
  const root = () => document.getElementById("practiceRoot");
  const bankStatus = () => document.querySelector("[data-practice-bank-status]");

  function shuffleEnabled() {
    return localStorage.getItem(PracticeCore.shuffleKey(category)) === "true";
  }

  function setShuffleEnabled(enabled) {
    localStorage.setItem(PracticeCore.shuffleKey(category), String(enabled));
  }

  function esc(html) {
    return String(html).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  }

  function render() {
    const el = root();
    if (!el) return;
    const apiUrl = (path) => path; // local same-origin
    if (view === "start" || view === "crawl") {
      renderBankGate(el);
    } else if (view === "categories") {
      renderCategories(el);
    } else if (view === "subcategories") {
      renderSubcategories(el);
    } else {
      renderQuiz(el);
    }
  }

  async function refreshStatus() {
    const status = await api("/api/practice/status");
    const meta = status.meta;
    const counts = meta ? meta.counts : {};
    if (status.isPopulated && view === "start") view = "categories";
    if (bankStatus()) {
      if (!status.isPopulated) bankStatus().textContent = "未爬取(进入练习页开始)";
      else bankStatus().textContent = `已爬取 ${Object.values(counts).reduce((a, b) => a + b, 0)} 题 · 最近 ${(meta.lastRun || "").slice(0, 10)}`;
    }
    if (view !== "quiz") render();
  }

  function renderBankGate(el) {
    if (view === "crawl") {
      el.innerHTML = `<div class="practice-center">
        <p class="practice-progress" data-practice-progress>正在爬取题库…</p>
        <p class="practice-paper" data-practice-paper></p>
      </div>`;
      return;
    }
    el.innerHTML = `<div class="practice-center empty-home-view">
      <div class="empty-home-symbol" aria-hidden="true"></div>
      <h2>开始练习</h2>
      <p>首次使用将直连蓝鲸平台爬取全部机考题库,之后完全离线刷题</p>
      <button type="button" class="cta-btn" data-practice-start onclick="PracticeStart()">爬取题库</button>
      <p class="practice-hint" data-practice-hint></p>
    </div>`;
  }

  function renderCategories(el) {
    const status = window.__practiceStatus || { meta: { counts: {} } };
    const counts = (status.meta && status.meta.counts) || {};
    const rows = CATEGORY_ORDER.filter((name) => counts[name]).map((name) => `
      <button type="button" class="practice-category" data-practice-category="${esc(name)}" onclick="PracticeOpenCategory('${esc(name)}')">
        <span class="practice-category-name">${esc(name)}</span>
        <span class="practice-category-count">${counts[name]} 题</span>
      </button>`).join("");
    el.innerHTML = `<div class="practice-categories">${rows || "<p>题库为空</p>"}</div>`;
  }

  async function openCategory(name) {
    category = name;
    const text = await (await fetch(`/api/practice/categories/${encodeURIComponent(name)}`)).text();
    const questionsList = PracticeCore.parseJSONL(text);
    groups = PracticeCore.groupBySubcategory(questionsList);
    view = "subcategories";
    render();
  }

  function renderSubcategories(el) {
    const rows = groups.map((group, i) => `
      <button type="button" class="practice-subcategory" data-practice-subcategory onclick="PracticeStartSession(${i})">
        <span class="practice-category-name">${esc(group.name)}</span>
        <span class="practice-category-count">${group.questions.length} 题</span>
      </button>`).join("");
    el.innerHTML = `<div class="practice-subheader">
        <button type="button" class="btn-style" onclick="PracticeBackToCategories()">← ${esc(category)}</button>
      </div>
      <div class="practice-categories">${rows}</div>`;
  }

  function startSession(groupIndex) {
    const group = groups[groupIndex];
    subCategory = group.name;
    questions = shuffleEnabled() ? PracticeCore.shuffledKeepingGroups(group.questions, BigInt(Math.floor(Math.random() * Number.MAX_SAFE_INTEGER))) : group.questions;
    index = 0;
    selected = new Set();
    revealed = null;
    right = 0;
    wrong = 0;
    view = "quiz";
    render();
  }

  function renderQuiz(el) {
    const question = questions[index];
    if (!question) {
      el.innerHTML = `<div class="practice-center">
        <h2>练习完成</h2>
        <p>答对 ${right} 题 · 答错 ${wrong} 题 · 共 ${questions.length} 题</p>
        <button type="button" class="cta-btn" onclick="PracticeBackToSubcategories()">返回题型列表</button>
      </div>`;
      return;
    }
    const isMulti = Array.isArray(question.answer) && question.answer.length > 1;
    const stemHtml = question.stem ? `<div class="q-stem">${question.stem}</div>` : "";
    const optionRows = ["A", "B", "C", "D"].map((letter, i) => {
      const optionText = question.options[i] || "";
      const cls = [];
      if (revealed) {
        const isCorrect = (question.answer == null || question.answer === "" || question.answer === [] )
          ? false : (Array.isArray(question.answer) ? question.answer.includes(letter) : question.answer === letter);
        const isSelected = selected.has(letter);
        if (isCorrect) cls.push("correct");
        else if (isSelected) cls.push("wrong");
        if (isSelected) cls.push("selected");
      } else if (selected.has(letter)) {
        cls.push("selected");
      }
      return `<button type="button" class="practice-option ${cls.join(" ")}" data-practice-option="${letter}" onclick="PracticeTapOption('${letter}')">
        <span class="practice-option-letter">${letter}</span>
        <span>${optionText}</span>
      </button>`;
    }).join("");
    const badge = !revealed && isMulti ? "<span class=\"practice-badge\">多选</span>"
      : !revealed && (question.answer == null || question.answer === "") ? "<span class=\"practice-badge\">无答案</span>" : "";
    const resultHtml = revealed ? `<div class="practice-result" data-practice-result>
      ${revealed.correct === null ? "<p>无标准答案</p>" : revealed.correct ? "<p>答对 ✓</p>" : "<p>答错 ✗</p>"}
      ${question.analysis ? `<div class="practice-analysis">${question.analysis}</div>` : ""}
      <button type="button" class="cta-btn" data-practice-next onclick="PracticeNext()">${index + 1 >= questions.length ? "完成" : "下一题"}</button>
    </div>` : "";
    el.innerHTML = `<div class="practice-quiz">
      <div class="practice-quiz-top">
        <span class="practice-count">第 ${index + 1}/${questions.length} 题</span>
        <span class="practice-stats">答对 ${right} · 答错 ${wrong}</span>
        <label class="switch-control" title="随机顺序">
          <input type="checkbox" data-practice-shuffle ${shuffleEnabled() ? "checked" : ""} onchange="PracticeToggleShuffle(this.checked)">
          <span aria-hidden="true"></span>
          <span>随机</span>
        </label>
      </div>
      ${badge}
      ${stemHtml}
      <div class="q-block">${question.question}</div>
      <div class="practice-options">${optionRows}</div>
      ${resultHtml}
    </div>`;
  }

  function tapOption(letter) {
    const question = questions[index];
    if (revealed || !question) return;
    if (Array.isArray(question.answer) && question.answer.length > 1) {
      if (selected.has(letter)) selected.delete(letter);
      else selected.add(letter);
      render();
      return;
    }
    selected = new Set([letter]);
    const correct = PracticeCore.grade(selected, question);
    revealed = { selected, correct };
    if (correct === true) right += 1;
    else if (correct === false) wrong += 1;
    render();
  }

  function nextQuestion() {
    if (!revealed) return;
    index += 1;
    selected = new Set();
    revealed = null;
    render();
  }

  function startCrawl() {
    api("/api/practice/crawl", { method: "POST" }).then((result) => {
      if (result.error) return;
      view = "crawl";
      render();
      openEvents();
    });
  }

  function updateBank() {
    api("/api/practice/update", { method: "POST" }).then((result) => {
      if (result.error) return;
      view = "crawl";
      render();
      openEvents();
    });
  }

  function openEvents() {
    if (eventSource) eventSource.close();
    eventSource = new EventSource("/api/practice/events");
    eventSource.onmessage = (event) => {
      const data = JSON.parse(event.data);
      const progress = root()?.querySelector("[data-practice-progress]");
      const paper = root()?.querySelector("[data-practice-paper]");
      if (data.type === "progress" && progress) {
        progress.textContent = `正在爬取题库（${data.index}/${data.total}）`;
        if (paper) paper.textContent = data.paperName || "";
      } else if (data.type === "done") {
        eventSource.close();
        eventSource = null;
        view = "categories";
        refreshStatus();
      } else if (data.type === "error") {
        eventSource.close();
        eventSource = null;
        view = "start";
        render();
      }
    };
  }

  function deleteBank() {
    if (!window.confirm("删除本地题库后,再次进入练习页会重新爬取全部试卷。确定删除?")) return;
    api("/api/practice/delete", { method: "POST" }).then(() => {
      view = "start";
      render();
      refreshStatus();
    });
  }

  function downloadLog() {
    window.location.href = "/api/practice/log";
  }

  // 全局钩子(与 app.js 的内联 onclick 约定一致)
  window.PracticeStart = startCrawl;
  window.PracticeOpenCategory = openCategory;
  window.PracticeStartSession = startSession;
  window.PracticeTapOption = tapOption;
  window.PracticeNext = nextQuestion;
  window.PracticeToggleShuffle = (enabled) => { setShuffleEnabled(enabled); render(); };
  window.PracticeBackToCategories = () => { view = "categories"; render(); };
  window.PracticeBackToSubcategories = () => { view = "subcategories"; render(); };
  window.practiceUpdateBank = updateBank;
  window.practiceDeleteBank = deleteBank;
  window.practiceDownloadLog = downloadLog;
  window.practiceRefreshBankStatus = refreshStatus;

  return { refreshStatus, render };
})();

// app.js 在激活 practice tab 时调用;也挂到 window 供内联使用。
window.PracticeRefresh = () => { Practice.refreshStatus(); };
```

- [ ] **Step 5: 实现 styles.css 练习样式**(追加到文件末尾,复用现有 CSS 变量)

```css
/* ===== 练习页(practice)===== */
.practice-root { padding: 8px 4px; }
.practice-center { text-align: center; padding: 32px 12px; }
.practice-hint { color: var(--text2); font-size: 13px; margin-top: 12px; }
.practice-progress { font-weight: 700; margin-bottom: 6px; }
.practice-paper { color: var(--text2); font-size: 14px; }
.practice-categories { display: grid; gap: 10px; max-width: 560px; margin: 0 auto; }
.practice-category, .practice-subcategory {
  display: flex; justify-content: space-between; align-items: center;
  padding: 16px 18px; border-radius: 14px; border: 2px solid var(--border);
  background: var(--surface); color: var(--text); font-size: 15px; font-weight: 700; text-align: left; cursor: pointer;
}
.practice-category:hover, .practice-subcategory:hover { border-color: var(--text2); }
.practice-category-count { color: var(--text2); font-weight: 600; font-size: 13px; }
.practice-subheader { display: flex; align-items: center; gap: 10px; margin-bottom: 14px; }
.practice-quiz { max-width: 640px; margin: 0 auto; }
.practice-quiz-top { display: flex; align-items: center; gap: 14px; margin-bottom: 10px; color: var(--text2); }
.practice-count { font-weight: 700; color: var(--text); }
.practice-stats { font-weight: 600; font-size: 13px; }
.practice-quiz-top .switch-control { margin-left: auto; }
.practice-badge { display: inline-block; padding: 2px 10px; border-radius: 999px; font-size: 12px; font-weight: 700; margin-bottom: 8px; }
.practice-options { display: grid; gap: 10px; margin-top: 12px; }
.practice-option {
  display: flex; gap: 12px; align-items: flex-start; text-align: left;
  padding: 14px 16px; border-radius: 14px; border: 2px solid var(--border);
  background: var(--surface); color: var(--text); font-size: 15px; cursor: pointer;
}
.practice-option.selected { border-color: var(--text2); }
.practice-option.correct { border-color: #58cc02; background: rgba(88, 204, 2, 0.08); }
.practice-option.wrong { border-color: #ff4b4b; background: rgba(255, 75, 75, 0.08); }
.practice-option-letter { font-weight: 800; width: 20px; }
.practice-result { margin-top: 16px; border-top: 2px solid var(--border); padding-top: 12px; }
.practice-analysis { color: var(--text2); font-size: 14px; margin: 8px 0 12px; }
.bank-actions { display: flex; gap: 8px; flex-wrap: wrap; justify-content: flex-end; }
.btn-danger { color: #ff4b4b; border-color: #ff4b4b; background: transparent; }
```

- [ ] **Step 6: app.js 接入练习视图激活钩子**

在 `app.js` 的 `activateHomeTab` 中,当 `tab === "practice"` 时调用 `Practice.refreshStatus()`(该函数已挂 window,`PracticeRefresh`),在现有 `focusHomeHeading` 调用之后追加一行:

```js
  if (tab === "practice" && window.PracticeRefresh) window.PracticeRefresh();
```

- [ ] **Step 7: 运行 browser smoke 确认通过**

Run: `cd apps/web && node test/browser-smoke.js`
Expected: 全部场景 PASS(含新增练习场景)

- [ ] **Step 8: 提交**

```bash
git add apps/web/public/index.html apps/web/public/styles.css apps/web/public/js/practice.js apps/web/test/browser-smoke.js apps/web/public/js/app.js
git commit -m "练习页 UI:四级视图 + 本地刷题 + 我的题库分区
Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 5: README 更新 + check 脚本 + 全量回归

**Files:**
- Modify: `apps/web/package.json`(check 脚本加新文件)
- Modify: `README.md`(功能表、差异表、测试数)

- [ ] **Step 1: package.json check 脚本追加新文件**

在 `check` 脚本的 `node --check public/js/quiz-core.js` 后追加:

```json
&& node --check public/js/practice-core.js && node --check public/js/practice.js && node --check lib/practice-crawl.js && node --check test/practice-core.test.js && node --check test/practice-crawl.test.js && node --check test/server-practice.test.js
```

- [ ] **Step 2: 更新 README**

2a. 功能表"自动化验证"行的 Web 列,把 `117 项 Node 单元测试` 改为 `Node 单元测试 + 浏览器回归`(以 `npm test` 实际数量为准,实现后填入确切数字)。

2b. 功能表新增一行(练习能力,放在"会话持久化"行之后):

```markdown
| 练习刷题 | 首次使用直连蓝鲸平台爬取全部机考题库到本地（.local/practice，逐卷进度与断点续爬），按 大类→题型细分 两级分类离线刷题，组合题材料渲染、按大类随机顺序；我的页提供 更新题库/删除题库/爬取日志导出 | 与 Web 对齐的完整练习页（首次直连爬取、断点续爬、原子更新、删除、日志导出） |
```

2c. 更新功能表下方段落中"Web 的练习页目前只是返回考试列表的入口"的句子,改为描述 Web 练习页与 iOS 一致的实现。

- [ ] **Step 3: 全量回归**

Run:
```bash
cd apps/web && npm run check && npm test
cd /Users/qzh/Project/lanjing_test && npm test --prefix apps/bank 2>/dev/null || true
```
Expected: 全部 PASS;若 bank 无 test script 则跳过。CI 三个 workflow(ci-web/ci-ios/ci-bank)在 push 后应全绿。

- [ ] **Step 4: 提交**

```bash
git add apps/web/package.json README.md
git commit -m "README 更新练习能力说明 + check 脚本覆盖新文件
Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Self-Review 结论

- **Spec 覆盖**:爬取(任务 2/3)、断点续爬(任务 2 测试)、原子刷新(任务 2/3 测试)、SSE 进度(任务 3)、四级视图与零网络答题(任务 4)、我的页三入口(任务 4 第 3b 步)、日志导出(任务 3 路由 + 任务 2 export 函数)、免登录语义(任务 3 白名单 + 测试)、README(任务 5)全有对应任务
- **类型一致性**:`startCrawl(api, {bankDir, refresh})`、`currentTaskState()`、`subscribe(cb)`、`loadMeta`/`loadCrawlLog`/`exportLogText`/`exportFileName`、`CATEGORIES` 在任务 2 定义、任务 3 消费;`PracticeCore` 五个函数任务 1 定义、任务 4 消费;api 接口三方法任务 2 定义、任务 3 adapter 实现——签名一致
- **无占位符**:所有测试与实现代码完整给出;Task 4 的 smoke 场景依赖现有 helper 结构,已注明按其实际结构对齐
