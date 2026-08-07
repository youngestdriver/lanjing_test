"use strict";

// Offline sub-classifier for the collected question bank. Every record in
// <bankDir>/*.jsonl gets a `subCategory` (finer 题型 class) derived from its
// question + analysis text, using per-(category, section) ordered regex rules.
// Pure Node module: no dependencies, never writes to disk (classifyBank only
// computes; the CLI performs the rewrite).
//
// Tuning basis: the analysis text on this platform frequently names the type
// itself ("可判定本题为现期比重问题", "优先考虑属性规律…对称",
// "数列…再考虑递推数列"), which is exactly what these rules key on.
// Verified against the full bank: ~1.1% of records fall to 其他.

const fs = require("node:fs");
const path = require("node:path");

const TARGET_CATEGORIES = ["言语理解", "数字运算", "逻辑推理", "资料分析", "特有题型"];

// ---------- Rule tables ----------
//
// Keyed by "category|section"; rules run in array order and the first match
// wins. Order is load-bearing where noted (e.g. 削弱 before 翻译 — scenario
// stems embed "如果…那么"; 综合分析 before 增长率 in 资料分析).

const SECTION_RULES = {
  "言语理解|逻辑填空": [
    { name: "虚词辨析", patterns: [/关联词|虚词|连词|连接词|衔接词|表示?(转折|递进|并列|因果|假设|让步|承接|条件)/] },
    { name: "成语辨析", patterns: [/成语|[“"][^”"]{4}[”"](?:比喻|形容|指|强调|体现)/] },
  ],
  "言语理解|阅读理解": [
    { name: "标题选择", patterns: [/标题/] },
    { name: "词句理解", patterns: [/对(文中|文段)?[“"][^”"]{1,20}[”"].{0,15}(理解|意思)|[“"][^”"]{1,12}[”"]一词|加点的词|指代|代词|“这”|“前者”|“后者”|相对面/] },
    { name: "接语选择", patterns: [/接下来|下文|承接|接语/] },
    { name: "细节理解", patterns: [/不符合|不相符|不符|不正确|不恰当|可以知道|可以看出|关于.*(正确|错误)|说法|表现的是|属于|未提及|没有提到|符合文意|理解正确|不能推出|可以推出|推出|推断|表述.*(正确|错误)/] },
    { name: "意图推断", patterns: [/意在|想要|想表达|旨在|启示|告诉|意图|强调|反映.*问题/] },
    { name: "主旨概括", patterns: [/主要说明|主要讲述|主要谈论|主旨|概括|中心|主要观点|主要内容|说明的是|谈论|说明了|主要介绍|介绍了|复述|关键词|重在/] },
  ],
  "言语理解|语句表达": [
    { name: "病句辨析", patterns: [/语病|病句|搭配不当|成分残缺|句式杂糅|语序不当|成分赘余|结构混乱|歧义|标点/] },
    { name: "错别字", patterns: [/错字|错别字/] },
    { name: "语句排序", patterns: [/排序|最连贯|语序|确定首句|对比选项|重新排列/] },
    { name: "接语选择", patterns: [/接语|接下来|下文/] },
    { name: "词语填空", patterns: [/填入.*最恰当|横线处.*(词语|成语)|词语.*使用|依次.*最恰当/] },
    { name: "语句衔接", patterns: [/横线|填入.*句子|衔接|承上启下|空格|语意连贯|括号/] },
  ],
  "数字运算|数字推理": [
    { name: "幂次数列", patterns: [/幂次|幂方|平方数|立方数/] },
    { name: "分数数列", patterns: [/分数数列|均为分数|全部都是分数|全为分数|都是分数|分式/] },
    { name: "多重数列", patterns: [/多重数列|交叉|项数较多|两两分组|奇偶项|奇数项|偶数项/] },
    { name: "图形数阵", patterns: [/图形数阵|数阵|图中|图形/] },
    { name: "数字拆分", patterns: [/机械划分|因式分解|小数数列|拆分|小数点|个位.*十位|数位/] },
    { name: "递推数列", patterns: [/递推|前项|前两项|相加.*等于|相乘.*等于/] },
    { name: "多级数列", patterns: [/作差|做差|作商|做商|等差数列|等比数列|多级数列|后项减前项/] },
  ],
  "数字运算|数量关系": [
    { name: "浓度问题", patterns: [/浓度|溶液|溶质|盐水|酒精溶液|蒸发|含盐|加水|加盐/] },
    { name: "工程问题", patterns: [/工程|效率|合作|单独.*完成|工期|工作量|工作效率|完成.*(天|小时|分钟)/] },
    { name: "利润问题", patterns: [/利润|成本|售价|进价|标价|折扣|打折|定价|盈利|亏损|利润率/] },
    { name: "行程问题", patterns: [/速度|相遇|追及|相向|同向|相距|路程|千米|公里|火车|列车|轮船|飞机|跑步|步行|小时.*(驶|行)/] },
    { name: "排列组合与概率", patterns: [/排列|组合|概率|多少种|选法|任选|抽取|抽到|随机|种方法|几种|顺序/] },
    { name: "几何问题", patterns: [/三角形|周长|面积|正方形|长方形|正方体|长方体|圆形|圆|圆柱|圆锥|梯形|体积|边长|半径|直径|棱长|表面积|阴影|球/] },
    { name: "年龄问题", patterns: [/年龄|岁/] },
    { name: "日期与周期", patterns: [/星期|周几|闰年|日期|每月|当月|周期|循环|工作日|休息日|连续.*天/] },
    { name: "钟表问题", patterns: [/钟表|时针|分针|钟面|敲钟|挂钟/] },
    { name: "植树与间隔", patterns: [/植树|种树|栽树|电线杆|间隔|两端都|棵/] },
    { name: "牛吃草问题", patterns: [/牛吃草|牧草|长草|吃草/] },
    { name: "平均数问题", patterns: [/平均分|平均数|平均成绩|总平均/] },
    { name: "鸡兔同笼", patterns: [/鸡兔|头.*脚|脚.*头/] },
    { name: "容斥问题", patterns: [/都不|既.*又|参加.*(和|与).*(又|都)|至少.*人/] },
    { name: "极值与构造", patterns: [/最大|最小|最多|最少|保证|至少需要/] },
    { name: "整除与余数", patterns: [/整除|因数|质数|公约数|公倍数|被.*除/] },
  ],
  "数字运算|数字运算": [
    { name: "定义新运算", patterns: [/定义.*新运算|规定.*运算|新运算|定义.*运算/] },
    // 方程 before 巧算: "解方程…则x的值为" must not fall to 巧算's "的值为".
    { name: "方程与比例", patterns: [/方程|的解|设.*为|比.*多|比.*少|比例|之比/] },
    { name: "巧算与速算", patterns: [/计算|的值为|的值是|简便|估算|整数部分|尾数|巧算|结果/] },
    { name: "整除与余数", patterns: [/整除|余数|除以|被.*除|倍数特征|因数|质数/] },
    { name: "数位与数字", patterns: [/三位数|两位数|四位数|个位|十位|百位|位数|数字|页码|书页|号码|数位/] },
    { name: "数列与规律", patterns: [/第.*个数|规律|数列|依次/] },
  ],
  "逻辑推理|逻辑判断": [
    // 削弱/加强/真假 must precede 翻译: scenario stems embed "如果…那么".
    { name: "削弱质疑", patterns: [/削弱|质疑|反驳|反对|除.*外/] },
    { name: "加强支持", patterns: [/最能支持|支持|加强|前提|假设|预设|使.*成立/] },
    { name: "真假推理", patterns: [/真话|假话|为真|为假|预测|说谎|真.*假|假.*真|只有.*(一人|一句|一个|一项|一位)|属实/] },
    { name: "分析推理", patterns: [/最大信息法|推理起点|分析题干|一家人|入选|每人只对了一半|各不相同|可以确定|根据以上(条件|信息|线索|表述)|排列|顺序|位置|相邻|座次|第.*(名|位)|对应|匹配|方阵|每行|每列|三人|四人|五人|其中有一个/] },
    { name: "翻译推理", patterns: [/翻译题干|如果.*那么|只有.*才|除非|当且仅当|充分条件|必要条件|假言/] },
    { name: "结论推出", patterns: [/可以推出|由此可知|推出|推断出|由此可以|可推知|日常|得出结论/] },
    { name: "评价型", patterns: [/推理方式|逻辑错误|最为接近|最相近|类似|与题干|论证.*(有效|无效)|实验方法/] },
  ],
  "逻辑推理|图形推理": [
    { name: "空间重构", patterns: [/空间重构|折纸|展开|折叠|视图|三视图|表面|相邻面|截面|立体|相对面|骰子/] },
    { name: "属性规律", patterns: [/属性规律|对称|曲直|开闭|封闭性|开放图形|封闭区域|生活化图形/] },
    { name: "位置规律", patterns: [/位置规律|旋转|平移|翻转|移动|位置|间隔|字母|顺(逆)时针/] },
    { name: "样式规律", patterns: [/样式规律|求同|求异|叠加|黑白运算|去同存异|去异存同|图形间关系/] },
    { name: "数量规律", patterns: [/数量规律|面数量|线数量|点数量|角数量|元素|笔画|面的个数|线条|个数|汉字|包含数字/] },
  ],
  "逻辑推理|类比推理": [
    { name: "语义关系", patterns: [/近义|反义|语义|比喻|象征|褒义|贬义|本意|引申|延伸含义|多义|字义|释义/] },
    { name: "逻辑关系", patterns: [/种属|组成|包含|对应|因果|并列|交叉|属种|组成关系/] },
    { name: "语法关系", patterns: [/词性|动宾|主谓|偏正|语法|成语结构|名词|形容词|修饰|主宾/] },
  ],
  "逻辑推理|定义判断": [
    { name: "多定义", patterns: [/多定义|两个定义|包含.*定义|①②/] },
  ],
};

// Residual class when no rule matches, per section.
const FALLBACKS = {
  "言语理解|逻辑填空": "实词辨析",
  "数字运算|数量关系": "和差倍比与方程",
  "数字运算|数字运算": "方程与和差倍比",
  "数字运算|数字推理": "多级数列",
  "逻辑推理|定义判断": "单定义",
};

const DEFAULT_FALLBACK = "其他";

// 资料分析 rules apply to every section except 长篇阅读, which keeps its
// own class (it is 言语-type reading attached to a 资料分析 paper).
const DATA_ANALYSIS_RULES = [
  { name: "综合分析", patterns: [/能够.{0,8}推出|不能.{0,8}推出|可从.{0,6}推出|说法.{0,8}(正确|错误)|正确的有|错误的有|正确的是|错误的是|可以推出|下列说法|推断出/] },
  // 增长量 carries a unit amount; 增长率 carries a percent or 同比/环比
  // wording — "增长了1200亿元" must land in 增长量, "同比增长了10%" in 增长率.
  { name: "增长量问题", patterns: [/增长量|增长(了)?.{0,10}(亿元|万元|万吨|亿|万|人)|增加.{0,10}(亿元|万元|万吨|亿|万|人)|比.*(多|增加|减少|少).{0,10}(亿元|万|亿|人)|同比增加|增加了|多多少|个百分点|比.{0,8}(多|少)/] },
  { name: "增长率问题", patterns: [/增长率|增速|增幅|同比|环比|比上月|较上月|涨跌|降幅|上升.{0,4}%|下降.{0,4}%|增长.{0,4}%|同比增速|增速比|与.*相比.{0,12}增长/] },
  { name: "比重问题", patterns: [/比重|占比|占.*的|所占|利润率|资产负债率|率(是|为|约)/] },
  { name: "平均数问题", patterns: [/平均|每|人均|月均|日均|年均|单价|元每|每平方|单位.*(产量|成本)/] },
  { name: "倍数与比值问题", patterns: [/倍|比值|比例|之比|是.*的/] },
  { name: "基期与现期问题", patterns: [/基期|现期|上年同期|上一年|去年|约为|约多少|大约|累计|招了|为多少|（ ）(亿|万)|达到/] },
  { name: "简单计算", patterns: [/最多|最少|最高|最低|最大|最小|排序|下降最多|上升最少|高于|低于|差额|相差约|有几个月|共有|从图中|从表/] },
];

// ---------- HTML stripping ----------

/**
 * Strip tags and decode the common entities into plain text for rule
 * matching. Curly quotes are kept as-is (source uses literal “”), and the
 * &ldquo;-style entities are deliberately NOT decoded — the word-quote
 * patterns in the rule tables match the literal characters.
 */
function stripHtml(html) {
  return String(html ?? "")
    .replace(/<[^>]*>/g, " ")
    .replace(/&nbsp;/gi, " ")
    .replace(/&lt;/gi, "<")
    .replace(/&gt;/gi, ">")
    .replace(/&amp;/gi, "&")
    .replace(/&quot;/gi, "\"")
    .replace(/&#\d+;/gi, " ")
    .replace(/\s+/g, " ")
    .trim();
}

// ---------- Classification ----------

function rulesFor(category, section) {
  if (category === "资料分析" && !section.startsWith("长篇阅读")) return DATA_ANALYSIS_RULES;
  return SECTION_RULES[`${category}|${section}`] || null;
}

/** Classify one record → subCategory. Never throws; unknown → 其他. */
function classify(record) {
  const category = String(record.category ?? "");
  const section = String(record.section ?? "");
  // 特有题型: the section itself is the sub-category (user's explicit choice).
  if (category === "特有题型") return section || DEFAULT_FALLBACK;
  // 资料分析's 长篇阅读 section is 言语-type reading attached to a data
  // paper — it keeps its own class instead of the type rules.
  if (category === "资料分析" && section.startsWith("长篇阅读")) return "长篇阅读";
  const text = `${stripHtml(record.question)} ${stripHtml(record.analysis)}`;
  const list = rulesFor(category, section);
  if (!list) return DEFAULT_FALLBACK;
  for (const rule of list) {
    for (const pattern of rule.patterns) {
      if (pattern.test(text)) return rule.name;
    }
  }
  return FALLBACKS[`${category}|${section}`] || DEFAULT_FALLBACK;
}

/**
 * Read-only classification of the whole bank. Returns:
 *   { total, changed, byClass, others, fileLines }
 * fileLines maps category → rewritten JSONL lines (original fields verbatim,
 * `subCategory` appended last; key order preserved by JSON.stringify).
 */
function classifyBank(bankDir, targets = TARGET_CATEGORIES) {
  const total = { value: 0 };
  let changed = 0;
  const byClass = {};
  const others = [];
  const fileLines = {};

  for (const target of targets) {
    const file = path.join(bankDir, target + ".jsonl");
    let text;
    try {
      text = fs.readFileSync(file, "utf8");
    } catch {
      continue;
    }
    const lines = [];
    for (const line of text.split("\n")) {
      const trimmed = line.trim();
      if (!trimmed) continue;
      let record;
      try {
        record = JSON.parse(trimmed);
      } catch {
        continue; // truncated trailing line — leave as-is? lines[] rewrite must
        // not drop valid data; a truncated line can't be re-serialized, so
        // carry it through verbatim.
        lines.push(trimmed);
        continue;
      }
      total.value += 1;
      const sub = classify(record);
      if (record.subCategory !== sub) changed += 1;
      record.subCategory = sub;
      lines.push(JSON.stringify(record));
      const key = `${record.category}|${sub}`;
      byClass[key] = (byClass[key] || 0) + 1;
      if (sub === DEFAULT_FALLBACK && others.length < 20) {
        others.push({
          category: record.category,
          section: record.section,
          question: stripHtml(record.question).slice(0, 60),
        });
      }
    }
    if (lines.length) fileLines[target] = lines;
  }
  return { total: total.value, changed, byClass, others, fileLines };
}

module.exports = {
  TARGET_CATEGORIES,
  SECTION_RULES,
  FALLBACKS,
  DATA_ANALYSIS_RULES,
  stripHtml,
  classify,
  classifyBank,
};
