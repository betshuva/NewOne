package com.betshuva.app

import java.util.UUID

data class IncomingShareFile(val path: String, val name: String, val mime: String)

data class IncomingShareEnvelope(
    val id: String,
    val createdAt: Long,
    val accountId: String? = null,
    val files: List<IncomingShareFile> = emptyList(),
    val text: String? = null,
    val subject: String? = null,
    val targetShortcutId: String? = null,
    val action: String? = null,
    val calendar: Map<String, Any?>? = null,
    val errors: List<String> = emptyList(),
    val leaseId: String? = null,
    val deliveredTargets: Map<String, List<String>> = emptyMap(),
    val preparedMessages: List<Map<String, String?>>? = null,
) {
    fun payload(): Map<String, Any?> = mapOf(
        "id" to id,
        "files" to files.map { mapOf("path" to it.path, "name" to it.name, "mime" to it.mime) },
        "text" to text,
        "subject" to subject,
        "targetShortcutId" to targetShortcutId,
        "action" to action,
        "calendar" to calendar,
        "errors" to errors,
        "leaseId" to leaseId,
        "deliveredTargets" to deliveredTargets,
        "preparedMessages" to preparedMessages,
    )
}

interface IncomingShareStore {
    fun load(): List<IncomingShareEnvelope>
    fun save(envelopes: List<IncomingShareEnvelope>)
}

/** Durable import ownership is independent of the Activity or a sending screen. */
class IncomingShareQueue(
    private val store: IncomingShareStore,
    private val now: () -> Long = System::currentTimeMillis,
    private val maxEntries: Int = 10,
    private val lifetimeMs: Long = 24L * 60 * 60 * 1000,
) {
    private val entries = store.load().toMutableList()
    private val inFlight = mutableMapOf<String, String>()
    private val heldForRetry = mutableSetOf<String>()

    @Synchronized
    fun hasCapacity(): Boolean = entries.size < maxEntries

    @Synchronized
    fun enqueue(envelope: IncomingShareEnvelope): Boolean {
        if (entries.size >= maxEntries || entries.any { it.id == envelope.id }) return false
        val updated = entries + envelope
        store.save(updated)
        entries.add(envelope)
        return true
    }

    /** Claim before returning content; another login cannot consume a claimed import. */
    @Synchronized
    fun take(accountId: String): IncomingShareEnvelope? {
        if (!isAccountId(accountId)) return null
        val index = entries.indexOfFirst {
            (it.accountId == null || it.accountId == accountId) &&
                it.id !in inFlight && it.id !in heldForRetry
        }
        if (index < 0) return null
        val claimed = entries[index].copy(accountId = accountId)
        val updated = entries.toMutableList().apply { this[index] = claimed }
        store.save(updated)
        entries[index] = claimed
        val lease = UUID.randomUUID().toString()
        inFlight[claimed.id] = lease
        return claimed.copy(leaseId = lease)
    }

    /** Return only recorded paths to the caller; never authorize deletion of arbitrary paths. */
    @Synchronized
    fun finish(
        id: String,
        accountId: String,
        outcome: String,
        leaseId: String,
        completedPaths: Set<String> = emptySet(),
        clearText: Boolean = false,
        deliveredTargets: Map<String, List<String>> = emptyMap(),
        clearCalendar: Boolean = false,
    ): List<String> {
        if (!isAccountId(accountId) || outcome !in setOf("completed", "cancelled", "retry")) return emptyList()
        val index = entries.indexOfFirst { it.id == id && it.accountId == accountId }
        if (index < 0 || inFlight[id] != leaseId) return emptyList()
        val entry = entries[index]
        val deliveryState = entry.deliveredTargets.toMutableMap()
        require(deliveredTargets.size <= 101) // 100 files plus an optional text item.
        deliveredTargets.forEach { (content, targets) ->
            require(contentPattern.matches(content) && targets.size <= 100)
            require(targets.all { targetPattern.matches(it) })
            val key = content.lowercase()
            val merged = ((deliveryState[key] ?: emptyList()) + targets).distinct()
            require(merged.size <= 100)
            deliveryState[key] = merged
        }
        require(deliveryState.size <= 101)
        val removed = if (outcome == "retry") entry.files.filter { it.path in completedPaths } else entry.files
        val remaining = entry.copy(
            files = entry.files.filterNot { file -> removed.any { it.path == file.path } },
            text = if (clearText) null else entry.text,
            subject = if (clearText) null else entry.subject,
            calendar = if (clearCalendar) null else entry.calendar,
            errors = emptyList(),
            deliveredTargets = deliveryState,
            preparedMessages = entry.preparedMessages?.filterNot { message ->
                val source = message["sourcePath"] ?: message["localPath"]
                source != null && removed.any { it.path == source } || source == null && clearText
            }?.takeIf { it.isNotEmpty() },
        )
        val finished = outcome != "retry" ||
            remaining.files.isEmpty() && remaining.text.isNullOrBlank() &&
                remaining.calendar == null && remaining.action == null && remaining.preparedMessages.isNullOrEmpty()
        val updated = entries.toMutableList().apply {
            if (finished) removeAt(index) else this[index] = remaining
        }
        store.save(updated)
        entries.clear()
        entries.addAll(updated)
        inFlight.remove(id)
        if (finished) heldForRetry.remove(id) else heldForRetry.add(id)
        return removed.map { it.path }
    }

    @Synchronized
    fun retry(accountId: String): Int {
        if (!isAccountId(accountId)) return 0
        val ids = entries.filter { it.accountId == accountId && it.id !in inFlight }.map { it.id }.toSet()
        heldForRetry.removeAll(ids)
        return ids.size
    }

    /** A replacement authenticated screen can reclaim work whose owner was disposed. */
    @Synchronized
    fun resetInflight(accountId: String) {
        if (!isAccountId(accountId)) return
        val ids = entries.filter { it.accountId == accountId }.map { it.id }.toSet()
        ids.forEach { inFlight.remove(it) }
    }

    @Synchronized
    fun canAttachCapture(id: String, accountId: String, leaseId: String): Boolean =
        isAccountId(accountId) && inFlight[id] == leaseId && entries.any {
            it.id == id && it.accountId == accountId && it.action == "capture" && it.files.isEmpty()
        }

    /** Replace the action with durable bytes before sending; a retry must not recapture. */
    @Synchronized
    fun attachCapture(id: String, accountId: String, leaseId: String, file: IncomingShareFile): Boolean {
        if (!canAttachCapture(id, accountId, leaseId)) return false
        val index = entries.indexOfFirst { it.id == id }
        val updated = entries.toMutableList().apply {
            this[index] = this[index].copy(files = listOf(file), action = null)
        }
        store.save(updated)
        entries.clear()
        entries.addAll(updated)
        return true
    }

    /** Persist approved contact fields and edited text before the first delivery. */
    @Synchronized
    fun prepare(id: String, accountId: String, leaseId: String, messages: List<Map<String, String?>>): Boolean {
        if (!isAccountId(accountId) || inFlight[id] != leaseId) return false
        val index = entries.indexOfFirst { it.id == id && it.accountId == accountId }
        if (index < 0) return false
        require(messages.size <= 101)
        val allowedPaths = entries[index].files.map { it.path }.toSet()
        messages.forEach { message ->
            require(message.keys.all { it in preparedFields })
            require((message["text"]?.length ?: 0) <= 20_000)
            require((message["fileName"]?.length ?: 0) <= 255)
            require((message["mimeType"]?.length ?: 0) <= 128)
            require(message["fileType"] == null || message["fileType"] in preparedTypes)
            for (key in listOf("localPath", "sourcePath")) {
                val path = message[key]
                require(path == null || path in allowedPaths)
            }
            require(!message["text"].isNullOrBlank() || message["localPath"] != null)
        }
        require(preparedJsonBytes(messages) <= 1024 * 1024)
        val prepared = messages.map { it.toMap() }
        val original = entries[index].preparedMessages
        if (original != null) return original == prepared
        val updated = entries.toMutableList().apply { this[index] = this[index].copy(preparedMessages = prepared) }
        store.save(updated)
        entries.clear()
        entries.addAll(updated)
        return true
    }

    @Synchronized
    fun count(accountId: String): Int = if (!isAccountId(accountId)) 0 else entries.count {
        (it.accountId == null || it.accountId == accountId) && it.id !in inFlight
    }

    @Synchronized
    fun paths(): Set<String> = entries.flatMap { it.files }.map { it.path }.toSet()

    @Synchronized
    fun prune(): List<String> {
        val cutoff = now() - lifetimeMs
        val removed = entries.filter { it.createdAt < cutoff && it.id !in inFlight }
        if (removed.isEmpty()) return emptyList()
        val ids = removed.map { it.id }.toSet()
        val updated = entries.filterNot { it.id in ids }
        store.save(updated)
        entries.clear()
        entries.addAll(updated)
        heldForRetry.removeAll(ids)
        return removed.flatMap { it.files }.map { it.path }
    }

    companion object {
        private val accountPattern = Regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
        private val contentPattern = Regex("^[0-9a-fA-F]{64}$")
        private val targetPattern = Regex("^(user|group):[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
        private val preparedFields = setOf("text", "localPath", "fileName", "fileType", "mimeType", "sourcePath")
        private val preparedTypes = setOf("text", "image", "video", "audio", "document")
        private fun jsonStringBytes(value: String): Int = 2 + value.toByteArray(Charsets.UTF_8).size + value.sumOf { char ->
            when (char) {
                '"', '\\', '\b', '\n', '\r', '\t', '\u000c' -> 1
                else -> if (char.code < 0x20) 5 else 0
            }
        }
        private fun preparedJsonBytes(messages: List<Map<String, String?>>): Long = 2L +
            (messages.size - 1).coerceAtLeast(0) + messages.sumOf { message ->
                2L + (message.size - 1).coerceAtLeast(0) + message.entries.sumOf { (key, value) ->
                    jsonStringBytes(key).toLong() + 1 + (value?.let(::jsonStringBytes) ?: 4)
                }
            }
        fun isAccountId(value: String): Boolean = accountPattern.matches(value)
        fun accountFromShortcut(value: String?): String? =
            value?.substringBefore(':')?.takeIf { isAccountId(it) && value.substringAfter(':', "").isNotBlank() }
    }
}
