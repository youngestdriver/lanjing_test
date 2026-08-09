import Foundation

/// Faithful Swift port of apps/bank/lib/question-classifier.js: derives the
/// 题型细分 subCategory from a question's text + analysis using ordered
/// per-(category, section) regex rules. The rule tables below are transcribed
/// verbatim from the JS source — keep the two in sync when changing.
/// 资料分析 is exempt (as in the JS source): the platform's answer card already
/// splits it into 文字资料/统计表/统计图/简单计算/比重问题/…, so the HTML
/// section IS the sub-category (same convention as 特有题型).
///
/// Porting notes:
///   - JS `regex.test(text)` (unanchored search) == `firstMatch(in:)` here;
///   - `stripHtml` follows the JS replacement order exactly, and deliberately
///     does NOT decode &ldquo;-style entities — the rule patterns match the
///     literal curly quotes in the source text;
///   - NSRegularExpression is Sendable, so the compiled rule tables are safe
///     as `static let` under Swift 6 strict concurrency.
enum QuestionClassifier: Sendable {

    struct Rule: Sendable, Equatable {
        let name: String
        let patterns: [NSRegularExpression]

        init(name: String, patterns: [String]) {
            self.name = name
            self.patterns = patterns.map { try! NSRegularExpression(pattern: $0) }
        }
    }

    static let defaultFallback = "其他"

    // ---------- Rule tables ----------
    //
    // Keyed by "category|section"; rules run in array order and the first
    // match wins. Order is load-bearing where noted (e.g. 削弱 before 翻译 —
    // scenario stems embed "如果…那么").

    static let sectionRules: [String: [Rule]] = [
        "言语理解|逻辑填空": [
            Rule(name: "虚词辨析", patterns: [
                "关联词|虚词|连词|连接词|衔接词|表示?(转折|递进|并列|因果|假设|让步|承接|条件)",
            ]),
            Rule(name: "成语辨析", patterns: [
                "成语|[“\"][^”\"]{4}[”\"](?:比喻|形容|指|强调|体现)",
            ]),
        ],
        "言语理解|阅读理解": [
            Rule(name: "标题选择", patterns: ["标题"]),
            Rule(name: "词句理解", patterns: [
                "对(文中|文段)?[“\"][^”\"]{1,20}[”\"].{0,15}(理解|意思)|[“\"][^”\"]{1,12}[”\"]一词|加点的词|指代|代词|“这”|“前者”|“后者”|相对面",
            ]),
            Rule(name: "接语选择", patterns: ["接下来|下文|承接|接语"]),
            Rule(name: "细节理解", patterns: [
                "不符合|不相符|不符|不正确|不恰当|可以知道|可以看出|关于.*(正确|错误)|说法|表现的是|属于|未提及|没有提到|符合文意|理解正确|不能推出|可以推出|推出|推断|表述.*(正确|错误)",
            ]),
            Rule(name: "意图推断", patterns: ["意在|想要|想表达|旨在|启示|告诉|意图|强调|反映.*问题"]),
            Rule(name: "主旨概括", patterns: [
                "主要说明|主要讲述|主要谈论|主旨|概括|中心|主要观点|主要内容|说明的是|谈论|说明了|主要介绍|介绍了|复述|关键词|重在",
            ]),
        ],
        "言语理解|语句表达": [
            Rule(name: "病句辨析", patterns: ["语病|病句|搭配不当|成分残缺|句式杂糅|语序不当|成分赘余|结构混乱|歧义|标点"]),
            Rule(name: "错别字", patterns: ["错字|错别字"]),
            Rule(name: "语句排序", patterns: ["排序|最连贯|语序|确定首句|对比选项|重新排列"]),
            Rule(name: "接语选择", patterns: ["接语|接下来|下文"]),
            Rule(name: "词语填空", patterns: ["填入.*最恰当|横线处.*(词语|成语)|词语.*使用|依次.*最恰当"]),
            Rule(name: "语句衔接", patterns: ["横线|填入.*句子|衔接|承上启下|空格|语意连贯|括号"]),
        ],
        "数字运算|数字推理": [
            Rule(name: "幂次数列", patterns: ["幂次|幂方|平方数|立方数"]),
            Rule(name: "分数数列", patterns: ["分数数列|均为分数|全部都是分数|全为分数|都是分数|分式"]),
            Rule(name: "多重数列", patterns: ["多重数列|交叉|项数较多|两两分组|奇偶项|奇数项|偶数项"]),
            Rule(name: "图形数阵", patterns: ["图形数阵|数阵|图中|图形"]),
            Rule(name: "数字拆分", patterns: ["机械划分|因式分解|小数数列|拆分|小数点|个位.*十位|数位"]),
            Rule(name: "递推数列", patterns: ["递推|前项|前两项|相加.*等于|相乘.*等于"]),
            Rule(name: "多级数列", patterns: ["作差|做差|作商|做商|等差数列|等比数列|多级数列|后项减前项"]),
        ],
        "数字运算|数量关系": [
            Rule(name: "浓度问题", patterns: ["浓度|溶液|溶质|盐水|酒精溶液|蒸发|含盐|加水|加盐"]),
            Rule(name: "工程问题", patterns: ["工程|效率|合作|单独.*完成|工期|工作量|工作效率|完成.*(天|小时|分钟)"]),
            Rule(name: "利润问题", patterns: ["利润|成本|售价|进价|标价|折扣|打折|定价|盈利|亏损|利润率"]),
            Rule(name: "行程问题", patterns: ["速度|相遇|追及|相向|同向|相距|路程|千米|公里|火车|列车|轮船|飞机|跑步|步行|小时.*(驶|行)"]),
            Rule(name: "排列组合与概率", patterns: ["排列|组合|概率|多少种|选法|任选|抽取|抽到|随机|种方法|几种|顺序"]),
            Rule(name: "几何问题", patterns: ["三角形|周长|面积|正方形|长方形|正方体|长方体|圆形|圆|圆柱|圆锥|梯形|体积|边长|半径|直径|棱长|表面积|阴影|球"]),
            Rule(name: "年龄问题", patterns: ["年龄|岁"]),
            Rule(name: "日期与周期", patterns: ["星期|周几|闰年|日期|每月|当月|周期|循环|工作日|休息日|连续.*天"]),
            Rule(name: "钟表问题", patterns: ["钟表|时针|分针|钟面|敲钟|挂钟"]),
            Rule(name: "植树与间隔", patterns: ["植树|种树|栽树|电线杆|间隔|两端都|棵"]),
            Rule(name: "牛吃草问题", patterns: ["牛吃草|牧草|长草|吃草"]),
            Rule(name: "平均数问题", patterns: ["平均分|平均数|平均成绩|总平均"]),
            Rule(name: "鸡兔同笼", patterns: ["鸡兔|头.*脚|脚.*头"]),
            Rule(name: "容斥问题", patterns: ["都不|既.*又|参加.*(和|与).*(又|都)|至少.*人"]),
            Rule(name: "极值与构造", patterns: ["最大|最小|最多|最少|保证|至少需要"]),
            Rule(name: "整除与余数", patterns: ["整除|因数|质数|公约数|公倍数|被.*除"]),
        ],
        "数字运算|数字运算": [
            Rule(name: "定义新运算", patterns: ["定义.*新运算|规定.*运算|新运算|定义.*运算"]),
            // 方程 before 巧算: "解方程…则x的值为" must not fall to 巧算's "的值为".
            Rule(name: "方程与比例", patterns: ["方程|的解|设.*为|比.*多|比.*少|比例|之比"]),
            Rule(name: "巧算与速算", patterns: ["计算|的值为|的值是|简便|估算|整数部分|尾数|巧算|结果"]),
            Rule(name: "整除与余数", patterns: ["整除|余数|除以|被.*除|倍数特征|因数|质数"]),
            Rule(name: "数位与数字", patterns: ["三位数|两位数|四位数|个位|十位|百位|位数|数字|页码|书页|号码|数位"]),
            Rule(name: "数列与规律", patterns: ["第.*个数|规律|数列|依次"]),
        ],
        "逻辑推理|逻辑判断": [
            // 削弱/加强/真假 must precede 翻译: scenario stems embed "如果…那么".
            Rule(name: "削弱质疑", patterns: ["削弱|质疑|反驳|反对|除.*外"]),
            Rule(name: "加强支持", patterns: ["最能支持|支持|加强|前提|假设|预设|使.*成立"]),
            Rule(name: "真假推理", patterns: ["真话|假话|为真|为假|预测|说谎|真.*假|假.*真|只有.*(一人|一句|一个|一项|一位)|属实"]),
            Rule(name: "分析推理", patterns: [
                "最大信息法|推理起点|分析题干|一家人|入选|每人只对了一半|各不相同|可以确定|根据以上(条件|信息|线索|表述)|排列|顺序|位置|相邻|座次|第.*(名|位)|对应|匹配|方阵|每行|每列|三人|四人|五人|其中有一个",
            ]),
            Rule(name: "翻译推理", patterns: ["翻译题干|如果.*那么|只有.*才|除非|当且仅当|充分条件|必要条件|假言"]),
            Rule(name: "结论推出", patterns: ["可以推出|由此可知|推出|推断出|由此可以|可推知|日常|得出结论"]),
            Rule(name: "评价型", patterns: ["推理方式|逻辑错误|最为接近|最相近|类似|与题干|论证.*(有效|无效)|实验方法"]),
        ],
        "逻辑推理|图形推理": [
            Rule(name: "空间重构", patterns: ["空间重构|折纸|展开|折叠|视图|三视图|表面|相邻面|截面|立体|相对面|骰子"]),
            Rule(name: "属性规律", patterns: ["属性规律|对称|曲直|开闭|封闭性|开放图形|封闭区域|生活化图形"]),
            Rule(name: "位置规律", patterns: ["位置规律|旋转|平移|翻转|移动|位置|间隔|字母|顺(逆)时针"]),
            Rule(name: "样式规律", patterns: ["样式规律|求同|求异|叠加|黑白运算|去同存异|去异存同|图形间关系"]),
            Rule(name: "数量规律", patterns: ["数量规律|面数量|线数量|点数量|角数量|元素|笔画|面的个数|线条|个数|汉字|包含数字"]),
        ],
        "逻辑推理|类比推理": [
            Rule(name: "语义关系", patterns: ["近义|反义|语义|比喻|象征|褒义|贬义|本意|引申|延伸含义|多义|字义|释义"]),
            Rule(name: "逻辑关系", patterns: ["种属|组成|包含|对应|因果|并列|交叉|属种|组成关系"]),
            Rule(name: "语法关系", patterns: ["词性|动宾|主谓|偏正|语法|成语结构|名词|形容词|修饰|主宾"]),
        ],
        "逻辑推理|定义判断": [
            Rule(name: "多定义", patterns: ["多定义|两个定义|包含.*定义|①②"]),
        ],
    ]

    // Residual class when no rule matches, per section.
    static let fallbacks: [String: String] = [
        "言语理解|逻辑填空": "实词辨析",
        "数字运算|数量关系": "和差倍比与方程",
        "数字运算|数字运算": "方程与和差倍比",
        "数字运算|数字推理": "多级数列",
        "逻辑推理|定义判断": "单定义",
    ]

    // ---------- HTML stripping ----------

    /// Strip tags and decode the common entities into plain text for rule
    /// matching, in the JS replacement order. Curly quotes are kept as-is
    /// (source uses literal “”), and the &ldquo;-style entities are
    /// deliberately NOT decoded — the word-quote patterns in the rule tables
    /// match the literal characters.
    static func stripHtml(_ html: String?) -> String {
        var text = html ?? ""
        text = regexReplace(text, pattern: "<[^>]*>", with: " ")
        text = regexReplace(text, pattern: "&nbsp;", with: " ", caseInsensitive: true)
        text = regexReplace(text, pattern: "&lt;", with: "<", caseInsensitive: true)
        text = regexReplace(text, pattern: "&gt;", with: ">", caseInsensitive: true)
        text = regexReplace(text, pattern: "&amp;", with: "&", caseInsensitive: true)
        text = regexReplace(text, pattern: "&quot;", with: "\"", caseInsensitive: true)
        text = regexReplace(text, pattern: "&#\\d+;", with: " ", caseInsensitive: true)
        text = regexReplace(text, pattern: "\\s+", with: " ")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func regexReplace(_ text: String, pattern: String, with replacement: String, caseInsensitive: Bool = false) -> String {
        var options: String.CompareOptions = [.regularExpression]
        if caseInsensitive { options.insert(.caseInsensitive) }
        return text.replacingOccurrences(of: pattern, with: replacement, options: options)
    }

    // ---------- Classification ----------

    static func rulesFor(category: String, section: String) -> [Rule]? {
        sectionRules["\(category)|\(section)"]
    }

    /// Classify one question → subCategory. Never throws; unknown → 其他.
    static func classify(category: String, section: String, question: String, analysis: String?) -> String {
        // 特有题型 / 资料分析: the HTML-defined section IS the sub-category.
        // The platform already splits 资料分析 into 文字资料/统计表/统计图/
        // 简单计算/比重问题/… on its answer card, so the rule engine must
        // not re-classify it.
        if category == "特有题型" || category == "资料分析" {
            return section.isEmpty ? defaultFallback : section
        }
        let text = "\(stripHtml(question)) \(stripHtml(analysis))"
        if let rules = rulesFor(category: category, section: section) {
            for rule in rules {
                for pattern in rule.patterns {
                    let range = NSRange(location: 0, length: (text as NSString).length)
                    if pattern.firstMatch(in: text, range: range) != nil { return rule.name }
                }
            }
        }
        return fallbacks["\(category)|\(section)"] ?? defaultFallback
    }
}
