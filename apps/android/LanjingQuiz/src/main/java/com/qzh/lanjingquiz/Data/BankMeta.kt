package com.qzh.lanjingquiz.Data

import kotlinx.serialization.Serializable

/**
 * 题库元信息(bank/meta.json;spec §3.2 键逐字:version/round/lastRun/targets/counts/papers)。
 * counts 与 JSONL 行数一致,是分类列表数据源;targets 仅信息性 —— 文件名字恒从硬编码
 * BankLogic.categories 派生,绝不从 targets 派生(历史上收集器在 targets 写过错别字 "语言理解")。
 * papers 记录已爬卷 paperId → true(断点续爬)。
 */
@Serializable
data class BankMeta(
    val version: Int = 1,
    val round: Int = 0,
    val lastRun: String? = null,
    val targets: List<String> = emptyList(),
    val counts: Map<String, Int> = emptyMap(),
    val papers: Map<String, Boolean> = emptyMap(),
) {
    val totalCount: Int get() = counts.values.sum()
}
