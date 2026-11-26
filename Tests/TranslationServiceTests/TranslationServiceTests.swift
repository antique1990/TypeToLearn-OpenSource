import Foundation
import Translation

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

private enum StreamFailure: Error { case interrupted }

@MainActor
private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure(description: message) }
}

// Explicit stream events synchronize assertions with production callbacks;
// there are no timing sleeps or platform translation models in these tests.
@MainActor
private final class Batch {
    let service = TranslationService()
    var requests: [TranslationSession.Request] = []
    var continuation: TranslationSession.Stream.Continuation?
    var received: [String: String] = [:]
    var completed = false
    let started = AsyncStream<Void>.makeStream()
    let delivered = AsyncStream<Void>.makeStream()

    init() {
        TranslationSession.onBatch = { [weak self] requests, continuation in
            guard let self else { return }
            self.requests = requests
            self.continuation = continuation
            self.started.continuation.yield(())
        }
    }

    func start(_ texts: [String]) -> Task<[String: String], any Error> {
        Task { @MainActor in
            defer { self.completed = true }
            return try await self.service.translate(texts, sourceID: "zh-Hans", targetID: "en") { text, value in
                self.received[text] = value
                self.delivered.continuation.yield(())
            }
        }
    }

    func send(_ text: String?, _ value: String) {
        continuation?.yield(.init(clientIdentifier: text, targetText: value))
    }
}

@main
private struct TranslationServiceTests {
    @MainActor
    static func main() async throws {
        try await streamsBeforeBatchCompletes()
        try await retainsPartialResultsOnFailure()
        try await cachedResultsAvoidNewBatch()
        try await cancellationPreservesCacheUntilMemoryRelease()
        try await cancellationStopsCallbacks()
        try await preCancelledTaskDoesNotStartBatch()
        try await failureWithoutResultsStillThrows()
        print("PASS: 7 TranslationService streaming tests (native macOS, controlled Translation API double)")
    }

    @MainActor
    static func streamsBeforeBatchCompletes() async throws {
        let batch = Batch()
        var starts = batch.started.stream.makeAsyncIterator()
        var deliveries = batch.delivered.stream.makeAsyncIterator()
        let task = batch.start(["你好", "世界", "你好"])
        await starts.next()
        try expect(batch.requests.map(\.sourceText) == ["你好", "世界"], "Requests must be deduplicated")
        // Invalid responses must not appear in the callback or the final output.
        batch.send(nil, "missing identifier")
        batch.send("其他", "unexpected identifier")
        batch.send("世界", "")
        batch.send("世界", "world")
        await deliveries.next()
        try expect(batch.received == ["世界": "world"], "Only the valid response should be delivered")
        try expect(!batch.completed, "First translation must be delivered before the batch completes")
        try expect(batch.service.cached(["世界"], sourceID: "zh-Hans", targetID: "en") == ["世界": "world"],
                   "Each delivered translation must already be cached")
        batch.send("你好", "hello")
        await deliveries.next()
        try expect(!batch.completed, "All results may arrive while the batch is still open")
        batch.continuation?.finish()
        let result = try await task.value
        try expect(result == ["你好": "hello", "世界": "world"], "Final result must retain all delivered translations")
    }

    @MainActor
    static func retainsPartialResultsOnFailure() async throws {
        let batch = Batch()
        var starts = batch.started.stream.makeAsyncIterator()
        var deliveries = batch.delivered.stream.makeAsyncIterator()
        let task = batch.start(["你好", "世界"])
        await starts.next()
        batch.send("你好", "hello")
        await deliveries.next()
        batch.continuation?.finish(throwing: StreamFailure.interrupted)
        let result = try await task.value
        try expect(result == ["你好": "hello"], "A later stream error must preserve completed results")
        try expect(batch.received == result, "Partial results should already be visible")
    }

    @MainActor
    static func cachedResultsAvoidNewBatch() async throws {
        let batch = Batch()
        var starts = batch.started.stream.makeAsyncIterator()
        var deliveries = batch.delivered.stream.makeAsyncIterator()
        let task = batch.start(["陈佳文"])
        await starts.next()
        batch.send("陈佳文", "Chen Jiaben")
        await deliveries.next()
        try expect(batch.received == ["陈佳文": "Chen Jiawen"], "Callbacks must receive the corrected translation")
        batch.continuation?.finish()
        _ = try await task.value
        let count = TranslationSession.batchCount
        // Existing callers can omit the optional callback and use the dictionary.
        let cached = try await batch.service.translate(["陈佳文"], sourceID: "zh-Hans", targetID: "en")
        try expect(cached == ["陈佳文": "Chen Jiawen"], "A cache hit must keep corrected text")
        try expect(TranslationSession.batchCount == count, "A cache hit must not create a translation batch")
        try expect(batch.service.cached(["陈佳文"], sourceID: "zh-Hans", targetID: "fr").isEmpty,
                   "Cache entries must remain scoped to the language pair")
    }

    @MainActor
    static func cancellationStopsCallbacks() async throws {
        let batch = Batch()
        var starts = batch.started.stream.makeAsyncIterator()
        var deliveries = batch.delivered.stream.makeAsyncIterator()
        let task = batch.start(["你好", "世界"])
        await starts.next()
        batch.send("你好", "hello")
        await deliveries.next()
        task.cancel()
        // A framework that races with cancellation may enqueue another result.
        batch.send("世界", "world")
        batch.continuation?.finish()
        do {
            _ = try await task.value
            throw TestFailure(description: "A cancelled request must throw CancellationError")
        } catch is CancellationError {}
        try expect(batch.received == ["你好": "hello"], "Cancellation must suppress later callbacks")
        try expect(batch.service.cached(["世界"], sourceID: "zh-Hans", targetID: "en").isEmpty,
                   "A result received after cancellation must not be cached")
    }

    @MainActor
    static func cancellationPreservesCacheUntilMemoryRelease() async throws {
        let batch = Batch()
        var starts = batch.started.stream.makeAsyncIterator()
        var deliveries = batch.delivered.stream.makeAsyncIterator()
        let task = batch.start(["你好"])
        await starts.next()
        batch.send("你好", "hello")
        await deliveries.next()
        batch.continuation?.finish()
        _ = try await task.value
        batch.service.cancel()
        let count = TranslationSession.batchCount
        let cached = try await batch.service.translate(["你好"], sourceID: "zh-Hans", targetID: "en")
        try expect(cached == ["你好": "hello"], "Closing a session must retain recent translations")
        try expect(TranslationSession.batchCount == count, "Reopening with cached text must avoid system translation")
        batch.service.releaseResources()
        try expect(batch.service.cached(["你好"], sourceID: "zh-Hans", targetID: "en").isEmpty,
                   "Memory pressure must evict the retained cache")
        let fresh = batch.start(["你好"])
        await starts.next()
        try expect(TranslationSession.batchCount == count + 1, "Evicted translations must be requested again")
        batch.send("你好", "hello again")
        batch.continuation?.finish()
        let refreshed = try await fresh.value
        try expect(refreshed == ["你好": "hello again"], "Released resources must be usable again")
    }

    @MainActor
    static func preCancelledTaskDoesNotStartBatch() async throws {
        let batch = Batch()
        let count = TranslationSession.batchCount
        let task = batch.start(["你好"])
        task.cancel()
        do {
            _ = try await task.value
            throw TestFailure(description: "A pre-cancelled request must throw CancellationError")
        } catch is CancellationError {}
        try expect(TranslationSession.batchCount == count, "A pre-cancelled request must not start work")
        try expect(batch.received.isEmpty, "A pre-cancelled request must not publish a result")
    }

    @MainActor
    static func failureWithoutResultsStillThrows() async throws {
        let batch = Batch()
        var starts = batch.started.stream.makeAsyncIterator()
        let task = batch.start(["你好"])
        await starts.next()
        batch.continuation?.finish(throwing: StreamFailure.interrupted)
        do {
            _ = try await task.value
            throw TestFailure(description: "An error before any translation must propagate to the caller")
        } catch StreamFailure.interrupted {}
        try expect(batch.received.isEmpty, "An unsuccessful batch must not emit a callback")
    }
}
