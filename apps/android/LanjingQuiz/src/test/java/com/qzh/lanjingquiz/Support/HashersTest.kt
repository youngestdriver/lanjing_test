package com.qzh.lanjingquiz.Support

import org.junit.Assert.assertEquals
import org.junit.Test

class HashersTest {
    @Test fun `sha256 lowercase hex`() {
        assertEquals("8d969eef6ecad3c29a3a629280e686cf0c3f5d5a86aff3ca12020c923adc6c92", Hashers.sha256Hex("123456"))
        assertEquals("e10adc3949ba59abbe56e057f20f883e", Hashers.md5Hex("123456"))
    }
    @Test fun `empty string hashes`() {
        assertEquals("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", Hashers.sha256Hex(""))
        assertEquals("d41d8cd98f00b204e9800998ecf8427e", Hashers.md5Hex(""))
    }
}
