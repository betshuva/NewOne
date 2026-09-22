package com.betshuva.app

import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors

/** Clipboard reads happen only in response to the user's paste command. */
class NativeMediaBridge(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "com.betshuva.app/media")
    private val worker = Executors.newSingleThreadExecutor()
    private var pendingSave: Pair<ByteArray, MethodChannel.Result>? = null
    private val maxBytes = 50 * 1024 * 1024

    init {
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "copyImage" -> {
                        val bytes = call.argument<ByteArray>("bytes")!!
                        val mime = call.argument<String>("mimeType")!!
                        require(bytes.isNotEmpty() && bytes.size <= maxBytes && mime.startsWith("image/"))
                        worker.execute {
                            try {
                                val directory = File(activity.cacheDir, "clipboard_images").apply { mkdirs() }
                                val cutoff = System.currentTimeMillis() - 7L * 24 * 60 * 60 * 1000
                                directory.listFiles()?.filter { it.lastModified() < cutoff }?.forEach { it.delete() }
                                val extension = MimeTypeMap.getSingleton().getExtensionFromMimeType(mime) ?: "png"
                                val file = File(directory, "${UUID.randomUUID()}.$extension")
                                file.writeBytes(bytes)
                                val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.clipboard", file)
                                activity.runOnUiThread {
                                    try {
                                        val clipboard = activity.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                                        clipboard.setPrimaryClip(ClipData.newUri(activity.contentResolver, "תמונה", uri))
                                        result.success(true)
                                    } catch (_: Exception) { result.error("clipboard", "Cannot copy image", null) }
                                }
                            } catch (_: Exception) { fail(result) }
                        }
                    }
                    "pasteImage" -> {
                        val clipboard = activity.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                        val clip = clipboard.primaryClip
                        val uri = if (clip != null && clip.itemCount > 0) clip.getItemAt(0).uri else null
                        if (uri == null || uri.scheme != "content") {
                            result.success(null)
                        } else {
                            worker.execute {
                                try {
                                    val mime = activity.contentResolver.getType(uri) ?: ""
                                    require(mime.startsWith("image/"))
                                    val bytes = activity.contentResolver.openInputStream(uri)!!.use { input ->
                                        val output = ByteArrayOutputStream()
                                        val buffer = ByteArray(64 * 1024)
                                        while (true) {
                                            val size = input.read(buffer)
                                            if (size < 0) break
                                            require(output.size() + size <= maxBytes)
                                            output.write(buffer, 0, size)
                                        }
                                        output.toByteArray()
                                    }
                                    val ext = MimeTypeMap.getSingleton().getExtensionFromMimeType(mime) ?: "png"
                                    activity.runOnUiThread { result.success(mapOf(
                                        "bytes" to bytes, "mimeType" to mime,
                                        "fileName" to "clipboard-${System.currentTimeMillis()}.$ext"
                                    )) }
                                } catch (_: Exception) { fail(result) }
                            }
                        }
                    }
                    "saveFile" -> {
                        check(pendingSave == null)
                        val bytes = call.argument<ByteArray>("bytes")!!
                        require(bytes.isNotEmpty() && bytes.size <= maxBytes)
                        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT)
                            .addCategory(Intent.CATEGORY_OPENABLE)
                            .setType(call.argument<String>("mimeType") ?: "application/octet-stream")
                            .putExtra(Intent.EXTRA_TITLE, call.argument<String>("fileName") ?: "image.png")
                        pendingSave = bytes to result
                        try { activity.startActivityForResult(intent, SAVE_REQUEST) }
                        catch (error: Exception) { pendingSave = null; throw error }
                    }
                    else -> result.notImplemented()
                }
            } catch (_: Exception) { result.error("media", "Cannot complete media action", null) }
        }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != SAVE_REQUEST) return false
        val pending = pendingSave ?: return true
        pendingSave = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) pending.second.success(false)
        else worker.execute {
            try {
                activity.contentResolver.openOutputStream(uri, "w")!!.use { it.write(pending.first) }
                activity.runOnUiThread { pending.second.success(true) }
            } catch (_: Exception) { fail(pending.second) }
        }
        return true
    }

    private fun fail(result: MethodChannel.Result) {
        activity.runOnUiThread { result.error("media", "Cannot complete media action", null) }
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        pendingSave?.second?.success(false)
        pendingSave = null
        worker.shutdown()
    }

    companion object { private const val SAVE_REQUEST = 42871 }
}
