// From flutter_app/android, with Kotlin CLI and JDK 17 installed:
// kotlinc app/src/main/kotlin/com/betshuva/app/HttpVideoSource.kt \
//   tests/HttpVideoSourceCheck.kt -include-runtime -d /tmp/video-http-check.jar
// java --add-modules jdk.httpserver -jar /tmp/video-http-check.jar
package com.betshuva.app

import com.sun.net.httpserver.HttpServer
import java.net.InetSocketAddress
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

fun main() {
    val data = ByteArray(700_001) { (it % 251).toByte() }
    val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
    val executor = Executors.newCachedThreadPool()
    server.executor = executor
    server.createContext("/range") { exchange ->
        val range = Regex("bytes=(\\d+)-(\\d+)").matchEntire(exchange.requestHeaders.getFirst("Range"))!!
        val start = range.groupValues[1].toInt()
        val end = minOf(range.groupValues[2].toInt(), data.lastIndex)
        if (start >= data.size) {
            exchange.responseHeaders.set("Content-Range", "bytes */${data.size}")
            exchange.sendResponseHeaders(416, -1)
        } else {
            exchange.responseHeaders.set("Content-Range", "bytes $start-$end/${data.size}")
            exchange.sendResponseHeaders(206, (end - start + 1).toLong())
            exchange.responseBody.write(data, start, end - start + 1)
        }
        exchange.close()
    }
    server.createContext("/full") { exchange ->
        exchange.sendResponseHeaders(200, data.size.toLong())
        exchange.responseBody.write(data)
        exchange.close()
    }
    server.createContext("/chunked") { exchange ->
        exchange.sendResponseHeaders(200, 0)
        exchange.responseBody.write(data)
        exchange.close()
    }
    server.createContext("/bad") { exchange ->
        exchange.responseHeaders.set("Content-Range", "bytes 1-9/10")
        exchange.sendResponseHeaders(206, 9)
        exchange.responseBody.write(ByteArray(9))
        exchange.close()
    }
    server.createContext("/short") { exchange ->
        exchange.responseHeaders.set("Content-Range", "bytes 0-999/1000")
        exchange.sendResponseHeaders(206, 10)
        exchange.responseBody.write(ByteArray(10))
        exchange.close()
    }
    server.createContext("/large") { exchange ->
        exchange.sendResponseHeaders(200, 9_000_000)
        exchange.close()
    }
    server.createContext("/redirect") { exchange ->
        exchange.responseHeaders.set("Location", "/range")
        exchange.sendResponseHeaders(302, -1)
        exchange.close()
    }
    server.createContext("/unsafe") { exchange ->
        exchange.responseHeaders.set("Location", "ftp://example.test/file")
        exchange.sendResponseHeaders(302, -1)
        exchange.close()
    }
    server.createContext("/slow") { exchange ->
        Thread.sleep(3500)
        exchange.sendResponseHeaders(200, -1)
        exchange.close()
    }
    server.createContext("/encoded") { exchange ->
        exchange.responseHeaders.set("Content-Encoding", "gzip")
        exchange.sendResponseHeaders(200, -1)
        exchange.close()
    }
    server.start()
    try {
        fun source(path: String): HttpVideoSource = HttpVideoSource(
            HttpVideoSource.validatedUri("http://127.0.0.1:${server.address.port}$path")!!,
            AtomicBoolean(false),
        )
        for (path in listOf("/range", "/full", "/chunked", "/redirect")) {
            source(path).use { input ->
                check(input.size() == data.size.toLong())
                val buffer = ByteArray(400_000)
                for (position in listOf(0, 262_142, 524_288, 700_000, 12)) {
                    val count = input.readAt(position.toLong(), buffer, 3, buffer.size - 3)
                    check(count > 0)
                    check(buffer.sliceArray(3 until 3 + count).contentEquals(data.sliceArray(position until position + count)))
                }
                check(input.readAt(data.size.toLong(), buffer, 0, 1) == -1)
                check(input.readAt(0, buffer, buffer.size, 0) == 0)
            }
            println("PASS $path random access, zero read, EOF")
        }
        for (path in listOf("/bad", "/short", "/large", "/unsafe", "/encoded", "/slow")) {
            var failed = false
            source(path).use { input ->
                try { input.size() } catch (_: java.io.IOException) { failed = true }
            }
            check(failed) { "$path should fail" }
            println("PASS $path rejected")
        }
        source("/range").use { input ->
            check(input.readAt(800_000, ByteArray(2), 0, 2) == -1)
            check(input.size() == data.size.toLong())
            input.close()
            check(runCatching { input.readAt(0, ByteArray(1), 0, 1) }.isFailure)
        }
        val invalid = listOf("", "file:///tmp/a", "https:///foo", "https://u:p@example.test/a", "https://example.test:0/a", "https://example.test:65536/a", "https://example.test:/a", "https://example.test:abc/a", "https://example.test:-2/a")
        check(invalid.all { HttpVideoSource.validatedUri(it) == null })
        check(HttpVideoSource.validatedUri("HTTPS://example.test:443/a?x=1") != null)
        check(HttpVideoSource.validatedUri("https://[::1]:443/a") != null)
        println("PASS initial EOF, cancellation, strict URI validation")
    } finally {
        server.stop(0)
        executor.shutdownNow()
    }
}
