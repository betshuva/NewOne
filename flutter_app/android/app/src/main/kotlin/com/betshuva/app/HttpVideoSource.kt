package com.betshuva.app

import java.io.ByteArrayOutputStream
import java.io.Closeable
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URI
import java.util.Locale
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/** A small, bounded range reader for the platform thumbnail extractor. */
internal class HttpVideoSource(
    private val uri: URI,
    private val cancelled: AtomicBoolean,
) : Closeable {
    private val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(12)
    private val blocks = object : LinkedHashMap<Long, ByteArray>(8, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<Long, ByteArray>?): Boolean =
            size > 8
    }
    private var fullBody: ByteArray? = null
    private var length = -1L
    private var received = 0
    private var requests = 0

    fun size(): Long {
        checkActive()
        if (length < 0 && blocks.isEmpty() && fullBody == null) blockAt(0)
        return length
    }

    fun readAt(position: Long, buffer: ByteArray, offset: Int, size: Int): Int {
        checkActive()
        if (position < 0 || offset < 0 || size < 0 || offset > buffer.size - size) {
            throw IOException("Invalid video read")
        }
        if (size == 0) return 0
        if (length >= 0 && position >= length) return -1
        val start = position - position % BLOCK_BYTES
        val block = fullBody ?: blockAt(start)
        val source = fullBody ?: block
        val index = if (fullBody != null) position else position - start
        if (index >= source.size) return -1
        val count = minOf(size, source.size - index.toInt())
        source.copyInto(buffer, offset, index.toInt(), index.toInt() + count)
        return count
    }

    private fun blockAt(start: Long): ByteArray {
        blocks[start]?.let { return it }
        if (start > Long.MAX_VALUE - BLOCK_BYTES) throw IOException("Invalid video range")
        val end = start + BLOCK_BYTES - 1
        var target = uri
        repeat(4) { redirect ->
            checkActive()
            if (++requests > 48) throw IOException("Video request limit exceeded")
            val connection = target.toURL().openConnection() as HttpURLConnection
            try {
                connection.instanceFollowRedirects = false
                connection.useCaches = false
                connection.connectTimeout = timeoutMillis()
                connection.readTimeout = timeoutMillis()
                connection.setRequestProperty("Range", "bytes=$start-$end")
                connection.setRequestProperty("Accept-Encoding", "identity")
                val code = connection.responseCode
                if (code in REDIRECT_CODES) {
                    if (redirect == 3) throw IOException("Too many video redirects")
                    val location = connection.getHeaderField("Location")
                        ?: throw IOException("Missing video redirect")
                    target = validatedUri(target.resolve(location).toString())
                        ?: throw IOException("Invalid video redirect")
                    return@repeat
                }
                val encoding = connection.getHeaderField("Content-Encoding")
                if (encoding != null && !encoding.equals("identity", ignoreCase = true)) {
                    throw IOException("Unsupported video encoding")
                }
                if (code == HttpURLConnection.HTTP_OK) {
                    // Some servers ignore Range. Accept only a small complete file.
                    val declared = connection.getHeaderField("Content-Length")?.toLongOrNull()
                    if (declared != null && (declared < 0 || declared > MAX_BYTES - received)) {
                        throw IOException("Video response too large")
                    }
                    val data = readResponse(connection, MAX_BYTES - received)
                    if (declared != null && data.size.toLong() != declared) {
                        throw IOException("Incomplete video response")
                    }
                    fullBody = data
                    length = data.size.toLong()
                    blocks.clear()
                    return data
                }
                if (code == 416) {
                    val total = EOF_RANGE.matchEntire(connection.getHeaderField("Content-Range") ?: "")
                        ?.groupValues?.get(1)?.toLongOrNull()
                    if (total == null || start < total || (length >= 0 && length != total)) {
                        throw IOException("Invalid video end range")
                    }
                    length = total
                    return ByteArray(0)
                }
                if (code != HttpURLConnection.HTTP_PARTIAL) throw IOException("Video request failed")
                val range = CONTENT_RANGE.matchEntire(connection.getHeaderField("Content-Range") ?: "")
                    ?: throw IOException("Missing video range")
                val actualStart = range.groupValues[1].toLongOrNull()
                val actualEnd = range.groupValues[2].toLongOrNull()
                val total = range.groupValues[3].toLongOrNull()
                    ?: throw IOException("Unknown video length")
                if (actualStart != start || actualEnd == null || actualEnd < start ||
                    actualEnd != minOf(end, total - 1) || total <= actualEnd ||
                    (length >= 0 && length != total)) {
                    throw IOException("Invalid video range")
                }
                length = total
                val expected = (actualEnd - start + 1).toInt()
                val data = readResponse(connection, expected)
                if (data.size != expected) throw IOException("Incomplete video range")
                blocks[start] = data
                return data
            } finally {
                connection.disconnect()
            }
        }
        throw IOException("Video redirect failed")
    }

    private fun readResponse(connection: HttpURLConnection, limit: Int): ByteArray {
        if (limit <= 0) throw IOException("Video byte limit exceeded")
        val output = ByteArrayOutputStream(minOf(limit, BLOCK_BYTES))
        connection.inputStream.use { input ->
            val buffer = ByteArray(16 * 1024)
            while (true) {
                checkActive()
                // One extra byte detects oversized/chunked responses without reading them fully.
                val count = input.read(buffer, 0, minOf(buffer.size, limit - output.size() + 1))
                if (count < 0) break
                received += count
                if (received > MAX_BYTES || count > limit - output.size()) {
                    throw IOException("Video byte limit exceeded")
                }
                output.write(buffer, 0, count)
            }
        }
        return output.toByteArray()
    }

    private fun checkActive() {
        if (cancelled.get() || Thread.currentThread().isInterrupted || System.nanoTime() >= deadline) {
            throw IOException("Video request expired")
        }
    }

    private fun timeoutMillis(): Int {
        checkActive()
        return minOf(3000, TimeUnit.NANOSECONDS.toMillis(deadline - System.nanoTime()).toInt())
            .coerceAtLeast(1)
    }

    override fun close() {
        cancelled.set(true)
    }

    companion object {
        private const val BLOCK_BYTES = 256 * 1024
        private const val MAX_BYTES = 8 * 1024 * 1024
        private val REDIRECT_CODES = setOf(301, 302, 303, 307, 308)
        private val CONTENT_RANGE = Regex("bytes (\\d+)-(\\d+)/(\\d+)", RegexOption.IGNORE_CASE)
        private val EOF_RANGE = Regex("bytes \\*/(\\d+)", RegexOption.IGNORE_CASE)

        fun validatedUri(value: String?): URI? = try {
            val uri = URI(value ?: "")
            uri.takeIf {
                it.scheme?.lowercase(Locale.ROOT) in setOf("http", "https") &&
                    !it.host.isNullOrBlank() && it.rawUserInfo == null &&
                    (it.port == -1 || it.port in 1..65535) &&
                    !it.rawAuthority.orEmpty().endsWith(":")
            }
        } catch (_: Exception) {
            null
        }
    }
}
