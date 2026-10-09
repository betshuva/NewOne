// Compile the pure queue and this file with kotlinc; run the resulting JAR.
import com.betshuva.app.IncomingShareEnvelope
import com.betshuva.app.IncomingShareFile
import com.betshuva.app.IncomingShareQueue
import com.betshuva.app.IncomingShareStore

private const val alice = "11111111-1111-4111-8111-111111111111"
private const val bob = "22222222-2222-4222-8222-222222222222"

private class MemoryStore : IncomingShareStore {
    var saved = emptyList<IncomingShareEnvelope>()
    var fail = false
    override fun load() = saved.toList()
    override fun save(envelopes: List<IncomingShareEnvelope>) {
        if (fail) error("Disk unavailable")
        saved = envelopes.toList()
    }
}

fun main() {
    var assertions = 0
    fun verify(ok: Boolean) { check(ok); assertions++ }
    var now = 1_000L
    val store = MemoryStore()
    val queue = IncomingShareQueue(store, { now }, lifetimeMs = 100)
    fun envelope(id: String, account: String? = null) = IncomingShareEnvelope(id, now,
        accountId = account,
        files = listOf(IncomingShareFile("/cache/$id.jpg", "photo.jpg", "image/jpeg")),
        text = "https://example.test", subject = "Shared page")
    verify(queue.enqueue(envelope("one")))
    verify(!queue.enqueue(envelope("one")))
    verify(queue.take("") == null && queue.take("alice") == null)
    val taken = queue.take(alice)!!
    verify(taken.accountId == alice && !taken.leaseId.isNullOrBlank())
    verify(store.saved.single().accountId == alice)
    verify(queue.take(bob) == null && queue.take(alice) == null)
    verify(queue.finish("one", bob, "completed", taken.leaseId!!).isEmpty())
    verify(queue.finish("missing", alice, "completed", taken.leaseId!!).isEmpty())
    verify(queue.finish("one", alice, "retry", taken.leaseId!!, setOf("/private/secret")).isEmpty())
    verify(queue.paths() == setOf("/cache/one.jpg") && queue.count(alice) == 1)
    verify(queue.take(alice) == null) // No immediate retry loop after failure.
    verify(queue.retry(bob) == 0 && queue.retry(alice) == 1)
    val second = queue.take(alice)!!
    verify(second.leaseId != taken.leaseId)
    verify(queue.finish("one", alice, "completed", taken.leaseId!!).isEmpty())
    val acceptedFiles = queue.finish("one", alice, "retry", second.leaseId!!,
        setOf("/cache/one.jpg"))
    verify(acceptedFiles == listOf("/cache/one.jpg"))
    verify(store.saved.single().files.isEmpty() && store.saved.single().text != null)
    // Relaunch replays only the remainder, and never to a different account.
    val restarted = IncomingShareQueue(store, { now }, lifetimeMs = 100)
    verify(restarted.take(bob) == null)
    val remainder = restarted.take(alice)!!
    verify(remainder.files.isEmpty() && remainder.text == "https://example.test")
    verify(restarted.finish("one", alice, "retry", remainder.leaseId!!, clearText = true).isEmpty())
    verify(store.saved.isEmpty())
    verify(restarted.enqueue(envelope("direct", bob)))
    verify(restarted.take(alice) == null)
    val direct = restarted.take(bob)!!
    verify(IncomingShareQueue.accountFromShortcut("$bob:recipient") == bob)
    verify(IncomingShareQueue.accountFromShortcut("alice:recipient") == null)
    now += 200
    verify(restarted.prune().isEmpty()) // TTL cannot delete an active upload.
    restarted.resetInflight(bob)
    val reclaimed = restarted.take(bob)!!
    verify(reclaimed.leaseId != direct.leaseId)
    verify(restarted.finish("direct", bob, "completed", direct.leaseId!!).isEmpty())
    verify(restarted.finish("direct", bob, "retry", reclaimed.leaseId!!).isEmpty())
    verify(restarted.prune() == listOf("/cache/direct.jpg"))
    verify(store.saved.isEmpty())
    repeat(10) { verify(restarted.enqueue(envelope("batch$it"))) }
    verify(!restarted.enqueue(envelope("overflow")))
    val first = restarted.take(alice)!!
    verify(restarted.finish(first.id, alice, "cancelled", first.leaseId!!) == listOf("/cache/${first.id}.jpg"))
    verify(restarted.enqueue(envelope("replacement")))
    val before = store.saved.toList()
    store.fail = true
    try { restarted.take(alice); error("Expected persistence failure") } catch (e: IllegalStateException) {
        verify(e.message == "Disk unavailable")
    }
    verify(store.saved == before)
    store.fail = false
    val afterFailure = restarted.take(alice)!!
    verify(afterFailure.accountId == alice)
    verify(restarted.finish(afterFailure.id, alice, "invalid", afterFailure.leaseId!!).isEmpty())
    val captureStore = MemoryStore()
    val captures = IncomingShareQueue(captureStore, { now })
    verify(captures.enqueue(IncomingShareEnvelope("capture", now, action = "capture")))
    val capture = captures.take(alice)!!
    val picture = IncomingShareFile("/cache/captured.jpg", "captured.jpg", "image/jpeg")
    verify(!captures.attachCapture(capture.id, bob, capture.leaseId!!, picture))
    verify(!captures.attachCapture(capture.id, alice, "stale-lease", picture))
    verify(captures.attachCapture(capture.id, alice, capture.leaseId!!, picture))
    verify(!captures.attachCapture(capture.id, alice, capture.leaseId!!, picture))
    verify(captureStore.saved.single().action == null && captureStore.saved.single().files == listOf(picture))
    verify(captures.finish(capture.id, alice, "retry", capture.leaseId!!).isEmpty())
    val captureRestarted = IncomingShareQueue(captureStore, { now })
    val persistedCapture = captureRestarted.take(alice)!!
    verify(persistedCapture.action == null && persistedCapture.files == listOf(picture))
    verify(captureRestarted.finish(persistedCapture.id, alice, "completed", persistedCapture.leaseId!!) == listOf(picture.path))
    verify(captureStore.saved.isEmpty())
    val deliveryStore = MemoryStore()
    val deliveries = IncomingShareQueue(deliveryStore, { now })
    verify(deliveries.enqueue(envelope("partial")))
    val partial = deliveries.take(alice)!!
    val contentKey = "a".repeat(64)
    verify(deliveries.finish(partial.id, alice, "retry", partial.leaseId!!,
        deliveredTargets = mapOf(contentKey to listOf("user:$bob"))).isEmpty())
    verify(deliveryStore.saved.single().deliveredTargets == mapOf(contentKey to listOf("user:$bob")))
    val deliveryRestarted = IncomingShareQueue(deliveryStore, { now })
    val retryPartial = deliveryRestarted.take(alice)!!
    verify(retryPartial.deliveredTargets[contentKey] == listOf("user:$bob"))
    val beforeInvalid = deliveryStore.saved.toList()
    try {
        deliveryRestarted.finish(retryPartial.id, alice, "retry", retryPartial.leaseId!!,
            deliveredTargets = mapOf("wrong-key" to listOf("user:$bob")))
        error("Expected invalid delivery key")
    } catch (_: IllegalArgumentException) { verify(deliveryStore.saved == beforeInvalid) }
    try {
        deliveryRestarted.finish(retryPartial.id, alice, "retry", retryPartial.leaseId!!,
            deliveredTargets = mapOf(contentKey to listOf("user:wrong-target")))
        error("Expected invalid target")
    } catch (_: IllegalArgumentException) { verify(deliveryStore.saved == beforeInvalid) }
    try {
        deliveryRestarted.finish(retryPartial.id, alice, "retry", retryPartial.leaseId!!,
            deliveredTargets = (0..101).associate { it.toString(16).padStart(64, '0') to listOf("user:$bob") })
        error("Expected bounded content count")
    } catch (_: IllegalArgumentException) { verify(deliveryStore.saved == beforeInvalid) }
    verify(deliveryRestarted.finish(retryPartial.id, alice, "retry", retryPartial.leaseId!!,
        deliveredTargets = mapOf(contentKey to listOf("user:$bob", "group:$bob"))).isEmpty())
    verify(deliveryStore.saved.single().deliveredTargets[contentKey] == listOf("user:$bob", "group:$bob"))
    verify(deliveryRestarted.paths() == setOf("/cache/partial.jpg"))
    val calendarStore = MemoryStore()
    val calendars = IncomingShareQueue(calendarStore, { now })
    val event = mapOf<String, Any?>("title" to "Shared meeting", "beginTime" to 1000L)
    verify(calendars.enqueue(envelope("calendar-and-text").copy(calendar = event)))
    val withText = calendars.take(alice)!!
    verify(calendars.finish(withText.id, alice, "retry", withText.leaseId!!, clearText = true).isEmpty())
    verify(calendarStore.saved.single().calendar == event)
    verify(calendarStore.saved.single().text == null && calendarStore.saved.single().subject == null)
    verify(calendarStore.saved.single().files == withText.files)
    val calendarRestarted = IncomingShareQueue(calendarStore, { now })
    val eventOnly = calendarRestarted.take(alice)!!
    verify(eventOnly.calendar == event && eventOnly.text == null)
    verify(calendarRestarted.finish(eventOnly.id, alice, "retry", eventOnly.leaseId!!, clearCalendar = true).isEmpty())
    verify(calendarStore.saved.single().calendar == null && calendarStore.saved.single().files == withText.files)
    val independentStore = MemoryStore()
    val independent = IncomingShareQueue(independentStore, { now })
    verify(independent.enqueue(envelope("calendar-keeps-text").copy(calendar = event)))
    val withCalendar = independent.take(alice)!!
    verify(independent.finish(withCalendar.id, alice, "retry", withCalendar.leaseId!!, clearCalendar = true).isEmpty())
    verify(independentStore.saved.single().calendar == null && independentStore.saved.single().text == withCalendar.text)
    verify(independentStore.saved.single().subject == withCalendar.subject && independentStore.saved.single().files == withCalendar.files)
    val prepareStore = MemoryStore()
    val preparation = IncomingShareQueue(prepareStore, { now })
    val preparedEntry = envelope("prepared").copy(files = listOf(
        IncomingShareFile("/cache/contact.vcf", "contact.vcf", "text/vcard"),
        IncomingShareFile("/cache/photo.jpg", "photo.jpg", "image/jpeg"),
        IncomingShareFile("/cache/event.ics", "event.ics", "text/calendar"),
    ), calendar = event)
    verify(preparation.enqueue(preparedEntry))
    val preparing = preparation.take(alice)!!
    val approved = listOf(
        mapOf<String, String?>("text" to "Edited web link", "sourcePath" to null),
        mapOf("text" to "Contact fields approved by the user", "sourcePath" to "/cache/contact.vcf"),
        mapOf("localPath" to "/cache/photo.jpg", "sourcePath" to "/cache/photo.jpg", "fileName" to "photo.jpg", "mimeType" to "image/jpeg", "fileType" to "image"),
    )
    verify(!preparation.prepare(preparing.id, bob, preparing.leaseId!!, approved))
    verify(!preparation.prepare(preparing.id, alice, "stale", approved))
    verify(preparation.prepare(preparing.id, alice, preparing.leaseId!!, approved))
    verify(prepareStore.saved.single().preparedMessages == approved)
    verify(preparation.prepare(preparing.id, alice, preparing.leaseId!!, approved))
    verify(!preparation.prepare(preparing.id, alice, preparing.leaseId!!,
        approved.mapIndexed { index, message -> if (index == 1) message + ("text" to "Changed private fields") else message }))
    val preparedBeforeInvalid = prepareStore.saved.toList()
    for (bad in listOf(
        listOf(mapOf("localPath" to "/private/secret.jpg")),
        listOf(mapOf("text" to "Contact", "sourcePath" to "/private/contacts.vcf")),
        listOf(mapOf("text" to "text", "unapprovedKey" to "value")),
        listOf(mapOf("text" to "x".repeat(20_001))),
        listOf(mapOf("text" to "text", "fileName" to "x".repeat(256))),
        listOf(mapOf("text" to "text", "mimeType" to "x".repeat(129))),
        listOf(mapOf("text" to "text", "fileType" to "arbitrary")),
        List(102) { mapOf("text" to "text") },
        List(101) { mapOf("text" to "א".repeat(20_000)) },
    )) {
        try {
            preparation.prepare(preparing.id, alice, preparing.leaseId!!, bad)
            error("Expected bounded, owned preparation")
        } catch (_: IllegalArgumentException) { verify(prepareStore.saved == preparedBeforeInvalid) }
    }
    verify(preparation.finish(preparing.id, alice, "retry", preparing.leaseId!!,
        setOf("/cache/photo.jpg"), clearText = true).isNotEmpty())
    verify(prepareStore.saved.single().preparedMessages == listOf(approved[1]))
    verify(prepareStore.saved.single().calendar == event)
    verify(prepareStore.saved.single().files.map { it.path } == listOf("/cache/contact.vcf", "/cache/event.ics"))
    val preparedRestarted = IncomingShareQueue(prepareStore, { now })
    val approvedRetry = preparedRestarted.take(alice)!!
    verify(approvedRetry.preparedMessages == listOf(approved[1]))
    verify(preparedRestarted.prepare(approvedRetry.id, alice, approvedRetry.leaseId!!, listOf(approved[1])))
    verify(preparedRestarted.finish(approvedRetry.id, alice, "retry", approvedRetry.leaseId!!,
        setOf("/cache/contact.vcf")).isNotEmpty())
    verify(prepareStore.saved.single().preparedMessages == null && prepareStore.saved.single().calendar == event)
    verify(prepareStore.saved.single().files.single().path == "/cache/event.ics")
    val syntheticStore = MemoryStore()
    val synthetic = IncomingShareQueue(syntheticStore, { now })
    verify(synthetic.enqueue(IncomingShareEnvelope("metadata-card", now, calendar = event)))
    val metadataCard = synthetic.take(alice)!!
    val card = listOf(mapOf<String, String?>("text" to "Prepared event card", "sourcePath" to null))
    verify(synthetic.prepare(metadataCard.id, alice, metadataCard.leaseId!!, card))
    verify(synthetic.finish(metadataCard.id, alice, "retry", metadataCard.leaseId!!, clearCalendar = true).isEmpty())
    verify(syntheticStore.saved.single().calendar == null && syntheticStore.saved.single().preparedMessages == card)
    println("IncomingShareQueue: $assertions ownership, lease, retry, persistence, bounds and expiry checks passed")
}
