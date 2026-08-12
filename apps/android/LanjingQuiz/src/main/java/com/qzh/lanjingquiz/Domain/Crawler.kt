package com.qzh.lanjingquiz.Domain

import com.qzh.lanjingquiz.Data.AnswerShape
import com.qzh.lanjingquiz.Data.BankMeta
import com.qzh.lanjingquiz.Data.BankQuestion
import com.qzh.lanjingquiz.Data.BankStorage
import com.qzh.lanjingquiz.Data.CrawlLogEntry
import com.qzh.lanjingquiz.Network.ApiException
import com.qzh.lanjingquiz.Network.EnterExamResult
import com.qzh.lanjingquiz.Network.ExamDto
import com.qzh.lanjingquiz.Network.QuestionBatchRequest
import com.qzh.lanjingquiz.Network.QuestionDto
import com.qzh.lanjingquiz.Network.UpstreamApi
import com.qzh.lanjingquiz.Support.Formatters
import com.qzh.lanjingquiz.Support.HtmlHelpers
import kotlinx.coroutines.CancellationException

/**
 * 练习题库爬取器 —— iOS PracticeUpstreamClient.crawlAllPapers 移植(collector runCollection)。
 *
 * 目标筛选:style 含 "机考题库" 且卷名含五类之一(首次命中优先);wfs 只选进卷路径。
 * 尝试生命周期:wfs=1 进卷创建新作答,抓取后 best-effort submitExam(fire-and-forget 吞错);
 * wfs=0 只读永不结束;练习答案永不提交上游。
 *
 * refresh=false(首次/增量):meta.papers 已标记卷跳过;按 _id 去重追加;每卷后写 meta
 * (papers+counts);连续 3 卷进入失败停止(已存卷保留)。
 * refresh=true(更新题库):重爬全部,任一失败不提交(旧库保留);成功后 5 分类文件 + meta
 * 最后写原子替换。
 */
class Crawler(
    private val api: UpstreamApi,
    private val storage: BankStorage,
) {

    /** 爬取进度(UI 用);phase 为机器名(paperList/enter/save/endAttempt/skip),显示名属 UI 层。 */
    data class CrawlProgress(
        val current: Int,
        val total: Int,
        val paperName: String?,
        val phase: String,
    )

    suspend fun crawl(refresh: Boolean, onProgress: (CrawlProgress) -> Unit): Result<Unit> =
        try {
            runCrawl(refresh, onProgress)
            Result.success(Unit)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            Result.failure(e)
        }

    private suspend fun runCrawl(refresh: Boolean, onProgress: (CrawlProgress) -> Unit) {
        // 日志写失败绝不打断爬取(best-effort)
        val log = { entry: CrawlLogEntry -> runCatching { storage.appendCrawlLog(entry) } }

        val papers: List<ExamDto>
        try {
            papers = api.examList().exams.filter { isTargetExam(it) }
            log(CrawlLogEntry(Formatters.isoNow(), null, "全部试卷",
                CrawlLogEntry.STEP_PAPER_LIST, CrawlLogEntry.OUTCOME_SUCCESS, "共 ${papers.size} 份试卷"))
        } catch (e: Throwable) {
            log(CrawlLogEntry(Formatters.isoNow(), null, "全部试卷",
                CrawlLogEntry.STEP_PAPER_LIST, CrawlLogEntry.OUTCOME_FAILURE, e.message))
            throw e
        }
        onProgress(CrawlProgress(0, papers.size, null, CrawlLogEntry.STEP_PAPER_LIST))

        val previousRound = storage.readMeta()?.round ?: 0
        var meta = if (refresh) null else storage.readMeta()
        var counts = meta?.counts ?: emptyMap()
        var seenIds = if (refresh) mutableSetOf() else loadSeenIds(storage).toMutableSet()
        val byCategory = mutableMapOf<String, MutableList<BankQuestion>>()  // refresh 模式
        val papersDone = mutableMapOf<String, Boolean>()
        var consecutiveFailures = 0
        val failedPapers = mutableListOf<String>()  // refresh 模式:任一失败即不提交

        for ((index, paper) in papers.withIndex()) {
            val paperId = paper.id.toString()
            if (!refresh && meta?.papers?.get(paperId) == true) {
                log(CrawlLogEntry(Formatters.isoNow(), paperId, paper.name,
                    CrawlLogEntry.STEP_SKIP, CrawlLogEntry.OUTCOME_SKIPPED, "已爬取，跳过"))
                onProgress(CrawlProgress(index + 1, papers.size, paper.name, CrawlLogEntry.STEP_SKIP))
                continue
            }

            val (session, records) = try {
                enterPaper(paper)
            } catch (e: Throwable) {
                log(CrawlLogEntry(Formatters.isoNow(), paperId, paper.name,
                    CrawlLogEntry.STEP_ENTER, CrawlLogEntry.OUTCOME_FAILURE, e.message))
                failedPapers += paper.name
                consecutiveFailures += 1
                // refresh:继续爬(日志记录每一份失败卷),最后统一不提交;增量:连败 3 次停止
                if (!refresh && consecutiveFailures >= 3) throw e
                onProgress(CrawlProgress(index + 1, papers.size, paper.name, CrawlLogEntry.STEP_ENTER))
                continue
            }
            consecutiveFailures = 0
            log(CrawlLogEntry(Formatters.isoNow(), paperId, paper.name,
                CrawlLogEntry.STEP_ENTER, CrawlLogEntry.OUTCOME_SUCCESS, "${records.size} 题"))

            val newRecords = records.filter { seenIds.add(it.id) }
            try {
                if (refresh) {
                    for (record in newRecords) {
                        byCategory.getOrPut(record.category) { mutableListOf() }.add(record)
                    }
                } else {
                    for ((category, categoryRecords) in newRecords.groupBy { it.category }) {
                        storage.appendRecords(category, categoryRecords)
                        counts = counts + (category to (counts[category] ?: 0) + categoryRecords.size)
                    }
                }
                log(CrawlLogEntry(Formatters.isoNow(), paperId, paper.name,
                    CrawlLogEntry.STEP_SAVE, CrawlLogEntry.OUTCOME_SUCCESS, "${newRecords.size} 题"))
            } catch (e: Throwable) {
                log(CrawlLogEntry(Formatters.isoNow(), paperId, paper.name,
                    CrawlLogEntry.STEP_SAVE, CrawlLogEntry.OUTCOME_FAILURE, e.message))
                throw e
            }

            papersDone[paperId] = true
            endAttempt(paper, session)
            log(CrawlLogEntry(Formatters.isoNow(), paperId, paper.name,
                CrawlLogEntry.STEP_END_ATTEMPT, CrawlLogEntry.OUTCOME_SUCCESS, "已发起结束请求"))

            // 增量模式每卷后存 meta(断点续爬);round 保持 previousRound,最终完成 +1
            if (!refresh) {
                meta = BankMeta(
                    version = 1, round = previousRound, lastRun = meta?.lastRun,
                    targets = BankLogic.categories, counts = counts, papers = papersDone,
                )
                storage.writeMeta(meta)
            }
            onProgress(CrawlProgress(index + 1, papers.size, paper.name, CrawlLogEntry.STEP_END_ATTEMPT))
        }

        if (failedPapers.isNotEmpty()) {
            throw ApiException(
                ApiException.UPSTREAM,
                "${failedPapers.size} 份试卷爬取失败：${failedPapers.joinToString("、")}",
            )
        }

        val finalCounts = if (refresh) byCategory.mapValues { (_, v) -> v.size } else counts
        val finalMeta = BankMeta(
            version = 1, round = previousRound + 1, lastRun = Formatters.isoNow(),
            targets = BankLogic.categories, counts = finalCounts, papers = papersDone,
        )
        if (refresh) {
            // 全部 5 个分类文件(无记录的分类写空文件),然后 meta 最后写 —— 原子提交点
            val files = BankLogic.categories.associateWith { category -> byCategory[category] ?: emptyList() }
            storage.writeAll(files)
            storage.writeMeta(finalMeta)
        } else {
            storage.writeMeta(finalMeta)
        }
    }

    /** 进卷 → 解析答题卡 → 批拉取 → 分类映射为 BankQuestion(返回会话供 endAttempt)。 */
    private suspend fun enterPaper(paper: ExamDto): Pair<EnterExamResult, List<BankQuestion>> {
        val session = api.enterExam(paper.id.toString(), isNew = paper.wfs == 1)
        val category = matchCategory(paper.name)
            ?: throw ApiException(ApiException.INVALID_RESPONSE, "服务器响应异常")
        val page = ExamHtmlParser.parse(
            api.examStartHtml(paper.id.toString()),
            fallbackExamInfoId = paper.id.toString(),
            knownResultsId = session.examResultsId,
        )
        val dtos = fetchAll(page.cards, session.examResultsId, session.examInfoId, session.uuid)
        // 答题卡 section 与题目按 questionsId 关联(first wins),位置兜底(iOS PracticeMapping.join)
        val cardById = page.cards.associateBy { it.questionsId }
        val records = dtos.mapIndexed { i, dto ->
            val card = cardById[dto.id] ?: page.cards.getOrNull(i)
            bankQuestion(dto, card?.section ?: QuestionClassifier.DEFAULT_SECTION, category, paper.name)
        }
        return session to records
    }

    /** 批拉取:按 combId 分单元(单元内不混 combId),每批 ≤50(与考试模块 fetchAll 同规则)。 */
    private suspend fun fetchAll(
        cards: List<CardInfo>,
        resultsId: String,
        infoId: String,
        uuid: String?,
    ): List<QuestionDto> {
        val combByTestId = cards.filter { it.combId != null }.associate { it.questionsId to it.combId!! }
        val units = mutableListOf<Pair<List<String>, String?>>()
        var unit = mutableListOf<String>()
        var unitComb: String? = null
        for (card in cards) {
            val comb = combByTestId[card.questionsId]
            if (unit.isNotEmpty() && (unitComb != comb || unit.size >= 50)) {
                units += unit.toList() to unitComb
                unit = mutableListOf()
                unitComb = null
            }
            unit += card.questionsId
            unitComb = comb
        }
        if (unit.isNotEmpty()) units += unit.toList() to unitComb

        val all = mutableListOf<QuestionDto>()
        for ((testIds, combId) in units) {
            all += api.fetchQuestions(QuestionBatchRequest(
                examResultsId = resultsId,
                examInfoId = infoId,
                testIds = testIds,
                uuids = testIds.map { uuid ?: "null" },
                combId = combId,
            ))
        }
        return all
    }

    /** 上游 DTO → BankQuestion(port of PracticeMapping.bankQuestion):4 槽保留/正确字母/分类器。 */
    private fun bankQuestion(dto: QuestionDto, section: String, category: String, paperName: String): BankQuestion {
        val correctKeys = listOf(dto.key1, dto.key2, dto.key3, dto.key4)
            .mapIndexedNotNull { i, key -> if (key?.value == "1") LETTERS[i] else null }
        val answer: AnswerShape? = when {
            correctKeys.size > 1 -> AnswerShape.Multi(correctKeys)
            correctKeys.size == 1 -> AnswerShape.Single(correctKeys[0])
            dto.testAnsRight.isNotEmpty() -> AnswerShape.Single(dto.testAnsRight)
            else -> null  // 诚实"未知"
        }
        val cleanedSection = QuestionClassifier.cleanSection(section)
        return BankQuestion(
            id = dto.id,
            category = category,
            section = cleanedSection,
            subCategory = QuestionClassifier.classify(category, cleanedSection, dto.question, dto.analysis),
            question = HtmlHelpers.normalizeImgSrcs(dto.question) ?: "",
            stem = HtmlHelpers.normalizeImgSrcs(dto.parentInfo),
            options = dto.optionTexts(),
            answer = answer,
            analysis = HtmlHelpers.normalizeImgSrcs(dto.analysis),
            sourceExamName = paperName,
            round = null,
            collectedAt = null,
        )
    }

    /** 本 app 创建的作答(wfs=1)best-effort 结束;全部错误吞掉;wfs=0 永不结束。 */
    private suspend fun endAttempt(paper: ExamDto, session: EnterExamResult) {
        if (paper.wfs != 1) return
        // 练习卷 exam_ending 返回 JSON 而非结果页 → submitExam 报"考试未能结束" —— 预期,吞掉
        runCatching { api.submitExam(paper.id.toString(), session.examResultsId) }
    }

    /** 全库已有记录 id(增量去重)。 */
    private fun loadSeenIds(storage: BankStorage): Set<String> =
        BankLogic.categories.flatMap { storage.readCategory(it).map { q -> q.id } }.toSet()

    companion object {
        private val LETTERS = listOf("A", "B", "C", "D")

        /** 五类之一首次命中(卷名含分类字符串)。 */
        fun matchCategory(paperName: String): String? =
            BankLogic.categories.firstOrNull { paperName.contains(it) }

        /** 目标试卷:style 含 "机考题库" 且卷名含五类之一(与 wfs 无关,wfs 只选进卷路径)。 */
        fun isTargetExam(exam: ExamDto): Boolean =
            exam.styleName?.contains("机考题库") == true && matchCategory(exam.name) != null
    }
}
