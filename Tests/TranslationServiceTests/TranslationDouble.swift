// Native macOS unit-test double. This replaces only Apple's Translation API;
// the harness compiles and exercises the production TranslationService source.
import Foundation

public enum TranslationStrategy { case lowLatency }

@MainActor
public final class LanguageAvailability {
    public enum Status { case installed, supported, unsupported }
    public nonisolated init(preferredStrategy: TranslationStrategy? = nil) {}
    public func status(from: Locale.Language, to: Locale.Language) async -> Status { .installed }
}

@MainActor
public final class TranslationSession {
    public struct Request: Sendable {
        public let sourceText: String
        public let clientIdentifier: String?
        public init(sourceText: String, clientIdentifier: String?) {
            self.sourceText = sourceText
            self.clientIdentifier = clientIdentifier
        }
    }

    public struct Response: Sendable {
        public let clientIdentifier: String?
        public let targetText: String
        public init(clientIdentifier: String?, targetText: String) {
            self.clientIdentifier = clientIdentifier
            self.targetText = targetText
        }
    }

    public typealias Stream = AsyncThrowingStream<Response, any Error>
    public static var onBatch: (([Request], Stream.Continuation) -> Void)?
    public static var batchCount = 0
    private var continuation: Stream.Continuation?

    public init(installedSource: Locale.Language, target: Locale.Language,
                preferredStrategy: TranslationStrategy? = nil) {}

    public func translate(batch: [Request]) -> Stream {
        let (stream, continuation) = Stream.makeStream()
        self.continuation = continuation
        Self.batchCount += 1
        Self.onBatch?(batch, continuation)
        return stream
    }

    public func cancel() { continuation?.finish(throwing: CancellationError()) }
}
