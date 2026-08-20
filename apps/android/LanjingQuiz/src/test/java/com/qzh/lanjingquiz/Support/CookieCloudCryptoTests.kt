package com.qzh.lanjingquiz.Support

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test
import java.util.Base64

/**
 * 与 iOS CookieCloudCryptoTests 相同的互操作向量(官方扩展 crypto-js 实现生成,
 * openssl 交叉校验)。两个客户端必须与浏览器扩展逐字节一致。
 */
class CookieCloudCryptoTests {
    private val uuid1 = "test-uuid-1234"
    private val password1 = "test-password-5678"
    private val uuid2 = "uuid-b-998877"
    private val password2 = "pass-cc-xyz"

    private val plain1 = "{\"cookie_data\":{},\"local_storage_data\":{}}"
    private val plain2 = "{\"cookie_data\":{\"test.lanjingweike.com\":[{\"name\":\"sessionId\",\"value\":\"SESS_XYZ_123\"}]},\"local_storage_data\":{}}"

    // salt 0102030405060708, AES-256-CBC, EVP_BytesToKey(MD5)
    private val legacy1 = "U2FsdGVkX18BAgMEBQYHCH6Zia7WX/lPiAk9Dhed3vx8TFLyPzqhwlaByt4349lTUfMD9vFVxkq9uyczthmIHA=="
    // salt a1b2c3d4e5f60718, realistic cookie payload
    private val legacy2 = "U2FsdGVkX1+hssPU5fYHGKFCcwVDsFQ8Rtm6kcIhZQOLGfOj3mpiBUTubhhuM30y93XPXCTzCIoKFvZiSfs96BlaptjH00IiQ6xy4LqypQGZv8yFImuQ2fD+A2QsprFrSQOhfWQmiNCnDcuunWYEzzNeEPfXfCoJuq87hTQO9aU="

    // AES-128-CBC, key = 派生 key 串的 UTF-8 字节,零 IV
    private val fixed1 = "VJYTd1/GVaq27p6vmgE9FJdIPLMEnM7Bc9uRsLjAIjbtPU3Q6fFJAJZ1FSHe3FiV"
    private val fixed2 = "uc0DwkYemk+s/7Ru6tGsJ9n0WuKzQ+0ORnCGd2bKGp07Vp4sbbsX2COq5eO+64oQcFmYAN4k+LVd2C4meAHQ71ipaZwhbqjb1W+0/FhTmMmM++07mflHMHKuoQtx8TTT/HeQvR/TXH2kk2J27IDrRQ=="

    @Test
    fun `derive key matches extension derivation`() {
        assertEquals("ff67775c3432c7dc", String(CookieCloudCrypto.deriveKey(uuid1, password1)))
        assertEquals("c6b0b54daf5c0c37", String(CookieCloudCrypto.deriveKey(uuid2, password2)))
    }

    @Test
    fun `decrypts legacy vectors from the extension`() {
        assertEquals(plain1, CookieCloudCrypto.decryptAny(legacy1, uuid1, password1, "legacy"))
        assertEquals(plain2, CookieCloudCrypto.decryptAny(legacy2, uuid2, password2, "legacy"))
    }

    @Test
    fun `decrypts and encrypts fixed vectors from the extension`() {
        assertEquals(plain1, CookieCloudCrypto.decryptAny(fixed1, uuid1, password1, "aes-128-cbc-fixed"))
        assertEquals(fixed1, CookieCloudCrypto.fixedEncrypt(plain1, CookieCloudCrypto.deriveKey(uuid1, password1)))
        assertEquals(fixed2, CookieCloudCrypto.fixedEncrypt(plain2, CookieCloudCrypto.deriveKey(uuid2, password2)))
    }

    @Test
    fun `encryptAny always pushes the fixed format`() {
        val (encrypted, type) = CookieCloudCrypto.encryptAny(plain2, uuid2, password2)
        assertEquals("aes-128-cbc-fixed", type)
        assertEquals(fixed2, encrypted)
        assertEquals(plain2, CookieCloudCrypto.decryptAny(encrypted, uuid2, password2, type))
    }

    @Test
    fun `decryptAny falls back when declared type is wrong`() {
        // 声明 legacy 实为 fixed-IV 载荷(线上观测),以及反过来的情况;未知类型两种算法都试
        assertEquals(plain1, CookieCloudCrypto.decryptAny(fixed1, uuid1, password1, "legacy"))
        assertEquals(plain1, CookieCloudCrypto.decryptAny(legacy1, uuid1, password1, "aes-128-cbc-fixed"))
        assertEquals(plain1, CookieCloudCrypto.decryptAny(fixed1, uuid1, password1, "future-type"))
        assertThrows(Exception::class.java) {
            CookieCloudCrypto.decryptAny(fixed1, uuid1, "wrong-password", "legacy")
        }
    }

    @Test
    fun `decrypt fails closed instead of returning garbage`() {
        // 错误密码 → PKCS7 padding 失败
        assertThrows(Exception::class.java) {
            CookieCloudCrypto.decryptAny(legacy1, uuid1, "wrong-password", "legacy")
        }
        // legacy 载荷缺少 Salted__ 头 → 拒绝
        val noHeader = Base64.getEncoder().encodeToString(ByteArray(32) { 0x41 })
        assertThrows(Exception::class.java) {
            CookieCloudCrypto.decryptAny(noHeader, uuid1, password1, "legacy")
        }
        // 未知 crypto_type(未来扩展版本)→ 两种算法均失败后抛错
        assertThrows(Exception::class.java) {
            CookieCloudCrypto.decryptAny("x", uuid1, password1, "future-crypto-type")
        }
        // 缺省 crypto_type 默认 legacy
        assertEquals(plain1, CookieCloudCrypto.decryptAny(legacy1, uuid1, password1, null))
    }
}
