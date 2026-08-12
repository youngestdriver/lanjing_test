package com.qzh.lanjingquiz.UI.Shared

import android.annotation.SuppressLint
import android.view.ViewGroup
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.height
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import com.qzh.lanjingquiz.Network.ApiClient
import com.qzh.lanjingquiz.Support.HtmlRenderer
import kotlin.math.abs

/**
 * 富文本 HTML 渲染(iOS WKWebView 对应物):
 * loadDataWithBaseURL(base, 文档, "text/html", "utf-8", null);onPageFinished 后
 * evaluateJavascript("document.documentElement.scrollHeight") 回读高度,delta > 0.5dp 才更新,
 * max(1, h) 下限;allowTextSelection=false 时注入 user-select:none 且 isEnabled=false。
 */
@Composable
fun RichHtmlBody(
    html: String,
    fontSizeSp: Int,
    dark: Boolean,
    allowTextSelection: Boolean,
    modifier: Modifier = Modifier,
    baseUrl: String = ApiClient.DEFAULT_BASE_URL,
    onHeightChange: (Int) -> Unit = {},
) {
    val density = LocalDensity.current
    var heightPx by remember { mutableStateOf(0) }
    val fontSizePx = with(density) { fontSizeSp.sp.toPx() }.toInt()
    val heightDp = with(density) { heightPx.toDp() }
    val factoryRef = remember { arrayOfNulls<RichWebViewFactory>(1) }

    Box(modifier = modifier.height(heightDp)) {
        AndroidView(
            factory = { context ->
                RichWebViewFactory(
                    context = context,
                    initialHtml = html,
                    initialFontSizePx = fontSizePx,
                    initialDark = dark,
                    initialSelection = allowTextSelection,
                    initialBaseUrl = baseUrl,
                ) { newPx ->
                    val changed = newPx != heightPx &&
                        abs(with(density) { (newPx - heightPx).toFloat().toDp().value }) > 0.5f
                    if (changed) {
                        heightPx = newPx
                        onHeightChange(newPx)
                    }
                }.also { factoryRef[0] = it }.create()
            },
            update = {
                factoryRef[0]?.update(
                    html = html, fontSizePx = fontSizePx, dark = dark,
                    allowTextSelection = allowTextSelection, baseUrl = baseUrl,
                )
            },
        )
    }
}

private class RichWebViewFactory(
    private val context: android.content.Context,
    initialHtml: String,
    initialFontSizePx: Int,
    initialDark: Boolean,
    initialSelection: Boolean,
    initialBaseUrl: String,
    private val onHeightChange: (Int) -> Unit,
) {
    private var html = initialHtml
    private var fontSizePx = initialFontSizePx
    private var dark = initialDark
    private var allowTextSelection = initialSelection
    private var baseUrl = initialBaseUrl
    private lateinit var webView: WebView

    fun create(): WebView {
        val view = WebView(context)
        view.layoutParams = ViewGroup.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
        view.settings.javaScriptEnabled = true
        view.settings.mixedContentMode = android.webkit.WebSettings.MIXED_CONTENT_COMPATIBILITY_MODE
        view.isVerticalScrollBarEnabled = false
        view.isHorizontalScrollBarEnabled = false
        view.isEnabled = allowTextSelection
        view.webViewClient = object : WebViewClient() {
            override fun onPageFinished(view: WebView, url: String?) {
                super.onPageFinished(view, url)
                measureHeight(view)
            }
        }
        load(view)
        webView = view
        return view
    }

    fun update(html: String, fontSizePx: Int, dark: Boolean, allowTextSelection: Boolean, baseUrl: String) {
        val docChanged = html != this.html || fontSizePx != this.fontSizePx ||
            dark != this.dark || allowTextSelection != this.allowTextSelection
        this.html = html
        this.fontSizePx = fontSizePx
        this.dark = dark
        this.allowTextSelection = allowTextSelection
        this.baseUrl = baseUrl
        webView.isEnabled = allowTextSelection
        if (docChanged) load(webView)
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun load(view: WebView) {
        val doc = HtmlRenderer.document(html, fontSizePx, dark)
        view.loadDataWithBaseURL(baseUrl, doc, "text/html", "utf-8", null)
        if (!allowTextSelection) injectNoSelection(view)
    }

    /** 禁选:注入 user-select:none + touch-callout(isEnabled=false 已在 create/update 设置)。 */
    private fun injectNoSelection(view: WebView) {
        val js = "var s=document.createElement('style');" +
            "s.textContent='*{-webkit-user-select:none!important;user-select:none!important;-webkit-touch-callout:none!important;}';" +
            "document.head.appendChild(s);"
        view.evaluateJavascript(js, null)
    }

    private fun measureHeight(view: WebView) {
        view.evaluateJavascript("document.documentElement.scrollHeight") { value ->
            val digits = value.trim().trim('"').toIntOrNull() ?: return@evaluateJavascript
            onHeightChange(kotlin.math.max(1, digits))
        }
    }
}
