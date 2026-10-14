package android.widget

import android.content.Context
import android.view.View

class FrameLayout(context: Context) : View(context) {
    val children = mutableListOf<View>()

    fun addView(view: View, parameters: LayoutParams) {
        check(parameters.width == LayoutParams.MATCH_PARENT)
        check(parameters.height == LayoutParams.MATCH_PARENT)
        children.add(view)
    }

    fun removeAllViews() { children.clear() }

    class LayoutParams(val width: Int, val height: Int) {
        companion object { const val MATCH_PARENT = -1 }
    }
}

class TextView(context: Context) : View(context) {
    var text: CharSequence = ""
    var gravity = 0
    var backgroundColorValue = 0

    fun setBackgroundColor(color: Int) { backgroundColorValue = color }
}
