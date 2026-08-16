package com.betshuva.app

import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity: FlutterActivity() {
    private val channelName = "com.betshuva.app/share"
    private var channel: MethodChannel? = null
    private var pendingShare: Map<String, String?>? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        channel?.setMethodCallHandler { call, result ->
            if (call.method == "getInitialShare") {
                if (pendingShare == null) pendingShare = parseShare(intent)
                result.success(pendingShare)
                pendingShare = null
            } else {
                result.notImplemented()
            }
        }
        pendingShare = parseShare(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val share = parseShare(intent) ?: return
        if (channel != null) channel?.invokeMethod("sharedContent", share)
        else pendingShare = share
    }

    private fun parseShare(intent: Intent?): Map<String, String?>? {
        if (intent?.action != Intent.ACTION_SEND) return null
        val mime = intent.type ?: ""
        val text = intent.getStringExtra(Intent.EXTRA_TEXT)
        val uri = intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
        if (uri == null) return if (!text.isNullOrBlank()) mapOf("text" to text) else null
        return try {
            var name = "shared_image"
            contentResolver.query(uri, null, null, null, null)?.use { cursor ->
                val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (index >= 0 && cursor.moveToFirst()) name = cursor.getString(index)
            }
            val safeName = name.replace(Regex("[^A-Za-z0-9._-]"), "_")
            val file = File(cacheDir, "share_${System.currentTimeMillis()}_$safeName")
            contentResolver.openInputStream(uri)?.use { input ->
                file.outputStream().use { output -> input.copyTo(output) }
            } ?: return null
            mapOf("path" to file.absolutePath, "name" to name, "mime" to mime)
        } catch (_: Exception) {
            null
        }
    }
}
