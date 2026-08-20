package com.qzh.lanjingquiz.Support

object FormEncoder {
    private val ALLOWED = ('a'..'z') + ('A'..'Z') + ('0'..'9') + listOf('-', '_', '.', '~')

    fun encode(params: Map<String, String>): String =
        params.entries.joinToString("&") { (k, v) -> encodeComponent(k) + "=" + encodeComponent(v) }

    private fun encodeComponent(s: String): String {
        val sb = StringBuilder()
        for (b in s.toByteArray(Charsets.UTF_8)) {
            val c = (b.toInt() and 0xFF).toChar()
            if (c in ALLOWED) sb.append(c)
            else sb.append('%').append("%02X".format(b.toInt() and 0xFF))
        }
        return sb.toString()
    }
}
