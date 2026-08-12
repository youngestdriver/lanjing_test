package com.qzh.lanjingquiz.Support

/**
 * 富文本 HTML 渲染模板(§3.5 逐字)+ 图片 src 归一化(iOS RichHTMLContent 移植)。
 */
object HtmlRenderer {

    /** 上游 base(与 ApiClient.DEFAULT_BASE_URL 一致)。 */
    const val BASE_URL = "https://test.lanjingweike.com"

    /**
     * 文档模板:viewport meta;body 前景 #3c3c3c(浅)/ #ffffff(深);
     * 字号模板 "{size}px/1.55 sans-serif"(安卓换系统 sans-serif);背景全透明;
     * 暗色加 `color: inherit !important`(html/body 自身不受此规则,它们带 `color: <fg> !important`)。
     * 图片 src 在文档内归一化(优先 src 后 data-src、实体解码、拒绝 data:、相对路径按上游 base 解析)。
     */
    fun document(html: String, fontSizePx: Int, dark: Boolean): String {
        val foreground = if (dark) "#ffffff" else "#3c3c3c"
        val colorRule = if (dark) "* { background-color: transparent !important; color: inherit !important; }"
                        else "* { background-color: transparent !important; }"
        return """
        <!doctype html>
        <html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
        <style>
        html, body {
            margin: 0; padding: 0; width: 100%; overflow: hidden;
            background: transparent; color: $foreground !important;
            font: ${fontSizePx}px/1.55 sans-serif;
            overflow-wrap: break-word;
        }
        p { margin: 0 0 0.55em; }
        img {
            display: inline;
            max-width: 100% !important;
            height: auto !important;
            vertical-align: middle;
        }
        $colorRule
        </style></head>
        <body>${normalizeImageSrcs(html)}</body>
        </html>
        """.trimIndent()
    }

    /**
     * 提取 img 标签的有效图片 URL:优先 src 后 data-src(与 iOS 同款未锚定正则:
     * data-src 出现在 src 之前时,首个 "src=" 即 data-src);实体解码;
     * data: URI 拒绝(null);相对/协议相对路径按上游 base 解析。
     */
    fun imageSrc(imgTag: String): String? {
        for (pattern in listOf("src", "data-src")) {
            val match = Regex("""$pattern\s*=\s*["']([^"']+)["']""", RegexOption.IGNORE_CASE)
                .find(imgTag) ?: continue
            return resolveImageSrc(match.groupValues[1])
        }
        return null
    }

    /** 相对路径 → 绝对;实体解码;data: 拒绝。 */
    fun resolveImageSrc(raw: String): String? {
        val decoded = raw.replace("&amp;", "&").replace("&lt;", "<")
            .replace("&gt;", ">").replace("&quot;", "\"")
        if (decoded.startsWith("data:")) return null
        return when {
            decoded.startsWith("http://") || decoded.startsWith("https://") -> decoded
            decoded.startsWith("//") -> "https:$decoded"
            decoded.startsWith("/") -> BASE_URL + decoded
            else -> "$BASE_URL/$decoded"
        }
    }

    /** 文档内重写 img 标签:把可解析的 src(优先 src 后 data-src)固化为绝对地址。 */
    fun normalizeImageSrcs(html: String): String {
        val imgRegex = Regex("""<img\b[^>]*>""", RegexOption.IGNORE_CASE)
        return imgRegex.replace(html) { m ->
            val tag = m.value
            val resolved = imageSrc(tag) ?: return@replace tag   // 无可解析 src(data: 等)→ 原样保留
            val stripped = Regex("""\s(?:src|data-src)\s*=\s*["'][^"']*["']""", RegexOption.IGNORE_CASE)
                .replace(tag, "")
            val closed = stripped.trimEnd().endsWith("/>")
            // 去掉标签自身收尾的 ">" 再附加归一化后的 src
            val base = stripped.trimEnd().removeSuffix("/>").removeSuffix(">").trimEnd()
            base + " src=\"$resolved\"" + if (closed) "/>" else ">"
        }
    }
}
