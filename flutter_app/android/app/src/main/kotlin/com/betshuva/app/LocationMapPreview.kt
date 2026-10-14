package com.betshuva.app

import android.content.Context
import android.graphics.Color
import android.net.Uri
import android.text.TextUtils
import android.view.Gravity
import android.view.View
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.FrameLayout
import android.widget.TextView
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

class LocationMapPreviewFactory : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        val url = (args as? Map<*, *>)?.get("url") as? String ?: ""
        return LocationMapPreview(context, url)
    }
}

private class LocationMapPreview(context: Context, url: String) : PlatformView {
    private val container = FrameLayout(context)
    private val webView = WebView(context)
    private val fallback = TextView(context).apply {
        text = "לא ניתן להציג מפה כרגע. לחצו לפתיחת המיקום."
        gravity = Gravity.CENTER
        setBackgroundColor(Color.rgb(234, 245, 253))
        visibility = View.GONE
    }
    private var disposed = false

    init {
        container.addView(webView, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT
        ))
        container.addView(fallback, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT
        ))
        webView.isFocusable = false
        webView.isFocusableInTouchMode = false
        webView.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            allowFileAccess = false
            allowContentAccess = false
            javaScriptCanOpenWindowsAutomatically = false
            setSupportMultipleWindows(false)
            setGeolocationEnabled(false)
            mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
            mediaPlaybackRequiresUserGesture = true
        }
        // The preview has no JavaScript bridge. Flutter opens external maps.
        webView.webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
                if (request.isForMainFrame) {
                    if (!disposed) fallback.visibility = View.VISIBLE
                    return true
                }
                // Only the map iframe can load or follow Google's embed redirect.
                return request.method != "GET" ||
                    !(validMapUrl(request.url.toString()) ||
                        (request.isRedirect && validEmbedRedirect(request.url)))
            }

            override fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) {
                if (!disposed && (request.isForMainFrame || isMapDocument(request.url))) {
                    fallback.visibility = View.VISIBLE
                }
            }

            override fun onReceivedHttpError(view: WebView, request: WebResourceRequest, response: WebResourceResponse) {
                if (!disposed && (request.isForMainFrame || isMapDocument(request.url))) {
                    fallback.visibility = View.VISIBLE
                }
            }
        }
        if (validMapUrl(url)) {
            webView.loadDataWithBaseURL(
                "https://betshuva.com/", mapPreviewHtml(url), "text/html", "UTF-8", null
            )
        } else {
            fallback.visibility = View.VISIBLE
        }
    }

    override fun getView(): View = container

    override fun dispose() {
        if (disposed) return
        disposed = true
        webView.stopLoading()
        webView.webViewClient = WebViewClient()
        container.removeAllViews()
        webView.destroy()
    }

    private fun validMapUrl(value: String): Boolean = try {
        val uri = Uri.parse(value)
        uri.scheme == "https" && uri.host == "www.google.com" &&
            (uri.port == -1 || uri.port == 443) && uri.userInfo == null &&
            uri.fragment == null && uri.path == "/maps" &&
            uri.getQueryParameter("output") == "embed" &&
            !uri.getQueryParameter("q").isNullOrBlank() &&
            (uri.getQueryParameter("q")?.length ?: 0) <= 500 &&
            uri.queryParameterNames.all { it in setOf("q", "output", "hl") }
    } catch (_: Exception) {
        false
    }

    private fun validEmbedRedirect(uri: Uri): Boolean = try {
        val origins = uri.getQueryParameters("origin")
        val payloads = uri.getQueryParameters("pb")
        uri.scheme == "https" && uri.host == "www.google.com" &&
            (uri.port == -1 || uri.port == 443) && uri.userInfo == null &&
            uri.fragment == null && uri.path == "/maps/embed" &&
            uri.encodedQuery?.split('&')?.size == 2 &&
            uri.queryParameterNames == setOf("origin", "pb") &&
            origins == listOf("mfe") && payloads.size == 1 &&
            payloads[0].isNotBlank() && payloads[0].length <= 4096
    } catch (_: Exception) {
        false
    }

    private fun isMapDocument(uri: Uri): Boolean =
        validMapUrl(uri.toString()) || validEmbedRedirect(uri)

    private fun mapPreviewHtml(url: String): String = """
        <!doctype html>
        <html lang="he" dir="rtl">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; frame-src https://www.google.com/maps https://www.google.com/maps/embed; base-uri 'none'; form-action 'none'">
          <style>html,body{margin:0;width:100%;height:100%;overflow:hidden}iframe{display:block;width:100%;height:100%;border:0;pointer-events:none}</style>
        </head>
        <body>
          <iframe src="${TextUtils.htmlEncode(url)}" title="מפת המיקום המשותף" sandbox="allow-scripts allow-same-origin" referrerpolicy="no-referrer"></iframe>
        </body>
        </html>
    """.trimIndent()
}
