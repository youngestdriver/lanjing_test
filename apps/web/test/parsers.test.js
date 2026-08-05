"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const {
  parsePreviousAnswers,
  parseExamHtml,
  parseResultHtml,
  detectSessionExpiry,
} = require("../lib/parsers");

const EXAM_HTML = `
  <script>
    var exam_results_id = '87380582';
    var exam_info_id = '1439658';
  </script>
  <div class="card-content-title">科技常识</div>
  <a href="#question-1">
    <div class="question_cbox right marked" questionsId="q1" uuId="u1">
      <span>1</span>
    </div>
  </a>
  <a href="#question-2">
    <div class="question_cbox error" questionsId="q2" uuId="u2">
      <span>2</span>
    </div>
  </a>
  <div class="card-content-title">逻辑推理</div>
  <a href="#question-3">
    <div class="question_cbox" questionsId="q3" uuId="u3">
      <span>3</span>
    </div>
  </a>
  <a href="#question-4">
    <div class="right question_cbox" questionsId="q4" uuId="u4">
      <span>4</span>
    </div>
  </a>
  <a href="#question-1-copy">
    <div class="question_cbox error" questionsId="q1" uuId="u1">
      <span>5</span>
    </div>
  </a>
`;

test("parsePreviousAnswers returns answers in A-D order", () => {
  assert.deepEqual(parsePreviousAnswers("key3,key1,"), ["A", "C"]);
  assert.deepEqual(parsePreviousAnswers("key4, key2, key2,unknown,"), ["B", "D"]);
});

test("parsePreviousAnswers handles one or no saved answers", () => {
  assert.deepEqual(parsePreviousAnswers("key3,"), ["C"]);
  assert.deepEqual(parsePreviousAnswers(""), []);
  assert.deepEqual(parsePreviousAnswers(null), []);
});

test("parseExamHtml extracts IDs, states, marks, and sections", () => {
  const result = parseExamHtml(EXAM_HTML, "fallback");

  assert.equal(result.examResultsId, "87380582");
  assert.equal(result.examInfoId, "1439658");
  assert.equal(result.uuid, "u1");
  assert.deepEqual(result.testIds, ["q1", "q2", "q3", "q4"]);
  assert.deepEqual(result.questionStates, [
    { questionsId: "q1", uuId: "u1", num: 1, section: "科技常识", state: "right", marked: true },
    { questionsId: "q2", uuId: "u2", num: 2, section: "科技常识", state: "error", marked: false },
    { questionsId: "q3", uuId: "u3", num: 3, section: "逻辑推理", state: "unanswered", marked: false },
    { questionsId: "q4", uuId: "u4", num: 4, section: "逻辑推理", state: "right", marked: false },
  ]);
  assert.deepEqual(result.sectionMap, {
    "科技常识": { total: 2, right: 1, error: 1, unanswered: 0 },
    "逻辑推理": { total: 2, right: 1, error: 0, unanswered: 1 },
  });
});

test("parseExamHtml honors known result IDs and handles empty HTML", () => {
  assert.equal(parseExamHtml(EXAM_HTML, "fallback", "known-id").examResultsId, "known-id");
  assert.deepEqual(parseExamHtml("", "fallback"), {
    examResultsId: null,
    examInfoId: "fallback",
    uuid: null,
    testIds: [],
    questionStates: [],
    sectionMap: {},
  });
});

test("parseExamHtml groups questions without a section", () => {
  const html = `
    <script>var exam_results_id = '999';</script>
    <a href="#one">
      <div class="question_cbox" questionsId="q1" uuId="u1"><span>1</span></div>
    </a>
  `;
  const result = parseExamHtml(html, "888");

  assert.equal(result.questionStates[0].section, "");
  assert.deepEqual(result.sectionMap, {
    "(无分类)": { total: 1, right: 0, error: 0, unanswered: 1 },
  });
});

test("parseResultHtml extracts a valid score and percentages", () => {
  const html = `
    <div class="summary score">95.5</div>
    <span class="exam-result-percentage">88</span>
    <span class="exam-result-percentage">12</span>
  `;

  assert.deepEqual(parseResultHtml(html), { score: "95.5", beatRate: "88", rank: "12" });
});

test("parseResultHtml reuses one percentage and tolerates none", () => {
  assert.deepEqual(
    parseResultHtml('<div class="score">80</div><span class="exam-result-percentage">77</span>'),
    { score: "80", beatRate: "77", rank: "77" },
  );
  assert.deepEqual(
    parseResultHtml('<div class="score">60</div>'),
    { score: "60", beatRate: "?", rank: "?" },
  );
  assert.deepEqual(
    parseResultHtml('<div class="score">0</div>'),
    { score: "0", beatRate: "?", rank: "?" },
  );
});

test("parseResultHtml rejects pages without a numeric score marker", () => {
  assert.equal(parseResultHtml('<span class="exam-result-percentage">88</span>'), null);
  assert.equal(parseResultHtml('<div class="score">pending</div>'), null);
  assert.equal(parseResultHtml('<div class="score">1..2</div>'), null);
  assert.equal(parseResultHtml(""), null);
});

test("detectSessionExpiry recognizes redirects, login HTML, and offline JSON", () => {
  assert.equal(detectSessionExpiry(302, "", ["/login/account/login"]), true);
  assert.equal(
    detectSessionExpiry(200, '<!DOCTYPE html><form action="/login/account/login"></form>'),
    true,
  );
  assert.equal(detectSessionExpiry(200, '{"onlineStatus":"0"}'), true);
  assert.equal(detectSessionExpiry(200, '{"onlineStatus":1}'), false);
  assert.equal(detectSessionExpiry(200, EXAM_HTML), false);
});
