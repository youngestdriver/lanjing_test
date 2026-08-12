package com.qzh.lanjingquiz.Support

import java.security.MessageDigest

object Hashers {
    fun sha256Hex(s: String): String = hexDigest("SHA-256", s)
    fun md5Hex(s: String): String = hexDigest("MD5", s)
    private fun hexDigest(algorithm: String, s: String): String =
        MessageDigest.getInstance(algorithm).digest(s.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }
}
