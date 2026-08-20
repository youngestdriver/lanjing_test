package com.qzh.lanjingquiz.Domain

/**
 * 答题卡 HTML 解析 —— iOS ExamHtmlParser.swift 逐行移植(正则来自 apps/web/server.js parseExamHtml)。
 *
 * 卡片:questionsId/uuId/number/section/state/marked;state ∈ "unanswered"|"right"|"error";
 * 空 section → "(无分类)"(sectionOrder 键);组合题 insert-list 容器携带 combId。
 */
data class CardInfo(
    val questionsId: String,
    val uuId: String?,
    /** raw 题号:组合子题 "1.1" 原样保留。 */
    val number: String,
    val section: String,
    val state: String,
    val marked: Boolean,
    /** 资料分析组合题分组 id(insert-list 容器);常规题 null。 */
    val combId: String? = null,
)

data class ExamPage(
    /** 缺失时为 ""(iOS 为 nil;ApiClient.enterExam 已保证非空才进入流程)。 */
    val examResultsId: String,
    val examInfoId: String,
    val uuid: String?,
    val sections: List<String>,
    val cards: List<CardInfo>,
)

object ExamHtmlParser {

    fun parse(html: String, fallbackExamInfoId: String, knownResultsId: String? = null): ExamPage {
        val examResultsId = knownResultsId ?: extractVar("exam_results_id", html) ?: ""
        val examInfoId = extractVar("exam_info_id", html) ?: fallbackExamInfoId

        // section 标题(容忍尾随空格/多余 class:资料分析 comb section 输出 `<div class="card-content-title ">`)
        val sectionBounds = Regex("""<div class="([^"]*card-content-title[^"]*)">([^<]+)</div>""")
            .findAll(html).map { m -> m.groupValues[2] to m.range.first }.toList()

        // 组合题区间:insert-list div 携带自身 questionsId(combId);深度追踪找到闭合位置,
        // 仅真正被 insert-list 包裹的卡片继承 combId(comb section 后的常规卡片不得继承)。
        val combBounds = buildCombBounds(html)

        // 卡片块 = 相邻锚点之间的文本(server: html.split(/<a\s+href="#[^"]*">\s*/),跳过第 0 块)
        val anchors = Regex("""<a\s+href="#[^"]*">\s*""").findAll(html).map { it.range }.toList()

        val cards = mutableListOf<CardInfo>()
        val seen = mutableSetOf<String>()

        for ((i, anchor) in anchors.withIndex()) {
            // 锚点匹配含尾部空白;chunk 起点 = 匹配结束(不含)
            val chunkStart = anchor.last + 1
            val chunkEnd = if (i + 1 < anchors.size) anchors[i + 1].first else html.length
            if (chunkStart >= chunkEnd) continue
            val chunk = html.substring(chunkStart, chunkEnd)

            val qIdMatch = Regex("""questionsId="([^"]+)"""").find(chunk) ?: continue
            val qId = qIdMatch.groupValues[1].trim()
            if (qId.isEmpty() || !seen.add(qId)) continue

            val uuId = Regex("""uuId="([^"]+)"""").find(chunk)?.groupValues?.get(1)?.trim()

            // raw 题号:组合子题 "1.1"…"15.5",常规题纯整数 —— 原样保留
            val num = Regex(""">\s*(\d+(?:\.\d+)?)\s*</span>""").find(chunk)?.groupValues?.get(1)?.trim() ?: ""

            val stateMatch = Regex("""<div\b[^>]*class=["']([^"']*\bquestion_cbox\b[^"']*)["'][^>]*>""").find(chunk)
            val classes = stateMatch?.groupValues?.get(1)?.split(" ")?.map { it.trim() }?.toSet() ?: emptySet()
            val state = when {
                "right" in classes -> QuizLogic.STATE_RIGHT
                "error" in classes -> QuizLogic.STATE_ERROR
                else -> QuizLogic.STATE_UNANSWERED
            }
            val marked = "marked" in classes

            // section 归属:最后一个位于卡片之前的 section 标题(server 用全文 indexOf)
            val cardPos = html.indexOf("questionsId=\"$qId\"")
            var section = ""
            for ((title, pos) in sectionBounds.asReversed()) {
                if (cardPos > pos) { section = title; break }
            }

            var combId: String? = null
            for (comb in combBounds) {
                if (cardPos > comb.pos && cardPos < comb.end) { combId = comb.combId; break }
            }

            cards += CardInfo(qId, uuId, num, section, state, marked, combId)
        }

        // 每 section 统计与顺序("(无分类)" 占位空 section)
        val sections = mutableListOf<String>()
        for (c in cards) {
            val key = if (c.section.isEmpty()) "(无分类)" else c.section
            if (sections.none { it == key }) sections += key
        }

        val uuid = cards.firstOrNull()?.uuId ?: extractVar("uuId", html)
        return ExamPage(examResultsId, examInfoId, uuid, sections, cards)
    }

    private fun extractVar(name: String, html: String): String? =
        Regex("""var\s+$name\s*=\s*['"]([^'"]+)['"]""").find(html)?.groupValues?.get(1)

    private data class CombBound(val combId: String, val pos: Int, var end: Int)

    private fun buildCombBounds(html: String): List<CombBound> {
        val openRegex = Regex("""<div class="([^"]*insert-list[^"]*)"[^>]*questionsId="([^"]+)"""")
        val tagRegex = Regex("""<div\b[^>]*>|</div>""")
        val opens = openRegex.findAll(html).map { m ->
            CombBound(m.groupValues[2].trim(), m.range.first, m.range.first)
        }.toList()
        if (opens.isEmpty()) return emptyList()
        val combs = opens.toMutableList()
        val indexByPos = combs.mapIndexed { i, c -> c.pos to i }.toMap()
        var depth = 0
        var pendingIndex: Int? = null
        var pendingDepth = 0
        for (tag in tagRegex.findAll(html)) {
            val text = tag.value
            if (text.startsWith("</")) {
                depth -= 1
                val pending = pendingIndex
                if (pending != null && depth == pendingDepth) {
                    combs[pending].end = tag.range.last + 1   // 独占结尾,同 iOS
                    pendingIndex = null
                }
            } else {
                val index = indexByPos[tag.range.first]
                if (index != null) {
                    pendingIndex = index
                    pendingDepth = depth
                }
                depth += 1
            }
        }
        return combs
    }
}
