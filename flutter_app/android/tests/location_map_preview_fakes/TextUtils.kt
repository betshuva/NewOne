package android.text

object TextUtils {
    fun htmlEncode(value: String): String = buildString {
        for (character in value) append(when (character) {
            '&' -> "&amp;"
            '<' -> "&lt;"
            '>' -> "&gt;"
            '"' -> "&quot;"
            '\'' -> "&#39;"
            else -> character.toString()
        })
    }
}
