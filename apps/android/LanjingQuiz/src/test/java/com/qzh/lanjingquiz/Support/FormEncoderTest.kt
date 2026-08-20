package com.qzh.lanjingquiz.Support

import org.junit.Assert.assertEquals
import org.junit.Test

class FormEncoderTest {
    @Test fun `percent encodes with alphanumerics and dash underscore tilde allowed`() {
        val out = FormEncoder.encode(mapOf(
            "userName" to "13800000000@1",
            "remember" to "false",
            "备注" to "a b&c=d",
        ))
        assertEquals("userName=13800000000%401&remember=false&%E5%A4%87%E6%B3%A8=a%20b%26c%3Dd", out)
    }
    @Test fun `ordered by map iteration and joined with ampersand`() {
        assertEquals("a=1&b=2", FormEncoder.encode(linkedMapOf("a" to "1", "b" to "2")))
    }
}
