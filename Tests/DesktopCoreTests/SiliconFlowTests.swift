import XCTest
import Foundation
@testable import DesktopCore

final class SiliconFlowTests: XCTestCase {
    private func client(model: SiliconFlowModel = .qwen25_32B) -> SiliconFlowClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = model == .qwen25_7B ? [Translation7BFixture.self] : [TranslationFixture.self]
        return SiliconFlowClient(session: URLSession(configuration: config))
    }
    func testOutOfOrderIDsMapToCorrectCandidates() async throws {
        let output = try await client().translate(["你好", "再见"], source: "zh-Hans", target: "en", key: "fixture-key")
        XCTAssertEqual(output, ["你好": "Hello", "再见": "Goodbye"])
    }
    func testSelected7BModelIsSentInRequest() async throws {
        let output = try await client(model: .qwen25_7B).translate(["你好", "再见"],
            source: "zh-Hans", target: "en", model: .qwen25_7B, key: "fixture-key")
        XCTAssertEqual(output, ["你好": "Hello", "再见": "Goodbye"])
    }
    func testDuplicateIDsAreRejected() async {
        do {
            _ = try await client().translate(["duplicate", "再见"], source: "zh-Hans", target: "en", key: "fixture-key")
            XCTFail("Duplicate IDs must not attach translation to wrong candidate")
        } catch { XCTAssertEqual(error as? CloudTranslationError, .invalidResponse) }
    }
    func testRateLimitDoesNotExposeResponseBody() async {
        do {
            _ = try await client().translate(["rate-limit"], source: "zh-Hans", target: "en", key: "fixture-key")
            XCTFail("Expected rate limit")
        } catch { XCTAssertEqual(error as? CloudTranslationError, .rateLimited) }
    }
}

private class TranslationFixture: URLProtocol, @unchecked Sendable {
    class var expectedModel: String { "Qwen/Qwen2.5-32B-Instruct" }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTAssertEqual(request.url, SiliconFlowClient.endpoint)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-key")
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }; body.append(contentsOf: buffer.prefix(count))
            }
        }
        let payload = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        XCTAssertEqual(payload?["model"] as? String, type(of: self).expectedModel)
        XCTAssertEqual((payload?["response_format"] as? [String: String])?["type"], "json_object")
        let messages = payload?["messages"] as? [[String: String]]
        XCTAssertEqual(messages?.first?["role"], "system")
        XCTAssertTrue(messages?.first?["content"]?.hasPrefix("You are a professional multilingual translation engine for real-world internet content.") == true)
        let text = String(decoding: body, as: UTF8.self)
        let code = text.contains("rate-limit") ? 429 : 200
        let content = text.contains("duplicate")
            ? #"{"translations":[{"id":0,"text":"Hello"},{"id":0,"text":"Goodbye"}]}"#
            : #"{"translations":[{"id":1,"text":"Goodbye"},{"id":0,"text":"Hello"}]}"#
        let response: [String: Any] = ["choices": [["finish_reason": "stop", "message": ["role": "assistant", "content": content]]]]
        let data = try! JSONSerialization.data(withJSONObject: response)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class Translation7BFixture: TranslationFixture, @unchecked Sendable {
    override class var expectedModel: String { "Qwen/Qwen2.5-7B-Instruct" }
}
