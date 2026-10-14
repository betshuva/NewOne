package android.view

import android.content.Context

open class View(val context: Context) {
    var visibility = VISIBLE
    var isFocusable = true
    var isFocusableInTouchMode = true

    companion object {
        const val VISIBLE = 0
        const val GONE = 8
    }
}

object Gravity {
    const val CENTER = 17
}
