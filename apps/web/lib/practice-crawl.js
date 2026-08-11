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
const bank = require("../../bank/lib/question-bank");
const classifier = require("../../bank/lib/question-classifier");

const STEPS = { PAPER_LIST: "paperList", ENTER: "enter", SAVE: "save", END_ATTEMPT: "endAttempt", SKIP: "skip" };
const OUTCOMES = { SUCCESS: "success", FAILURE: "failure", SKIPPED: "skipped" };

// The upstream emits the correct option as a key1..key4 flag ("1" = correct);
// bank.buildRecord reads a normalized `_answers` letter array instead (mirrors
// the bank CLI's upstream.js). Idempotent: keeps an existing _answers.
const ANSWER_KEYS = { key1: "A", key2: "B", key3: "C", key4: "D" };

function withAnswerLetters(dto) {
  if (!dto || typeof dto !== "object") return dto;
  if (Array.isArray(dto._answers) && dto._answers.length) return dto;
  const letters = [];
  for (const [key, letter] of Object.entries(ANSWER_KEYS)) {
    if (String(dto[key]) === "1") letters.push(letter);
  }
  if (letters.length) dto._answers = letters;
  return dto;
}

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
  // Non-refresh dedupes against the stored bank (and accumulates across papers
  // in this run). Refresh rebuilds every file from scratch, so each paper gets
  // a fresh per-paper set — cross-paper dedupe would drop legitimate repeats.
  const bankSeenIds = refresh ? null : bank.loadBank(bankDir, targets).seenIds;
  const counts = refresh ? {} : { ...(previous?.counts || {}) };
  const byCategory = {}; // refresh mode collects here; commit at the end
  let papersDone = { ...(refresh ? {} : previous?.papers) };
  let crawledAny = false;
  let consecutiveFailures = 0;
  let failedPapers = [];

  for (const [index, paper] of papers.entries()) {
    const paperId = String(paper.id);
    if (!refresh && papersDone[paperId]) {
      log(makeLogEntry({ paperId, paperName: paper.name, step: STEPS.SKIP, outcome: OUTCOMES.SKIPPED, message: "已爬取，跳过" }));
      continue;
    }

    const seenIds = refresh ? new Set() : bankSeenIds;
    let records;
    try {
      const entered = await api.enter(paper);
      const dtos = (await api.fetchQuestions(entered)).map(withAnswerLetters);
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
    crawledAny = true;
    // wfs=1 papers create a fresh upstream attempt which is best-effort-ended;
    // wfs=0 papers are the user's own attempts — read-only, never ended.
    if (paper.wfs === 1) {
      await api.endAttempt(paper).catch(() => {});
      log(makeLogEntry({ paperId, paperName: paper.name, step: STEPS.END_ATTEMPT, outcome: OUTCOMES.SUCCESS, message: "已发起结束请求" }));
    }

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
  // A resume that crawled nothing new is not a new round; refresh always is.
  const finalMeta = {
    version: 1,
    targets,
    round: (previous?.round || 0) + (refresh || crawledAny ? 1 : 0),
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
      taskState.running = false;
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
  CATEGORIES: bank.TARGET_CATEGORIES,
  crawlAllPapers,
  startCrawl,
  currentTaskState,
  subscribe,
  loadMeta,
  loadCrawlLog,
  exportLogText,
  exportFileName,
};
