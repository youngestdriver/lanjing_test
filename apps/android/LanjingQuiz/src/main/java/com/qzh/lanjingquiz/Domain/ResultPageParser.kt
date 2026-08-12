package com.qzh.lanjingquiz.Domain

import com.qzh.lanjingquiz.Network.ExamResult

/** 结果页解析 —— iOS ResultPageParser.swift 逐行移植(正则来自 apps/web/server.js)。 */
object ResultPageParser {

    fun parse(html: String): ExamResult {
        val score = Regex("""class="score"[^>]*>\s*([\d.]+)\s*<""").find(html)?.groupValues?.get(1) ?: "0"
        val nums = Regex("""exam-result-percentage[^>]*>\s*(\d+)""").findAll(html)
            .map { it.groupValues[1] }.toList()
        val beatRate = nums.firstOrNull() ?: "?"
        val rank = nums.getOrNull(1) ?: nums.firstOrNull() ?: "?"
        return ExamResult(score, beatRate, rank)
    }
}
