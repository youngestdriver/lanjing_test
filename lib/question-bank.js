"use strict";

// Question-bank collector: enter 机考题库 papers, fetch every question with
// its answer key and 解析, and append deduplicated records to per-category
// JSONL files under <bankDir>/.
//
// Reality of the upstream platform (verified against the live service):
//   - each paper (【言语理解（二）】机考题库 …) has a FIXED question pool;
//     re-entering a paper yields the exact same questions, and papers of the
//     same category are disjoint — one pass per paper collects everything;
//   - the category lives in the PAPER NAME (言语理解/数字运算/逻辑推理/
//     资料分析/特有题型); the answer-card section is a sub-type label like
//     "逻辑填空(共200题,每题1分,合计200.0分)";
//   - exam_ending for practice papers answers JSON {"code":10000,"success":true}
//     (not a result HTML page), and the exam list's wfs flips back to 1
//     immediately, so a "502 考试未能结束" from submit means the attempt
//     actually ended — verify via a fresh exam-list refetch;
//   - wfs=0 papers are the user's own in-progress attempts: their questions
//     can be read without submitting, so the collector collects them
//     read-only (enter-continue → fetch → never submit).
//
// Pure Node module (node:crypto/fs/path only): unit tests drive it with a fake
// `api` object; the collector CLI wires it to lib/upstream.js, a direct
// upstream client with the same api contract (status/login/getExams/enter/
// getQuestions/submit).

const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");

const TARGET_CATEGORIES = ["言语理解", "数字运算", "逻辑推理", "资料分析", "特有题型"];
const DEFAULT_SECTION = "(无分类)";
const META_VERSION = 1;

class ApiError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

// ---------- Pure helpers ----------

/** Trim a section title; empty becomes the parser's "(无分类)" placeholder. */
function normalizeSection(title) {
  const t = String(title ?? "").trim();
  return t || DEFAULT_SECTION;
}

/**
 * Section labels from the answer card carry a point-count suffix, e.g.
 * "逻辑填空(共200题,每题1分,合计200.0分)" → "逻辑填空". Only the "(共…)" tail
 * is stripped; informative notes like "（仅中国石油和国家管网考）" survive.
 */
function cleanSection(title) {
  return normalizeSection(title).replace(/\(共[^)]*\)\s*$/, "").trim() || DEFAULT_SECTION;
}

/**
 * Map a PAPER NAME onto one of the canonical target categories: first target
 * whose name is a substring of the paper name wins (【言语理解（二）】机考题库
 * → 言语理解). Returns null for non-target papers.
 */
function matchCategory(paperName, targets = TARGET_CATEGORIES) {
  const name = String(paperName ?? "");
  for (const target of targets) {
    const t = String(target).trim();
    if (t && name.includes(t)) return t;
  }
  return null;
}

/** True for 机考题库-style papers whose name carries one of the targets. */
function isTargetExam(exam, targets = TARGET_CATEGORIES) {
  return String(exam.style ?? "").includes("机考题库") && matchCategory(exam.name, targets) !== null;
}

/**
 * Join fetched question DTOs with their answer-card states. The server emits
 * both in testIds order; match by questionsId like app.js does, falling back
 * to positional join. Returns [{ question, state, section }] — questions
 * without a matching state get the placeholder section.
 */
function joinQuestions(questions, states) {
  const stateById = new Map();
  for (const state of states || []) {
    if (state && state.questionsId != null && !stateById.has(String(state.questionsId))) {
      stateById.set(String(state.questionsId), state);
    }
  }
  const joined = [];
  for (let i = 0; i < (questions || []).length; i += 1) {
    const question = questions[i];
    if (!question || question._id == null) continue;
    const state = stateById.get(String(question._id)) || (states && states[i]) || null;
    joined.push({ question, state, section: state?.section || DEFAULT_SECTION });
  }
  return joined;
}

/**
 * Stable content fingerprint (question + options, HTML stripped) — used for
 * duplicate-content *stats* only, never for dedupe (which keys on _id).
 * Accepts either an upstream question DTO (answer1..4) or a stored record
 * (options array).
 */
function contentHash(input) {
  const q = input || {};
  const strip = (html) => String(html ?? "")
    .replace(/<[^>]*>/g, " ")
    .replace(/\s+/g, " ")
    .trim()
    .toLowerCase();
  const options = Array.isArray(q.options)
    ? q.options
    : ["answer1", "answer2", "answer3", "answer4"].map((k) => q[k]);
  const parts = [strip(q.question), ...options.map(strip)];
  return crypto.createHash("sha256").update(parts.join("\n")).digest("hex");
}

/** Build a bank record from a question DTO, its section and category. */
function buildRecord(question, section, category, ctx) {
  const answers = Array.isArray(question._answers) ? question._answers : [];
  let answer;
  if (answers.length > 1) answer = answers;              // 多选 → array
  else if (answers.length === 1) answer = answers[0];    // 单选 → letter
  else if (question.test_ans_right) answer = question.test_ans_right; // 无 keyN → fallback
  else answer = null;                                    // 填空且无答案 → null (honest)
  return {
    _id: String(question._id),
    category,
    section: cleanSection(section),
    question: question.question || "",
    // Shared material for comb (资料分析) questions (fetched via combId); ""
    // for ordinary questions.
    stem: question.parent_info || "",
    options: [question.answer1 || "", question.answer2 || "", question.answer3 || "", question.answer4 || ""],
    answer,
    analysis: question.analysis || "",
    sourceExamId: String(ctx.sourceExamId),
    sourceExamName: ctx.sourceExamName || "",
    round: ctx.round,
    collectedAt: ctx.collectedAt,
  };
}

// ---------- Storage (JSONL per category + meta.json) ----------

// JSONL is append-only per round, so a crash at any point keeps every previous
// record; a truncated trailing line (the only failure mode of an interrupted
// append) is dropped on load. The dedupe Set is rebuilt by scanning the files,
// so there is no index to drift from the data.

function bankFilePath(bankDir, category) {
  return path.join(bankDir, category + ".jsonl");
}

function loadBank(bankDir, targets = TARGET_CATEGORIES) {
  const seenIds = new Set();
  const contentHashes = new Set();
  const counts = {};
  for (const target of targets) counts[target] = 0;
  for (const target of targets) {
    let text;
    try {
      text = fs.readFileSync(bankFilePath(bankDir, target), "utf8");
    } catch {
      continue;
    }
    for (const line of text.split("\n")) {
      const trimmed = line.trim();
      if (!trimmed) continue;
      let record;
      try {
        record = JSON.parse(trimmed);
      } catch {
        break; // partial trailing line from an interrupted append — drop it
      }
      if (!record || record._id == null || record.category !== target) continue;
      seenIds.add(String(record._id));
      contentHashes.add(contentHash(record));
      counts[target] += 1;
    }
  }
  return { seenIds, contentHashes, counts };
}

function appendRecords(bankDir, records) {
  if (!records.length) return;
  fs.mkdirSync(bankDir, { recursive: true, mode: 0o700 });
  try { fs.chmodSync(bankDir, 0o700); } catch {}
  const byCategory = new Map();
  for (const record of records) {
    if (!byCategory.has(record.category)) byCategory.set(record.category, []);
    byCategory.get(record.category).push(JSON.stringify(record) + "\n");
  }
  for (const [category, lines] of byCategory) {
    fs.writeFileSync(bankFilePath(bankDir, category), lines.join(""), {
      encoding: "utf8",
      flag: "a",
      mode: 0o600,
    });
  }
}

function defaultMeta() {
  return {
    version: META_VERSION,
    targets: TARGET_CATEGORIES,
    round: 0,
    lastRun: null,
    examState: {},
    counts: {},
    stats: { totalRounds: 0, contentDupes: 0, answerUnknown: 0, consecutiveFailures: 0 },
  };
}

function loadMeta(bankDir) {
  try {
    const saved = JSON.parse(fs.readFileSync(path.join(bankDir, "meta.json"), "utf8"));
    if (saved && saved.version === META_VERSION) {
      return {
        ...defaultMeta(),
        ...saved,
        targets: saved.targets || defaultMeta().targets,
        examState: saved.examState || {},
        counts: saved.counts || {},
        stats: { ...defaultMeta().stats, ...(saved.stats || {}) },
      };
    }
  } catch {}
  return defaultMeta();
}

function saveMeta(bankDir, meta) {
  fs.mkdirSync(bankDir, { recursive: true, mode: 0o700 });
  const tmp = path.join(bankDir, "meta.json.tmp");
  fs.writeFileSync(tmp, JSON.stringify(meta, null, 2) + "\n", { encoding: "utf8", mode: 0o600 });
  fs.renameSync(tmp, path.join(bankDir, "meta.json"));
}

// The `api` object driving runCollection is provided by lib/upstream.js
// (createUpstreamApi) — a direct upstream client with the same contract the
// old web-server-backed createHttpApi exposed (status/login/getExams/enter/
// getQuestions/submit; errors thrown as ApiError). Unit tests inject a fake
// api object instead.

// ---------- Exam selection ----------

function isDrained(state, exam) {
  return state[String(exam.id)]?.status === "drained";
}

/**
 * Pick the exam for this round, in priority order:
 *   1. any exam we entered but never submitted (crash/failed submit) — resume
 *      via whatever flow applies, regardless of style/wfs;
 *   2. wfs===1 target papers (机考题库 style whose name carries a category),
 *      in list order — enter creates a fresh attempt, then we abandon it;
 *   3. wfs===0 target papers (the user's in-progress attempts), in list order
 *      — collected READ-ONLY (enter-continue → fetch → never submit);
 *      disabled via ctx.collectInProgress=false;
 *   --exam <id> overrides all filters and drains the named exam.
 * A stale pendingSubmit whose exam no longer appears in the list is marked
 * drained so it never blocks the loop.
 */
function pickExam(exams, ctx) {
  if (ctx.singleExamId) {
    const exam = (exams || []).find((e) => String(e.id) === String(ctx.singleExamId));
    return exam ? { exam, reason: "forced" } : { exam: null, reason: "forced-not-found" };
  }
  const state = ctx.examState || {};
  const byId = new Map((exams || []).map((e) => [String(e.id), e]));
  for (const [id, st] of Object.entries(state)) {
    if (st.status !== "pendingSubmit") continue;
    const exam = byId.get(id);
    if (exam) return { exam, reason: "pendingSubmit" };
    st.status = "drained"; // no longer listed — nothing to resume
    st.drainedAt = new Date().toISOString();
  }
  for (const exam of exams || []) {
    if (exam.wfs !== 1 || isDrained(state, exam)) continue;
    if (!isTargetExam(exam, ctx.targets)) continue;
    return { exam, reason: "collect" };
  }
  if (ctx.collectInProgress) {
    for (const exam of exams || []) {
      if (exam.wfs !== 0 || isDrained(state, exam)) continue;
      if (!isTargetExam(exam, ctx.targets)) continue;
      return { exam, reason: "inProgress" };
    }
  }
  return { exam: null, reason: "exhausted" };
}

// ---------- Round ----------

/**
 * After the proxy reports "考试未能结束" (502), the attempt may still have
 * ended upstream: practice papers answer exam_ending with a JSON success
 * instead of a result page. Verify via a fresh exam-list refetch: wfs===1 (or
 * the exam gone) means the attempt ended. Two checks ~2s apart cover list lag.
 */
async function verifyEnded(api, examId, delayMs = 2000) {
  const check = async () => {
    const list = await api.getExams();
    const exam = list.find((e) => String(e.id) === String(examId));
    return exam ? exam.wfs === 1 : true;
  };
  if (await check()) return { success: true, score: null };
  await new Promise((resolve) => setTimeout(resolve, delayMs));
  if (await check()) return { success: true, score: null };
  return null;
}

/**
 * One collection round: list → pick → enter → questions → join → filter new
 * target questions → submit (abandon). Attempts the collector itself created
 * are always ended; the user's in-progress attempts (wfs=0) are read-only.
 * `ctx` is mutated (examState, seenIds) and shared across rounds.
 */
async function collectRound(api, ctx) {
  const log = ctx.log || console;
  const exams = await api.getExams();
  const picked = pickExam(exams, ctx);
  if (!picked.exam) return { exam: null, reason: picked.reason, newQuestions: [], sections: {} };
  const exam = picked.exam;
  const id = String(exam.id);

  const state = ctx.examState;
  const previous = state[id] || {};
  // createdByUs: true only when this round creates a fresh attempt (wfs=1) or
  // resumes one we previously created. A pendingSubmit without createdByUs on
  // a wfs=0 paper is someone else's attempt — read-only, never submitted.
  // Note: entering a wfs=1 paper always creates a fresh attempt we own, even
  // when resuming a stale pendingSubmit marker.
  const ownAttempt = exam.wfs === 1
    ? true
    : (picked.reason === "pendingSubmit" && state[id].createdByUs === true);
  state[id] = {
    ...previous,
    status: "pendingSubmit", // persisted by the caller — crash-safe resume
    createdByUs: ownAttempt,
    name: exam.name,
    roundsCollected: (previous.roundsCollected || 0) + 1,
  };

  await api.enter(id);
  const payload = await api.getQuestions(id);
  const joined = joinQuestions(payload.questions, payload.states);

  const sections = {};
  for (const j of joined) {
    const clean = cleanSection(j.section);
    sections[clean] = (sections[clean] || 0) + 1;
  }

  const category = matchCategory(exam.name, ctx.targets);
  const newQuestions = [];
  if (category) {
    for (const j of joined) {
      const questionId = String(j.question._id);
      if (ctx.seenIds.has(questionId)) continue;
      ctx.seenIds.add(questionId);
      newQuestions.push(buildRecord(j.question, j.section, category, {
        sourceExamId: exam.id,
        sourceExamName: exam.name,
        round: ctx.round,
        collectedAt: new Date().toISOString(),
      }));
    }
  }

  // An attempt we did not create (the user's in-progress work, or a resumed
  // pendingSubmit that was never ours): never submit it — one read-only pass
  // is complete (the paper's pool is fixed).
  if (!ownAttempt) {
    state[id].status = "drained";
    state[id].drainedAt = new Date().toISOString();
    return { exam, reason: picked.reason, newQuestions, sections, submitResult: null, drained: true };
  }

  let submitResult = null;
  try {
    submitResult = await api.submit(id);
  } catch (err) {
    if (err instanceof ApiError && err.status === 502) {
      submitResult = await verifyEnded(api, id, ctx.verifyDelayMs);
      if (submitResult) {
        log.warn(`[round ${ctx.round}] submit returned 502 but the attempt ended (JSON success) — verified via exam list`);
      } else {
        log.warn(`[round ${ctx.round}] submit failed (${err.message}), resuming next round`);
        return { exam, reason: picked.reason, newQuestions, sections, submitResult: null, drained: false };
      }
    } else {
      log.warn(`[round ${ctx.round}] submit failed (${err.message}), resuming next round`);
      return { exam, reason: picked.reason, newQuestions, sections, submitResult: null, drained: false };
    }
  }

  const drained = newQuestions.length === 0;
  if (drained) {
    state[id].status = "drained";
    state[id].drainedAt = new Date().toISOString();
  } else {
    state[id].status = "collected";
    state[id].lastNew = ctx.round;
  }
  return { exam, reason: picked.reason, newQuestions, sections, submitResult, drained };
}

// ---------- Main loop ----------

function summaryByCategory(records) {
  const byCategory = {};
  for (const r of records) byCategory[r.category] = (byCategory[r.category] || 0) + 1;
  return Object.entries(byCategory).map(([c, n]) => `${c}+${n}`).join(" ");
}

function delay(ms, signal) {
  return new Promise((resolve) => {
    const timer = setTimeout(resolve, ms);
    signal?.addEventListener("abort", () => { clearTimeout(timer); resolve(); }, { once: true });
  });
}

/**
 * Collection loop. Options: { bankDir (required), targets, maxRounds=200,
 * idleLimit=3 (consecutive all-empty rounds → stop), roundDelayMs=1500,
 * collectInProgress=true, singleExamId, log, onProgress, signal }.
 * Stops with: exhausted | idle | maxRounds | abort | auth | error.
 * Every round persists new records and meta.json, so any interrupted run can
 * resume by rerunning on the same bankDir.
 */
async function runCollection(api, opts) {
  const bankDir = opts.bankDir;
  const targets = opts.targets || TARGET_CATEGORIES;
  const maxRounds = opts.maxRounds ?? 200;
  const idleLimit = opts.idleLimit ?? 3;
  const roundDelayMs = opts.roundDelayMs ?? 1500;
  const log = opts.log || console;
  const onProgress = opts.onProgress || (() => {});

  fs.mkdirSync(bankDir, { recursive: true, mode: 0o700 });
  try { fs.chmodSync(bankDir, 0o700); } catch {}
  const bank = loadBank(bankDir, targets);
  const meta = loadMeta(bankDir);
  const ctx = {
    targets,
    examState: meta.examState,
    seenIds: bank.seenIds,
    singleExamId: opts.singleExamId || null,
    collectInProgress: opts.collectInProgress ?? true,
    verifyDelayMs: opts.verifyDelayMs,
    log,
  };

  let consecutiveFailures = meta.stats.consecutiveFailures || 0;
  let idleStreak = 0;
  let stoppedBy = null;

  let round = meta.round;
  for (; round < maxRounds; round += 1) {
    if (opts.signal?.aborted) { stoppedBy = "abort"; break; }
    const roundNumber = round + 1;
    ctx.round = roundNumber;
    try {
      const result = await collectRound(api, ctx);
      consecutiveFailures = 0;
      meta.stats.consecutiveFailures = 0;

      if (!result.exam) {
        log.info(`[round ${roundNumber}] no exam to process (${result.reason})`);
        stoppedBy = result.reason === "exhausted" ? "exhausted" : "error";
        break;
      }

      appendRecords(bankDir, result.newQuestions);
      for (const record of result.newQuestions) {
        meta.counts[record.category] = (meta.counts[record.category] || 0) + 1;
        const hash = contentHash(record);
        if (bank.contentHashes.has(hash)) meta.stats.contentDupes += 1;
        else bank.contentHashes.add(hash);
        if (record.answer === null) meta.stats.answerUnknown += 1;
      }
      meta.round = roundNumber;
      meta.lastRun = new Date().toISOString();
      meta.stats.totalRounds = roundNumber;
      saveMeta(bankDir, meta);

      const submit = !result.submitResult
        ? "n/a"
        : result.submitResult.score != null
          ? `ok score=${result.submitResult.score}`
          : "ok (JSON success)";
      log.info(
        `[round ${roundNumber}/${maxRounds}] ${result.exam.name} new=${result.newQuestions.length} `
        + `${summaryByCategory(result.newQuestions)} | `
        + `totals=${Object.entries(meta.counts).map(([c, n]) => `${c}=${n}`).join(" ")} `
        + `(dup-content=${meta.stats.contentDupes}) | submit ${submit}`,
      );
      onProgress({
        round: roundNumber,
        maxRounds,
        exam: result.exam,
        newQuestions: result.newQuestions,
        sections: result.sections,
        submitResult: result.submitResult,
        totals: { ...meta.counts },
        stats: { ...meta.stats },
      });

      if (result.drained) {
        log.info(`[round ${roundNumber}] ${result.exam.name} exhausted — no new questions, moving on`);
      }
      idleStreak = result.newQuestions.length === 0 ? idleStreak + 1 : 0;
      if (idleStreak >= idleLimit) { stoppedBy = "idle"; break; }
    } catch (err) {
      consecutiveFailures += 1;
      meta.stats.consecutiveFailures = consecutiveFailures;
      meta.lastRun = new Date().toISOString();
      saveMeta(bankDir, meta);
      if (err instanceof ApiError && err.status === 401) {
        log.warn(`[round ${roundNumber}] session expired — stopping`);
        stoppedBy = "auth";
        break;
      }
      log.warn(`[round ${roundNumber}] failed: ${err.message} (${consecutiveFailures} consecutive)`);
      if (consecutiveFailures >= 3) { stoppedBy = "error"; break; }
    }
    await delay(roundDelayMs, opts.signal);
  }
  if (!stoppedBy) stoppedBy = "maxRounds";

  const files = targets.map((t) => bankFilePath(bankDir, t));
  return {
    stoppedBy,
    round: meta.round,
    examsProcessed: Object.keys(meta.examState).length,
    countsByCategory: meta.counts,
    stats: meta.stats,
    files,
  };
}

module.exports = {
  TARGET_CATEGORIES,
  DEFAULT_SECTION,
  ApiError,
  normalizeSection,
  cleanSection,
  matchCategory,
  isTargetExam,
  joinQuestions,
  contentHash,
  buildRecord,
  loadBank,
  appendRecords,
  loadMeta,
  saveMeta,
  pickExam,
  collectRound,
  runCollection,
};
