const test = require("node:test");
const assert = require("node:assert/strict");

const QuizCore = require("../public/js/quiz-core");

test("normalizes and restores previous answers in stable option order", () => {
  assert.deepEqual(QuizCore.parsePreviousAnswers("key3,key1,key3,unknown,"), ["A", "C"]);
  assert.deepEqual(QuizCore.parsePreviousAnswers(""), []);
  assert.deepEqual(QuizCore.normalizeSelection(["D", "A", "D", "Z"]), ["A", "D"]);
});

test("toggles multi-select choices without mutating the existing selection", () => {
  const original = ["A", "C"];
  assert.deepEqual(QuizCore.toggleSelection(original, "C"), ["A"]);
  assert.deepEqual(QuizCore.toggleSelection(original, "B"), ["A", "B", "C"]);
  assert.deepEqual(original, ["A", "C"]);
});

test("requires exact multi-select equality and encodes answers for upstream", () => {
  assert.equal(QuizCore.selectionsEqual(["C", "A"], ["A", "C"]), true);
  assert.equal(QuizCore.selectionsEqual(["A"], ["A", "C"]), false);
  assert.equal(QuizCore.selectionsEqual(["A", "B", "C"], ["A", "C"]), false);
  assert.equal(QuizCore.encodeAnswers(["C", "A"]), "key1,key3,");
});

test("finds the next unanswered question and wraps around", () => {
  const states = [
    { state: "unanswered" },
    { state: "right" },
    { state: "error" },
    { state: "unanswered" },
  ];
  assert.equal(QuizCore.nextUnansweredIndex(states, 1), 3);
  assert.equal(QuizCore.nextUnansweredIndex(states, 3), 0);
  assert.equal(QuizCore.nextUnansweredIndex([{ state: "right" }], 0), -1);
});

test("suppresses a stale ended exam until its upstream state changes", () => {
  const oldExam = { id: 7, wfs: 0 };
  const suppression = { 7: 0 };

  const stale = QuizCore.filterSuppressedExams([oldExam], suppression);
  assert.deepEqual(stale.exams, []);
  assert.deepEqual(stale.suppressed, suppression);

  const absent = QuizCore.filterSuppressedExams([], stale.suppressed);
  assert.deepEqual(absent.exams, []);
  assert.deepEqual(absent.suppressed, suppression);

  const refreshed = QuizCore.filterSuppressedExams([{ id: 7, wfs: 1 }], absent.suppressed);
  assert.deepEqual(refreshed.exams, [{ id: 7, wfs: 1 }]);
  assert.deepEqual(refreshed.suppressed, {});
});
