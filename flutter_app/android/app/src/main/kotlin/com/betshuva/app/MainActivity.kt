package com.betshuva.app

import android.app.NotificationManager
import android.app.Notification
import android.app.Person
import android.content.Intent
import android.content.pm.ShortcutInfo
import android.content.pm.ShortcutManager
import android.graphics.drawable.Icon
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors

class MainActivity: FlutterActivity() {
    private var channel: MethodChannel? = null
    private val pendingShares = ArrayDeque<Map<String, Any?>>()
    private val shareWorker = Executors.newSingleThreadExecutor()
    private val shareCategory = "com.betshuva.app.CONVERSATION"
    private val shareDirectory by lazy { File(cacheDir, "incoming_shares").apply { mkdirs() } }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.betshuva.app/share")
        channel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "reconcileNotifications" -> {
                    val args = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
                    val counts = args["counts"] as? Map<*, *> ?: emptyMap<Any, Any>()
                    val before = (args["before"] as? Number)?.toLong() ?: 0L
                    val manager = getSystemService(NotificationManager::class.java)
                    manager.activeNotifications.forEach { item ->
                        val tag = item.tag ?: ""
                        val conversation = tag.startsWith("chat:") || tag.startsWith("group:")
                        val read = if (conversation) (counts[tag] as? Number)?.toInt() ?: 0 else -1
                        val legacy = !conversation && args["clearLegacy"] == true
                        if (item.notification.channelId == "betshuva_messages" &&
                            item.postTime <= before &&
                            item.notification.flags and Notification.FLAG_ONGOING_EVENT == 0 &&
                            (read == 0 || legacy)) manager.cancel(item.tag, item.id)
                    }
                    result.success(null)
                }
                "takePendingShare" -> result.success(if (pendingShares.isEmpty()) null else pendingShares.removeFirst())
                "releaseShare" -> {
                    val paths = call.arguments as? List<*> ?: emptyList<Any>()
                    shareWorker.execute {
                        paths.filterIsInstance<String>().forEach { path ->
                            val file = File(path)
                            if (file.parentFile?.canonicalPath == shareDirectory.canonicalPath) file.delete()
                        }
                    }
                    result.success(null)
                }
                "updateShareTargets" -> {
                    try {
                        updateShareTargets(call.arguments as? Map<*, *> ?: emptyMap<Any, Any>())
                        result.success(null)
                    } catch (_: Exception) { result.success(null) } // Optional Android suggestions.
                }
                else -> result.notImplemented()
            }
        }
        shareWorker.execute {
            val cutoff = System.currentTimeMillis() - 24L * 60 * 60 * 1000
            shareDirectory.listFiles()?.filter { it.lastModified() < cutoff }?.forEach { it.delete() }
        }
        acceptShare(intent)
    }

    override fun onDestroy() {
        channel?.setMethodCallHandler(null)
        channel = null
        shareWorker.shutdown()
        super.onDestroy()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        acceptShare(intent)
    }

    private fun acceptShare(source: Intent?) {
        if (source?.action != Intent.ACTION_SEND && source?.action != Intent.ACTION_SEND_MULTIPLE) return
        val incoming = Intent(source)
        // Consume once: a later login/rebuild must not re-import the launch intent.
        setIntent(Intent(this, MainActivity::class.java).setAction(Intent.ACTION_MAIN))
        shareWorker.execute {
            val share = try { parseShare(incoming) } catch (_: Exception) {
                mapOf("errors" to listOf("לא ניתן לקרוא את הפריטים ששיתפת. נסה לבחור אותם מחדש."))
            }
            runOnUiThread {
                pendingShares.addLast(share)
                // The queue survives until the authenticated Flutter screen asks for it.
                channel?.invokeMethod("sharesAvailable", null)
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun parseShare(source: Intent): Map<String, Any?> {
        val uris = linkedSetOf<Uri>()
        if (source.action == Intent.ACTION_SEND_MULTIPLE) {
            source.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)?.let { uris.addAll(it) }
        } else {
            source.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)?.let { uris.add(it) }
        }
        source.clipData?.let { clip ->
            for (i in 0 until clip.itemCount) clip.getItemAt(i).uri?.let { uris.add(it) }
        }
        val files = mutableListOf<Map<String, String>>()
        val errors = mutableListOf<String>()
        if (uris.size > 100) errors.add("אפשר לשתף עד 100 קבצים בכל פעם; פריטים נוספים לא נוספו.")
        uris.take(100).forEach { uri ->
            var copied: File? = null
            var name = "shared_file"
            try {
                // External senders may grant content URIs, never private app filesystem paths.
                require(uri.scheme == "content")
                contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { cursor ->
                    if (cursor.moveToFirst()) {
                        val ni = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                        if (ni >= 0) name = cursor.getString(ni) ?: name
                        val si = cursor.getColumnIndex(OpenableColumns.SIZE)
                        if (si >= 0 && !cursor.isNull(si)) require(cursor.getLong(si) <= 50L * 1024 * 1024)
                    }
                }
                name = name.substringAfterLast('/').substringAfterLast('\\').take(180).ifBlank { "shared_file" }
                val resolved = contentResolver.getType(uri)
                val extensionMime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(name.substringAfterLast('.', "").lowercase())
                val mime = listOf(resolved, extensionMime, source.type)
                    .firstOrNull { !it.isNullOrBlank() && !it.contains('*') && it != "application/octet-stream" }
                    ?: "application/octet-stream"
                copied = File(shareDirectory, UUID.randomUUID().toString() + "_" + name.replace(Regex("[^A-Za-z0-9._-]"), "_"))
                contentResolver.openInputStream(uri)?.use { input ->
                    copied.outputStream().use { output ->
                        val buffer = ByteArray(64 * 1024)
                        var total = 0L
                        while (true) {
                            val size = input.read(buffer)
                            if (size < 0) break
                            total += size
                            require(total <= 50L * 1024 * 1024)
                            output.write(buffer, 0, size)
                        }
                    }
                } ?: throw IllegalArgumentException("Unreadable URI")
                files.add(mapOf("path" to copied.absolutePath, "name" to name, "mime" to mime))
            } catch (_: Exception) {
                copied?.delete()
                errors.add("לא ניתן לצרף את $name. יש לוודא שהוא זמין ושגודלו אינו עולה על 50MB.")
            }
        }
        return mapOf(
            "files" to files,
            "text" to source.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString(),
            "targetShortcutId" to source.getStringExtra(Intent.EXTRA_SHORTCUT_ID),
            "errors" to errors
        )
    }

    private fun updateShareTargets(args: Map<*, *>) {
        if (Build.VERSION.SDK_INT < 29) return
        val manager = getSystemService(ShortcutManager::class.java)
        val accountId = args["accountId"] as? String ?: ""
        val contacts = args["contacts"] as? List<*> ?: emptyList<Any>()
        val shortcuts = contacts.take(manager.maxShortcutCountPerActivity).mapNotNull { raw ->
            val contact = raw as? Map<*, *> ?: return@mapNotNull null
            val id = contact["id"] as? String ?: return@mapNotNull null
            val name = (contact["name"] as? String)?.take(80)?.ifBlank { null } ?: return@mapNotNull null
            if (accountId.isBlank()) return@mapNotNull null
            val shortcutId = "$accountId:$id"
            ShortcutInfo.Builder(this, shortcutId)
                .setShortLabel(name).setLongLabel(name)
                .setIcon(Icon.createWithResource(this, com.betshuva.app.R.mipmap.ic_launcher))
                .setCategories(setOf(shareCategory))
                .setLongLived(true)
                .setPersons(arrayOf(Person.Builder().setName(name).setKey(id).build()))
                .setIntent(Intent(this, MainActivity::class.java)
                    .setAction(Intent.ACTION_SEND)
                    .putExtra(Intent.EXTRA_SHORTCUT_ID, shortcutId))
                .setRank(contacts.indexOf(raw))
                .build()
        }
        val prefs = getSharedPreferences("share_targets", MODE_PRIVATE)
        val oldIds = prefs.getStringSet("ids", emptySet()) ?: emptySet()
        val ids = shortcuts.map { it.id }.toSet()
        val removed = oldIds - ids
        if (removed.isNotEmpty()) {
            manager.disableShortcuts(removed.toList())
            manager.removeDynamicShortcuts(removed.toList())
            if (Build.VERSION.SDK_INT >= 30) manager.removeLongLivedShortcuts(removed.toList())
        }
        if (shortcuts.isEmpty()) manager.removeAllDynamicShortcuts()
        else manager.setDynamicShortcuts(shortcuts)
        prefs.edit().putStringSet("ids", ids).apply()
    }
}
