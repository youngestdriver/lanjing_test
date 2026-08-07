"use strict";

// Sub-classifier tests: rule hits per section, priority order, fallbacks,
// record fidelity, idempotence, and a full-bank dry run that auto-skips when
// the local bank files are absent (CI has none).

const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { test } = require("node:test");

const {
  TARGET_CATEGORIES,
  stripHtml,
  classify,
  classifyBank,
} = require("../lib/question-classifier");

/** Minimal record helper: question/analysis as raw HTML. */
function rec(category, section, question, analysis = "", extra = {}) {
  return { _id: "x", category, section, question, options: ["", "", "", ""], answer: "A", analysis, ...extra };
}

// ---------- stripHtml ----------

test("stripHtml strips tags, decodes entities, collapses whitespace", () => {
  assert.equal(stripHtml("<p>你好</p>"), "你好");
  assert.equal(stripHtml("A&nbsp;&nbsp;&nbsp;B"), "A B");
  assert.equal(stripHtml("a&amp;b &lt;c&gt; &quot;d&quot; &#65;"), 'a&b <c> "d"');
  assert.equal(stripHtml("  <span>  多行\n文本 </span>  "), "多行 文本");
  // curly quotes stay literal; &ldquo; is NOT decoded (rule patterns match literals)
  assert.equal(stripHtml("他说：“好”"), "他说：“好”");
  assert.equal(stripHtml("他说&ldquo;好&rdquo;"), "他说&ldquo;好&rdquo;");
});

// ---------- 言语理解 ----------

test("逻辑填空: 虚词/成语/实词辨析", () => {
  assert.equal(classify(rec("言语理解", "逻辑填空", "依次填入画横线部分最恰当的一项是", "此处是表示转折的关联词")), "虚词辨析");
  assert.equal(classify(rec("言语理解", "逻辑填空", "依次填入最恰当的是", "填入成语“栩栩如生”，形容非常逼真")), "成语辨析");
  assert.equal(classify(rec("言语理解", "逻辑填空", "依次填入画横线处最恰当的一项是", "第一空与“情怀”搭配的词语是")), "实词辨析"); // fallback
});

test("阅读理解: 标题/词句/接语/细节/意图/主旨", () => {
  const q = (stem, analysis = "") => rec("言语理解", "阅读理解", stem, analysis);
  assert.equal(classify(q("最适合做这段文字标题的是")), "标题选择");
  assert.equal(classify(q("对文中“隐形的翅膀”一词理解正确的是", "指代")), "词句理解");
  assert.equal(classify(q("这段文字接下来最可能讲述的是")), "接语选择");
  assert.equal(classify(q("关于“当众羞辱”，下列说法不符合文意的是")), "细节理解");
  assert.equal(classify(q("这段文字意在强调")), "意图推断");
  assert.equal(classify(q("这段文字主要说明了")), "主旨概括");
  assert.equal(classify(q("这段文字谈论的核心问题是")), "主旨概括");
});

test("阅读理解: 意图推断优先于主旨概括 (first match wins)", () => {
  assert.equal(classify(rec("言语理解", "阅读理解", "这段文字主要说明的是……意在强调……")), "意图推断");
});

test("语句表达: 病句/错别字/排序/接语/词语填空/衔接", () => {
  const q = (stem, analysis = "") => rec("言语理解", "语句表达", stem, analysis);
  assert.equal(classify(q("下列各句中，没有语病的一句是")), "病句辨析");
  assert.equal(classify(q("下列句子中没有错别字的是")), "错别字");
  assert.equal(classify(q("将以上6个句子重新排列，语序正确的是")), "语句排序");
  assert.equal(classify(q("这段文字接下来最可能讲的是")), "接语选择");
  assert.equal(classify(q("依次填入下列横线处的词语，最恰当的一组是")), "词语填空");
  assert.equal(classify(q("以下哪句话最适合放在文中横线处？")), "语句衔接");
});

test("语句表达: 病句辨析优先于语句排序 (order)", () => {
  assert.equal(classify(rec("言语理解", "语句表达", "下列各句中没有语病且语序最恰当的一句是")), "病句辨析");
});

// ---------- 数字运算 ----------

test("数字推理: 幂次/分数/多重/数阵/拆分/递推/多级", () => {
  const q = (stem, analysis = "") => rec("数字运算", "数字推理", stem, analysis);
  assert.equal(classify(q("3，4，－2，12，－28，（ ）", "考虑幂次数列，存在负数优先考虑立方数")), "幂次数列");
  assert.equal(classify(q("1/2，2/3，3/5，（ ）", "本数列均为分数")), "分数数列");
  assert.equal(classify(q("1，2，3，4，5，6，（ ）", "项数较多，考虑多重数列")), "多重数列");
  assert.equal(classify(q("下图数阵中问号处应填（ ）", "图形数阵")), "图形数阵");
  assert.equal(classify(q("12，34，56，78，（ ）", "小数数列，考虑机械划分")), "数字拆分");
  assert.equal(classify(q("1，2，3，5，8，（ ）", "前两项相加等于第三项，递推数列")), "递推数列");
  assert.equal(classify(q("3，5，9，17，（ ）", "作差后为等差数列")), "多级数列");
  // analysis-only classification (formula-image stems have empty text)
  assert.equal(classify(rec("数字运算", "数字推理", "", "该分数数列中各项均为分数")), "分数数列");
  // fallback → 多级数列
  assert.equal(classify(rec("数字运算", "数字推理", "3，5，7，（ ）", "无明显特征")), "多级数列");
});

test("数量关系: 浓度/工程/利润/行程/排列组合/几何/年龄/日期", () => {
  const q = (stem, analysis = "") => rec("数字运算", "数量关系", stem, analysis);
  assert.equal(classify(q("一瓶30%的盐溶液500克，加50克水后浓度变为？")), "浓度问题");
  assert.equal(classify(q("甲单独完成需10天，乙单独完成需15天，两人合作需几天")), "工程问题");
  assert.equal(classify(q("某商品按定价的八折出售，仍可获利20%，成本为？")), "利润问题");
  assert.equal(classify(q("一列火车以60千米/时的速度完全经过路边的一根电线杆用了6秒", "电线杆是参照物")), "行程问题"); // not 植树
  assert.equal(classify(q("从5人中任选3人参加比赛，有多少种选法")), "排列组合与概率");
  assert.equal(classify(q("一个边长为3的正方体，其表面积为？")), "几何问题");
  assert.equal(classify(q("今年父亲38岁，儿子10岁，几年后父亲年龄是儿子的3倍")), "年龄问题");
  assert.equal(classify(q("某年2月有5个星期日，则这一年的3月1日是星期几")), "日期与周期");
  assert.equal(classify(q("请问539能被多少个不同的自然数整除？")), "整除与余数");
  assert.equal(classify(q("甲有100元，乙有60元，甲给乙多少元后两人一样多")), "和差倍比与方程"); // fallback
});

test("数字运算(基础): 定义新运算/巧算/整除/数位/方程", () => {
  const q = (stem, analysis = "") => rec("数字运算", "数字运算", stem, analysis);
  assert.equal(classify(q("定义一种新的运算a※b=2a+b，则3※4的值为")), "定义新运算");
  assert.equal(classify(q("规定一种新运算a△b=3a-2b，则5△2=？")), "定义新运算");
  assert.equal(classify(q("计算：9999×9999的值为")), "巧算与速算");
  assert.equal(classify(q("一个数除以7余3，除以5余2，这个数最小是")), "整除与余数");
  assert.equal(classify(q("一个两位数，个位数字是十位数字的2倍，这个数可能是")), "数位与数字");
  assert.equal(classify(q("解方程：3x+5=20，则x的值为")), "方程与比例");
  assert.equal(classify(q("甲乙两数的和为50，甲是乙的4倍，求甲")), "方程与和差倍比"); // fallback
});

// ---------- 逻辑推理 ----------

test("逻辑判断: 削弱先于翻译 (scenario embeds 如果…那么)", () => {
  const rec1 = rec("逻辑推理", "逻辑判断",
    "有专家指出：如果电动自行车大量增加，将会带来更多事故。以下哪项最能削弱上述观点？");
  assert.equal(classify(rec1), "削弱质疑");
});

test("逻辑判断: 加强/真假/分析/翻译/结论", () => {
  const q = (stem, analysis = "") => rec("逻辑推理", "逻辑判断", stem, analysis);
  assert.equal(classify(q("以下哪项如果为真，最能支持上述结论？")), "加强支持");
  assert.equal(classify(q("只有一人说真话，请问谁是小偷")), "真假推理");
  assert.equal(classify(q("根据以上条件，可以确定甲、乙、丙三人的座位顺序是")), "分析推理");
  assert.equal(classify(q("只有小王是大学生，小王才懂英语。若为假，则下列哪句为真")), "真假推理"); // 真假 before 翻译
  assert.equal(classify(q("翻译题干：如果A那么B")), "翻译推理");
  assert.equal(classify(q("由此可以推出的是")), "结论推出");
});

test("图形推理: 空间/属性/位置/样式/数量/其他", () => {
  const q = (stem, analysis = "") => rec("逻辑推理", "图形推理", stem, analysis);
  assert.equal(classify(q("折纸盒", "空间重构题")), "空间重构");
  assert.equal(classify(q("观察图形规律", "优先考虑属性规律，图形均为轴对称图形")), "属性规律");
  assert.equal(classify(q("观察图形规律", "元素组成相同，优先考虑位置规律，图形顺时针旋转")), "位置规律");
  assert.equal(classify(q("观察图形规律", "考虑样式规律，去同存异")), "样式规律");
  assert.equal(classify(q("观察图形规律", "考虑数量规律，每个图形均由3个圆组成")), "数量规律");
  assert.equal(classify(rec("逻辑推理", "图形推理", "与众不同的图形是", "")), "其他");
});

test("类比推理: 语义/逻辑/语法关系", () => {
  const q = (stem, analysis = "") => rec("逻辑推理", "类比推理", stem, analysis);
  assert.equal(classify(q("雪花对于（）相当于（）对于光泽", "近义关系")), "语义关系");
  assert.equal(classify(q("鸽子对于（）相当于（）对于蓝色", "种属关系")), "逻辑关系");
  assert.equal(classify(q("（）对于认真相当于对于负责", "词性均为形容词")), "语法关系");
});

test("定义判断: 多定义/单定义", () => {
  assert.equal(classify(rec("逻辑推理", "定义判断", "根据上述定义", "多定义题")), "多定义");
  assert.equal(classify(rec("逻辑推理", "定义判断", "根据上述定义，下列不属于训练的是")), "单定义"); // fallback
});

// ---------- 资料分析 ----------

test("资料分析: 综合分析优先于增长率", () => {
  const record = rec("资料分析", "比重问题",
    "能够从上述资料中推出的是", "2019年同比增长了10%");
  assert.equal(classify(record), "综合分析");
});

test("资料分析: 增长率 vs 增长量 (percent vs units)", () => {
  const q = (stem, analysis = "") => rec("资料分析", "统计表", stem, analysis);
  assert.equal(classify(q("2021年出口额同比增长约？", "同比增长率")), "增长率问题");
  assert.equal(classify(q("2021年出口额同比增长约？", "增长了1200亿元")), "增长量问题");
});

test("资料分析: 比重/平均数/倍数/基期现期/简单计算", () => {
  const q = (stem, analysis = "") => rec("资料分析", "文字资料", stem, analysis);
  assert.equal(classify(q("2021年进口额占进出口总额的比重为")), "比重问题");
  assert.equal(classify(q("2021年人均收入为多少元", "平均")), "平均数问题");
  assert.equal(classify(q("2021年出口额是进口额的多少倍")), "倍数与比值问题");
  assert.equal(classify(q("2020年基期量为多少", "上年同期")), "基期与现期问题");
  assert.equal(classify(q("2018年三季度景气指数最高的行业是")), "简单计算");
});

test("资料分析: 长篇阅读 section 独立成类", () => {
  assert.equal(classify(rec("资料分析", "长篇阅读（仅中国石油和国家管网考）", "以下这段文字最适合放在原文中的哪个位置")), "长篇阅读");
  assert.equal(classify(rec("资料分析", "长篇阅读（仅中国石油和国家管网考）", "根据本文，《诗经》中记载的制衣过程不包括", "A项根据文章第④段")), "长篇阅读");
});

// ---------- 特有题型 ----------

test("特有题型: section 即子类 (12 sections, 多选记录同规则)", () => {
  const sections = [
    "时政", "职场题", "党性", "物理题（往年仅中石化和中石油考）",
    "中国石化企业文化", "中国石油企业文化", "中国海油企业文化",
    "国家管网企业文化", "国家能源企业文化", "谚语警句",
    "三视图（往年仅中石化考）", "数独题（往年仅中石化考）",
  ];
  for (const section of sections) {
    assert.equal(classify(rec("特有题型", section, "题干")), section, section);
  }
  // multi-answer record classifies identically
  const multi = rec("特有题型", "时政", "党的二十大报告指出", "", { answer: ["A", "C"] });
  assert.equal(classify(multi), "时政");
});

// ---------- classifyBank: fidelity + idempotence ----------

test("classifyBank preserves all fields verbatim and appends subCategory", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "lanjing-qclass-"));
  const file = path.join(dir, "言语理解.jsonl");
  const original = {
    _id: "q1", category: "言语理解", section: "逻辑填空",
    question: "<p>依次填入最恰当的一项是</p>", options: ["<p>A</p>", "", "", ""],
    answer: "B", analysis: "<p>成语辨析，形容非常逼真</p>",
    sourceExamId: "E1", sourceExamName: "【言语理解（二）】机考题库", round: 3,
    collectedAt: "2026-08-07T00:00:00.000Z",
  };
  fs.writeFileSync(file, JSON.stringify(original) + "\n", "utf8");

  const result = classifyBank(dir, TARGET_CATEGORIES);
  assert.equal(result.total, 1);
  assert.equal(result.changed, 1);
  assert.deepEqual(result.byClass, { "言语理解|成语辨析": 1 });
  assert.equal(result.others.length, 0);

  const rewritten = JSON.parse(result.fileLines["言语理解"][0]);
  const { subCategory, ...rest } = rewritten;
  assert.equal(subCategory, "成语辨析");
  assert.deepEqual(rest, original); // every original field byte-identical
  // key order: subCategory appended last
  assert.equal(Object.keys(rewritten).at(-1), "subCategory");
  fs.rmSync(dir, { recursive: true, force: true });
});

test("reclassifyBank rewrite is idempotent and backs up once", () => {
  // Simulate the CLI write loop (rewrite helper is inline in the CLI, so test
  // the semantics via classifyBank + the same tmp+rename pattern).
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "lanjing-qclass-"));
  const file = path.join(dir, "言语理解.jsonl");
  fs.writeFileSync(file, JSON.stringify(rec("言语理解", "逻辑填空", "填入画横线处最恰当的是", "第一空搭配")) + "\n", "utf8");

  const write = (result) => {
    const bak = file + ".bak";
    if (!fs.existsSync(bak)) fs.copyFileSync(file, bak);
    const tmp = file + ".tmp";
    fs.writeFileSync(tmp, result.fileLines["言语理解"].join("\n") + "\n", { encoding: "utf8", mode: 0o600 });
    fs.renameSync(tmp, file);
  };

  const first = classifyBank(dir, TARGET_CATEGORIES);
  write(first);
  const bakContent = fs.readFileSync(file + ".bak", "utf8");
  const afterFirst = fs.readFileSync(file, "utf8");
  assert.equal(bakContent, JSON.stringify(rec("言语理解", "逻辑填空", "填入画横线处最恰当的是", "第一空搭配")) + "\n");

  const second = classifyBank(dir, TARGET_CATEGORIES);
  assert.equal(second.changed, 0); // already classified identically
  write(second);
  const afterSecond = fs.readFileSync(file, "utf8");
  assert.equal(afterSecond, afterFirst); // byte-identical across reruns
  assert.equal(fs.existsSync(file + ".bak"), true);
  // .bak not overwritten on the second run
  assert.equal(fs.readFileSync(file + ".bak", "utf8"), bakContent);

  const lines = afterSecond.trim().split("\n");
  assert.equal(lines.length, 1); // no duplicates
  assert.equal(lines[0].includes('"subCategory"'), true);
  fs.rmSync(dir, { recursive: true, force: true });
});

test("unknown category or section falls back to 其他", () => {
  assert.equal(classify(rec("未知分类", "未知section", "题干")), "其他");
  assert.equal(classify(rec("言语理解", "不存在的section", "题干")), "其他");
  assert.equal(classify(rec("资料分析", "综合", "无法判定的题干")), "其他");
});

// ---------- full-bank dry run (dev machine only) ----------

test("full bank: every record classified, 其他 ratio < 5%", (t) => {
  const bankDir = path.join(__dirname, "..", "..", "bank");
  if (!fs.existsSync(path.join(bankDir, "言语理解.jsonl"))) {
    t.skip("no local bank (CI)");
    return;
  }
  const result = classifyBank(bankDir, TARGET_CATEGORIES);
  assert.equal(result.total, 3065);
  assert.equal(result.others.length <= 20, true);
  const others = Object.entries(result.byClass)
    .filter(([key]) => key.endsWith("|其他"))
    .reduce((sum, [, n]) => sum + n, 0);
  assert.ok(others / result.total < 0.05, `其他 ratio too high: ${others}/${result.total}`);
  // every record gets a non-empty subCategory (byClass keys all carry one)
  const totalByClass = Object.values(result.byClass).reduce((a, b) => a + b, 0);
  assert.equal(totalByClass, result.total);
});
