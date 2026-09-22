package com.betshuva.app

import android.graphics.Bitmap
import android.media.MediaDataSource
import android.media.MediaMetadataRetriever
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.net.URI
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.roundToInt

internal class VideoThumbnailer {
    private val main = Handler(Looper.getMainLooper())
    private val worker = ThreadPoolExecutor(
        1, 1, 0L, TimeUnit.MILLISECONDS, ArrayBlockingQueue(4),
        { command -> Thread(command, "video-thumbnail") },
        ThreadPoolExecutor.AbortPolicy(),
    )
    private val pending = mutableSetOf<Request>()
    private var disposed = false

    fun generate(url: String?, result: MethodChannel.Result) {
        val uri = HttpVideoSource.validatedUri(url)
        if (disposed || uri == null) {
            result.success(null)
            return
        }
        val request = Request(result)
        request.timeout = Runnable { complete(request, null) }
        request.task = Runnable {
            val bytes = if (request.cancelled.get()) null else extract(uri, request.cancelled)
            main.post { complete(request, bytes) }
        }
        pending.add(request)
        main.postDelayed(request.timeout, 25_000)
        try {
            worker.execute(request.task)
        } catch (_: RejectedExecutionException) {
            complete(request, null)
        }
    }

    private fun complete(request: Request, bytes: ByteArray?) {
        if (!pending.remove(request)) return
        request.cancelled.set(true)
        main.removeCallbacks(request.timeout)
        worker.remove(request.task)
        request.result.success(bytes)
    }

    private fun extract(uri: URI, cancelled: AtomicBoolean): ByteArray? {
        val source = HttpVideoSource(uri, cancelled)
        var retriever: MediaMetadataRetriever? = null
        var frame: Bitmap? = null
        var thumbnail: Bitmap? = null
        try {
            retriever = MediaMetadataRetriever()
            retriever.setDataSource(object : MediaDataSource() {
                override fun getSize(): Long = source.size()
                override fun readAt(position: Long, buffer: ByteArray, offset: Int, size: Int): Int =
                    source.readAt(position, buffer, offset, size)
                override fun close() = source.close()
            })
            if (cancelled.get()) return null
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O_MR1) {
                val width = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toLongOrNull()
                val height = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toLongOrNull()
                if (width == null || height == null || width !in 1..8192 || height !in 1..8192 ||
                    width * height > 9_000_000) return null
            }
            // Android applies stream rotation when producing the bitmap.
            frame = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                retriever.getScaledFrameAtTime(0, MediaMetadataRetriever.OPTION_CLOSEST_SYNC, 480, 480)
            } else {
                retriever.getFrameAtTime(0, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
            }
            val bitmap = frame ?: return null
            if (cancelled.get()) return null
            val scale = minOf(1.0, 480.0 / maxOf(bitmap.width, bitmap.height))
            thumbnail = if (scale < 1.0) {
                Bitmap.createScaledBitmap(
                    bitmap, (bitmap.width * scale).roundToInt().coerceAtLeast(1),
                    (bitmap.height * scale).roundToInt().coerceAtLeast(1), true,
                )
            } else bitmap
            val output = ByteArrayOutputStream()
            if (!thumbnail.compress(Bitmap.CompressFormat.JPEG, 82, output)) return null
            return output.toByteArray().takeIf { it.isNotEmpty() && it.size <= 512 * 1024 }
        } catch (_: Exception) {
            return null
        } catch (_: OutOfMemoryError) {
            return null
        } finally {
            if (thumbnail !== frame) thumbnail?.recycle()
            frame?.recycle()
            source.close()
            try { retriever?.release() } catch (_: Exception) { }
        }
    }

    fun dispose() {
        disposed = true
        pending.toList().forEach { complete(it, null) }
        worker.shutdownNow()
    }

    private class Request(val result: MethodChannel.Result) {
        val cancelled = AtomicBoolean(false)
        lateinit var timeout: Runnable
        lateinit var task: Runnable
    }
}
