package com.qzh.lanjingquiz.Support

import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * apps/web/lib/cookiecloud.js 的 Kotlin 移植:与官方 CookieCloud 浏览器扩展加解密兼容。
 *
 *   the_key = MD5(`${uuid}-${password}`).hex.prefix(16)   // 16 字符 key 串
 *
 *   legacy:   OpenSSL EVP_BytesToKey(MD5) -> AES-256-CBC,随机 8 字节盐,PKCS7;
 *             payload 为 base64("Salted__" + salt + ciphertext)
 *   fixed:    AES-128-CBC,key = the_key 的 UTF-8 字节,零 IV,PKCS7;
 *             payload 为裸 base64 密文
 *
 * 本 app 恒推送 "aes-128-cbc-fixed",解密两种都支持。解密 fail-closed:
 * 缺 "Salted__" 头、未知 crypto_type 或错误密码(PKCS7 padding 错误)抛异常而非返回垃圾。
 */
object CookieCloudCrypto {
    // key = UTF-8 字节 of 前16字符 of MD5("{uuid}-{password}") 小写 hex
    fun deriveKey(uuid: String, password: String): ByteArray {
        val hex = Hashers.md5Hex("$uuid-$password")
        return hex.substring(0, 16).toByteArray(Charsets.UTF_8)
    }

    fun fixedEncrypt(plain: String, key: ByteArray): String {
        val cipher = Cipher.getInstance("AES/CBC/PKCS5Padding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), IvParameterSpec(ByteArray(16)))
        return Base64.getEncoder().encodeToString(cipher.doFinal(plain.toByteArray(Charsets.UTF_8)))
    }

    fun fixedDecrypt(base64Cipher: String, key: ByteArray): String {
        val cipher = Cipher.getInstance("AES/CBC/PKCS5Padding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), IvParameterSpec(ByteArray(16)))
        return String(cipher.doFinal(Base64.getDecoder().decode(base64Cipher)), Charsets.UTF_8)
    }

    /**
     * legacy: base64(Salted__ + 8B salt + AES-256-CBC(PKCS7), key=32B, iv=16B via EVP_BytesToKey MD5)。
     * EVP_BytesToKey 的 passphrase 是派生出的 16 字符 key 串(iOS/扩展/web 均如此),
     * 不是原始密码。
     */
    fun legacyDecrypt(base64Cipher: String, uuid: String, password: String): String {
        val full = Base64.getDecoder().decode(base64Cipher)
        if (full.size < 16 || !String(full, 0, 8, Charsets.US_ASCII).equals("Salted__")) {
            throw IllegalArgumentException("missingSaltedHeader")
        }
        val salt = full.copyOfRange(8, 16)
        val (key, iv) = evpBytesToKey(deriveKey(uuid, password), salt, 48)
        val cipher = Cipher.getInstance("AES/CBC/PKCS5Padding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), IvParameterSpec(iv))
        return String(cipher.doFinal(full.copyOfRange(16, full.size)), Charsets.UTF_8)
    }

    /** EVP_BytesToKey MD5:D_i = MD5(D_{i-1} + passphrase + salt);key=前32B, iv=次16B。 */
    private fun evpBytesToKey(passphrase: ByteArray, salt: ByteArray, total: Int): Pair<ByteArray, ByteArray> {
        val md = java.security.MessageDigest.getInstance("MD5")
        var prev = ByteArray(0)
        val out = java.io.ByteArrayOutputStream()
        while (out.size() < total) {
            md.reset()
            md.update(prev)
            md.update(passphrase)
            md.update(salt)
            prev = md.digest()
            out.write(prev)
        }
        val all = out.toByteArray()
        return all.copyOfRange(0, 32) to all.copyOfRange(32, 48)
    }

    fun encryptAny(plain: String, uuid: String, password: String): Pair<String, String> {
        val key = deriveKey(uuid, password)
        return fixedEncrypt(plain, key) to "aes-128-cbc-fixed"
    }

    /** 先按声明类型,失败再试另一算法;双失败抛最后一次错误。 */
    fun decryptAny(encrypted: String, uuid: String, password: String, cryptoType: String?): String {
        val key = deriveKey(uuid, password)
        val errors = ArrayList<Throwable>()
        val attempt: (() -> String) = when (cryptoType ?: "legacy") {
            "aes-128-cbc-fixed" -> ({ fixedDecrypt(encrypted, key) })
            else -> ({ legacyDecrypt(encrypted, uuid, password) })
        }
        try { return attempt() } catch (e: Throwable) { errors.add(e) }
        try {
            return if (cryptoType == "aes-128-cbc-fixed") legacyDecrypt(encrypted, uuid, password)
                   else fixedDecrypt(encrypted, key)
        } catch (e: Throwable) { errors.add(e) }
        throw errors.last()
    }
}
