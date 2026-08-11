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
