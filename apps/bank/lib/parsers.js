"use strict";

// Pure HTML/JSON parsing helpers for the upstream platform, shared with
// apps/web/lib/parsers.js (a deliberate separate copy: the bank tool runs
// standalone, without the web app). Keep the two in sync when changing.

const ANSWER_KEYS = [
  ["key1", "A"],
  ["key2", "B"],
  ["key3", "C"],
  ["key4", "D"],
];

function parsePreviousAnswers(testAnswer) {
  if (typeof testAnswer !== "string") return [];

  const keys = new Set(
    testAnswer
      .split(",")
      .map((key) => key.trim())
      .filter(Boolean),
  );

  return ANSWER_KEYS
    .filter(([key]) => keys.has(key))
    .map(([, answer]) => answer);
}

function parseExamHtml(input, examInfoId, knownResultsId) {
  const html = typeof input === "string" ? input : "";
  const extract = (name) => {
    const match = html.match(new RegExp(`var\\s+${name}\\s*=\\s*['\"]([^'\"]+)['\"]`));
    return match?.[1] ?? null;
  };

  const examResultsId = knownResultsId || extract("exam_results_id");
  const parsedExamInfoId = extract("exam_info_id") || String(examInfoId);

  // Section titles tolerate a trailing space / extra classes in the class attr
  // (资料分析 comb sections are emitted as `<div class="card-content-title ">`).
  const sectionMatches = [...html.matchAll(/<div class="([^"]*card-content-title[^"]*)">([^<]+)<\/div>/g)];
  const sectionBounds = sectionMatches.map((match) => ({
    title: match[2],
    pos: match.index,
  }));

  // Comb (资料分析) groups: an insert-list div wraps several sub-questions and
  // carries the combId in its own questionsId attribute — the payload
  // /exam/get_question_info/ needs per question to fetch the shared parent_info.
  // Depth-tracking finds where each insert-list div closes, so only cards
  // actually inside a comb inherit its combId (regular cards that follow a
  // comb section must not).
  const combBounds = (() => {
    const opens = [...html.matchAll(/<div class="([^"]*insert-list[^"]*)"[^>]*questionsId="([^"]+)"/g)];
    if (!opens.length) return [];
    const combs = opens.map((match) => ({ combId: match[2].trim(), pos: match.index, end: match.index }));
    const byPos = new Map(combs.map((comb) => [comb.pos, comb]));
    let depth = 0;
    let pending = null;
    for (const tag of html.matchAll(/<div\b[^>]*>|<\/div>/g)) {
      if (tag[0].startsWith("</")) {
        depth -= 1;
        if (pending && depth === pending.openDepth) {
          pending.end = tag.index + tag[0].length;
          pending = null;
        }
        continue;
      }
      const comb = byPos.get(tag.index);
      if (comb) {
        pending = comb;
        pending.openDepth = depth;
      }
      depth += 1;
    }
    return combs;
  })();

  const cards = html.split(/<a\s+href="#[^"]*">\s*/);
  const questionStates = [];
  const seen = new Set();

  for (let index = 1; index < cards.length; index += 1) {
    const chunk = cards[index];
    const questionId = chunk.match(/questionsId="([^"]+)"/)?.[1]?.trim();
    if (!questionId || seen.has(questionId)) continue;
    seen.add(questionId);

    const uuid = chunk.match(/uuId="([^"]+)"/)?.[1]?.trim() ?? null;
    // Raw number text: comb sub-questions use "1.1"…"15.5" style labels,
    // ordinary questions a plain integer — keep the string as-is for display.
    const num = chunk.match(/>\s*(\d+(?:\.\d+)?)\s*<\/span>/)?.[1]?.trim() ?? "";
    const boxClass = chunk.match(/<div\b[^>]*class=["']([^"']*\bquestion_cbox\b[^"']*)["'][^>]*>/)?.[1] ?? "";
    const boxClasses = new Set(boxClass.trim().split(/\s+/).filter(Boolean));
    const state = boxClasses.has("right")
      ? "right"
      : boxClasses.has("error")
        ? "error"
        : "unanswered";

    const cardPosition = html.indexOf(`questionsId="${questionId}`);
    let section = "";
    for (let sectionIndex = sectionBounds.length - 1; sectionIndex >= 0; sectionIndex -= 1) {
      if (cardPosition > sectionBounds[sectionIndex].pos) {
        section = sectionBounds[sectionIndex].title;
        break;
      }
    }

    // The card belongs to the comb whose insert-list div actually wraps it
    // (regular cards after a comb section are outside every comb range).
    let combId = null;
    for (const comb of combBounds) {
      if (cardPosition > comb.pos && cardPosition < comb.end) {
        combId = comb.combId;
        break;
      }
    }

    questionStates.push({
      questionsId: questionId,
      uuId: uuid,
      num,
      section,
      combId,
      state,
      marked: boxClasses.has("marked"),
    });
  }

  const testIds = questionStates.map((state) => state.questionsId);
  const uuid = questionStates[0]?.uuId || extract("uuId");
  const sectionMap = {};

  for (const question of questionStates) {
    const key = question.section || "(无分类)";
    if (!sectionMap[key]) {
      sectionMap[key] = { total: 0, right: 0, error: 0, unanswered: 0 };
    }
    sectionMap[key].total += 1;
    sectionMap[key][question.state] += 1;
  }

  return {
    examResultsId,
    examInfoId: parsedExamInfoId,
    uuid,
    testIds,
    questionStates,
    sectionMap,
  };
}

function parseResultHtml(input) {
  const html = typeof input === "string" ? input : "";
  const scoreTags = html.matchAll(
    /<[^>]*\sclass\s*=\s*["']([^"']*)["'][^>]*>\s*(\d+(?:\.\d+)?)\s*</gi,
  );

  let score = null;
  for (const match of scoreTags) {
    if (match[1].split(/\s+/).includes("score")) {
      score = match[2];
      break;
    }
  }
  if (score === null) return null;

  const percentages = [...html.matchAll(/exam-result-percentage[^>]*>\s*(\d+(?:\.\d+)?)/gi)]
    .map((match) => match[1]);
  const beatRate = percentages[0] ?? "?";
  const rank = percentages[1] ?? beatRate;

  return { score, beatRate, rank };
}

function detectSessionExpiry(status, text, redirectTargets = []) {
  if (Number(status) === 401) return true;

  const targets = Array.isArray(redirectTargets) ? redirectTargets : [redirectTargets];
  if (targets.some((target) => String(target || "").includes("/login/account/login"))) {
    return true;
  }

  if (typeof text !== "string") return false;
  if (/"onlineStatus"\s*:\s*(?:"0"|0)(?=\s*[,}])/.test(text)) return true;

  return /<!doctype\s+html/i.test(text) && text.includes("/login/account/login");
}

module.exports = {
  parsePreviousAnswers,
  parseExamHtml,
  parseResultHtml,
  detectSessionExpiry,
};
