package com.qzh.lanjingquiz.Support

import java.time.Instant
import java.time.ZoneId
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.util.Locale

object Formatters {
    private val displayPattern = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss", Locale.US)
    private val filePattern = DateTimeFormatter.ofPattern("yyyyMMdd_HHmm", Locale.US)

    fun mmss(seconds: Int): String = String.format(Locale.US, "%02d:%02d", seconds / 60, seconds % 60)
    fun isoNow(): String = Instant.now().toString()
    fun displayTime(epochMillis: Long): String =
        ZonedDateTime.ofInstant(Instant.ofEpochMilli(epochMillis), ZoneId.systemDefault())
            .format(displayPattern)

    /** ISO8601 字符串 → 本地时区 "yyyy-MM-dd HH:mm:ss"(爬取日志导出行;解析失败原样返回)。 */
    fun displayIso(iso: String): String = runCatching {
        ZonedDateTime.ofInstant(Instant.parse(iso), ZoneId.systemDefault()).format(displayPattern)
    }.getOrDefault(iso)

    fun exportFileName(now: ZonedDateTime = ZonedDateTime.now()): String =
        "爬取日志_" + now.format(filePattern) + ".txt"
}
