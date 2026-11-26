import XCTest
import Foundation
@testable import DesktopCore

final class SiliconFlowRetryTests: XCTestCase {
    @MainActor
    func testTemporaryServerFailureRetriesOnceAndPublishesProgress() async throws {
        let fixture = makeClient([.http(503), .success])
        var events: [SiliconFlowProgress] = []
        let output = try await fixture.client.translate(["这真是让你难过呀"], source: "zh-Hans", target: "en", key: "fixture-key") {
            events.append($0)
        }
        XCTAssertEqual(output["这真是让你难过呀"], "This really makes you sad.")
        XCTAssertEqual(RetryFixture.count(fixture.id), 2)
        XCTAssertEqual(events, [.requesting(attempt: 1), .retrying(attempt: 2, delay: 0.75, reason: .service(503)), .requesting(attempt: 2)])
    }

    func testTemporaryNetworkFailureRecovers() async throws {
        let fixture = makeClient([.network(.networkConnectionLost), .success])
        let output = try await fixture.client.translate(["这真是让你难过呀"], source: "zh-Hans", target: "en", key: "fixture-key")
        XCTAssertFalse(output.isEmpty)
        XCTAssertEqual(RetryFixture.count(fixture.id), 2)
    }

    func testTimeoutRemainsDistinctAndNeverMakesAThirdRequest() async {
        let fixture = makeClient([.network(.timedOut), .network(.timedOut), .success])
        await expectFailure(.timeout, fixture: fixture)
        XCTAssertEqual(RetryFixture.count(fixture.id), 2)
    }

    func testServerErrorsNeverMakeAThirdRequest() async {
        let fixture = makeClient([.http(504), .http(502), .success])
        await expectFailure(.service(502), fixture: fixture)
        XCTAssertEqual(RetryFixture.count(fixture.id), 2)
    }

    func testHTTP408And429RetryOnce() async throws {
        for code in [408, 429] {
            let fixture = makeClient([.http(code), .success])
            let output = try await fixture.client.translate(["这真是让你难过呀"], source: "zh-Hans", target: "en", key: "fixture-key")
            XCTAssertFalse(output.isEmpty)
            XCTAssertEqual(RetryFixture.count(fixture.id), 2)
        }
    }

    func testPermanentErrorsAndInvalidJSONAreNotRetried() async {
        for (code, error) in [(400, CloudTranslationError.service(400)), (401, .invalidKey),
                              (403, .invalidKey), (402, .quota), (404, .modelUnavailable), (302, .service(302))] {
            let fixture = makeClient([.http(code), .success])
            await expectFailure(error, fixture: fixture)
            XCTAssertEqual(RetryFixture.count(fixture.id), 1)
        }
        let malformed = makeClient([.invalidJSON, .success])
        await expectFailure(.invalidResponse, fixture: malformed)
        XCTAssertEqual(RetryFixture.count(malformed.id), 1)
    }

    func testOfflineAndTLSFailuresAreNotRetried() async {
        for error in [URLError.Code.notConnectedToInternet, .serverCertificateUntrusted] {
            let fixture = makeClient([.network(error), .success])
            await expectFailure(.network, fixture: fixture)
            XCTAssertEqual(RetryFixture.count(fixture.id), 1)
        }
    }

    func testLongRetryAfterDoesNotRetryTooEarlyOrBlockTheCandidate() async {
        let fixture = makeClient([.http(429, retryAfter: "120"), .success])
        await expectFailure(.rateLimited, fixture: fixture)
        XCTAssertEqual(RetryFixture.count(fixture.id), 1)
    }

    func testRetryAfterSecondsAndDateRespectBoundedServerDelay() {
        let now = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(SiliconFlowClient.retryDelay("2", now: now), 2)
        XCTAssertEqual(SiliconFlowClient.retryDelay("Thu, 01 Jan 1970 00:00:03 GMT", now: now), 3)
        XCTAssertEqual(SiliconFlowClient.retryDelay("Thu, 01 Jan 1970 00:00:00 GMT", now: now), 0.75)
        XCTAssertEqual(SiliconFlowClient.retryDelay("garbage", now: now), 0.75)
        XCTAssertNil(SiliconFlowClient.retryDelay("Thu, 01 Jan 1970 00:02:00 GMT", now: now))
        XCTAssertNil(SiliconFlowClient.retryDelay("6", now: now))
    }

    @MainActor
    func testCancellationDuringBackoffPreventsSecondRequest() async {
        let fixture = makeClient([.http(429, retryAfter: "5"), .success])
        let started = AsyncStream<Void>.makeStream()
        var events: [SiliconFlowProgress] = []
        let task = Task {
            try await fixture.client.translate(["这真是让你难过呀"], source: "zh-Hans", target: "en", key: "fixture-key") { event in
                events.append(event)
                if case .retrying = event { started.continuation.yield(()) }
            }
        }
        var iterator = started.stream.makeAsyncIterator()
        await iterator.next()
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation must propagate") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(RetryFixture.count(fixture.id), 1)
        XCTAssertEqual(events, [.requesting(attempt: 1), .retrying(attempt: 2, delay: 5, reason: .rateLimited)])
    }

    func testCancellationDuringRequestStopsWithoutRetry() async {
        let started = AsyncStream<Void>.makeStream()
        let fixture = makeClient([.stall, .success], onRequest: { started.continuation.yield(()) })
        let task = Task {
            try await fixture.client.translate(["这真是让你难过呀"], source: "zh-Hans", target: "en", key: "fixture-key")
        }
        var iterator = started.stream.makeAsyncIterator()
        await iterator.next()
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation must propagate") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(RetryFixture.count(fixture.id), 1)
    }

    private typealias Fixture = (client: SiliconFlowClient, id: String)
    private func makeClient(_ replies: [RetryFixture.Reply], onRequest: (@Sendable () -> Void)? = nil) -> Fixture {
        let id = RetryFixture.add(replies, onRequest: onRequest)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RetryFixture.self]
        config.httpAdditionalHeaders = ["X-Fixture-ID": id]
        return (SiliconFlowClient(session: URLSession(configuration: config)), id)
    }
    private func expectFailure(_ failure: CloudTranslationError, fixture: Fixture) async {
        do {
            _ = try await fixture.client.translate(["这真是让你难过呀"], source: "zh-Hans", target: "en", key: "fixture-key")
            XCTFail("Expected bounded failure")
        } catch { XCTAssertEqual(error as? CloudTranslationError, failure) }
    }
}

private final class RetryFixture: URLProtocol, @unchecked Sendable {
    enum Reply { case http(Int, retryAfter: String? = nil); case network(URLError.Code); case success; case invalidJSON; case stall }
    private struct Scenario {
        var replies: [Reply]
        var requests = 0
        let onRequest: (@Sendable () -> Void)?
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var scenarios: [String: Scenario] = [:]
    static func count(_ id: String) -> Int { lock.withLock { scenarios[id]?.requests ?? 0 } }
    static func add(_ replies: [Reply], onRequest: (@Sendable () -> Void)?) -> String {
        let id = UUID().uuidString
        lock.withLock { scenarios[id] = Scenario(replies: replies, onRequest: onRequest) }
        return id
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTAssertEqual(request.timeoutInterval, 20)
        guard let id = request.value(forHTTPHeaderField: "X-Fixture-ID") else { fatalError("Missing fixture ID") }
        let (reply, onRequest): (Reply, (@Sendable () -> Void)?) = Self.lock.withLock {
            guard var scenario = Self.scenarios[id] else { fatalError("Missing fixture") }
            scenario.requests += 1
            let reply = scenario.replies.isEmpty ? Reply.http(500) : scenario.replies.removeFirst()
            Self.scenarios[id] = scenario
            return (reply, scenario.onRequest)
        }
        onRequest?()
        let code: Int
        var headers: [String: String] = [:]
        switch reply {
        case .http(let value, let retryAfter): code = value; headers["Retry-After"] = retryAfter
        case .network(let value): client?.urlProtocol(self, didFailWithError: URLError(value)); return
        case .stall: return
        default: code = 200
        }
        let content = #"{"translations":[{"id":0,"text":"This really makes you sad."}]}"#
        let body: [String: Any] = ["choices": [["finish_reason": "stop", "message": ["role": "assistant", "content": content]]]]
        let data: Data
        if case .invalidJSON = reply { data = Data("private-provider-response-that-must-not-escape".utf8) }
        else { data = try! JSONSerialization.data(withJSONObject: body) }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
