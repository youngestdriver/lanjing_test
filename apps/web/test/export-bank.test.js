"use strict";

// Markdown exporter tests: HTML→text conversion, answer/option formatting,
// record rendering, and a small exportBank integration run.

const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { test } = require("node:test");

const {
  TARGET_CATEGORIES,
  IMAGE_STEM,
  htmlToText,
  answerText,
  optionsText,
  recordToMarkdown,
  sanitizeFileName,
  exportBank,
} = require("../lib/bank-export");

// ---------- htmlToText ----------

test("htmlToText decodes entities and collapses whitespace", () => {
  assert.equal(htmlToText("<p>你好&nbsp;世界</p>"), "你好 世界");
  assert.equal(htmlToText("他说&ldquo;好&rdquo;"), "他说“好”");
  assert.equal(htmlToText("A&times;B&divide;C&ge;D"), "A×B÷C≥D");
  assert.equal(htmlToText("&#215; &#x3c0;"), "× π");
  assert.equal(htmlToText("a<br>b"), "a b");
  assert.equal(htmlToText("<p>第一段</p><p>第二段</p>"), "第一段\n\n第二段");
  assert.equal(htmlToText('<span style="color: red">带样式</span>'), "带样式");
  assert.equal(htmlToText("  <p>  多行\n\t文本 </p>  "), "多行 文本");
});

test("htmlToText reports formula-image stems as IMAGE_STEM", () => {
  assert.equal(htmlToText(""), IMAGE_STEM);
  assert.equal(htmlToText("<p><img src=\"/x.png\"></p>"), IMAGE_STEM);
  assert.equal(htmlToText(null), IMAGE_STEM);
  assert.equal(htmlToText("<p>有文字<img src=\"/x.png\">也有图</p>"), "有文字也有图");
});

// ---------- formatting ----------

test("answerText renders single/multi/unknown answers", () => {
  assert.equal(answerText("A"), "A");
  assert.equal(answerText(["A", "C"]), "A、C");
  assert.equal(answerText(null), "（未知）");
  assert.equal(answerText(""), "（未知）");
});

test("optionsText skips empty slots (填空) and numbers A-D", () => {
  assert.equal(optionsText(["<p>苹果</p>", "<p>香蕉</p>", "", ""]), "A. 苹果\nB. 香蕉");
  assert.equal(optionsText(["", "", "", ""]), "（无选项）");
});

test("recordToMarkdown renders 题干/选项/答案/解析 and provenance", () => {
  const record = {
    _id: "q1", category: "言语理解", section: "逻辑填空", subCategory: "成语辨析",
    question: "<p>依次填入最恰当的一项是</p>",
    options: ["<p>栩栩如生</p>", "<p>惟妙惟肖</p>", "", ""],
    answer: ["A", "B"],
    analysis: "<p>形容非常逼真。&ldquo;栩栩如生&rdquo;强调生动。</p>",
    sourceExamId: "E1", sourceExamName: "【言语理解（二）】机考题库",
    collectedAt: "2026-08-07T00:00:00.000Z",
  };
  const md = recordToMarkdown(record, 1);
  assert.match(md, /### 1\. 依次填入最恰当的一项是/);
  assert.match(md, /\*\*选项：\*\*/);
  assert.match(md, /A\. 栩栩如生\nB\. 惟妙惟肖/);
  assert.match(md, /\*\*答案：\*\* A、B/);
  assert.match(md, /\*\*解析：\*\*/);
  assert.match(md, /形容非常逼真。“栩栩如生”强调生动。/);
  assert.match(md, /<sub>来源：【言语理解（二）】机考题库 · 收集于 2026-08-07<\/sub>/);
});

test("sanitizeFileName makes filesystem-safe names", () => {
  assert.equal(sanitizeFileName("言语理解-成语辨析.md"), "言语理解-成语辨析.md");
  assert.equal(sanitizeFileName("a/b\\c:d*e?f\"g<h>i|j"), "a-b-c-d-e-f-g-h-i-j");
  assert.equal(sanitizeFileName("a  b"), "a-b");
});

// ---------- exportBank integration ----------

test("exportBank writes one Markdown file per subCategory", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "lanjing-qexport-"));
  const bankDir = path.join(dir, "bank");
  const outDir = path.join(dir, "export");
  fs.mkdirSync(bankDir, { recursive: true });
  const records = [
    { _id: "q1", category: "言语理解", section: "逻辑填空", subCategory: "成语辨析", question: "<p>成语题一</p>", options: ["<p>A</p>", "<p>B</p>", "", ""], answer: "A", analysis: "<p>解析一</p>", sourceExamId: "E1", sourceExamName: "卷1", collectedAt: "2026-08-07T00:00:00.000Z" },
    { _id: "q2", category: "言语理解", section: "逻辑填空", subCategory: "成语辨析", question: "<p>成语题二</p>", options: ["<p>A</p>", "<p>B</p>", "<p>C</p>", "<p>D</p>"], answer: ["B", "D"], analysis: "", sourceExamId: "E1", sourceExamName: "卷1", collectedAt: "2026-08-07T00:00:00.000Z" },
    { _id: "q3", category: "数字运算", section: "数量关系", subCategory: "行程问题", question: "<p>两车相向而行</p>", options: ["<p>60</p>", "<p>80</p>", "", ""], answer: "C", analysis: "<p>相遇公式</p>", sourceExamId: "E2", sourceExamName: "卷2", collectedAt: "2026-08-07T00:00:00.000Z" },
  ];
  const byTarget = {};
  for (const r of records) (byTarget[r.category] = byTarget[r.category] || []).push(r);
  for (const [cat, list] of Object.entries(byTarget)) {
    fs.writeFileSync(path.join(bankDir, cat + ".jsonl"), list.map((r) => JSON.stringify(r)).join("\n") + "\n", "utf8");
  }

  const result = exportBank(bankDir, outDir, TARGET_CATEGORIES);
  assert.equal(result.total, 3);
  assert.equal(result.files.length, 2);

  const chengyu = fs.readFileSync(path.join(outDir, "言语理解-成语辨析.md"), "utf8");
  assert.match(chengyu, /^# 言语理解 · 成语辨析（2 题）/);
  assert.match(chengyu, /### 1\. 成语题一/);
  assert.match(chengyu, /### 2\. 成语题二/);
  assert.match(chengyu, /\*\*答案：\*\* B、D/);
  assert.equal((chengyu.match(/---/g) || []).length >= 2, true);

  const xingcheng = fs.readFileSync(path.join(outDir, "数字运算-行程问题.md"), "utf8");
  assert.match(xingcheng, /^# 数字运算 · 行程问题（1 题）/);
  assert.match(xingcheng, /两车相向而行/);
  assert.match(xingcheng, /\*\*答案：\*\* C/);
  fs.rmSync(dir, { recursive: true, force: true });
});

test("exportBank skips missing categories and reports 0 files", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "lanjing-qexport-"));
  const result = exportBank(path.join(dir, "nope"), path.join(dir, "out"), TARGET_CATEGORIES);
  assert.equal(result.total, 0);
  assert.deepEqual(result.files, []);
  fs.rmSync(dir, { recursive: true, force: true });
});
