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
        <body>${normalizeImageSrcs(stripTrailingFiller(html))}</body>
        </html>
        """.trimIndent()
    }

    /**
     * 上游富文本编辑器会在可见内容之后追加空填充块(<p><br/></p>、<p>&nbsp;</p>、
     * 游离 <br>、&nbsp;/空白串)。浏览器把它们渲染成整行空白,按题把选项/解析往下
     * 推,形成题面与选项之间大小不一的空隙。只剥尾部:段落内部空行、段尾含文本的
     * <br>、以及题面里的答题括号(…)原样保留(iOS 对应物 RichHTMLContent.stripTrailingFiller)。
     */
    fun stripTrailingFiller(html: String): String {
        var result = html
        while (true) {
            val before = result
            // Java/Kotlin 的 \s 不含 NBSP,显式加   字面量(与 Swift trim 语义对齐)。
            result = result
                .replace(Regex("""(?i)(?:&nbsp;|\s|\u00A0)+$"""), "")
                .replace(Regex("""(?i)<br\s*/?>(?:&nbsp;|\s|\u00A0)*$"""), "")
            result = removeTrailingEmptyBlock(result) ?: result
            if (result == before) break
        }
        return result
    }

    /** 若字符串以内容为空(仅空白/实体)的 <p><…></p> 或 <div><…></div> 块结尾,去掉该块;否则 null。 */
    private fun removeTrailingEmptyBlock(html: String): String? {
        val pClose = html.lastIndexOf("</p>", ignoreCase = true)
        val divClose = html.lastIndexOf("</div>", ignoreCase = true)
        val useDiv = divClose >= 0 && (pClose < 0 || divClose > pClose)
        if (pClose < 0 && divClose < 0) return null
        val closePos = if (useDiv) divClose else pClose
        val tag = if (useDiv) "div" else "p"
        // close 之前最后一个该标签开标签(<p>、<p …> 等);
        // <(p|div)(?=[\s>]) 不会命中 </p> 或 <picture>/<pre>。
        val open = Regex("""<${tag}(?=[\s>])""", RegexOption.IGNORE_CASE)
            .findAll(html)
            .filter { it.range.first < closePos }
            .lastOrNull() ?: return null
        // 开标签尚未结束(下一个 ">" 在 close 之后)→ 结构异常,不动。
        val gt = html.indexOf('>', open.range.last + 1)
        if (gt < 0 || gt > closePos) return null
        val content = html.substring(gt + 1, closePos)
        // 填充块内部可只有 <br>/<span> 这类不可见包装;图片/表格/媒体等会渲染真实内容,绝不视为填充。
        val hasVisualContent = Regex(
            """(?i)<(?:img|picture|svg|canvas|iframe|embed|object|video|audio|table|math|input|textarea|select|hr|form)\b"""
        ).containsMatchIn(content)
        val text = content
            .replace(Regex("""<[^>]+>"""), "")
            .replace("&nbsp;", " ").replace("&#160;", " ")
            .trim()
        if (text.isNotEmpty() || hasVisualContent) return null
        return html.substring(0, open.range.first) + html.substring(closePos + tag.length + 3)
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
