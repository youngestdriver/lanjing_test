package com.qzh.lanjingquiz.Domain

/**
 * 题型细分分类器 —— apps/bank/lib/question-classifier.js 逐条移植(iOS QuestionClassifier.swift
 * 已移植一次,规则表逐字对照;测试覆盖全部规则)。爬取时写 subCategory。
 *
 * 特有题型/资料分析 两卷绕过规则引擎:平台答题卡已把 资料分析 拆分为 文字资料/统计表/统计图/
 * 简单计算/比重问题/…,HTML section 即 subCategory,空 section → 其他。
 *
 * HTML 剥离顺序(严格):<[^>]*> → " " → &nbsp; → " "(大小写不敏感) → &lt; → "<" →
 * &gt; → ">" → &amp; → "&" → &quot; → "\"" → &#\d+; → " "(大小写不敏感) → \s+ → " " → trim;
 * &ldquo;/&rdquo; 故意不解码(规则匹配原文全角引号)。
 */
object QuestionClassifier {

    const val DEFAULT_FALLBACK = "其他"
    const val DEFAULT_SECTION = "(无分类)"

    private data class Rule(val name: String, val patterns: List<Regex>)

    private fun rule(name: String, vararg patterns: String) = Rule(name, patterns.map(::Regex))

    // ---------- 规则表(键 "category|section";数组顺序即优先级,首个命中胜出) ----------
    // 顺序即行为(如 削弱 在 翻译 前 —— 情景题干内嵌 "如果…那么")。

    private val sectionRules: Map<String, List<Rule>> = mapOf(
        "言语理解|逻辑填空" to listOf(
            rule("虚词辨析", "关联词|虚词|连词|连接词|衔接词|表示?(转折|递进|并列|因果|假设|让步|承接|条件)"),
            rule("成语辨析", """成语|[“"][^”"]{4}[”"](?:比喻|形容|指|强调|体现)"""),
        ),
        "言语理解|阅读理解" to listOf(
            rule("标题选择", "标题"),
            rule("词句理解", """对(文中|文段)?[“"][^”"]{1,20}[”"].{0,15}(理解|意思)|[“"][^”"]{1,12}[”"]一词|加点的词|指代|代词|“这”|“前者”|“后者”|相对面"""),
            rule("接语选择", "接下来|下文|承接|接语"),
            rule("细节理解", "不符合|不相符|不符|不正确|不恰当|可以知道|可以看出|关于.*(正确|错误)|说法|表现的是|属于|未提及|没有提到|符合文意|理解正确|不能推出|可以推出|推出|推断|表述.*(正确|错误)"),
            rule("意图推断", "意在|想要|想表达|旨在|启示|告诉|意图|强调|反映.*问题"),
            rule("主旨概括", "主要说明|主要讲述|主要谈论|主旨|概括|中心|主要观点|主要内容|说明的是|谈论|说明了|主要介绍|介绍了|复述|关键词|重在"),
        ),
        "言语理解|语句表达" to listOf(
            rule("病句辨析", "语病|病句|搭配不当|成分残缺|句式杂糅|语序不当|成分赘余|结构混乱|歧义|标点"),
            rule("错别字", "错字|错别字"),
            rule("语句排序", "排序|最连贯|语序|确定首句|对比选项|重新排列"),
            rule("接语选择", "接语|接下来|下文"),
            rule("词语填空", "填入.*最恰当|横线处.*(词语|成语)|词语.*使用|依次.*最恰当"),
            rule("语句衔接", "横线|填入.*句子|衔接|承上启下|空格|语意连贯|括号"),
        ),
        "数字运算|数字推理" to listOf(
            rule("幂次数列", "幂次|幂方|平方数|立方数"),
            rule("分数数列", "分数数列|均为分数|全部都是分数|全为分数|都是分数|分式"),
            rule("多重数列", "多重数列|交叉|项数较多|两两分组|奇偶项|奇数项|偶数项"),
            rule("图形数阵", "图形数阵|数阵|图中|图形"),
            rule("数字拆分", "机械划分|因式分解|小数数列|拆分|小数点|个位.*十位|数位"),
            rule("递推数列", "递推|前项|前两项|相加.*等于|相乘.*等于"),
            rule("多级数列", "作差|做差|作商|做商|等差数列|等比数列|多级数列|后项减前项"),
        ),
        "数字运算|数量关系" to listOf(
            rule("浓度问题", "浓度|溶液|溶质|盐水|酒精溶液|蒸发|含盐|加水|加盐"),
            rule("工程问题", "工程|效率|合作|单独.*完成|工期|工作量|工作效率|完成.*(天|小时|分钟)"),
            rule("利润问题", "利润|成本|售价|进价|标价|折扣|打折|定价|盈利|亏损|利润率"),
            rule("行程问题", "速度|相遇|追及|相向|同向|相距|路程|千米|公里|火车|列车|轮船|飞机|跑步|步行|小时.*(驶|行)"),
            rule("排列组合与概率", "排列|组合|概率|多少种|选法|任选|抽取|抽到|随机|种方法|几种|顺序"),
            rule("几何问题", "三角形|周长|面积|正方形|长方形|正方体|长方体|圆形|圆|圆柱|圆锥|梯形|体积|边长|半径|直径|棱长|表面积|阴影|球"),
            rule("年龄问题", "年龄|岁"),
            rule("日期与周期", "星期|周几|闰年|日期|每月|当月|周期|循环|工作日|休息日|连续.*天"),
            rule("钟表问题", "钟表|时针|分针|钟面|敲钟|挂钟"),
            rule("植树与间隔", "植树|种树|栽树|电线杆|间隔|两端都|棵"),
            rule("牛吃草问题", "牛吃草|牧草|长草|吃草"),
            rule("平均数问题", "平均分|平均数|平均成绩|总平均"),
            rule("鸡兔同笼", "鸡兔|头.*脚|脚.*头"),
            rule("容斥问题", "都不|既.*又|参加.*(和|与).*(又|都)|至少.*人"),
            rule("极值与构造", "最大|最小|最多|最少|保证|至少需要"),
            rule("整除与余数", "整除|因数|质数|公约数|公倍数|被.*除"),
        ),
        "数字运算|数字运算" to listOf(
            rule("定义新运算", "定义.*新运算|规定.*运算|新运算|定义.*运算"),
            // 方程 before 巧算:"解方程…则x的值为" 不得落入巧算的 "的值为"
            rule("方程与比例", "方程|的解|设.*为|比.*多|比.*少|比例|之比"),
            rule("巧算与速算", "计算|的值为|的值是|简便|估算|整数部分|尾数|巧算|结果"),
            rule("整除与余数", "整除|余数|除以|被.*除|倍数特征|因数|质数"),
            rule("数位与数字", "三位数|两位数|四位数|个位|十位|百位|位数|数字|页码|书页|号码|数位"),
            rule("数列与规律", "第.*个数|规律|数列|依次"),
        ),
        "逻辑推理|逻辑判断" to listOf(
            // 削弱/加强/真假 必须排在 翻译 前:情景题干内嵌 "如果…那么"
            rule("削弱质疑", "削弱|质疑|反驳|反对|除.*外"),
            rule("加强支持", "最能支持|支持|加强|前提|假设|预设|使.*成立"),
            rule("真假推理", "真话|假话|为真|为假|预测|说谎|真.*假|假.*真|只有.*(一人|一句|一个|一项|一位)|属实"),
            rule("分析推理", "最大信息法|推理起点|分析题干|一家人|入选|每人只对了一半|各不相同|可以确定|根据以上(条件|信息|线索|表述)|排列|顺序|位置|相邻|座次|第.*(名|位)|对应|匹配|方阵|每行|每列|三人|四人|五人|其中有一个"),
            rule("翻译推理", "翻译题干|如果.*那么|只有.*才|除非|当且仅当|充分条件|必要条件|假言"),
            rule("结论推出", "可以推出|由此可知|推出|推断出|由此可以|可推知|日常|得出结论"),
            rule("评价型", "推理方式|逻辑错误|最为接近|最相近|类似|与题干|论证.*(有效|无效)|实验方法"),
        ),
        "逻辑推理|图形推理" to listOf(
            rule("空间重构", "空间重构|折纸|展开|折叠|视图|三视图|表面|相邻面|截面|立体|相对面|骰子"),
            rule("属性规律", "属性规律|对称|曲直|开闭|封闭性|开放图形|封闭区域|生活化图形"),
            rule("位置规律", "位置规律|旋转|平移|翻转|移动|位置|间隔|字母|顺(逆)时针"),
            rule("样式规律", "样式规律|求同|求异|叠加|黑白运算|去同存异|去异存同|图形间关系"),
            rule("数量规律", "数量规律|面数量|线数量|点数量|角数量|元素|笔画|面的个数|线条|个数|汉字|包含数字"),
        ),
        "逻辑推理|类比推理" to listOf(
            rule("语义关系", "近义|反义|语义|比喻|象征|褒义|贬义|本意|引申|延伸含义|多义|字义|释义"),
            rule("逻辑关系", "种属|组成|包含|对应|因果|并列|交叉|属种|组成关系"),
            rule("语法关系", "词性|动宾|主谓|偏正|语法|成语结构|名词|形容词|修饰|主宾"),
        ),
        "逻辑推理|定义判断" to listOf(
            rule("多定义", "多定义|两个定义|包含.*定义|①②"),
        ),
    )

    /** 无规则命中时的兜底,按 (category|section)。 */
    private val fallbacks: Map<String, String> = mapOf(
        "言语理解|逻辑填空" to "实词辨析",
        "数字运算|数量关系" to "和差倍比与方程",
        "数字运算|数字运算" to "方程与和差倍比",
        "数字运算|数字推理" to "多级数列",
        "逻辑推理|定义判断" to "单定义",
    )

    // ---------- HTML 剥离(JS 替换顺序) ----------

    fun stripHtml(s: String): String {
        var text = s
        text = Regex("<[^>]*>").replace(text, " ")
        text = Regex("&nbsp;", RegexOption.IGNORE_CASE).replace(text, " ")
        text = Regex("&lt;", RegexOption.IGNORE_CASE).replace(text, "<")
        text = Regex("&gt;", RegexOption.IGNORE_CASE).replace(text, ">")
        text = Regex("&amp;", RegexOption.IGNORE_CASE).replace(text, "&")
        text = Regex("&quot;", RegexOption.IGNORE_CASE).replace(text, "\"")
        text = Regex("&#\\d+;", RegexOption.IGNORE_CASE).replace(text, " ")
        text = Regex("\\s+").replace(text, " ")
        return text.trim()
    }

    /** section 清洗:仅剥离尾部 "(共…)"(全角括号);空/纯空白 → "(无分类)"。 */
    fun cleanSection(section: String): String {
        val cleaned = Regex("""\(共[^)]*\)\s*$""").replace(section, "")
        val trimmed = cleaned.trim()
        return if (trimmed.isEmpty()) DEFAULT_SECTION else trimmed
    }

    // ---------- 分类 ----------

    /**
     * 一题 → subCategory。永不抛错;未知 → 其他。
     * 特有题型/资料分析:HTML section 即 subCategory,规则引擎不重分类。
     */
    fun classify(category: String, section: String, question: String, analysis: String): String {
        if (category == "特有题型" || category == "资料分析") {
            return if (section.isEmpty()) DEFAULT_FALLBACK else section
        }
        val text = "${stripHtml(question)} ${stripHtml(analysis)}"
        for (rule in sectionRules["$category|$section"].orEmpty()) {
            for (pattern in rule.patterns) {
                if (pattern.containsMatchIn(text)) return rule.name
            }
        }
        return fallbacks["$category|$section"] ?: DEFAULT_FALLBACK
    }
}
