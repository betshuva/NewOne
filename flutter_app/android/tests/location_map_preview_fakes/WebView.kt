package android.webkit

import android.content.Context
import android.net.Uri
import android.view.View

interface WebResourceRequest {
    val url: Uri
    val isForMainFrame: Boolean
    val isRedirect: Boolean
    val method: String
}

class WebResourceError
class WebResourceResponse

open class WebViewClient {
    open fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean = false
    open fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) {}
    open fun onReceivedHttpError(view: WebView, request: WebResourceRequest, response: WebResourceResponse) {}
}

class WebSettings {
    var javaScriptEnabled = false
    var domStorageEnabled = false
    var allowFileAccess = true
    var allowContentAccess = true
    var javaScriptCanOpenWindowsAutomatically = true
    var multipleWindowsSupported = true
    var geolocationSupported = true
    var mixedContentMode = 0
    var mediaPlaybackRequiresUserGesture = false

    fun setSupportMultipleWindows(value: Boolean) { multipleWindowsSupported = value }
    fun setGeolocationEnabled(value: Boolean) { geolocationSupported = value }

    companion object { const val MIXED_CONTENT_NEVER_ALLOW = 1 }
}

class WebView(context: Context) : View(context) {
    val settings = WebSettings()
    var webViewClient = WebViewClient()
    val loadedUrls = mutableListOf<String>()
    val loadedDocuments = mutableListOf<LoadedDocument>()
    var stopCalls = 0
    var destroyCalls = 0

    fun loadUrl(value: String) { loadedUrls.add(value) }
    fun loadDataWithBaseURL(baseUrl: String?, data: String, mimeType: String?, encoding: String?, historyUrl: String?) {
        loadedDocuments.add(LoadedDocument(baseUrl, data, mimeType, encoding, historyUrl))
    }
    fun stopLoading() { stopCalls++ }
    fun destroy() { destroyCalls++ }
}

data class LoadedDocument(
    val baseUrl: String?,
    val data: String,
    val mimeType: String?,
    val encoding: String?,
    val historyUrl: String?,
)
