package com.betshuva.app

import android.app.NotificationManager
import android.app.Notification
import android.app.Person
import android.content.Intent
import android.content.Context
import android.Manifest
import android.content.pm.PackageManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import android.content.pm.ShortcutInfo
import android.content.pm.ShortcutManager
import android.graphics.drawable.Icon
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import android.provider.CalendarContract
import android.widget.Toast
import android.webkit.MimeTypeMap
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors
import org.json.JSONArray

class MainActivity: FlutterActivity() {
    private var mediaBridge: NativeMediaBridge? = null
    private var channel: MethodChannel? = null
    private var contactsPermissionChannel: MethodChannel? = null
    private val shareWorker = Executors.newSingleThreadExecutor()
    private val shareCategory = "com.betshuva.app.CONVERSATION"
    private val shareDirectory by lazy { File(cacheDir, "incoming_shares").apply { mkdirs() } }
    private val pendingShares: IncomingShareQueue by lazy {
        synchronized(MainActivity::class.java) {
            durableShares ?: IncomingShareQueue(FileIncomingShareStore(File(filesDir, "incoming_share_queue.json"))).also {
                durableShares = it
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        mediaBridge = NativeMediaBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        contactsPermissionChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.betshuva.app/contacts")
        contactsPermissionChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "readPermissionStatus" -> {
                    val permission = Manifest.permission.READ_CONTACTS
                    val granted = ContextCompat.checkSelfPermission(this, permission) == PackageManager.PERMISSION_GRANTED
                    val requested = getSharedPreferences("contacts_permission", Context.MODE_PRIVATE).getBoolean("read_requested", false)
                    val permanent = !granted && requested && !ActivityCompat.shouldShowRequestPermissionRationale(this, permission)
                    result.success(if (granted) 1 else if (permanent) 4 else 0)
                }
                "markReadPermissionRequested" -> {
                    getSharedPreferences("contacts_permission", Context.MODE_PRIVATE).edit().putBoolean("read_requested", true).apply()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
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
                "takePendingShare" -> {
                    val args = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
                    try {
                        prunePendingShares()
                        result.success(pendingShares.take(args["accountId"] as? String ?: "")?.payload())
                    } catch (_: Exception) {
                        result.error("SHARE_STORAGE", "לא ניתן לפתוח כרגע את השיתוף. נסה שוב.", null)
                    }
                }
                "finishShare" -> {
                    val args = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
                    val id = args["id"] as? String ?: ""
                    val accountId = args["accountId"] as? String ?: ""
                    val leaseId = args["leaseId"] as? String ?: ""
                    val outcome = args["outcome"] as? String ?: ""
                    val paths = (args["completedPaths"] as? List<*>)?.filterIsInstance<String>()?.toSet() ?: emptySet()
                    try {
                        val rawDeliveries = args["deliveredTargets"] as? Map<*, *> ?: emptyMap<Any, Any>()
                        val deliveries = rawDeliveries.entries.associate { entry ->
                            require(entry.key is String && entry.value is List<*>)
                            val targets = entry.value as List<*>
                            require(targets.all { it is String })
                            (entry.key as String) to targets.filterIsInstance<String>()
                        }
                        val removed = pendingShares.finish(id, accountId, outcome, leaseId, paths,
                            args["clearText"] == true, deliveries, args["clearCalendar"] == true)
                        shareWorker.execute { removed.forEach(::deleteShareFile) }
                        result.success(null)
                    } catch (_: Exception) {
                        result.error("SHARE_STORAGE", "השיתוף נשמר לניסיון נוסף; לא ניתן לאשר את ההשלמה כרגע.", null)
                    }
                }
                "resetInflight" -> {
                    val args = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
                    pendingShares.resetInflight(args["accountId"] as? String ?: "")
                    result.success(null)
                }
                "retryPendingShares" -> {
                    val args = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
                    prunePendingShares()
                    val count = pendingShares.retry(args["accountId"] as? String ?: "")
                    result.success(count)
                    if (count > 0) channel?.invokeMethod("sharesAvailable", null)
                }
                "pendingShareCount" -> {
                    val args = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
                    prunePendingShares()
                    result.success(pendingShares.count(args["accountId"] as? String ?: ""))
                }
                "attachCapturedShareFile" -> {
                    val args = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
                    shareWorker.execute {
                        try {
                            val file = attachCapturedShareFile(args)
                            runOnUiThread { result.success(mapOf("path" to file.path, "name" to file.name, "mime" to file.mime)) }
                        } catch (_: Exception) {
                            runOnUiThread { result.error("SHARE_CAPTURE", "לא ניתן לשמור את הצילום לשיתוף כרגע. נסה שוב.", null) }
                        }
                    }
                }
                "prepareShareMessages" -> {
                    val args = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
                    try {
                        val raw = args["messages"] as? List<*> ?: throw IllegalArgumentException()
                        require(raw.size <= 101)
                        val messages = raw.map { value ->
                            val message = value as? Map<*, *> ?: throw IllegalArgumentException()
                            message.entries.associate { entry ->
                                require(entry.key is String && (entry.value == null || entry.value is String))
                                (entry.key as String) to (entry.value as String?)
                            }
                        }
                        require(JSONArray(messages).toString().toByteArray(Charsets.UTF_8).size <= 1024 * 1024)
                        require(pendingShares.prepare(args["id"] as? String ?: "", args["accountId"] as? String ?: "",
                            args["leaseId"] as? String ?: "", messages))
                        result.success(null)
                    } catch (_: Exception) {
                        result.error("SHARE_PREPARATION", "לא ניתן לשמור את הפריטים שאושרו לשליחה. השיתוף נשמר לניסיון נוסף.", null)
                    }
                }
                "releaseShare" -> {
                    // Compatibility cleanup cannot acknowledge queued/in-flight work.
                    // New callers must finish an exact envelope with its account and lease.
                    val paths = call.arguments as? List<*> ?: emptyList<Any>()
                    shareWorker.execute {
                        val retained = pendingShares.paths()
                        paths.filterIsInstance<String>().filterNot { it in retained }.forEach(::deleteShareFile)
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
            try { pendingShares.prune().forEach(::deleteShareFile) } catch (_: Exception) { /* Keep files if metadata cannot be persisted. */ }
            val cutoff = System.currentTimeMillis() - 24L * 60 * 60 * 1000
            val retained = pendingShares.paths()
            shareDirectory.listFiles()?.filter { it.lastModified() < cutoff && it.absolutePath !in retained }?.forEach { it.delete() }
        }
        acceptShare(intent)
    }

    override fun onDestroy() {
        mediaBridge?.dispose()
        mediaBridge = null
        channel?.setMethodCallHandler(null)
        channel = null
        contactsPermissionChannel?.setMethodCallHandler(null)
        contactsPermissionChannel = null
        shareWorker.shutdown()
        super.onDestroy()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        acceptShare(intent)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (mediaBridge?.onActivityResult(requestCode, resultCode, data) == true) return
        super.onActivityResult(requestCode, resultCode, data)
    }

    private fun acceptShare(source: Intent?) {
        if (source == null || source.action !in setOf(Intent.ACTION_SEND, Intent.ACTION_SEND_MULTIPLE, OPEN_ACTION)) return
        val incoming = Intent(source)
        // Consume once: a later login/rebuild must not re-import the launch intent.
        setIntent(Intent(this, MainActivity::class.java).setAction(Intent.ACTION_MAIN))
        shareWorker.execute {
            try { pendingShares.prune().forEach(::deleteShareFile) } catch (_: Exception) { /* Keep existing imports. */ }
            if (!pendingShares.hasCapacity()) {
                runOnUiThread { Toast.makeText(this, "יש יותר מדי שיתופים ממתינים. שלח או בטל פריטים קיימים ושתף שוב.", Toast.LENGTH_LONG).show() }
                return@execute
            }
            val share = try { parseShare(incoming) } catch (_: Exception) {
                IncomingShareEnvelope(UUID.randomUUID().toString(), System.currentTimeMillis(),
                    errors = listOf("לא ניתן לקרוא את הפריטים ששיתפת. נסה לבחור אותם מחדש."))
            }
            val accepted = try { pendingShares.enqueue(share) } catch (_: Exception) { false }
            if (!accepted) share.files.forEach { deleteShareFile(it.path) }
            runOnUiThread {
                if (accepted) channel?.invokeMethod("sharesAvailable", null)
                else Toast.makeText(this, "יש יותר מדי שיתופים ממתינים. שלח או בטל פריטים קיימים ושתף שוב.", Toast.LENGTH_LONG).show()
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun parseShare(source: Intent): IncomingShareEnvelope {
        if (source.action == OPEN_ACTION) {
            val action = source.getStringExtra("betshuva_action")
            require(action in setOf("newchat", "capture", "newlisting"))
            return IncomingShareEnvelope(UUID.randomUUID().toString(), System.currentTimeMillis(), action = action)
        }
        val uris = linkedSetOf<Uri>()
        if (source.action == Intent.ACTION_SEND_MULTIPLE) {
            source.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)?.let { uris.addAll(it) }
        } else {
            source.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)?.let { uris.add(it) }
        }
        source.clipData?.let { clip ->
            for (i in 0 until clip.itemCount) clip.getItemAt(i).uri?.let { uris.add(it) }
        }
        val files = mutableListOf<IncomingShareFile>()
        val errors = mutableListOf<String>()
        var availableBytes = 500L * 1024 * 1024 - (shareDirectory.listFiles()?.sumOf { it.length() } ?: 0L)
        if (uris.size > 100) errors.add("אפשר לשתף עד 100 קבצים בכל פעם; פריטים נוספים לא נוספו.")
        val sharedLinks = uris.filter { it.scheme in setOf("https", "http", "geo") }.map { it.toString() }
        uris.filterNot { it.scheme in setOf("https", "http", "geo") }.take(100).forEach { uri ->
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
                            require(total <= availableBytes)
                            require(shareDirectory.usableSpace > 16L * 1024 * 1024 + size)
                            output.write(buffer, 0, size)
                        }
                    }
                } ?: throw IllegalArgumentException("Unreadable URI")
                availableBytes -= copied.length()
                files.add(IncomingShareFile(copied.absolutePath, name, mime))
            } catch (_: Exception) {
                copied?.delete()
                errors.add("לא ניתן לצרף את $name. יש לוודא שהוא זמין, שגודלו אינו עולה על 50MB ושיש מקום פנוי בטלפון.")
            }
        }
        val text = source.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()?.takeIf { it.isNotBlank() }
            ?: source.clipData?.let { clip ->
                (0 until clip.itemCount).mapNotNull { clip.getItemAt(it).text?.toString() }
                    .filter { it.isNotBlank() }.joinToString("\n").ifBlank { null }
            } ?: sharedLinks.joinToString("\n").ifBlank { null }
        val subject = source.getCharSequenceExtra(Intent.EXTRA_SUBJECT)?.toString()
        val boundedText = if (text != null && text.length > 512 * 1024) {
            errors.add("הטקסט ששיתפת גדול מדי. בחר קובץ או טקסט קצר יותר.")
            null
        } else text
        val shortcutId = source.getStringExtra(Intent.EXTRA_SHORTCUT_ID)
        return IncomingShareEnvelope(
            id = UUID.randomUUID().toString(),
            createdAt = System.currentTimeMillis(),
            accountId = IncomingShareQueue.accountFromShortcut(shortcutId),
            files = files,
            text = boundedText,
            subject = subject?.take(1000),
            targetShortcutId = shortcutId,
            calendar = calendarMetadata(source),
            errors = errors,
        )
    }

    private fun calendarMetadata(source: Intent): Map<String, Any?>? {
        val mime = source.type?.substringBefore(';')?.lowercase()
        if (mime !in setOf("text/calendar", "application/ics", "vnd.android.cursor.item/event", "vnd.android.cursor.dir/event")) return null
        val values = linkedMapOf<String, Any?>()
        for ((key, extra) in listOf("title" to CalendarContract.Events.TITLE,
            "description" to CalendarContract.Events.DESCRIPTION,
            "eventLocation" to CalendarContract.Events.EVENT_LOCATION,
            "eventTimezone" to CalendarContract.Events.EVENT_TIMEZONE)) {
            source.getStringExtra(extra)?.take(8000)?.let { values[key] = it }
        }
        for ((key, extra) in listOf("beginTime" to CalendarContract.EXTRA_EVENT_BEGIN_TIME,
            "endTime" to CalendarContract.EXTRA_EVENT_END_TIME)) {
            if (source.hasExtra(extra)) {
                val value = source.getLongExtra(extra, -1L)
                if (value >= 0) values[key] = value
            }
        }
        if (source.hasExtra(CalendarContract.EXTRA_EVENT_ALL_DAY)) {
            values["allDay"] = source.getBooleanExtra(CalendarContract.EXTRA_EVENT_ALL_DAY, false)
        }
        return values.takeIf { it.isNotEmpty() }
    }

    private fun deleteShareFile(path: String) {
        try {
            val file = File(path)
            if (file.parentFile?.canonicalPath == shareDirectory.canonicalPath && file.canonicalPath == file.absolutePath) file.delete()
        } catch (_: Exception) { /* TTL cleanup retries files still present. */ }
    }

    private fun prunePendingShares() {
        try {
            val expired = pendingShares.prune()
            if (expired.isNotEmpty()) shareWorker.execute { expired.forEach(::deleteShareFile) }
        } catch (_: Exception) { /* A persistence failure keeps work available instead of losing it. */ }
    }

    private fun attachCapturedShareFile(args: Map<*, *>): IncomingShareFile {
        val id = args["id"] as? String ?: ""
        val accountId = args["accountId"] as? String ?: ""
        val leaseId = args["leaseId"] as? String ?: ""
        require(pendingShares.canAttachCapture(id, accountId, leaseId))
        val source = File(args["path"] as? String ?: "").canonicalFile
        val allowedRoots = listOf(cacheDir.canonicalPath + File.separator, filesDir.canonicalPath + File.separator)
        require(source.isFile && allowedRoots.any { source.path.startsWith(it) })
        val mime = args["mime"] as? String ?: "image/jpeg"
        require(mime in setOf("image/jpeg", "image/png", "image/webp", "image/gif"))
        val header = source.inputStream().use { input ->
            val buffer = ByteArray(12)
            val read = input.read(buffer)
            if (read < 0) ByteArray(0) else buffer.copyOf(read)
        }
        val valid = when (mime) {
            "image/jpeg" -> header.size >= 3 && header[0] == 0xff.toByte() && header[1] == 0xd8.toByte() && header[2] == 0xff.toByte()
            "image/png" -> header.size >= 8 && header.take(8).toByteArray().contentEquals(byteArrayOf(0x89.toByte(), 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a))
            "image/webp" -> header.size >= 12 && String(header, 0, 4, Charsets.US_ASCII) == "RIFF" && String(header, 8, 4, Charsets.US_ASCII) == "WEBP"
            "image/gif" -> header.size >= 6 && String(header, 0, 6, Charsets.US_ASCII) in setOf("GIF87a", "GIF89a")
            else -> false
        }
        require(valid)
        val size = source.length()
        require(size in 1..(50L * 1024 * 1024))
        val retainedBytes = shareDirectory.listFiles()?.sumOf { it.length() } ?: 0L
        require(retainedBytes + size <= 500L * 1024 * 1024)
        require(shareDirectory.usableSpace > size + 16L * 1024 * 1024)
        val name = (args["name"] as? String ?: "photo.jpg").substringAfterLast('/').substringAfterLast('\\').take(180).ifBlank { "photo.jpg" }
        val copy = File(shareDirectory, UUID.randomUUID().toString() + "_" + name.replace(Regex("[^A-Za-z0-9._-]"), "_"))
        try {
            source.inputStream().use { input ->
                copy.outputStream().use { output ->
                    val buffer = ByteArray(64 * 1024)
                    var total = 0L
                    while (true) {
                        val bytes = input.read(buffer)
                        if (bytes < 0) break
                        total += bytes
                        require(total <= size)
                        output.write(buffer, 0, bytes)
                    }
                    require(total == size)
                }
            }
            val shared = IncomingShareFile(copy.absolutePath, name, mime)
            require(pendingShares.attachCapture(id, accountId, leaseId, shared))
            return shared
        } catch (error: Exception) {
            copy.delete()
            throw error
        }
    }

    private fun updateShareTargets(args: Map<*, *>) {
        if (Build.VERSION.SDK_INT < 29) return
        val manager = getSystemService(ShortcutManager::class.java)
        val accountId = args["accountId"] as? String ?: ""
        val contacts = args["contacts"] as? List<*> ?: emptyList<Any>()
        val capacity = (manager.maxShortcutCountPerActivity - manager.manifestShortcuts.size).coerceAtLeast(0)
        val shortcuts = contacts.take(capacity).mapNotNull { raw ->
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

    private companion object {
        const val OPEN_ACTION = "com.betshuva.app.OPEN_ACTION"
        var durableShares: IncomingShareQueue? = null
    }
}
