import Foundation
import DesktopCore

// The harness never links MacKeychain.swift. Every scenario supplies a key
// provider; invoking the production default would fail without reading a key.
enum MacKeychain {
    static func load() throws -> String? { throw FixtureFailure.unexpectedKeychain }
}
enum FixtureFailure: Error { case unexpectedKeychain, invalidRequest }

private final class CloudFixture: URLProtocol, @unchecked Sendable {
    enum Failure { case service, invalidResponse }
    private static let lock = NSLock()
    private static var firstText = ""
    private static var failure: Failure?
    private static var batches: [[String]] = []
    static func configure(first: String, failure: Failure?) {
        lock.lock(); defer { lock.unlock() }
        firstText = first; self.failure = failure; batches = []
    }
    static func recover() { lock.lock(); failure = nil; lock.unlock() }
    static var requested: [[String]] { lock.lock(); defer { lock.unlock() }; return batches }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            var body = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    body.append(contentsOf: buffer.prefix(count))
                }
            }
            guard request.url == SiliconFlowClient.endpoint,
                  let payload = try JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let messages = payload["messages"] as? [[String: String]],
                  let encoded = messages.last?["content"]?.data(using: .utf8),
                  let input = try JSONSerialization.jsonObject(with: encoded) as? [String: Any],
                  let items = input["items"] as? [[String: Any]],
                  items.allSatisfy({ $0["text"] is String && $0["id"] is Int })
            else { throw FixtureFailure.invalidRequest }
            let texts = items.map { $0["text"] as! String }
            Self.lock.lock()
            Self.batches.append(texts)
            let failure = texts == [Self.firstText] ? nil : Self.failure
            Self.lock.unlock()
            let status = failure == .service ? 503 : 200
            let data: Data
            if failure == .invalidResponse { data = Data("{\"unexpected\":true}".utf8) }
            else {
                let translated = try JSONSerialization.data(withJSONObject: ["translations": items.map {
                    ["id": $0["id"]!, "text": "Translation of " + ($0["text"] as! String)]
                }])
                data = try JSONSerialization.data(withJSONObject: ["choices": [[
                    "finish_reason": "stop", "message": ["role": "assistant", "content": String(decoding: translated, as: UTF8.self)]
                ]]])
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@main struct CloudTranslationChecks {
    @MainActor static var failures: [String] = []
    @MainActor static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { failures.append(message); print("FAIL:", message) }
    }
    @MainActor static func makeTranslator(keyProvider: @escaping @MainActor () throws -> String? = { "fixture-only" }) -> MacTranslator {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CloudFixture.self]
        config.urlCache = nil
        return MacTranslator(learnedURL: nil,
            cloud: SiliconFlowClient(session: URLSession(configuration: config)), keyProvider: keyProvider)
    }
    @MainActor private static func scenario(failure: CloudFixture.Failure, mixed: Bool = false) async {
        let texts = mixed ? ["你好", "hello"] : ["这真是让你难过呀", "这种", "褶皱", "综合征", "这"]
        CloudFixture.configure(first: texts[0], failure: failure)
        var settings = DesktopSettings(); settings.provider = .siliconFlow; settings.cloudConsent = true
        let translator = makeTranslator()
        var callbacks: [String: String] = [:]
        var progress: [SiliconFlowProgress] = []
        var caught: CloudTranslationError?
        do {
            #if LEGACY_TRANSLATOR
            _ = try await translator.translate(texts, settings: settings) { callbacks[$0] = $1 }
            #else
            _ = try await translator.translate(texts, settings: settings,
                onProgress: { progress.append($0) }, onTranslation: { callbacks[$0] = $1 })
            #endif
        } catch { caught = error as? CloudTranslationError }
        let expectedError: CloudTranslationError = failure == .service ? .service(503) : .invalidResponse
        let label = "\(mixed ? "mixed-language" : "same-language") \(failure)"
        check(caught == expectedError, "\(label): later failure must throw even after first callback")
        check(callbacks == [texts[0]: "Translation of " + texts[0]], "\(label): preserve only successful first callback")
        check(translator.cached(texts, settings: settings) == callbacks, "\(label): preserve first cache after error")
        let requestsBeforeRetry = CloudFixture.requested
        check(requestsBeforeRetry.filter { $0.contains(texts[0]) }.count == 1, "\(label): first success requested once")
        check(requestsBeforeRetry.count == (failure == .service ? 3 : 2), "\(label): expected bounded HTTP attempt count")
        #if !LEGACY_TRANSLATOR
        check(progress.contains(.requesting(attempt: 1)), "\(label): progress must reach caller")
        if failure == .service {
            check(progress.contains { if case .retrying(_, _, .service(503)) = $0 { return true }; return false },
                  "\(label): retry progress must reach caller")
        }
        #endif
        CloudFixture.recover()
        var retryCallbacks: [String: String] = [:]
        do {
            let result = try await translator.translate(texts, settings: settings) { retryCallbacks[$0] = $1 }
            check(result.count == texts.count && retryCallbacks == result, "\(label): manual retry completes all candidates")
            check(result[texts[0]] == callbacks[texts[0]], "\(label): retry keeps original successful value")
        } catch { check(false, "\(label): recovery unexpectedly threw") }
        let retried = CloudFixture.requested.dropFirst(requestsBeforeRetry.count)
        check(!retried.isEmpty && retried.allSatisfy { !$0.contains(texts[0]) }, "\(label): retry must not send cached first candidate again")
        print("CHECKED:", label, "initial requests", requestsBeforeRetry.count, "retry requests", retried.count)
    }
    @MainActor static func main() async {
        await scenario(failure: .service)
        await scenario(failure: .invalidResponse)
        await scenario(failure: .service, mixed: true)
        CloudFixture.configure(first: "你好", failure: nil)
        var settings = DesktopSettings(); settings.provider = .siliconFlow; settings.cloudConsent = true
        let missing = makeTranslator(keyProvider: { nil })
        do {
            _ = try await missing.translate(["你好"], settings: settings)
            check(false, "Missing key should throw")
        } catch { check(error as? CloudTranslationError == .missingKey, "Missing key should produce a safe key error") }
        check(CloudFixture.requested.isEmpty, "Missing key must not issue a request")
        if failures.isEmpty { print("PASS: MacTranslator partial failures, callbacks, cache, retry progress, missing-only manual retry, and no-key isolation") }
        else { print("FAILED:", failures.count, "MacTranslator partial-error assertions"); exit(1) }
    }
}
