package com.qzh.lanjingquiz.Data

import kotlinx.serialization.Serializable

/**
 * 爬取日志一行(crawl_log.jsonl;spec §3.2):
 * timestamp(ISO8601)、paperId(String?,paperList 步为 null)、paperName、step、outcome、message(String?)。
 * step ∈ paperList|enter|save|endAttempt|skip;outcome ∈ success|failure|skipped。
 * 显示名(获取试卷列表/进入试卷/保存题目/结束作答/跳过)属 UI 层,不在此维护。
 */
@Serializable
data class CrawlLogEntry(
    val timestamp: String,
    val paperId: String? = null,
    val paperName: String = "",
    val step: String,
    val outcome: String,
    val message: String? = null,
) {
    companion object {
        const val STEP_PAPER_LIST = "paperList"
        const val STEP_ENTER = "enter"
        const val STEP_SAVE = "save"
        const val STEP_END_ATTEMPT = "endAttempt"
        const val STEP_SKIP = "skip"

        const val OUTCOME_SUCCESS = "success"
        const val OUTCOME_FAILURE = "failure"
        const val OUTCOME_SKIPPED = "skipped"
    }
}
