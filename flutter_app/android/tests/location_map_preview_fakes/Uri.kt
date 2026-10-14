package android.net

import java.net.URI
import java.net.URLDecoder
import java.net.URLEncoder

// Only the Uri surface used by LocationMapPreview is implemented. Like Android,
// query names are decoded, but getQueryParameters matches the encoded key in
// the original query. An encoded alias therefore needs the production raw
// query-field count guard; the fake does not contain navigation policy.
class Uri private constructor(private val original: String, private val value: URI) {
    val scheme: String? get() = value.scheme
    val host: String? get() = value.host
    val port: Int get() = value.port
    val userInfo: String? get() = value.userInfo
    val fragment: String? get() = value.fragment
    val path: String? get() = value.path
    val encodedQuery: String?
        get() = if (value.rawQuery == null) null else original.substringAfter('?').substringBefore('#')
    val queryParameterNames: Set<String>
        get() = fields().map { decode(it.substringBefore('=')) }.toSet()

    fun getQueryParameter(key: String): String? = getQueryParameters(key).firstOrNull()

    fun getQueryParameters(key: String): List<String> {
        val encodedKey = URLEncoder.encode(key, "UTF-8")
        return fields().filter { it.substringBefore('=') == encodedKey }
            .map { decode(it.substringAfter('=', "")) }
    }

    private fun fields(): List<String> = encodedQuery?.split('&') ?: emptyList()

    override fun toString(): String = original

    companion object {
        // Android Uri accepts raw quotes in a query. Preserve the original
        // query for HTML-escaping checks, while Java parses the structural URI.
        fun parse(value: String): Uri = Uri(value, URI(value
            .replace("\"", "%22").replace("<", "%3C").replace(">", "%3E")
            .replace(" ", "%20").replace("\t", "%09")
            .replace("\n", "%0A").replace("\r", "%0D")))

        private fun decode(value: String): String =
            URLDecoder.decode(value.replace("+", "%2B"), "UTF-8")
    }
}
