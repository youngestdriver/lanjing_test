package com.qzh.lanjingquiz.Domain

import com.qzh.lanjingquiz.Data.AnswerShape
import com.qzh.lanjingquiz.Data.BankMeta
import com.qzh.lanjingquiz.Data.BankQuestion
import com.qzh.lanjingquiz.Data.BankStorage
import com.qzh.lanjingquiz.Data.CrawlLogEntry
import com.qzh.lanjingquiz.Data.InMemorySecureStore
import com.qzh.lanjingquiz.Network.ApiClient
import com.qzh.lanjingquiz.Network.PersistentCookieJar
import com.qzh.lanjingquiz.Network.PrefsCookieStore
import com.qzh.lanjingquiz.Network.UpstreamApi
import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.util.concurrent.TimeUnit

/**
 * 爬取器行为测试:MockWebServer 驱动真实 ApiClient + 内存 FakeBankStorage。
 * 覆盖 spec §五:目标筛选/wfs 生命周期/增量断点/3 连败停/刷新原子提交/去重/分类/分批。
 */
class CrawlerTest {

    private lateinit var server: MockWebServer
    private lateinit var api: UpstreamApi
    private lateinit var storage: FakeBankStorage
    private val progresses = mutableListOf<Crawler.CrawlProgress>()

    @Before
    fun setUp() {
        server = MockWebServer()
        server.start()
        val cookieStore = PrefsCookieStore(InMemorySecureStore())
        val jar = PersistentCookieJar(cookieStore)
        val http = OkHttpClient.Builder()
            .cookieJar(jar)
            .followRedirects(false)
            .followSslRedirects(false)
            .build()
        api = ApiClient(http, jar, server.url("/").toString().trimEnd('/'))
        storage = FakeBankStorage()
        progresses.clear()
    }

    @After
    fun tearDown() {
        server.shutdown()
    }

    private fun crawler() = Crawler(api, storage)

    // ---- MockWebServer 响应序列 ----

    private fun enqueueExamList(vararg papers: String) {
        server.enqueue(MockResponse().setBody(
            """{"success":true,"bizContent":{"total":${papers.size},"styles":[],"examInfoModelList":[${papers.joinToString(",")}]}}"""
        ))
    }

    private fun paper(id: Int, name: String, style: String = "机考题库", wfs: Int = 1) =
        """{"id":$id,"examName":"$name","examStyleName":"$style","wfs":$wfs}"""

    /** wfs=1 卷完整序列:进卷队列 → exam_start ×2 → 题目 → 结束作答(exam_ending 返回 JSON → 吞错)。 */
    private fun enqueueNewPaper(html: String, questionsJson: String) {
        server.enqueue(MockResponse().setBody("{}"))                                  // enter_exam
        server.enqueue(MockResponse().setBody("{}"))                                  // faceCheckCondition
        server.enqueue(MockResponse().setBody("""{"bizContent":{"isOk":true}}"""))    // start_exam_queue
        server.enqueue(MockResponse().setBody("true"))                                // test_complete
        server.enqueue(MockResponse().setBody(html))                                  // exam_start(进卷解析)
        server.enqueue(MockResponse().setBody(html))                                  // exam_start(卡片解析)
        server.enqueue(MockResponse().setBody(questionsJson))                         // get_question_info
        server.enqueue(MockResponse().setBody("{}"))                                  // get_remian_time
        server.enqueue(MockResponse().setBody("{}"))                                  // exam_ending(非结果页 → 吞错)
    }

    /** wfs=0 卷:只读,永不结束。 */
    private fun enqueueReadOnlyPaper(html: String, questionsJson: String) {
        server.enqueue(MockResponse().setBody(html))                                  // exam_start(进卷解析)
        server.enqueue(MockResponse().setBody(html))                                  // exam_start(卡片解析)
        server.enqueue(MockResponse().setBody(questionsJson))                         // get_question_info
    }

    private fun failNextRequest() {
        server.enqueue(MockResponse().setResponseCode(500).setBody(""))
    }

    // ---- 夹具 ----

    private fun examHtml(resultsId: String, infoId: String, body: String): String =
        """<!DOCTYPE html><html><head><script>var exam_results_id = '$resultsId'; var exam_info_id = '$infoId';</script></head><body>$body</body></html>"""

    private fun cardsHtml(section: String, vararg ids: String): String {
        val cards = ids.mapIndexed { i, id ->
            """<a href="#$i"><div class="question_cbox"><span>$i</span><span questionsId="$id" uuId="u$i"></span></div></a>"""
        }.joinToString("\n")
        return """<div class="card-content-title">$section</div><div class="card-content-list">$cards</div>"""
    }

    private fun combCardsHtml(section: String, combId: String, count: Int, prefix: String): String {
        val cards = (1..count).joinToString("\n") { i ->
            """<a href="#c$i"><div class="box insert-box question_cbox s1 practice-mode-2 "><span class="iconBox" questionsId="$prefix$i" uuId="u1" num="questions_$prefix$i">1.$i</span></div></a>"""
        }
        return """<div class="card-content-title">$section</div><div class="box-list ">
  <div class="insert-list inline-insert-list " questionsId="$combId">
$cards
  </div>
</div>"""
    }

    private fun questionJson(id: String, imgSrc: String? = null): String {
        val img = imgSrc?.let { "<img src=\\\"$it\\\">" } ?: ""
        return """{"_id":"$id","question":"<p>${img}包含关联词的题干 $id</p>","parent_info":null,"answer1":"<p>A</p>","answer2":"<p>B</p>","answer3":"<p>C</p>","answer4":"<p>D</p>","key1":"1","key2":"0","key3":"0","key4":"0","test_ans":"","test_ans_right":"","analysis":"","_isMulti":false}"""
    }

    private fun questionsJson(ids: List<String>): String = ids.joinToString(",", "[", "]") { questionJson(it) }

    private fun drainRequests(): List<RecordedRequest> =
        generateSequence { server.takeRequest(1, TimeUnit.SECONDS) }.toList()

    private fun oldRecord(id: String): BankQuestion = BankQuestion(
        id = id, category = "言语理解", section = "逻辑填空", subCategory = "成语辨析",
        question = "<p>旧题</p>", stem = null,
        options = listOf("<p>A</p>", "<p>B</p>", "<p>C</p>", "<p>D</p>"),
        answer = AnswerShape.Single("A"), analysis = null,
        sourceExamName = null, round = null, collectedAt = null,
    )

    private fun testIdCount(body: String): Int {
        // 表单编码中逗号不在允许集(ASCII 字母数字 + -._~),被百分号编码为 %2C
        val ids = Regex("testIds=([^&]*)").find(body)?.groupValues?.get(1) ?: return 0
        return if (ids.isEmpty()) 0 else ids.split("%2C", "%2c").size
    }

    // ---- 用例 ----

    @Test
    fun `only 机考题库 papers whose name carries a category are crawled`() = runBlocking {
        enqueueExamList(
            paper(1, "【言语理解（二）】机考题库", wfs = 1),    // 目标
            paper(2, "【常识判断】模拟卷", style = "模拟考试"), // 非机考题库 style → 跳过
            paper(3, "【事业单位】机考题库", wfs = 0),          // 机考题库但卷名不含五类 → 跳过
        )
        enqueueNewPaper(
            examHtml("r1", "E1", cardsHtml("逻辑填空(共200题,每题1分,合计200.0分)", "q1", "q2")),
            questionsJson(listOf("q1", "q2")),
        )

        val result = crawler().crawl(refresh = false) { progresses += it }
        assertTrue(result.isSuccess)

        val records = storage.files["言语理解"].orEmpty()
        assertEquals(listOf("q1", "q2"), records.map { it.id })
        assertEquals("逻辑填空", records[0].section)        // cleanSection 剥离 (共…)
        assertEquals("虚词辨析", records[0].subCategory)    // 分类器规则命中
        assertEquals("【言语理解（二）】机考题库", records[0].sourceExamName)
        assertEquals(AnswerShape.Single("A"), records[0].answer)

        val meta = storage.meta!!
        assertEquals(1, meta.round)                          // 0 → 1
        assertNotNull(meta.lastRun)
        assertEquals(mapOf("1" to true), meta.papers)
        assertEquals(0, storage.writeAllCalls)

        val paths = drainRequests().map { it.requestUrl?.encodedPath ?: "" }
        assertEquals(10, paths.size)
        assertEquals(1, paths.count { it == "/exam/current_exam_list" })
        assertEquals(1, paths.count { it == "/exam/enter_exam/1/1" })
        assertEquals(0, paths.count { it.startsWith("/exam/enter_exam/1/2") || it.startsWith("/exam/enter_exam/1/3") })
        assertEquals(2, paths.count { it == "/exam/exam_start/1" })
        assertEquals(1, paths.count { it == "/exam/get_question_info/" })
        // wfs=1:抓取后调用 submitExam(fire-and-forget;exam_ending 返回 JSON 被吞错,爬取仍成功)
        assertEquals(1, paths.count { it == "/exam/get_remian_time" })
        assertEquals(1, paths.count { it.startsWith("/exam/exam_ending") })
    }

    @Test
    fun `wfs=0 papers are entered read-only and never ended`() = runBlocking {
        enqueueExamList(paper(1, "【数字运算（一）】机考题库", wfs = 0))
        enqueueReadOnlyPaper(
            examHtml("r1", "E1", cardsHtml("数量关系", "q1")),
            questionsJson(listOf("q1")),
        )

        val result = crawler().crawl(refresh = false) { progresses += it }
        assertTrue(result.isSuccess)
        assertEquals(listOf("q1"), storage.files["数字运算"].orEmpty().map { it.id })

        val paths = drainRequests().map { it.requestUrl?.encodedPath ?: "" }
        assertEquals(4, paths.size)   // examList + exam_start ×2 + get_question_info
        assertFalse(paths.any { it == "/exam/get_remian_time" })
        assertFalse(paths.any { it.startsWith("/exam/exam_ending") })
        assertTrue(storage.meta!!.papers.containsKey("1"))
    }

    @Test
    fun `incremental mode skips completed papers and stops after 3 consecutive failures`() = runBlocking {
        storage.meta = BankMeta(
            version = 1, round = 5, lastRun = "2026-08-10T00:00:00Z",
            targets = BankLogic.categories, counts = emptyMap(), papers = mapOf("1" to true),
        )
        enqueueExamList(
            paper(1, "【言语理解（一）】机考题库"),
            paper(2, "【言语理解（二）】机考题库", wfs = 0),
            paper(3, "【数字运算（一）】机考题库"),
            paper(4, "【数字运算（二）】机考题库"),
            paper(5, "【逻辑推理（一）】机考题库"),
        )
        enqueueReadOnlyPaper(
            examHtml("r2", "E2", cardsHtml("逻辑填空", "dup1", "p2a")),
            questionsJson(listOf("dup1", "p2a")),
        )
        failNextRequest()
        failNextRequest()
        failNextRequest()

        val result = crawler().crawl(refresh = false) { progresses += it }
        assertTrue(result.isFailure)

        // 已存卷保留:paper2 题目在库,meta 为 paper2 后的中间态(round 保持 5)
        assertEquals(listOf("dup1", "p2a"), storage.files["言语理解"].orEmpty().map { it.id })
        assertEquals(5, storage.meta!!.round)
        assertEquals(mapOf("2" to true), storage.meta!!.papers)

        // 爬取日志:paper1 跳过,paper2 成功,paper3-5 进入失败
        assertEquals(1, storage.crawlLog.count { it.step == CrawlLogEntry.STEP_SKIP && it.outcome == CrawlLogEntry.OUTCOME_SKIPPED })
        assertEquals(3, storage.crawlLog.count { it.step == CrawlLogEntry.STEP_ENTER && it.outcome == CrawlLogEntry.OUTCOME_FAILURE })

        // 进度回调:paperList + 跳过 + paper2 完成 + 两次失败(第 3 次失败即停止,不再回调)
        assertEquals(5, progresses.size)
        assertEquals(CrawlLogEntry.STEP_ENTER, progresses.last().phase)
        assertEquals(4, progresses.last().current)
        assertEquals(5, progresses.last().total)
    }

    @Test
    fun `refresh mode re-crawls everything and commits atomically when nothing failed`() = runBlocking {
        storage.meta = BankMeta(
            version = 1, round = 3, lastRun = "2026-08-08T00:00:00Z",
            targets = BankLogic.categories, counts = emptyMap(), papers = emptyMap(),
        )
        enqueueExamList(
            paper(1, "【言语理解（一）】机考题库"),
            paper(2, "【言语理解（二）】机考题库", wfs = 0),
        )
        enqueueNewPaper(
            examHtml("r1", "E1", cardsHtml("逻辑填空", "dup1", "a1")),
            questionsJson(listOf("dup1", "a1")),
        )
        enqueueReadOnlyPaper(
            examHtml("r2", "E2", cardsHtml("阅读理解", "dup1", "b1")),
            questionsJson(listOf("dup1", "b1")),
        )

        val result = crawler().crawl(refresh = true) { progresses += it }
        assertTrue(result.isSuccess)

        // 全量替换:5 个分类文件 + meta 最后写
        assertEquals(1, storage.writeAllCalls)
        assertEquals(BankLogic.categories.toSet(), storage.writeAllLast!!.keys)
        // 按 _id 去重:dup1 两份 → 一份
        assertEquals(listOf("dup1", "a1", "b1"), storage.files["言语理解"].orEmpty().map { it.id })
        for (category in BankLogic.categories.filter { it != "言语理解" }) {
            assertEquals(emptyList<BankQuestion>(), storage.files[category].orEmpty())
        }
        val meta = storage.meta!!
        assertEquals(4, meta.round)     // 3 → 4
        assertNotNull(meta.lastRun)
        assertEquals(mapOf("1" to true, "2" to true), meta.papers)
        assertEquals(mapOf("言语理解" to 3), meta.counts)
    }

    @Test
    fun `refresh mode commits nothing when any paper fails`() = runBlocking {
        val failedPaper = "【数字运算（一）】机考题库"
        storage.meta = BankMeta(
            version = 1, round = 3, lastRun = "2026-08-08T00:00:00Z",
            targets = BankLogic.categories, counts = emptyMap(), papers = emptyMap(),
        )
        storage.appendRecords("言语理解", listOf(oldRecord("old1")))
        enqueueExamList(
            paper(1, "【言语理解（一）】机考题库"),
            paper(2, failedPaper, wfs = 0),
            paper(3, "【数字运算（二）】机考题库", wfs = 0),
        )
        enqueueNewPaper(
            examHtml("r1", "E1", cardsHtml("逻辑填空", "a1")),
            questionsJson(listOf("a1")),
        )
        failNextRequest()          // paper2 进入失败
        enqueueReadOnlyPaper(
            examHtml("r3", "E3", cardsHtml("数量关系", "b1")),
            questionsJson(listOf("b1")),
        )

        val result = crawler().crawl(refresh = true) { progresses += it }
        assertTrue(result.isFailure)
        assertEquals("1 份试卷爬取失败：$failedPaper", result.exceptionOrNull()?.message)

        // 不提交:writeAll 未调用、旧 meta 保留、已存文件原封不动
        assertEquals(0, storage.writeAllCalls)
        assertEquals(3, storage.meta!!.round)
        assertEquals(listOf("old1"), storage.files["言语理解"].orEmpty().map { it.id })
        // 刷新模式继续爬剩余卷(日志记录每一份失败卷):paper1/paper3 进入成功,paper2 失败
        assertEquals(1, storage.crawlLog.count { it.step == CrawlLogEntry.STEP_ENTER && it.outcome == CrawlLogEntry.OUTCOME_FAILURE })
        assertEquals(2, storage.crawlLog.count { it.step == CrawlLogEntry.STEP_ENTER && it.outcome == CrawlLogEntry.OUTCOME_SUCCESS })
    }

    @Test
    fun `questions are fetched in batches of 50 with separate combId units`() = runBlocking {
        enqueueExamList(paper(1, "【资料分析（一）】机考题库", wfs = 0))
        val html = examHtml(
            "r1", "E1",
            combCardsHtml("文字资料(共55题,合计100.0分)", "g1", 55, "c") +
                cardsHtml("言语理解", *(1..55).map { "r$it" }.toTypedArray()),
        )
        val ids = (1..55).map { "c$it" } + (1..55).map { "r$it" }
        enqueueReadOnlyPaper(html, questionsJson(ids))
        // 4 个 get_question_info 响应(50/5/50/5),每次返回全量(爬取器按 id 关联)
        repeat(3) { server.enqueue(MockResponse().setBody(questionsJson(ids))) }

        val result = crawler().crawl(refresh = false) { progresses += it }
        assertTrue(result.isSuccess)
        assertEquals(110, storage.files["资料分析"].orEmpty().size)

        val requests = drainRequests()
        assertEquals(7, requests.size)
        val batchBodies = requests.filter { it.requestUrl?.encodedPath == "/exam/get_question_info/" }
            .map { it.body.readUtf8() }
        assertEquals(4, batchBodies.size)
        // comb 组单独成批,不与其他 combId 混合
        assertTrue(batchBodies[0].contains("combId=g1"))
        assertTrue(batchBodies[1].contains("combId=g1"))
        assertFalse(batchBodies[2].contains("combId"))
        assertFalse(batchBodies[3].contains("combId"))
        // testIds 按 50 分块
        assertEquals(50, testIdCount(batchBodies[0]))
        assertEquals(5, testIdCount(batchBodies[1]))
        assertEquals(50, testIdCount(batchBodies[2]))
        assertEquals(5, testIdCount(batchBodies[3]))
    }

    // ---- 内存 BankStorage 假实现(记录调用,供爬取器断言) ----

    private class FakeBankStorage : BankStorage {
        val files = mutableMapOf<String, MutableList<BankQuestion>>()
        var meta: BankMeta? = null
        var writeAllCalls = 0
        var writeAllLast: Map<String, List<BankQuestion>>? = null
        val crawlLog = mutableListOf<CrawlLogEntry>()

        override fun readCategory(category: String): List<BankQuestion> =
            files[category]?.toList() ?: emptyList()

        override fun appendRecords(category: String, records: List<BankQuestion>) {
            files.getOrPut(category) { mutableListOf() }.addAll(records)
        }

        override fun writeAll(files: Map<String, List<BankQuestion>>) {
            writeAllCalls += 1
            writeAllLast = files
            this.files.clear()
            files.forEach { (k, v) -> this.files[k] = v.toMutableList() }
        }

        override fun readMeta(): BankMeta? = meta

        override fun writeMeta(meta: BankMeta) { this.meta = meta }

        override fun isPopulated(): Boolean = meta != null

        override fun clearAll() {
            files.clear()
            meta = null
            crawlLog.clear()
        }

        override fun readCrawlLog(): List<CrawlLogEntry> = crawlLog.toList()

        override fun appendCrawlLog(entry: CrawlLogEntry) { crawlLog.add(entry) }
    }
}
