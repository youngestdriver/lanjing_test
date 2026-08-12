package com.qzh.lanjingquiz.Support

import java.time.Instant
import java.time.ZoneId
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.util.Locale

object Formatters {
    fun mmss(seconds: Int): String = String.format(Locale.US, "%02d:%02d", seconds / 60, seconds % 60)
    fun isoNow(): String = Instant.now().toString()
    fun displayTime(epochMillis: Long): String =
        ZonedDateTime.ofInstant(Instant.ofEpochMilli(epochMillis), ZoneId.systemDefault())
            .format(DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss", Locale.US))
    fun exportFileName(now: ZonedDateTime = ZonedDateTime.now()): String =
        "爬取日志_" + now.format(DateTimeFormatter.ofPattern("yyyyMMdd_HHmm", Locale.US)) + ".txt"
}
