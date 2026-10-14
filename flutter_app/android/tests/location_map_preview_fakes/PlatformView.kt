package io.flutter.plugin.platform

import android.content.Context
import android.view.View
import io.flutter.plugin.common.StandardMessageCodec

interface PlatformView {
    fun getView(): View
    fun dispose()
}

abstract class PlatformViewFactory(val codec: StandardMessageCodec) {
    abstract fun create(context: Context, viewId: Int, args: Any?): PlatformView
}
