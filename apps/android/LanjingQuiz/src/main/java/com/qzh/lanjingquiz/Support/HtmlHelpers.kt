package com.qzh.lanjingquiz.Support

/**
 * HTML 工具(§3.2/§3.5):题库记录图片 src 归一化 + 实体解码 + 图片 URL 解析。
 * normalizeImgSrcs 仅处理协议相对 src(作用于 question/stem/analysis,不动 options)。
 */
object HtmlHelpers {

    /**
     * 协议相对 img src("//host/…") → "https://host/…";绝对 https 原样;null 透传。
     * 当前题库数据无 http:// src;未来收集引入时由 WebView 混合内容策略拦截(文档 base 为 https),
     * 这里只修 "//" —— 与 iOS BankQuestion.normalizeImgSrcs 一致。
     */
    fun normalizeImgSrcs(html: String?): String? {
        if (html == null) return null
        return html
            .replace("src=\"//", "src=\"https://")
            .replace("src='//", "src='https://")
    }

    /** 解码常见实体:&amp; &lt; &gt; &quot;。 */
    fun decodeEntities(s: String): String =
        s.replace("&amp;", "&").replace("&lt;", "<")
            .replace("&gt;", ">").replace("&quot;", "\"")

    /**
     * 图片 URL 解析(§3.5):实体解码;拒绝 data: URI;
     * 相对/协议相对路径按 baseUrl 解析为绝对地址。
     */
    fun resolveImgSrc(src: String, baseUrl: String): String? {
        val decoded = decodeEntities(src)
        if (decoded.startsWith("data:")) return null
        return when {
            decoded.startsWith("http://") || decoded.startsWith("https://") -> decoded
            decoded.startsWith("//") -> "https:$decoded"
            decoded.startsWith("/") -> baseUrl + decoded
            else -> "$baseUrl/$decoded"
        }
    }
}
