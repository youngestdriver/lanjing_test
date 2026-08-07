import XCTest
@testable import LanjingQuiz

/// Ported from apps/bank/test/question-classifier.test.js — the JS suite
/// stays the source of truth; mirror any rule changes in both.
final class QuestionClassifierTests: XCTestCase {

    /// Minimal record helper: classify(question, analysis) for one paper section.
    private func rec(_ category: String, _ section: String, _ question: String, _ analysis: String = "") -> String {
        QuestionClassifier.classify(category: category, section: section, question: question, analysis: analysis)
    }

    // MARK: - stripHtml

    func testStripHtmlStripsTagsDecodesEntitiesCollapsesWhitespace() {
        XCTAssertEqual(QuestionClassifier.stripHtml("<p>你好</p>"), "你好")
        XCTAssertEqual(QuestionClassifier.stripHtml("A&nbsp;&nbsp;&nbsp;B"), "A B")
        XCTAssertEqual(QuestionClassifier.stripHtml("a&amp;b &lt;c&gt; &quot;d&quot; &#65;"), "a&b <c> \"d\"")
        XCTAssertEqual(QuestionClassifier.stripHtml("  <span>  多行\n文本 </span>  "), "多行 文本")
        // curly quotes stay literal; &ldquo; is NOT decoded (patterns match literals)
        XCTAssertEqual(QuestionClassifier.stripHtml("他说：“好”"), "他说：“好”")
        XCTAssertEqual(QuestionClassifier.stripHtml("他说&ldquo;好&rdquo;"), "他说&ldquo;好&rdquo;")
    }

    // MARK: - 言语理解

    func test逻辑填空虚词成语实词() {
        XCTAssertEqual(rec("言语理解", "逻辑填空", "依次填入画横线部分最恰当的一项是", "此处是表示转折的关联词"), "虚词辨析")
        XCTAssertEqual(rec("言语理解", "逻辑填空", "依次填入最恰当的是", "填入成语“栩栩如生”，形容非常逼真"), "成语辨析")
        XCTAssertEqual(rec("言语理解", "逻辑填空", "依次填入画横线处最恰当的一项是", "第一空与“情怀”搭配的词语是"), "实词辨析") // fallback
    }

    func test阅读理解标题词句接语细节意图主旨() {
        XCTAssertEqual(rec("言语理解", "阅读理解", "最适合做这段文字标题的是"), "标题选择")
        XCTAssertEqual(rec("言语理解", "阅读理解", "对文中“隐形的翅膀”一词理解正确的是", "指代"), "词句理解")
        XCTAssertEqual(rec("言语理解", "阅读理解", "这段文字接下来最可能讲述的是"), "接语选择")
        XCTAssertEqual(rec("言语理解", "阅读理解", "关于“当众羞辱”，下列说法不符合文意的是"), "细节理解")
        XCTAssertEqual(rec("言语理解", "阅读理解", "这段文字意在强调"), "意图推断")
        XCTAssertEqual(rec("言语理解", "阅读理解", "这段文字主要说明了"), "主旨概括")
        XCTAssertEqual(rec("言语理解", "阅读理解", "这段文字谈论的核心问题是"), "主旨概括")
    }

    func test阅读理解意图推断优先于主旨概括() {
        XCTAssertEqual(rec("言语理解", "阅读理解", "这段文字主要说明的是……意在强调……"), "意图推断")
    }

    func test语句表达病句错别字排序接语词语填空衔接() {
        XCTAssertEqual(rec("言语理解", "语句表达", "下列各句中，没有语病的一句是"), "病句辨析")
        XCTAssertEqual(rec("言语理解", "语句表达", "下列句子中没有错别字的是"), "错别字")
        XCTAssertEqual(rec("言语理解", "语句表达", "将以上6个句子重新排列，语序正确的是"), "语句排序")
        XCTAssertEqual(rec("言语理解", "语句表达", "这段文字接下来最可能讲的是"), "接语选择")
        XCTAssertEqual(rec("言语理解", "语句表达", "依次填入下列横线处的词语，最恰当的一组是"), "词语填空")
        XCTAssertEqual(rec("言语理解", "语句表达", "以下哪句话最适合放在文中横线处？"), "语句衔接")
    }

    func test语句表达病句辨析优先于语句排序() {
        XCTAssertEqual(rec("言语理解", "语句表达", "下列各句中没有语病且语序最恰当的一句是"), "病句辨析")
    }

    // MARK: - 数字运算

    func test数字推理幂次分数多重数阵拆分递推多级() {
        XCTAssertEqual(rec("数字运算", "数字推理", "3，4，－2，12，－28，（ ）", "考虑幂次数列，存在负数优先考虑立方数"), "幂次数列")
        XCTAssertEqual(rec("数字运算", "数字推理", "1/2，2/3，3/5，（ ）", "本数列均为分数"), "分数数列")
        XCTAssertEqual(rec("数字运算", "数字推理", "1，2，3，4，5，6，（ ）", "项数较多，考虑多重数列"), "多重数列")
        XCTAssertEqual(rec("数字运算", "数字推理", "下图数阵中问号处应填（ ）", "图形数阵"), "图形数阵")
        XCTAssertEqual(rec("数字运算", "数字推理", "12，34，56，78，（ ）", "小数数列，考虑机械划分"), "数字拆分")
        XCTAssertEqual(rec("数字运算", "数字推理", "1，2，3，5，8，（ ）", "前两项相加等于第三项，递推数列"), "递推数列")
        XCTAssertEqual(rec("数字运算", "数字推理", "3，5，9，17，（ ）", "作差后为等差数列"), "多级数列")
        // analysis-only classification (formula-image stems have empty text)
        XCTAssertEqual(rec("数字运算", "数字推理", "", "该分数数列中各项均为分数"), "分数数列")
        // fallback → 多级数列
        XCTAssertEqual(rec("数字运算", "数字推理", "3，5，7，（ ）", "无明显特征"), "多级数列")
    }

    func test数量关系浓度工程利润行程排列组合几何年龄日期() {
        XCTAssertEqual(rec("数字运算", "数量关系", "一瓶30%的盐溶液500克，加50克水后浓度变为？"), "浓度问题")
        XCTAssertEqual(rec("数字运算", "数量关系", "甲单独完成需10天，乙单独完成需15天，两人合作需几天"), "工程问题")
        XCTAssertEqual(rec("数字运算", "数量关系", "某商品按定价的八折出售，仍可获利20%，成本为？"), "利润问题")
        XCTAssertEqual(rec("数字运算", "数量关系", "一列火车以60千米/时的速度完全经过路边的一根电线杆用了6秒", "电线杆是参照物"), "行程问题") // not 植树
        XCTAssertEqual(rec("数字运算", "数量关系", "从5人中任选3人参加比赛，有多少种选法"), "排列组合与概率")
        XCTAssertEqual(rec("数字运算", "数量关系", "一个边长为3的正方体，其表面积为？"), "几何问题")
        XCTAssertEqual(rec("数字运算", "数量关系", "今年父亲38岁，儿子10岁，几年后父亲年龄是儿子的3倍"), "年龄问题")
        XCTAssertEqual(rec("数字运算", "数量关系", "某年2月有5个星期日，则这一年的3月1日是星期几"), "日期与周期")
        XCTAssertEqual(rec("数字运算", "数量关系", "请问539能被多少个不同的自然数整除？"), "整除与余数")
        XCTAssertEqual(rec("数字运算", "数量关系", "甲有100元，乙有60元，甲给乙多少元后两人一样多"), "和差倍比与方程") // fallback
    }

    func test数字运算定义新运算巧算整除数位方程() {
        XCTAssertEqual(rec("数字运算", "数字运算", "定义一种新的运算a※b=2a+b，则3※4的值为"), "定义新运算")
        XCTAssertEqual(rec("数字运算", "数字运算", "规定一种新运算a△b=3a-2b，则5△2=？"), "定义新运算")
        XCTAssertEqual(rec("数字运算", "数字运算", "计算：9999×9999的值为"), "巧算与速算")
        XCTAssertEqual(rec("数字运算", "数字运算", "一个数除以7余3，除以5余2，这个数最小是"), "整除与余数")
        XCTAssertEqual(rec("数字运算", "数字运算", "一个两位数，个位数字是十位数字的2倍，这个数可能是"), "数位与数字")
        XCTAssertEqual(rec("数字运算", "数字运算", "解方程：3x+5=20，则x的值为"), "方程与比例")
        XCTAssertEqual(rec("数字运算", "数字运算", "甲乙两数的和为50，甲是乙的4倍，求甲"), "方程与和差倍比") // fallback
    }

    // MARK: - 逻辑推理

    func test逻辑判断削弱先于翻译() {
        XCTAssertEqual(rec("逻辑推理", "逻辑判断", "有专家指出：如果电动自行车大量增加，将会带来更多事故。以下哪项最能削弱上述观点？"), "削弱质疑")
    }

    func test逻辑判断加强真假分析翻译结论() {
        XCTAssertEqual(rec("逻辑推理", "逻辑判断", "以下哪项如果为真，最能支持上述结论？"), "加强支持")
        XCTAssertEqual(rec("逻辑推理", "逻辑判断", "只有一人说真话，请问谁是小偷"), "真假推理")
        XCTAssertEqual(rec("逻辑推理", "逻辑判断", "根据以上条件，可以确定甲、乙、丙三人的座位顺序是"), "分析推理")
        XCTAssertEqual(rec("逻辑推理", "逻辑判断", "只有小王是大学生，小王才懂英语。若为假，则下列哪句为真"), "真假推理") // 真假 before 翻译
        XCTAssertEqual(rec("逻辑推理", "逻辑判断", "翻译题干：如果A那么B"), "翻译推理")
        XCTAssertEqual(rec("逻辑推理", "逻辑判断", "由此可以推出的是"), "结论推出")
    }

    func test图形推理空间属性位置样式数量其他() {
        XCTAssertEqual(rec("逻辑推理", "图形推理", "折纸盒", "空间重构题"), "空间重构")
        XCTAssertEqual(rec("逻辑推理", "图形推理", "观察图形规律", "优先考虑属性规律，图形均为轴对称图形"), "属性规律")
        XCTAssertEqual(rec("逻辑推理", "图形推理", "观察图形规律", "元素组成相同，优先考虑位置规律，图形顺时针旋转"), "位置规律")
        XCTAssertEqual(rec("逻辑推理", "图形推理", "观察图形规律", "考虑样式规律，去同存异"), "样式规律")
        XCTAssertEqual(rec("逻辑推理", "图形推理", "观察图形规律", "考虑数量规律，每个图形均由3个圆组成"), "数量规律")
        XCTAssertEqual(rec("逻辑推理", "图形推理", "与众不同的图形是", ""), "其他")
    }

    func test类比推理语义逻辑语法关系() {
        XCTAssertEqual(rec("逻辑推理", "类比推理", "雪花对于（）相当于（）对于光泽", "近义关系"), "语义关系")
        XCTAssertEqual(rec("逻辑推理", "类比推理", "鸽子对于（）相当于（）对于蓝色", "种属关系"), "逻辑关系")
        XCTAssertEqual(rec("逻辑推理", "类比推理", "（）对于认真相当于对于负责", "词性均为形容词"), "语法关系")
    }

    func test定义判断多定义单定义() {
        XCTAssertEqual(rec("逻辑推理", "定义判断", "根据上述定义", "多定义题"), "多定义")
        XCTAssertEqual(rec("逻辑推理", "定义判断", "根据上述定义，下列不属于训练的是"), "单定义") // fallback
    }

    // MARK: - 资料分析

    func test资料分析综合分析优先于增长率() {
        XCTAssertEqual(rec("资料分析", "比重问题", "能够从上述资料中推出的是", "2019年同比增长了10%"), "综合分析")
    }

    func test资料分析增长率与增长量() {
        XCTAssertEqual(rec("资料分析", "统计表", "2021年出口额同比增长约？", "同比增长率"), "增长率问题")
        XCTAssertEqual(rec("资料分析", "统计表", "2021年出口额同比增长约？", "增长了1200亿元"), "增长量问题")
    }

    func test资料分析比重平均数倍数基期现期简单计算() {
        XCTAssertEqual(rec("资料分析", "文字资料", "2021年进口额占进出口总额的比重为"), "比重问题")
        XCTAssertEqual(rec("资料分析", "文字资料", "2021年人均收入为多少元", "平均"), "平均数问题")
        XCTAssertEqual(rec("资料分析", "文字资料", "2021年出口额是进口额的多少倍"), "倍数与比值问题")
        XCTAssertEqual(rec("资料分析", "文字资料", "2020年基期量为多少", "上年同期"), "基期与现期问题")
        XCTAssertEqual(rec("资料分析", "文字资料", "2018年三季度景气指数最高的行业是"), "简单计算")
    }

    func test资料分析长篇阅读独立成类() {
        XCTAssertEqual(rec("资料分析", "长篇阅读（仅中国石油和国家管网考）", "以下这段文字最适合放在原文中的哪个位置"), "长篇阅读")
        XCTAssertEqual(rec("资料分析", "长篇阅读（仅中国石油和国家管网考）", "根据本文，《诗经》中记载的制衣过程不包括", "A项根据文章第④段"), "长篇阅读")
    }

    // MARK: - 特有题型

    func test特有题型section即子类() {
        for section in ["时政", "职场题", "党性", "物理题（往年仅中石化和中石油考）", "谚语警句"] {
            XCTAssertEqual(rec("特有题型", section, "题干"), section)
        }
        // empty section → 其他
        XCTAssertEqual(rec("特有题型", "", "题干"), "其他")
    }

    // MARK: - fallbacks

    func testUnknownCategoryOrSectionFallsBackTo其他() {
        XCTAssertEqual(rec("未知分类", "未知section", "题干"), "其他")
        XCTAssertEqual(rec("言语理解", "不存在的section", "题干"), "其他")
        XCTAssertEqual(rec("资料分析", "综合", "无法判定的题干"), "其他")
    }
}
