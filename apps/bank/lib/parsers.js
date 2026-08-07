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

  const sectionMatches = [...html.matchAll(/<div class="card-content-title">([^<]+)<\/div>/g)];
  const sectionBounds = sectionMatches.map((match) => ({
    title: match[1],
    pos: match.index,
  }));

  const cards = html.split(/<a\s+href="#[^"]*">\s*/);
  const questionStates = [];
  const seen = new Set();

  for (let index = 1; index < cards.length; index += 1) {
    const chunk = cards[index];
    const questionId = chunk.match(/questionsId="([^"]+)"/)?.[1]?.trim();
    if (!questionId || seen.has(questionId)) continue;
    seen.add(questionId);

    const uuid = chunk.match(/uuId="([^"]+)"/)?.[1]?.trim() ?? null;
    const number = Number.parseInt(chunk.match(/>\s*(\d+)\s*<\/span>/)?.[1] ?? "0", 10);
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

    questionStates.push({
      questionsId: questionId,
      uuId: uuid,
      num: number,
      section,
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
