package com.qzh.lanjingquiz

import com.qzh.lanjingquiz.Network.QuestionDto
import com.qzh.lanjingquiz.Network.StringValue

/**
 * 考试模块共享夹具:iOS Fixtures.swift 逐字移植 + 考试流程专用 HTML。
 */
object Fixtures {

    /** 与 iOS Fixtures.examStartHTML 逐字一致:2 个 section、5 个锚(q5 与 q1 同 id 用于去重验证)。 */
    val examStartHTML = """
    <!DOCTYPE html>
    <html>
    <head>
    <script>
    var exam_results_id = '87380582';
    var exam_info_id = '1439658';
    </script>
    </head>
    <body>
    <div class="exam-content">
      <div class="card-content-title">科技常识</div>
      <div class="card-content-list">
        <a href="#1">
          <div class="question_cbox right marked">
            <span>1</span><span questionsId="q1" uuId="u1"></span>
          </div>
        </a>
        <a href="#2">
          <div class="question_cbox error">
            <span>2</span><span questionsId="q2" uuId="u2"></span>
          </div>
        </a>
      </div>
      <div class="card-content-title">逻辑推理</div>
      <div class="card-content-list">
        <a href="#3">
          <div class="question_cbox">
            <span>3</span><span questionsId="q3"></span>
          </div>
        </a>
        <a href="#4">
          <div class="question_cbox right">
            <span>4</span><span questionsId="q4" uuId="u4"></span>
          </div>
        </a>
        <a href="#5">
          <div class="question_cbox right">
            <span>5</span><span questionsId="q1" uuId="u1"></span>
          </div>
        </a>
      </div>
    </div>
    </body>
    </html>
    """.trimIndent()

    /** 无 section 标题(单 section → "(无分类)"),与 iOS 逐字一致。 */
    val examStartNoSectionsHTML = """
    <!DOCTYPE html>
    <html>
    <head><script>var exam_results_id = '999'; var exam_info_id = '888';</script></head>
    <body>
    <a href="#1">
      <div class="question_cbox right"><span>1</span><span questionsId="solo1" uuId="su1"></span></div>
    </a>
    </body>
    </html>
    """.trimIndent()

    /** 资料分析风格页:comb section(尾随空格 class、insert-list 包裹子题)+ 常规 section,与 iOS 逐字一致。 */
    val examStartCombHTML = """
    <!DOCTYPE html>
    <html>
    <head><script>var exam_results_id = '87396523'; var exam_info_id = 'E2';</script></head>
    <body>
    <div class="card-content-title ">文字资料(共15题,合计75.0分)</div>
    <div class="box-list ">
      <div class="insert-list inline-insert-list " questionsId="comb_wa ">
        <a href="#c1">
          <div class="box insert-box question_cbox s1 practice-mode-2 ">
            <span class="iconBox" questionsId="c1" uuId="u1" num="questions_c1">1.1</span>
          </div>
        </a>
        <a href="#c2">
          <div class="box insert-box question_cbox s1 practice-mode-2 ">
            <span class="iconBox" questionsId="c2" uuId="u1" num="questions_c2">15.5</span>
          </div>
        </a>
      </div>
    </div>
    <div class="card-content-title">言语理解</div>
    <a href="#reg1">
      <div class="question_cbox right"><span>16</span><span questionsId="reg1" uuId="u2"></span></div>
    </a>
    </body>
    </html>
    """.trimIndent()

    val examStartMinimalHTML = """
    <!DOCTYPE html>
    <html><body><p>empty</p></body></html>
    """.trimIndent()

    /** 考试流程专用:4 张全 unanswered 卡片(2 section),供 QuizViewModel 测试。 */
    val quizExamHtml = """
    <!DOCTYPE html>
    <html>
    <head><script>
    var exam_results_id = 'ER1';
    var exam_info_id = 'E1';
    </script></head>
    <body>
    <div class="exam-content">
      <div class="card-content-title">科技常识</div>
      <div class="card-content-list">
        <a href="#1"><div class="question_cbox"><span>1</span><span questionsId="q1" uuId="u1"></span></div></a>
        <a href="#2"><div class="question_cbox"><span>2</span><span questionsId="q2" uuId="u2"></span></div></a>
      </div>
      <div class="card-content-title">逻辑推理</div>
      <div class="card-content-list">
        <a href="#3"><div class="question_cbox"><span>3</span><span questionsId="q3" uuId="u3"></span></div></a>
        <a href="#4"><div class="question_cbox"><span>4</span><span questionsId="q4" uuId="u4"></span></div></a>
      </div>
    </div>
    </body>
    </html>
    """.trimIndent()

    /** 4 题:q1 单选 key1、q2 单选 key3、q3 多选 key1+key3、q4 无答案全 0。 */
    val quizQuestionBatch = listOf(
        questionDTO("q1", keys = listOf("1", "0", "0", "0"), testAnsRight = "A", analysis = "<p>解析1</p>"),
        questionDTO("q2", keys = listOf("0", "0", "1", "0"), testAnsRight = "C", analysis = "<p>解析2</p>"),
        questionDTO("q3", keys = listOf("1", "0", "1", "0"), testAnsRight = "A,C", analysis = "<p>解析3</p>"),
        questionDTO("q4", keys = listOf("0", "0", "0", "0"), testAnsRight = "", analysis = "<p>解析4</p>"),
    )

    fun questionDTO(
        id: String = "q1",
        question: String = "<p>1+1=?</p>",
        parentInfo: String? = null,
        answers: List<String> = listOf("<p>2</p>", "<p>3</p>", "<p>4</p>", "<p>5</p>"),
        keys: List<String> = listOf("1", "0", "0", "0"),
        testAns: String = "",
        testAnsRight: String = "",
        analysis: String = "",
    ): QuestionDto {
        fun key(i: Int) = keys.getOrNull(i)?.let { StringValue(it) }
        fun ans(i: Int) = answers.getOrNull(i) ?: ""
        return QuestionDto(
            id = id,
            question = question,
            parentInfo = parentInfo,
            answer1 = ans(0), answer2 = ans(1), answer3 = ans(2), answer4 = ans(3),
            key1 = key(0), key2 = key(1), key3 = key(2), key4 = key(3),
            testAns = testAns,
            testAnsRight = testAnsRight,
            analysis = analysis,
        )
    }
}
