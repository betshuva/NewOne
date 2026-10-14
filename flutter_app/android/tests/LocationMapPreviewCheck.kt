// Exercises the actual production factory and WebViewClient without an APK.
import android.content.Context
import android.net.Uri
import android.view.View
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.widget.FrameLayout
import android.widget.TextView
import com.betshuva.app.LocationMapPreviewFactory
import io.flutter.plugin.platform.PlatformView
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.nio.file.Path
import kotlin.system.exitProcess

private const val initialUrl = "https://www.google.com/maps?q=31.700000%2C35.200000&output=embed&hl=he"
private const val embedUrl = "https://www.google.com/maps/embed?origin=mfe&pb=!1m3!1d100!2d35.2!3d31.7"

private data class Request(
    override val url: Uri,
    override val isForMainFrame: Boolean = false,
    override val isRedirect: Boolean = true,
    override val method: String = "GET",
) : WebResourceRequest

private class Preview(arguments: Any? = mapOf("url" to initialUrl)) {
    val platformView: PlatformView = LocationMapPreviewFactory().create(Context(), 1, arguments)
    val container = platformView.getView() as FrameLayout
    val webView = container.children.filterIsInstance<WebView>().single()
    val fallback = container.children.filterIsInstance<TextView>().single()
    val client = webView.webViewClient

    fun request(
        url: String = embedUrl,
        mainFrame: Boolean = false,
        redirect: Boolean = true,
        method: String = "GET",
    ) = Request(Uri.parse(url), mainFrame, redirect, method)

    fun navigate(
        url: String = embedUrl,
        mainFrame: Boolean = false,
        redirect: Boolean = true,
        method: String = "GET",
    ): Boolean = client.shouldOverrideUrlLoading(webView, request(url, mainFrame, redirect, method))
}

fun main(args: Array<String>) {
    System.getenv("MAP_PREVIEW_HTML_OUT")?.let { output ->
        val documents = Preview().webView.loadedDocuments
        check(documents.size == 1) { "Production map preview did not create an HTML wrapper" }
        Files.writeString(Path.of(output), documents.single().data, StandardCharsets.UTF_8)
        println("Exported production map HTML: $output")
    }
    val cases = linkedMapOf<String, () -> Unit>()
    var assertions = 0
    fun verify(ok: Boolean, message: String) {
        check(ok) { message }
        assertions++
    }
    fun hidden(preview: Preview) = preview.fallback.visibility == View.GONE
    fun blocked(url: String) {
        val preview = Preview()
        verify(preview.navigate(url), "Untrusted iframe navigation must be blocked: ${url.take(160)}")
        verify(hidden(preview), "Unrelated blocked iframe navigation must not cover the map")
        verify(preview.webView.loadedUrls.isEmpty() && preview.webView.loadedDocuments.size == 1,
            "Blocked navigation must not replace or reload the local document")
    }

    cases["google_embed_uses_iframe"] = {
        val preview = Preview()
        verify(preview.webView.loadedDocuments.size == 1,
            "Google embed must load inside a local iframe document, not as a top-level WebView URL")
        verify(preview.webView.loadedUrls.isEmpty(), "Google embed must not use top-level loadUrl")
        val document = preview.webView.loadedDocuments.single()
        verify(document.baseUrl == "https://betshuva.com/" && document.mimeType == "text/html" &&
            document.encoding == "UTF-8" && document.historyUrl == null, "Local document must have the trusted base and HTML encoding")
        verify(Regex("<iframe\\b").findAll(document.data).count() == 1, "Local preview must contain exactly one map iframe")
        verify(document.data.contains("src=\"${initialUrl.replace("&", "&amp;")}\""),
            "Iframe must load the validated initial Google URL with HTML escaping")
        verify(!Regex("<script\\b", RegexOption.IGNORE_CASE).containsMatchIn(document.data),
            "Local wrapper must not execute its own script")
        verify(document.data.contains("sandbox=\"allow-scripts allow-same-origin\"") &&
            document.data.contains("referrerpolicy=\"no-referrer\""), "Iframe must retain its sandbox and private referrer policy")
        verify(document.data.contains("default-src 'none'") && document.data.contains("base-uri 'none'") &&
            document.data.contains("form-action 'none'") &&
            document.data.contains("frame-src https://www.google.com/maps https://www.google.com/maps/embed"),
            "Wrapper CSP must permit only the Google map documents")
        verify(document.data.contains("width:100%;height:100%") && document.data.contains("pointer-events:none"),
            "Iframe must fill the preview and leave navigation taps to Flutter")
        verify(hidden(preview), "Initial valid preview must hide fallback")
        verify(!preview.navigate(initialUrl, redirect = false), "Initial map iframe navigation must continue")
        verify(!preview.navigate(), "Google redirect inside the iframe must continue")
        verify(preview.webView.loadedDocuments.size == 1, "Callbacks must not cancel and reload the wrapper")
    }

    cases["iframe_source_escapes_html_and_preserves_unicode"] = {
        val url = "https://www.google.com/maps?q=רחוב\"<שלום>'&output=embed&hl=he"
        val preview = Preview(mapOf("url" to url))
        verify(preview.webView.loadedDocuments.size == 1, "A named Unicode location must remain previewable")
        val html = preview.webView.loadedDocuments.single().data
        verify(html.contains("src=\"https://www.google.com/maps?q=רחוב&quot;&lt;שלום&gt;&#39;&amp;output=embed&amp;hl=he\""),
            "Raw query punctuation must not break the iframe attribute or erase Unicode")
        verify(Regex("<iframe\\b").findAll(html).count() == 1 && !html.contains("<שלום>"),
            "Query text must remain data and must not introduce markup")
        verify(hidden(preview), "Escaped named location must not show fallback")
    }

    cases["webview_security_settings"] = {
        val preview = Preview()
        verify(!preview.webView.isFocusable && !preview.webView.isFocusableInTouchMode, "Preview must not steal focus")
        val settings = preview.webView.settings
        verify(settings.javaScriptEnabled && settings.domStorageEnabled, "Maps must have JavaScript and DOM storage")
        verify(!settings.allowFileAccess && !settings.allowContentAccess, "Local file and content access must remain disabled")
        verify(!settings.javaScriptCanOpenWindowsAutomatically && !settings.multipleWindowsSupported, "Popups must remain disabled")
        verify(!settings.geolocationSupported, "Embedded map must not request device location")
        verify(settings.mixedContentMode == WebSettings.MIXED_CONTENT_NEVER_ALLOW, "Mixed content must remain disabled")
        verify(settings.mediaPlaybackRequiresUserGesture, "Media must still require a gesture")
    }

    cases["trusted_google_redirect"] = {
        for (url in listOf(
            embedUrl,
            "https://www.google.com:443/maps/embed?pb=fixture&origin=mfe",
            "https://www.google.com/maps/embed?origin=mfe&pb=fixture%26value%3D2",
        )) {
            val preview = Preview()
            verify(!preview.navigate(url), "Trusted Google GET redirect must continue: $url")
            verify(hidden(preview), "Trusted redirect must keep the map visible")
            verify(preview.webView.loadedUrls.isEmpty() && preview.webView.loadedDocuments.size == 1,
                "Redirect callback must not cancel and reload")
        }
    }

    cases["redirect_and_get_required"] = {
        for ((redirect, method) in listOf(false to "GET", true to "POST", true to "HEAD", true to "get")) {
            val preview = Preview()
            verify(preview.navigate(redirect = redirect, method = method), "Only redirect GET may continue: $redirect/$method")
            verify(hidden(preview), "Rejected unrelated iframe request must not cover the map")
        }
        val preview = Preview()
        verify(preview.navigate(initialUrl, redirect = false, method = "POST"), "Initial iframe must also reject POST")
    }

    cases["mainframe_navigation_is_blocked_with_fallback"] = {
        for (url in listOf(embedUrl, initialUrl, "https://evil.test/", "https://betshuva.com/")) {
            val preview = Preview()
            verify(preview.navigate(url, mainFrame = true), "All top-level navigations must be blocked")
            verify(!hidden(preview), "Blocked top-level navigation must display fallback")
            verify(preview.webView.loadedUrls.isEmpty() && preview.webView.loadedDocuments.size == 1,
                "Top-level callback must not load an external document")
        }
    }

    cases["exact_https_origin_and_path"] = {
        for (url in listOf(
            "http://www.google.com/maps/embed?origin=mfe&pb=x",
            "https://google.com/maps/embed?origin=mfe&pb=x",
            "https://maps.google.com/maps/embed?origin=mfe&pb=x",
            "https://www.google.com.evil.test/maps/embed?origin=mfe&pb=x",
            "https://evil.test/maps/embed?origin=mfe&pb=x",
            "https://www.google.com:444/maps/embed?origin=mfe&pb=x",
            "https://user@www.google.com/maps/embed?origin=mfe&pb=x",
            "https://www.google.com/maps/embed?origin=mfe&pb=x#fragment",
            "https://www.google.com/maps/embed/?origin=mfe&pb=x",
            "https://www.google.com/maps/embed/other?origin=mfe&pb=x",
            "https://www.google.com/maps?origin=mfe&pb=x",
            "intent://www.google.com/maps/embed?origin=mfe&pb=x",
        )) blocked(url)
    }

    cases["required_query_fields"] = {
        for (query in listOf(
            "pb=x", "origin=mfe", "origin=other&pb=x", "origin=&pb=x",
            "origin=mfe&pb=x&hl=he", "origin=mfe&pb=x&extra=1",
            "origin=mfe&pb=x&", "&origin=mfe&pb=x", "origin=mfe&&pb=x",
        )) blocked("https://www.google.com/maps/embed?$query")
    }

    cases["duplicate_and_encoded_alias_fields"] = {
        val alias = Uri.parse("https://www.google.com/maps/embed?origin=mfe&%6frigin=other&pb=x")
        verify(alias.queryParameterNames == setOf("origin", "pb"), "Fake Uri must decode parameter names")
        verify(alias.getQueryParameters("origin") == listOf("mfe"), "Fake Uri must match encoded query keys like Android")
        for (query in listOf(
            "origin=mfe&origin=mfe&pb=x", "origin=mfe&origin=other&pb=x",
            "origin=mfe&pb=x&pb=y", "origin=mfe&%6frigin=other&pb=x",
            "origin=mfe&pb=x&%70b=y", "%6frigin=mfe&pb=x", "origin=mfe&%70b=x",
        )) blocked("https://www.google.com/maps/embed?$query")
    }

    cases["payload_bounds"] = {
        for (payload in listOf("", "%20", "%09%0A", "x".repeat(4097))) {
            blocked("https://www.google.com/maps/embed?origin=mfe&pb=$payload")
        }
        val preview = Preview()
        verify(!preview.navigate("https://www.google.com/maps/embed?origin=mfe&pb=${"x".repeat(4096)}"), "Payload boundary of 4096 must be allowed")
        verify(hidden(preview), "Allowed boundary must not show fallback")
    }

    cases["unrelated_iframe_navigation_is_blocked"] = {
        for (url in listOf("https://maps.gstatic.com/tile?x=1", "https://www.google.com/maps/embed?pb=x", "about:blank")) {
            val preview = Preview()
            verify(preview.navigate(url, redirect = false), "Only approved map-document iframe navigation is allowed")
            verify(hidden(preview), "Unrelated iframe navigation must not hide the map")
            verify(preview.webView.loadedUrls.isEmpty() && preview.webView.loadedDocuments.size == 1,
                "Blocked iframe callback must not reload")
        }
    }

    cases["mainframe_network_error"] = {
        val preview = Preview()
        preview.client.onReceivedError(preview.webView, preview.request(mainFrame = true), WebResourceError())
        verify(!hidden(preview), "Main-frame network error must show fallback")
        verify(preview.fallback.text.toString().contains("לחצו לפתיחת המיקום"), "Fallback must retain external navigation guidance")
    }

    cases["mainframe_http_error"] = {
        val preview = Preview()
        preview.client.onReceivedHttpError(preview.webView, preview.request(mainFrame = true), WebResourceResponse())
        verify(!hidden(preview), "Main-frame HTTP error must show fallback")
    }

    cases["map_iframe_errors_show_fallback"] = {
        for (url in listOf(initialUrl, embedUrl)) {
            val networkPreview = Preview()
            networkPreview.client.onReceivedError(networkPreview.webView, networkPreview.request(url), WebResourceError())
            verify(!hidden(networkPreview), "Map iframe network error must show fallback")
            val httpPreview = Preview()
            httpPreview.client.onReceivedHttpError(httpPreview.webView, httpPreview.request(url), WebResourceResponse())
            verify(!hidden(httpPreview), "Map iframe HTTP error must show fallback")
        }
    }

    cases["tile_and_script_errors_are_ignored"] = {
        val preview = Preview()
        for (url in listOf("https://maps.gstatic.com/tile?x=1", "https://www.google.com/maps/script.js")) {
            val request = preview.request(url)
            preview.client.onReceivedError(preview.webView, request, WebResourceError())
            preview.client.onReceivedHttpError(preview.webView, request, WebResourceResponse())
            verify(hidden(preview), "An isolated tile or script failure must not cover the whole map")
        }
    }

    cases["dispose_and_late_callbacks"] = {
        val preview = Preview()
        preview.platformView.dispose()
        preview.platformView.dispose()
        verify(preview.webView.stopCalls == 1 && preview.webView.destroyCalls == 1, "Disposal must stop and destroy exactly once")
        verify(preview.container.children.isEmpty(), "Disposal must detach both views")
        verify(preview.webView.webViewClient !== preview.client, "Disposal must replace the callback client")
        preview.client.onReceivedError(preview.webView, preview.request(), WebResourceError())
        preview.client.onReceivedHttpError(preview.webView, preview.request(), WebResourceResponse())
        verify(preview.navigate("https://evil.test/", mainFrame = true), "Disposed stale callback must still reject untrusted main navigation")
        verify(hidden(preview), "Late callbacks must not resurrect the detached fallback")
        verify(preview.webView.loadedUrls.isEmpty() && preview.webView.loadedDocuments.size == 1,
            "Late callbacks must not trigger a load")
    }

    cases["initial_url_validation_is_preserved"] = {
        for (url in listOf(
            "http://www.google.com/maps?q=x&output=embed",
            "https://evil.test/maps?q=x&output=embed",
            "https://user@www.google.com/maps?q=x&output=embed",
            "https://www.google.com:444/maps?q=x&output=embed",
            "https://www.google.com/maps?q=x&output=embed#fragment",
            "https://www.google.com/maps/embed?origin=mfe&pb=x",
            "https://www.google.com/maps?q=&output=embed",
            "https://www.google.com/maps?q=x&output=other",
            "https://www.google.com/maps?q=x&output=embed&extra=1",
            "https://www.google.com/maps?q=${"x".repeat(501)}&output=embed",
        )) {
            val preview = Preview(mapOf("url" to url))
            verify(preview.webView.loadedUrls.isEmpty() && preview.webView.loadedDocuments.isEmpty(), "Invalid initial URL must not load")
            verify(!hidden(preview), "Invalid initial URL must show fallback")
        }
    }

    cases["invalid_factory_arguments"] = {
        for (arguments in listOf(null, "invalid", emptyMap<String, String>(), mapOf("url" to 123))) {
            val preview = Preview(arguments)
            verify(preview.webView.loadedUrls.isEmpty() && preview.webView.loadedDocuments.isEmpty(), "Invalid factory arguments must not load")
            verify(!hidden(preview), "Invalid factory arguments must show fallback")
        }
    }

    val selected = if (args.isEmpty()) cases else cases.filterKeys { it == args.single() }
    require(selected.isNotEmpty()) { "Unknown case: ${args.joinToString()}" }
    var failed = 0
    for ((name, run) in selected) {
        try {
            run()
            println("PASS $name")
        } catch (error: Throwable) {
            failed++
            System.err.println("FAIL $name: ${error.message}")
        }
    }
    println("LocationMapPreview: ${selected.size - failed}/${selected.size} cases passed, $assertions assertions")
    if (failed > 0) exitProcess(1)
}
