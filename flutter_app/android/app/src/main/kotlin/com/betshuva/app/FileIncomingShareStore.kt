package com.betshuva.app

import android.util.AtomicFile
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/** Atomic metadata writes keep an import recoverable if Android kills the app. */
class FileIncomingShareStore(private val file: File) : IncomingShareStore {
    private val atomicFile = AtomicFile(file)

    override fun load(): List<IncomingShareEnvelope> {
        if (!file.exists() && !File(file.path + ".bak").exists()) return emptyList()
        return try {
            val array = JSONArray(atomicFile.openRead().bufferedReader().use { it.readText() })
            (0 until array.length()).mapNotNull { index ->
                val item = array.optJSONObject(index) ?: return@mapNotNull null
                val id = item.optString("id").takeIf { it.isNotBlank() } ?: return@mapNotNull null
                val created = item.optLong("createdAt", 0).takeIf { it > 0 } ?: return@mapNotNull null
                val files = item.optJSONArray("files") ?: JSONArray()
                IncomingShareEnvelope(
                    id = id,
                    createdAt = created,
                    accountId = string(item, "accountId"),
                    files = (0 until files.length()).mapNotNull { fi ->
                        val f = files.optJSONObject(fi) ?: return@mapNotNull null
                        val path = string(f, "path") ?: return@mapNotNull null
                        IncomingShareFile(path, string(f, "name") ?: "shared_file", string(f, "mime") ?: "application/octet-stream")
                    },
                    text = string(item, "text"),
                    subject = string(item, "subject"),
                    targetShortcutId = string(item, "targetShortcutId"),
                    action = string(item, "action"),
                    calendar = item.optJSONObject("calendar")?.let { obj ->
                        obj.keys().asSequence().associateWith { key -> obj.opt(key).let { if (it == JSONObject.NULL) null else it } }
                    },
                    errors = item.optJSONArray("errors")?.let { errors ->
                        (0 until errors.length()).mapNotNull { errors.optString(it).takeIf(String::isNotBlank) }
                    } ?: emptyList(),
                    deliveredTargets = item.optJSONObject("deliveredTargets")?.let { deliveries ->
                        deliveries.keys().asSequence().associateWith { content ->
                            deliveries.optJSONArray(content)?.let { targets ->
                                (0 until targets.length()).mapNotNull { targets.optString(it).takeIf(String::isNotBlank) }
                            } ?: emptyList()
                        }
                    } ?: emptyMap(),
                    preparedMessages = item.optJSONArray("preparedMessages")?.let { messages ->
                        (0 until messages.length()).map { mi ->
                            val message = messages.getJSONObject(mi)
                            message.keys().asSequence().associateWith { key ->
                                if (message.isNull(key)) null else message.getString(key)
                            }
                        }
                    },
                )
            }
        } catch (_: Exception) {
            // A corrupt envelope must not make authentication or the app unusable.
            emptyList()
        }
    }

    override fun save(envelopes: List<IncomingShareEnvelope>) {
        file.parentFile?.mkdirs()
        val array = JSONArray()
        envelopes.forEach { entry ->
            val item = JSONObject(entry.payload())
            item.put("createdAt", entry.createdAt)
            item.put("accountId", entry.accountId ?: JSONObject.NULL)
            array.put(item)
        }
        val output = atomicFile.startWrite()
        try {
            output.write(array.toString().toByteArray(Charsets.UTF_8))
            atomicFile.finishWrite(output)
        } catch (error: Exception) {
            atomicFile.failWrite(output)
            throw error
        }
    }

    private fun string(item: JSONObject, key: String): String? =
        if (item.isNull(key)) null else item.optString(key).takeIf { it.isNotBlank() }
}
