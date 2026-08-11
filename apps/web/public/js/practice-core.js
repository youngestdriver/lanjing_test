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
