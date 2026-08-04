(function attachQuizCore(root, factory) {
  const core = factory();
  if (typeof module === "object" && module.exports) {
    module.exports = core;
  } else {
    root.QuizCore = core;
  }
})(typeof globalThis === "object" ? globalThis : this, function createQuizCore() {
  "use strict";

  const LETTERS = ["A", "B", "C", "D"];
  const KEY_BY_LETTER = {
    A: "key1",
    B: "key2",
    C: "key3",
    D: "key4",
  };

  function normalizeSelection(value) {
    const values = value instanceof Set
      ? Array.from(value)
      : Array.isArray(value)
        ? value
        : typeof value === "string"
          ? [value]
          : [];
    const selected = new Set(values.map(String));
    return LETTERS.filter((letter) => selected.has(letter));
  }

  function parsePreviousAnswers(testAnswer) {
    if (typeof testAnswer !== "string") return [];
    const keys = new Set(testAnswer.split(",").map((key) => key.trim()).filter(Boolean));
    return LETTERS.filter((letter) => keys.has(KEY_BY_LETTER[letter]));
  }

  function toggleSelection(value, letter) {
    if (!LETTERS.includes(letter)) return normalizeSelection(value);
    const selected = new Set(normalizeSelection(value));
    if (selected.has(letter)) selected.delete(letter);
    else selected.add(letter);
    return normalizeSelection(selected);
  }

  function selectionsEqual(left, right) {
    const a = normalizeSelection(left);
    const b = normalizeSelection(right);
    return a.length === b.length && a.every((letter, index) => letter === b[index]);
  }

  function encodeAnswers(value) {
    return normalizeSelection(value)
      .map((letter) => KEY_BY_LETTER[letter])
      .filter(Boolean)
      .map((key) => `${key},`)
      .join("");
  }

  function nextUnansweredIndex(states, currentIndex) {
    if (!Array.isArray(states) || states.length === 0) return -1;
    for (let offset = 1; offset <= states.length; offset += 1) {
      const index = (currentIndex + offset) % states.length;
      if (states[index]?.state === "unanswered") return index;
    }
    return -1;
  }

  function filterSuppressedExams(exams, suppressedStates) {
    const incoming = Array.isArray(exams) ? exams : [];
    const suppressed = { ...(suppressedStates || {}) };

    for (const exam of incoming) {
      const id = String(exam.id);
      if (Object.prototype.hasOwnProperty.call(suppressed, id)
          && String(suppressed[id]) !== String(exam.wfs)) {
        delete suppressed[id];
      }
    }

    return {
      exams: incoming.filter((exam) => (
        !Object.prototype.hasOwnProperty.call(suppressed, String(exam.id))
        || String(suppressed[String(exam.id)]) !== String(exam.wfs)
      )),
      suppressed,
    };
  }

  return {
    LETTERS,
    normalizeSelection,
    parsePreviousAnswers,
    toggleSelection,
    selectionsEqual,
    encodeAnswers,
    nextUnansweredIndex,
    filterSuppressedExams,
  };
});
