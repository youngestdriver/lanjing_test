package com.qzh.lanjingquiz.Domain

import org.junit.Assert.assertEquals
import org.junit.Test

/** iOS QuestionClassifierTests.swift 逐字移植(apps/bank/test/question-classifier.test.js 为源)。 */
class QuestionClassifierTest {

    private fun rec(category: String, section: String, question: String, analysis: String = ""): String =
        QuestionClassifier.classify(category, section, question, analysis)

    // MARK: - stripHtml

    @Test
    fun `stripHtml strips tags decodes entities collapses whitespace`() {
        assertEquals("你好", QuestionClassifier.stripHtml("<p>你好</p>"))
        assertEquals("A B", QuestionClassifier.stripHtml("A&nbsp;&nbsp;&nbsp;B"))
        assertEquals("a&b <c> \"d\"", QuestionClassifier.stripHtml("a&amp;b &lt;c&gt; &quot;d&quot; &#65;"))
        assertEquals("多行 文本", QuestionClassifier.stripHtml("  <span>  多行\n文本 </span>  "))
        // 全角引号保持原样;&ldquo; 故意不解码(规则匹配原文全角引号)
        assertEquals("他说：“好”", QuestionClassifier.stripHtml("他说：“好”"))
        assertEquals("他说&ldquo;好&rdquo;", QuestionClassifier.stripHtml("他说&ldquo;好&rdquo;"))
    }

    // MARK: - 言语理解

    @Test
    fun `逻辑填空 虚词成语实词`() {
        assertEquals("虚词辨析", rec("言语理解", "逻辑填空", "依次填入画横线部分最恰当的一项是", "此处是表示转折的关联词"))
        assertEquals("成语辨析", rec("言语理解", "逻辑填空", "依次填入最恰当的是", "填入成语“栩栩如生”，形容非常逼真"))
        assertEquals("实词辨析", rec("言语理解", "逻辑填空", "依次填入画横线处最恰当的一项是", "第一空与“情怀”搭配的词语是")) // fallback
    }

    @Test
    fun `阅读理解 标题词句接语细节意图主旨`() {
        assertEquals("标题选择", rec("言语理解", "阅读理解", "最适合做这段文字标题的是"))
        assertEquals("词句理解", rec("言语理解", "阅读理解", "对文中“隐形的翅膀”一词理解正确的是", "指代"))
        assertEquals("接语选择", rec("言语理解", "阅读理解", "这段文字接下来最可能讲述的是"))
        assertEquals("细节理解", rec("言语理解", "阅读理解", "关于“当众羞辱”，下列说法不符合文意的是"))
        assertEquals("意图推断", rec("言语理解", "阅读理解", "这段文字意在强调"))
        assertEquals("主旨概括", rec("言语理解", "阅读理解", "这段文字主要说明了"))
        assertEquals("主旨概括", rec("言语理解", "阅读理解", "这段文字谈论的核心问题是"))
    }

    @Test
    fun `阅读理解 意图推断优先于主旨概括`() {
        assertEquals("意图推断", rec("言语理解", "阅读理解", "这段文字主要说明的是……意在强调……"))
    }

    @Test
    fun `语句表达 病句错别字排序接语词语填空衔接`() {
        assertEquals("病句辨析", rec("言语理解", "语句表达", "下列各句中，没有语病的一句是"))
        assertEquals("错别字", rec("言语理解", "语句表达", "下列句子中没有错别字的是"))
        assertEquals("语句排序", rec("言语理解", "语句表达", "将以上6个句子重新排列，语序正确的是"))
        assertEquals("接语选择", rec("言语理解", "语句表达", "这段文字接下来最可能讲的是"))
        assertEquals("词语填空", rec("言语理解", "语句表达", "依次填入下列横线处的词语，最恰当的一组是"))
        assertEquals("语句衔接", rec("言语理解", "语句表达", "以下哪句话最适合放在文中横线处？"))
    }

    @Test
    fun `语句表达 病句辨析优先于语句排序`() {
        assertEquals("病句辨析", rec("言语理解", "语句表达", "下列各句中没有语病且语序最恰当的一句是"))
    }

    // MARK: - 数字运算

    @Test
    fun `数字推理 幂次分数多重数阵拆分递推多级`() {
        assertEquals("幂次数列", rec("数字运算", "数字推理", "3，4，－2，12，－28，（ ）", "考虑幂次数列，存在负数优先考虑立方数"))
        assertEquals("分数数列", rec("数字运算", "数字推理", "1/2，2/3，3/5，（ ）", "本数列均为分数"))
        assertEquals("多重数列", rec("数字运算", "数字推理", "1，2，3，4，5，6，（ ）", "项数较多，考虑多重数列"))
        assertEquals("图形数阵", rec("数字运算", "数字推理", "下图数阵中问号处应填（ ）", "图形数阵"))
        assertEquals("数字拆分", rec("数字运算", "数字推理", "12，34，56，78，（ ）", "小数数列，考虑机械划分"))
        assertEquals("递推数列", rec("数字运算", "数字推理", "1，2，3，5，8，（ ）", "前两项相加等于第三项，递推数列"))
        assertEquals("多级数列", rec("数字运算", "数字推理", "3，5，9，17，（ ）", "作差后为等差数列"))
        // 仅 analysis 命中(公式图题干文本为空)
        assertEquals("分数数列", rec("数字运算", "数字推理", "", "该分数数列中各项均为分数"))
        // fallback → 多级数列
        assertEquals("多级数列", rec("数字运算", "数字推理", "3，5，7，（ ）", "无明显特征"))
    }

    @Test
    fun `数量关系 浓度工程利润行程排列组合几何年龄日期`() {
        assertEquals("浓度问题", rec("数字运算", "数量关系", "一瓶30%的盐溶液500克，加50克水后浓度变为？"))
        assertEquals("工程问题", rec("数字运算", "数量关系", "甲单独完成需10天，乙单独完成需15天，两人合作需几天"))
        assertEquals("利润问题", rec("数字运算", "数量关系", "某商品按定价的八折出售，仍可获利20%，成本为？"))
        assertEquals("行程问题", rec("数字运算", "数量关系", "一列火车以60千米/时的速度完全经过路边的一根电线杆用了6秒", "电线杆是参照物")) // not 植树
        assertEquals("排列组合与概率", rec("数字运算", "数量关系", "从5人中任选3人参加比赛，有多少种选法"))
        assertEquals("几何问题", rec("数字运算", "数量关系", "一个边长为3的正方体，其表面积为？"))
        assertEquals("年龄问题", rec("数字运算", "数量关系", "今年父亲38岁，儿子10岁，几年后父亲年龄是儿子的3倍"))
        assertEquals("日期与周期", rec("数字运算", "数量关系", "某年2月有5个星期日，则这一年的3月1日是星期几"))
        assertEquals("整除与余数", rec("数字运算", "数量关系", "请问539能被多少个不同的自然数整除？"))
        assertEquals("和差倍比与方程", rec("数字运算", "数量关系", "甲有100元，乙有60元，甲给乙多少元后两人一样多")) // fallback
    }

    @Test
    fun `数字运算 定义新运算巧算整除数位方程`() {
        assertEquals("定义新运算", rec("数字运算", "数字运算", "定义一种新的运算a※b=2a+b，则3※4的值为"))
        assertEquals("定义新运算", rec("数字运算", "数字运算", "规定一种新运算a△b=3a-2b，则5△2=？"))
        assertEquals("巧算与速算", rec("数字运算", "数字运算", "计算：9999×9999的值为"))
        assertEquals("整除与余数", rec("数字运算", "数字运算", "一个数除以7余3，除以5余2，这个数最小是"))
        assertEquals("数位与数字", rec("数字运算", "数字运算", "一个两位数，个位数字是十位数字的2倍，这个数可能是"))
        assertEquals("方程与比例", rec("数字运算", "数字运算", "解方程：3x+5=20，则x的值为"))
        assertEquals("方程与和差倍比", rec("数字运算", "数字运算", "甲乙两数的和为50，甲是乙的4倍，求甲")) // fallback
    }

    // MARK: - 逻辑推理

    @Test
    fun `逻辑判断 削弱先于翻译`() {
        assertEquals("削弱质疑", rec("逻辑推理", "逻辑判断", "有专家指出：如果电动自行车大量增加，将会带来更多事故。以下哪项最能削弱上述观点？"))
    }

    @Test
    fun `逻辑判断 加强真假分析翻译结论`() {
        assertEquals("加强支持", rec("逻辑推理", "逻辑判断", "以下哪项如果为真，最能支持上述结论？"))
        assertEquals("真假推理", rec("逻辑推理", "逻辑判断", "只有一人说真话，请问谁是小偷"))
        assertEquals("分析推理", rec("逻辑推理", "逻辑判断", "根据以上条件，可以确定甲、乙、丙三人的座位顺序是"))
        assertEquals("真假推理", rec("逻辑推理", "逻辑判断", "只有小王是大学生，小王才懂英语。若为假，则下列哪句为真")) // 真假 before 翻译
        assertEquals("翻译推理", rec("逻辑推理", "逻辑判断", "翻译题干：如果A那么B"))
        assertEquals("结论推出", rec("逻辑推理", "逻辑判断", "由此可以推出的是"))
    }

    @Test
    fun `图形推理 空间属性位置样式数量其他`() {
        assertEquals("空间重构", rec("逻辑推理", "图形推理", "折纸盒", "空间重构题"))
        assertEquals("属性规律", rec("逻辑推理", "图形推理", "观察图形规律", "优先考虑属性规律，图形均为轴对称图形"))
        assertEquals("位置规律", rec("逻辑推理", "图形推理", "观察图形规律", "元素组成相同，优先考虑位置规律，图形顺时针旋转"))
        assertEquals("样式规律", rec("逻辑推理", "图形推理", "观察图形规律", "考虑样式规律，去同存异"))
        assertEquals("数量规律", rec("逻辑推理", "图形推理", "观察图形规律", "考虑数量规律，每个图形均由3个圆组成"))
        assertEquals("其他", rec("逻辑推理", "图形推理", "与众不同的图形是", ""))
    }

    @Test
    fun `类比推理 语义逻辑语法关系`() {
        assertEquals("语义关系", rec("逻辑推理", "类比推理", "雪花对于（）相当于（）对于光泽", "近义关系"))
        assertEquals("逻辑关系", rec("逻辑推理", "类比推理", "鸽子对于（）相当于（）对于蓝色", "种属关系"))
        assertEquals("语法关系", rec("逻辑推理", "类比推理", "（）对于认真相当于对于负责", "词性均为形容词"))
    }

    @Test
    fun `定义判断 多定义单定义`() {
        assertEquals("多定义", rec("逻辑推理", "定义判断", "根据上述定义", "多定义题"))
        assertEquals("单定义", rec("逻辑推理", "定义判断", "根据上述定义，下列不属于训练的是")) // fallback
    }

    // MARK: - 资料分析

    @Test
    fun `资料分析 HTML既定section即子类`() {
        // 平台答题卡已拆分这些 section;分类器原样回显,不做规则重分类
        for (section in listOf(
            "文字资料", "统计表", "统计图", "简单计算", "比重问题", "平均数问题",
            "倍数与比值相关", "综合分析", "基期与现期", "长篇阅读（仅中国石油和国家管网考）",
        )) {
            // 会规则命中"增长率"的题干仍取 section
            assertEquals(section, rec("资料分析", section, "能够从上述资料中推出的是", "2019年同比增长了10%"))
        }
        // 空 section → 其他(同特有题型)
        assertEquals("其他", rec("资料分析", "", "题干"))
    }

    // MARK: - 特有题型

    @Test
    fun `特有题型 section即子类`() {
        for (section in listOf("时政", "职场题", "党性", "物理题（往年仅中石化和中石油考）", "谚语警句")) {
            assertEquals(section, rec("特有题型", section, "题干"))
        }
        // 空 section → 其他
        assertEquals("其他", rec("特有题型", "", "题干"))
    }

    // MARK: - fallbacks

    @Test
    fun `unknown category or section falls back to 其他`() {
        assertEquals("其他", rec("未知分类", "未知section", "题干"))
        assertEquals("其他", rec("言语理解", "不存在的section", "题干"))
    }
}
