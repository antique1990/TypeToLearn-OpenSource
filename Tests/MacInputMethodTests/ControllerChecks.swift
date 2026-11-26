import AppKit
import InputMethodKit
import KeyboardCore
import DesktopCore

final class InputClient: NSObject, IMKTextInput {
    var committed = "前文"
    var marked = ""
    var selection = NSRange(location: 0, length: 0)
    var markedAttributes: [NSAttributedString.Key: Any] = [:]
    func insertText(_ string: Any!, replacementRange: NSRange) { committed += string as? String ?? ""; marked = "" }
    func setMarkedText(_ string: Any!, selectionRange: NSRange, replacementRange: NSRange) {
        let attributed = string as? NSAttributedString
        marked = attributed?.string ?? string as? String ?? ""
        markedAttributes = attributed.flatMap { $0.length > 0 ? $0.attributes(at: 0, effectiveRange: nil) : nil } ?? [:]
        selection = selectionRange
    }
    func selectedRange() -> NSRange { NSRange(location: committed.utf16.count + selection.location, length: 0) }
    func markedRange() -> NSRange { NSRange(location: committed.utf16.count, length: marked.utf16.count) }
    func attributedSubstring(from range: NSRange) -> NSAttributedString! { NSAttributedString(string: "") }
    func length() -> Int { committed.utf16.count + marked.utf16.count }
    func characterIndex(for point: NSPoint, tracking mappingMode: IMKLocationToOffsetMappingMode, inMarkedRange: UnsafeMutablePointer<ObjCBool>!) -> Int { 0 }
    func attributes(forCharacterIndex index: Int, lineHeightRectangle lineRect: UnsafeMutablePointer<NSRect>!) -> [AnyHashable: Any]! { lineRect.pointee = NSRect(x: 100, y: 400, width: 1, height: 20); return [:] }
    func validAttributesForMarkedText() -> [Any]! { [] }
    func overrideKeyboard(withKeyboardNamed keyboardUniqueName: String!) {}
    func selectMode(_ modeIdentifier: String!) {}
    func supportsUnicode() -> Bool { true }
    func bundleIdentifier() -> String! { "com.learnkeyboard.controllerchecks" }
    func windowLevel() -> CGWindowLevel { 0 }
    func supportsProperty(_ property: TSMDocumentPropertyTag) -> Bool { false }
    func uniqueClientIdentifierString() -> String! { "controllerchecks" }
    func string(from range: NSRange, actualRange: NSRangePointer!) -> String! { "" }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer!) -> NSRect { NSRect(x: 100, y: 400, width: 1, height: 20) }
}

struct CheckFailure: Error { let message: String }

@MainActor private final class ControllerAppleFixture: MacAppleTranslationService {
    var calls = 0
    var resets = 0
    var values: [String: String] = [:]
    func translate(_ texts: [String], sourceID: String, targetID: String,
                   onTranslation: (@MainActor (String, String) -> Void)?) async throws -> [String: String] {
        calls += 1
        if calls == 1 { throw NSError(domain: "TranslationErrorDomain", code: 16) }
        var result: [String: String] = [:]
        for text in texts { values[text] = "Recovered"; result[text] = "Recovered"; onTranslation?(text, "Recovered") }
        return result
    }
    func cached(_ texts: [String], sourceID: String, targetID: String) -> [String: String] {
        values.filter { texts.contains($0.key) }
    }
    func cancel() { resets += 1 }
    func releaseResources() { cancel(); values = [:] }
}

@MainActor private final class DeferredSpelling {
    private var replies: [CheckedContinuation<[String]?, Never>] = []
    var count: Int { replies.count }
    func request(_ prefix: String) async -> [String]? {
        await withCheckedContinuation { replies.append($0) }
    }
    func finish(_ words: [String]) {
        let pending = replies; replies = []
        for reply in pending { reply.resume(returning: words) }
    }
}

/// Each native session gets its own in-memory endpoint. No request can reach
/// SiliconFlow, and the translator never reads the user's Keychain credentials.
private final class ControllerTranslationFixture: @unchecked Sendable {
    enum Mode: Equatable { case partialInvalid, partialService, timeout, invalid, delayedSuccess }
    enum Reply { case success(String), invalid, service, timeout }
    private let lock = NSLock()
    private let mode: Mode
    private var succeeding = false
    private var recorded: [[String]] = []
    private var cancellations = 0
    private var invalidRequest = false
    init(_ mode: Mode) { self.mode = mode }
    var requests: [[String]] { lock.withLock { recorded } }
    var cancelledCount: Int { lock.withLock { cancellations } }
    var requestWasInvalid: Bool { lock.withLock { invalidRequest } }
    func allowSuccess() { lock.withLock { succeeding = true } }
    func cancelled() { lock.withLock { cancellations += 1 } }
    func plan(_ request: URLRequest) -> (Reply, TimeInterval, Int) {
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
        let payload = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let messages = payload?["messages"] as? [[String: String]]
        let content = messages?.last?["content"]?.data(using: .utf8) ?? Data()
        let input = (try? JSONSerialization.jsonObject(with: content)) as? [String: Any]
        let items = input?["items"] as? [[String: Any]] ?? []
        let texts = items.compactMap { $0["text"] as? String }
        return lock.withLock {
            if request.url != SiliconFlowClient.endpoint ||
                request.value(forHTTPHeaderField: "Authorization") != "Bearer fixture-key" || texts.isEmpty {
                invalidRequest = true
            }
            recorded.append(texts)
            if succeeding { return (.success("ok"), 0, texts.count) }
            switch mode {
            case .partialInvalid: return (recorded.count == 1 ? .success("ok") : .invalid, 0, texts.count)
            case .partialService: return (recorded.count == 1 ? .success("ok") : .service, 0, texts.count)
            case .timeout: return (.timeout, 0, texts.count)
            case .invalid: return (.invalid, 0.08, texts.count)
            case .delayedSuccess: return (.success("stale"), 0.6, texts.count)
            }
        }
    }
    func session() -> URLSession {
        let id = UUID().uuidString
        ControllerTranslationProtocol.register(self, id: id)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ControllerTranslationProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Controller-Fixture": id]
        return URLSession(configuration: configuration)
    }
}

private final class ControllerTranslationProtocol: URLProtocol, @unchecked Sendable {
    private static let registryLock = NSLock()
    private static var registry: [String: ControllerTranslationFixture] = [:]
    private let stateLock = NSLock()
    private var stopped = false
    private var finished = false
    private var fixture: ControllerTranslationFixture?
    static func register(_ fixture: ControllerTranslationFixture, id: String) {
        registryLock.withLock { registry[id] = fixture }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let id = request.value(forHTTPHeaderField: "X-Controller-Fixture"),
              let fixture = Self.registryLock.withLock({ Self.registry[id] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        self.fixture = fixture
        let (reply, delay, count) = fixture.plan(request)
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
            guard stateLock.withLock({ if stopped { return false }; finished = true; return true }) else { return }
            if case .timeout = reply {
                client?.urlProtocol(self, didFailWithError: URLError(.timedOut)); return
            }
            let code: Int
            let data: Data
            switch reply {
            case .success(let value):
                code = 200
                let content = try! JSONSerialization.data(withJSONObject: ["translations": (0..<count).map { ["id": $0, "text": value] }])
                data = try! JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "stop", "message": ["role": "assistant", "content": String(decoding: content, as: UTF8.self)]]]])
            case .invalid: code = 200; data = Data("{}".utf8)
            case .service: code = 503; data = Data()
            case .timeout: return
            }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {
        let cancelled = stateLock.withLock { let value = !stopped && !finished; stopped = true; return value }
        if cancelled { fixture?.cancelled() }
    }
}

@main struct ControllerChecks {
    @MainActor static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw CheckFailure(message: message) }
    }
    @MainActor static func wait(_ predicate: () -> Bool, diagnostics: () -> String = { "" }, line: UInt = #line) async throws {
        for _ in 0..<500 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CheckFailure(message: "Timed out waiting for native controller at line \(line): " + diagnostics())
    }
    @MainActor static func key(_ controller: InputController, _ client: InputClient, _ text: String, code: UInt16 = 0) {
        _ = controller.inputText(text, key: Int(code), modifiers: 0, client: client)
    }
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        var settings = DesktopSettings(); settings.translationEnabled = false
        func session() -> (InputController, InputClient) {
            let client = InputClient()
            let controller = InputController()
            controller.testSettings = settings
            controller.testLearnedURL = Bundle.main.resourceURL!.appendingPathComponent("learned-\(UUID()).json")
            controller.activateServer(client)
            return (controller, client)
        }
        func cloudSession(_ fixture: ControllerTranslationFixture) -> (InputController, InputClient, URLSession) {
            var cloudSettings = settings
            cloudSettings.translationEnabled = true
            cloudSettings.provider = .siliconFlow
            cloudSettings.cloudConsent = true
            cloudSettings.candidateLayout = .horizontal
            let transport = fixture.session()
            let client = InputClient()
            let controller = InputController()
            controller.testSettings = cloudSettings
            controller.testLearnedURL = Bundle.main.resourceURL!.appendingPathComponent("learned-\(UUID()).json")
            controller.testSetTranslator(MacTranslator(learnedURL: nil,
                cloud: SiliconFlowClient(session: transport), keyProvider: { "fixture-key" }))
            controller.activateServer(client)
            return (controller, client, transport)
        }
        do {
            let (controller, client) = session()
            key(controller, client, "nihao")
            key(controller, client, " ", code: 49)
            key(controller, client, "shijie")
            key(controller, client, " ", code: 49)
            try await wait({ client.committed.contains("世界") }, diagnostics: { "committed=\(client.committed) marked=\(client.marked) input=\(controller.testState.input) candidates=\(controller.testState.candidates.count) bundle=\(Bundle.main.bundlePath)" })
            try require(client.committed == "前文你好世界", "Fast queued space/typing lost text: \(client.committed)")
            controller.deactivateServer(client)
        }
        do {
            let (controller, client) = session()
            key(controller, client, "nihao")
            key(controller, client, ",", code: 43)
            key(controller, client, "shijie")
            key(controller, client, "!", code: 18)
            try await wait({ client.committed.hasSuffix("！") }, diagnostics: { "punctuation committed=\(client.committed) marked=\(client.marked) input=\(controller.testState.input) candidates=\(controller.testState.candidates.count)" })
            try require(client.committed == "前文你好，世界！", "Punctuation did not commit Chinese: \(client.committed)")
            controller.deactivateServer(client)
        }
        do {
            let (controller, client) = session()
            key(controller, client, "nihao")
            key(controller, client, "1", code: 18)
            try await wait({ client.marked.isEmpty }, diagnostics: { "number committed=\(client.committed) marked=\(client.marked)" })
            try require(client.committed == "前文你好", "Number selection during loading lost Chinese")
            controller.deactivateServer(client)
        }
        do {
            let (controller, client) = session()
            key(controller, client, "niquali")
            key(controller, client, "", code: 123); key(controller, client, "", code: 123); key(controller, client, "", code: 123)
            key(controller, client, "n")
            try await wait({ !controller.testState.candidates.isEmpty }, diagnostics: { "edit input=\(controller.testState.input)" })
            try require(controller.testState.input == "niqunali", "Mid-composition cursor edit failed")
            try require(controller.testState.candidates.contains { $0.text == "你去哪里" }, "Sentence candidate missing after edit")
            key(controller, client, "", code: 53)
            try require(client.committed == "前文" && client.marked.isEmpty, "Escape modified committed text")
            controller.deactivateServer(client)
        }
        do {
            let (controller, client) = session()
            key(controller, client, "shi")
            try await wait({ controller.testState.candidates.count > 5 }, diagnostics: { "paging count=\(controller.testState.candidates.count)" })
            key(controller, client, "=", code: 24)
            try require(controller.testExpanded && controller.testState.pageStart == 0,
                        "First +/- must expand without skipping initial candidates")
            try require(controller.testState.visible.count == 12, "Expanded window should show three rows of four")
            key(controller, client, "=", code: 24)
            try require(controller.testState.pageStart == 0 && controller.testState.selected == 4, "Plus must focus next row")
            key(controller, client, "-", code: 27)
            try require(controller.testState.selected == 0, "Minus must focus previous row")
            for _ in 0..<3 { key(controller, client, "=", code: 24) }
            try require(controller.testState.pageStart == 12, "Row boundary must advance page")
            key(controller, client, "-", code: 27)
            try require(controller.testState.pageStart == 0 && controller.testState.selected == 8,
                        "Backward page boundary must focus previous page last row")
            key(controller, client, "=", code: 24)
            try require(controller.testCategoriesVisible, "Paging did not reveal candidate categories")
            let expected = controller.testState.visible.first!.text
            key(controller, client, " ", code: 49)
            try await wait { client.marked.isEmpty }
            try require(client.committed == "前文" + expected, "Space selected wrong paged candidate")
            controller.deactivateServer(client)
        }
        do {
            let (controller, client) = session()
            key(controller, client, "shi")
            try await wait { controller.testState.candidates.count > 5 }
            key(controller, client, "\t", code: 48)
            try require(controller.testCategory == .radical, "Tab did not select radical category")
            let expected = controller.testState.visible[1].text
            key(controller, client, "2", code: 19)
            try await wait { client.marked.isEmpty }
            try require(client.committed == "前文" + expected, "Sorted candidate selection lost engine identity")
            controller.deactivateServer(client)
        }
        do {
            let (controller, client) = session()
            controller.testOpenEmoji()
            try require(controller.testState.browsingSymbols && controller.testState.candidates.count > 1000,
                        "Standalone emoji browser is missing catalog")
            try require(client.marked.isEmpty, "Emoji browser inserted a fake composition")
            let expected = controller.testState.visible[2].text
            key(controller, client, "3", code: 20)
            try require(client.committed == "前文" + expected && client.marked.isEmpty, "Emoji selection failed")
            controller.testOpenEmoji()
            key(controller, client, "nihao")
            key(controller, client, " ", code: 49)
            try await wait { client.committed.hasSuffix("你好") }
            try require(client.committed == "前文" + expected + "你好", "Typing after emoji browser lost input")
            controller.deactivateServer(client)
        }
        do {
            let (controller, client) = session()
            key(controller, client, "nihao")
            key(controller, client, "\r", code: 36)
            try require(client.committed == "前文nihao", "Return must commit original spelling")
            controller.deactivateServer(client)
        }
        do {
            let (controller, client) = session()
            key(controller, client, "nihaoshijie")
            try await wait { !controller.testState.candidates.isEmpty }
            try require(controller.testState.candidates.contains { $0.text == "你好世界" }, "Full sentence conversion missing")
            key(controller, client, "", code: 53)
            key(controller, client, "nhao")
            try await wait { !controller.testState.candidates.isEmpty }
            try require(controller.testState.candidates.contains { $0.text == "你好" }, "Mixed full/abbreviated conversion missing")
            controller.deactivateServer(client)
        }
        do {
            let (controller, client) = session()
            key(controller, client, "nihao")
            key(controller, client, " ", code: 49)
            controller.deactivateServer(client)
            let before = client.committed
            try await Task.sleep(for: .milliseconds(200))
            try require(client.committed == before && client.marked.isEmpty, "Late selection edited a deactivated client")
        }
        let sample = Candidate(text: "这是完整的中文候选", reading: "", consumed: 1)
        do {
            let (controller, client) = session()
            key(controller, client, "shi")
            key(controller, client, "9", code: 25)
            try await wait { !controller.testState.candidates.isEmpty }
            try require(client.committed == "前文" && controller.testState.input == "shi", "Loading accepted an invisible candidate number")
            controller.deactivateServer(client)
        }
        do {
            // Mixed entries such as V领 now give `v` valid completions. Use a
            // verified absent Cangjie code to exercise the no-candidate branch.
            let savedLayout = settings.layout
            settings.layout = .cangjie
            let (controller, client) = session()
            settings.layout = savedLayout
            let invalid = "zzzzz"
            key(controller, client, invalid)
            try await Task.sleep(for: .milliseconds(100))
            try require(controller.testState.candidates.isEmpty, "Expected invalid pinyin to have no candidates")
            key(controller, client, ",", code: 43)
            key(controller, client, "!", code: 18)
            try require(client.committed == "前文\(invalid)，！", "No-candidate fallback swallowed punctuation")
            controller.deactivateServer(client)
        }
        for delay in [0, 3, 15] {
            let (controller, client) = session()
            let keys: [(String, Int)] = [("n",45),("i",34),("h",4),("a",0),("o",31),(",",43),
                                       ("s",1),("h",4),("i",34),("j",38),("i",34),("e",14),("!",18)]
            for (text, code) in keys {
                _ = controller.inputText(text, key: code,
                    modifiers: text == "!" ? Int(NSEvent.ModifierFlags.shift.rawValue) : 0, client: client)
                if delay > 0 { try await Task.sleep(for: .milliseconds(delay)) }
            }
            try await wait { client.committed.hasSuffix("！") }
            try require(client.committed == "前文你好，世界！", "Per-key rapid punctuation failed at \(delay)ms: \(client.committed)")
            controller.deactivateServer(client)
        }
        do {
            let (controller, client) = session()
            key(controller, client, "jiji")
            _ = controller.inputText(" ", key: 49, modifiers: Int(NSEvent.ModifierFlags.shift.rawValue), client: client)
            try await wait { !controller.testState.candidates.isEmpty }
            try require(controller.testCategory == .decomposition && controller.testExpanded, "Shift-Space did not open structural Pinyin")
            guard let index = controller.testState.visible.firstIndex(where: { $0.text == "喆" }) else {
                throw CheckFailure(message: "jiji must offer 喆 from 吉 + 吉")
            }
            for _ in 0..<(index / 4) { key(controller, client, "=", code: 24) }
            key(controller, client, String(index % 4 + 1), code: 18)
            try require(client.committed == "前文喆" && client.marked.isEmpty, "Structural Pinyin did not consume whole spelling")
            controller.deactivateServer(client)
        }
        for word in ["Hello", "internationalization", "pneumonoultramicroscopicsilicovolcanoconiosis"] {
            let width = CandidateMetrics.width(sample, translation: word, maximum: 700) - 28
            let size = CandidateMetrics.fittedTranslationSize(word, width: width)
            let actualWidth = (word as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size)]).width
            try require(actualWidth <= width, "Single word cannot fit on one line")
        }
        for text in ["Hello", "I am very happy to meet you today and hope you have a wonderful afternoon.", String(repeating: "A long translated sentence with spaces. ", count: 8)] {
            let width = CandidateMetrics.width(sample, translation: text, maximum: 700)
            let size = CandidateMetrics.fittedTranslationSize(text, width: width - 28)
            try require(CandidateMetrics.height(text, width: width - 28, size: size) <= CandidateMetrics.twoLines(size: size), "Translation exceeds two measured lines")
        }
        do {
            let (controller, client) = session()
            key(controller, client, "shengri")
            controller.testOpenEmoji()
            controller.testShowEmojiGroup("nature")
            try require(controller.testState.visible.first?.text == "🐵", "Nature group must show its own first emoji")
            key(controller, client, "1", code: 18)
            try await Task.sleep(for: .milliseconds(100))
            try require(client.committed == "前文🐵" && client.marked.isEmpty,
                        "Stale keyword lookup replaced explicitly selected emoji group")
            key(controller, client, "shengri")
            controller.testOpenEmoji()
            controller.testShowEmojiGroup("nature")
            key(controller, client, "\t", code: 48)
            try await wait { controller.testState.candidates.contains { $0.text == "生日" } }
            controller.deactivateServer(client)
        }
        do {
            let (controller, client) = session()
            key(controller, client, "nihao")
            try await wait { !controller.testState.candidates.isEmpty }
            let hosting = controller.testHostingIdentity
            try require(controller.inputText(nil, key: 123, modifiers: 0, client: client), "Nil-text left arrow was rejected")
            try require(client.selection.location == 4, "Marked cursor did not move left")
            try require(client.markedAttributes[.underlineStyle] != nil && client.markedAttributes[.markedClauseSegment] != nil,
                        "Host did not receive native composition attributes with the insertion range")
            try require(controller.inputText(nil, key: 51, modifiers: 0, client: client), "Nil-text backspace was rejected")
            try require(controller.testState.input == "niho" && client.marked == "niho", "Backspace did not edit at marked cursor")
            try require(controller.testHostingIdentity == hosting, "Lookup replaced the entire hosting view")
            key(controller, client, "a")
            try await wait { controller.testState.candidates.contains { $0.text == "你好" } }
            try require(controller.testHostingIdentity == hosting, "Completed lookup rebuilt the hosting view")
            controller.deactivateServer(client)
        }
        do {
            let (controller, client) = session()
            key(controller, client, "iPhoe")
            _ = controller.inputText(nil, key: 123, modifiers: 0, client: client)
            key(controller, client, "n")
            try await wait { controller.testState.candidates.contains { $0.text == "iPhone" } }
            try require(client.marked == "iPhone", "Mixed-case input was not preserved")
            guard let index = controller.testState.visible.firstIndex(where: { $0.text == "iPhone" }) else {
                throw CheckFailure(message: "Mixed English candidate must be visible")
            }
            controller.testClickCandidate(index)
            try await wait { client.marked.isEmpty }
            try require(client.committed == "前文iPhone", "A single candidate click must commit")
            controller.deactivateServer(client)
        }
        do {
            settings.translationEnabled = true
            let (controller, client) = session()
            settings.translationEnabled = false
            key(controller, client, "nihao")
            try await wait { controller.testState.visible.count >= 2 }
            let chosen = controller.testState.visible[1]
            controller.testSetTranslations([chosen.text: "Chosen translation"])
            _ = controller.inputText("@", key: 19, modifiers: Int(NSEvent.ModifierFlags.shift.rawValue), client: client)
            try await wait({ client.committed.hasSuffix("Chosen translation") },
                           diagnostics: { "committed=\(client.committed) remaining=\(client.marked)" })
            try require(client.committed == "前文Chosen translation", "Shift-2 must commit second visible translation, not punctuation")
            controller.deactivateServer(client)
        }
        do {
            settings.translationEnabled = true
            let (controller, client) = session()
            settings.translationEnabled = false
            key(controller, client, "nihao")
            try await wait { !controller.testState.visible.isEmpty }
            controller.testSetTranslations([:])
            _ = controller.inputText("!", key: 18, modifiers: Int(NSEvent.ModifierFlags.shift.rawValue), client: client)
            _ = controller.inputText(nil, key: 51, modifiers: 0, client: client)
            try await Task.sleep(for: .milliseconds(120))
            try require(client.committed == "前文" && controller.testState.input == "niha",
                        "Backspace must cancel waiting translation and edit the original spelling")
            controller.deactivateServer(client)
        }
        // The actual key must remain synchronous: cancel an unfinished Rime
        // choice and edit its still-marked spelling, rather than replaying an
        // empty string or a private-use arrow character into the host later.
        for (code, moveFirst, expected, cursor) in [
            (51, false, "niha", 4), (117, true, "niha", 4),
            (123, false, "nihao", 4), (124, true, "nihao", 5),
            (115, false, "nihao", 0), (119, true, "nihao", 5)
        ] {
            let (controller, client) = session()
            key(controller, client, "nihao")
            try await wait { !controller.testState.visible.isEmpty }
            if moveFirst { _ = controller.inputText(nil, key: 123, modifiers: 0, client: client) }
            guard let index = controller.testState.visible.firstIndex(where: { $0.consumed == 0 && $0.engineIndex != nil }) else {
                throw CheckFailure(message: "Expected an unresolved Rime candidate for pending-edit coverage")
            }
            key(controller, client, String(index + 1), code: 18)
            try require(controller.inputText(nil, key: code, modifiers: 0, client: client),
                        "Pending Rime choice swallowed editing key \(code)")
            try await Task.sleep(for: .milliseconds(100))
            try require(client.committed == "前文" && client.marked == expected && controller.testState.cursor == cursor,
                        "Editing key \(code) did not cancel pending choice: \(client.committed) / \(client.marked)")
            controller.deactivateServer(client)
        }
        do {
            let (controller, client) = session()
            key(controller, client, "nihao")
            key(controller, client, " ", code: 49)
            key(controller, client, "n")
            _ = controller.inputText(nil, key: 51, modifiers: 0, client: client)
            try await Task.sleep(for: .milliseconds(100))
            try require(client.committed == "前文" && client.marked == "nihao",
                        "Cancelling a queued selection reordered the pending letter and backspace")
            controller.deactivateServer(client)
        }
        do {
            let (controller, client) = session()
            key(controller, client, "nihao")
            key(controller, client, " ", code: 49)
            try require(controller.inputText("\u{f701}", key: 125, modifiers: 0, client: client),
                        "Pending lookup did not handle candidate navigation synchronously")
            try await wait { !controller.testState.visible.isEmpty }
            try require(client.committed == "前文" && client.marked == "nihao",
                        "Candidate navigation committed text or inserted a function-key character")
            controller.deactivateServer(client)
        }
        do {
            let (controller, client) = session()
            key(controller, client, "nihao")
            key(controller, client, " ", code: 49)
            try require(!controller.inputText("\u{f704}", key: 122, modifiers: 0, client: client),
                        "Unknown function key must be passed to the real host synchronously")
            try await Task.sleep(for: .milliseconds(100))
            try require(client.committed == "前文nihao" && client.marked.isEmpty,
                        "Unknown function key was replayed as document text")
            controller.deactivateServer(client)
        }
        for mode in [ControllerTranslationFixture.Mode.partialInvalid, .partialService] {
            let fixture = ControllerTranslationFixture(mode)
            let (controller, client, transport) = cloudSession(fixture)
            defer { transport.invalidateAndCancel() }
            key(controller, client, "zhezhenshirangninanguoya")
            try await wait({ controller.testTranslationCanRetry && !controller.testIsTranslating },
                diagnostics: { "partial translation status=\(controller.testTranslationStatus) requests=\(fixture.requests.count)" })
            try require(controller.testState.candidates.first?.text == "这真是让你难过呀",
                        "The user's complete phrase was not the first Chinese candidate: \(controller.testState.candidates.first?.text ?? "missing")")
            guard let first = fixture.requests.first?.first else {
                throw CheckFailure(message: "Missing priority translation request")
            }
            try require(controller.testTranslations[first] == "ok", "A later batch failure erased the useful first translation")
            try require(!controller.testTranslationStatus.isEmpty, "Partial batch failure was silently treated as success")
            let failedCount = fixture.requests.count
            try require(failedCount == (mode == .partialService ? 3 : 2), "Transient failure retry was not bounded to one attempt")
            _ = controller.inputText(nil, key: 125, modifiers: 0, client: client)
            _ = controller.inputText(nil, key: 126, modifiers: 0, client: client)
            try await Task.sleep(for: .milliseconds(250))
            try require(fixture.requests.count == failedCount && controller.testTranslationCanRetry,
                        "Changing selection silently restarted a failed page")
            fixture.allowSuccess()
            controller.testRetryTranslation()
            try await wait({ !controller.testIsTranslating && !controller.testTranslationCanRetry &&
                controller.testState.visible.allSatisfy { controller.testTranslations[$0.text] != nil } },
                diagnostics: { "manual retry status=\(controller.testTranslationStatus) requests=\(fixture.requests.count)" })
            try require(fixture.requests.dropFirst(failedCount).allSatisfy { !$0.contains(first) },
                        "Manual retry sent an already cached successful candidate again")
            try require(controller.testTranslationStatus.isEmpty && !fixture.requestWasInvalid,
                        "Successful retry retained an error or used invalid fixture credentials")
            controller.deactivateServer(client)
        }
        do {
            let fixture = ControllerTranslationFixture(.timeout)
            let (controller, client, transport) = cloudSession(fixture)
            defer { transport.invalidateAndCancel() }
            key(controller, client, "nihao")
            try await wait({ controller.testTranslationStatus.contains("自动重试") },
                           diagnostics: { controller.testTranslationStatus })
            try require(controller.testIsTranslating && !controller.testTranslationCanRetry,
                        "The automatic retry appeared as a finished request")
            try await wait { controller.testTranslationCanRetry && !controller.testIsTranslating }
            try require(fixture.requests.count == 2 && controller.testTranslationStatus.contains("超时"),
                        "Repeated timeout did not stop after one retry with a visible error")
            controller.deactivateServer(client)
        }
        do {
            let fixture = ControllerTranslationFixture(.invalid)
            let (controller, client, transport) = cloudSession(fixture)
            defer { transport.invalidateAndCancel() }
            key(controller, client, "nihao")
            try await wait { controller.testState.visible.count >= 2 }
            _ = controller.inputText("@", key: 19, modifiers: Int(NSEvent.ModifierFlags.shift.rawValue), client: client)
            key(controller, client, "n")
            try await wait({ controller.testState.input == "nihaon" },
                           diagnostics: { "queued input=\(controller.testState.input) status=\(controller.testTranslationStatus)" })
            try require(client.committed == "前文" && client.marked == "nihaon",
                        "A failed Shift-2 translation lost, duplicated, or committed queued input")
            try require(controller.inputText(nil, key: 51, modifiers: 0, client: client) && controller.testState.input == "nihao",
                        "Translation failure left candidate selection locked")
            controller.deactivateServer(client)
        }
        do {
            let fixture = ControllerTranslationFixture(.delayedSuccess)
            let (controller, client, transport) = cloudSession(fixture)
            defer { transport.invalidateAndCancel() }
            key(controller, client, "nihao")
            try await wait { fixture.requests.count == 1 }
            controller.testOpenEmoji()
            try await wait { fixture.cancelledCount == 1 }
            try await Task.sleep(for: .milliseconds(650))
            try require(controller.testCategory == .emoji && controller.testTranslations.isEmpty &&
                controller.testTranslationStatus.isEmpty && !controller.testIsTranslating && !controller.testTranslationCanRetry,
                        "Cancelled translation changed the emoji page or left stale progress/error state")
            try require(fixture.requests.count == 1, "Switching to emoji retried the cancelled translation")
            controller.deactivateServer(client)
        }
        do {
            let fixture = ControllerTranslationFixture(.delayedSuccess)
            let (controller, client, transport) = cloudSession(fixture)
            defer { transport.invalidateAndCancel() }
            key(controller, client, "nihao")
            try await wait { fixture.requests.count == 1 }
            fixture.allowSuccess()
            key(controller, client, "a")
            try await wait { fixture.cancelledCount == 1 }
            try await wait({ !controller.testIsTranslating && !controller.testTranslations.isEmpty },
                           diagnostics: { "replacement composition status=\(controller.testTranslationStatus)" })
            try await Task.sleep(for: .milliseconds(650))
            try require(controller.testState.input == "nihaoa" && client.committed == "前文" &&
                controller.testTranslations.values.allSatisfy { $0 == "ok" } &&
                controller.testTranslationStatus.isEmpty && !controller.testTranslationCanRetry,
                        "An old cancelled response overwrote the newer spelling or its translations")
            controller.deactivateServer(client)
        }
        // Exercise the production settings -> lookup -> actual selection path.
        // The candidate's schema must remain the composition's snapshot even
        // when the user changes settings before committing it.
        func choose(_ text: String, controller: InputController, client: InputClient) async throws {
            try await wait({ controller.testState.candidates.contains { $0.text == text } },
                           diagnostics: { "Missing \(text); raw=\(controller.testState.input), status=\(controller.testTranslationStatus), candidates=\(controller.testState.candidates.map(\.text))" })
            for _ in 0..<12 {
                if let index = controller.testState.visible.firstIndex(where: { $0.text == text }) {
                    controller.testClickCandidate(index)
                    return
                }
                controller.testClickNextPage()
            }
            throw CheckFailure(message: "Fuzzy candidate was not reachable by paging: \(text)")
        }
        do {
            settings.fuzzyPinyinOptions = .sSh
            let (controller, client) = session()
            key(controller, client, "si")
            try await wait { controller.testState.candidates.contains { $0.text == "是" } }
            var changed = settings
            changed.fuzzyPinyinOptions = []
            changed.revision = UUID()
            controller.testSettings = changed
            try await choose("是", controller: controller, client: client)
            try await wait { client.committed == "前文是" && client.marked.isEmpty }
            key(controller, client, "si")
            try await wait { !controller.testState.candidates.isEmpty }
            try require(!controller.testState.candidates.contains { $0.text == "是" },
                        "Disabled rule remained active on a new composition")
            controller.deactivateServer(client)
        }
        for (raw, text, options) in [
            ("senglin", "森林", PinyinFuzzyOptions.enEng),
            ("mangyi", "满意", .anAng),
            ("yinghang", "银行", .inIng)
        ] {
            settings.fuzzyPinyinOptions = options
            let (controller, client) = session()
            key(controller, client, raw)
            try await choose(text, controller: controller, client: client)
            try await wait { client.committed == "前文" + text && client.marked.isEmpty }
            controller.deactivateServer(client)
        }
        for (raw, text) in [("si'zihao", "狮子"), ("shizihao", "私自")] {
            settings.fuzzyPinyinOptions = .sSh
            let (controller, client) = session()
            for letter in raw { key(controller, client, String(letter)) }
            try await choose(text, controller: controller, client: client)
            try await wait { controller.testState.input == "hao" }
            try require(client.committed == "前文" + text, "Fuzzy selection consumed wrong input prefix")
            try await choose("好", controller: controller, client: client)
            try await wait { client.committed == "前文" + text + "好" && client.marked.isEmpty }
            let learnedURL = controller.testLearnedURL!
            try await wait {
                !LearnedWords.load(from: learnedURL).candidates(for: raw, layout: .pinyin, script: .simplified,
                                                               pinyinPolicy: .configured(.sSh)).isEmpty
            }
            try require(LearnedWords.load(from: learnedURL).candidates(for: raw, layout: .pinyin, script: .simplified,
                                                                       pinyinPolicy: .configured([])).isEmpty,
                        "A learned fuzzy alias bypassed the disabled setting")
            controller.deactivateServer(client)
        }
        do {
            let previousFuzzyPreference = settings.fuzzyPinyinPreference
            settings.fuzzyPinyinOptions = .retroflex
            defer { settings.fuzzyPinyinPreference = previousFuzzyPreference }
            for (raw, pronoun) in [("nibuzaoshuo", "你"), ("wo'bu'zao'shuo", "我")] {
                let expected = pronoun + "不早说"
                let unsupported = [pronoun + "不找说", pronoun + "不着说"]
                let (controller, client) = session()
                for letter in raw { key(controller, client, String(letter)) }
                try await wait { !controller.testState.visible.isEmpty }
                try require(controller.testState.input == raw && controller.testState.visible.first?.text == expected,
                            "Expected composed \(expected) first for \(raw): \(controller.testState.visible.map(\.text))")
                let choices = controller.testState.candidates.map(\.text)
                try require(choices.contains(pronoun) && !choices.contains(where: unsupported.contains),
                            "Unexpected fuzzy or missing partial candidate for \(raw): \(choices)")
                key(controller, client, " ", code: 49)
                try await wait { client.committed == "前文" + expected && client.marked.isEmpty }
                try require(controller.testState.input.isEmpty, "Composed \(expected) left raw input after selection")
                controller.deactivateServer(client)
            }
        }
        do {
            let (controller, client) = session()
            key(controller, client, "shijie")
            try await wait { controller.testState.candidates.count > 8 }
            for _ in 0..<4 { controller.testClickNextPage() }
            for _ in 0..<8 { key(controller, client, "", code: 123) }
            try require(client.selection.location == 0 && controller.testState.cursor == 0,
                        "Left boundary must match the host insertion point")
            key(controller, client, "", code: 51)
            try require(client.marked == "shijie" && client.committed == "前文", "Left boundary backspace removed host text")
            key(controller, client, "", code: 124)
            key(controller, client, "", code: 51)
            try require(client.marked == "hijie" && client.selection.location == 0, "Delete after paging did not edit spelling")
            key(controller, client, "s")
            try require(client.marked == "shijie" && client.selection.location == 1,
                        "Inserted letter used a stale host cursor")
            controller.deactivateServer(client)
        }
        do {
            settings.fuzzyPinyinOptions = .all
            let (controller, client) = session()
            key(controller, client, "zhezhenshirangrengaoxiao")
            try await wait { !controller.testState.candidates.isEmpty }
            controller.testClickNextPage()
            try require(controller.testState.visible.count == 12, "Expanded long composition must show three rows")
            guard let offset = controller.testState.visible.firstIndex(where: { $0.text == "这" }) else {
                throw CheckFailure(message: "Long phrase crowded single-character 这 off the first expanded page")
            }
            controller.testClickCandidate(offset)
            try await wait { controller.testState.input == "zhenshirangrengaoxiao" }
            try require(client.committed == "前文这", "Single-character selection consumed a whole phrase")
            controller.deactivateServer(client)
        }
        do {
            let (controller, client) = session()
            key(controller, client, "shi")
            try await wait { controller.testState.candidates.count >= 48 }
            controller.testClickNextPage()
            while controller.testState.canPageForward { controller.testClickNextPage() }
            controller.testClickNextPage()
            try await wait({ controller.testState.candidates.count > 64 && controller.testState.pageStart >= 48 },
                           diagnostics: { "count=\(controller.testState.candidates.count), page=\(controller.testState.pageStart)" })
            try require(controller.testState.visible.count == 12, "Additional candidate page is incomplete")
            let expected = controller.testState.visible[11].text
            controller.testClickCandidate(11)
            try await wait { client.marked.isEmpty }
            try require(client.committed == "前文" + expected, "Twelfth candidate after continuation committed incorrectly")
            controller.deactivateServer(client)
        }
        for index in 0..<12 {
            let (controller, client) = session()
            key(controller, client, "shi")
            try await wait { controller.testState.candidates.count >= 12 }
            key(controller, client, "=", code: 24)
            for _ in 0..<(index / 4) { key(controller, client, "=", code: 24) }
            let expected = controller.testState.visible[index].text
            key(controller, client, String(index % 4 + 1), code: 18)
            try await wait { client.marked.isEmpty }
            try require(client.committed == "前文" + expected, "Row number must reach every candidate including tenth through twelfth")
            controller.deactivateServer(client)
        }
        do {
            settings.translationEnabled = true
            let (controller, client) = session()
            settings.translationEnabled = false
            key(controller, client, "shi")
            try await wait { controller.testState.candidates.count >= 12 }
            for _ in 0..<3 { key(controller, client, "=", code: 24) }
            let chosen = controller.testState.visible[11]
            controller.testSetTranslations([chosen.text: "Twelfth translation"])
            _ = controller.inputText("$", key: 21, modifiers: Int(NSEvent.ModifierFlags.shift.rawValue), client: client)
            try await wait { client.committed.hasSuffix("Twelfth translation") }
            try require(client.committed == "前文Twelfth translation", "Shift-4 did not select focused third row translation")
            controller.deactivateServer(client)
        }
        // Hold the spelling response indefinitely. Chinese publication, key
        // handling and commits must continue without releasing this service.
        do {
            let spelling = DeferredSpelling()
            let (controller, client) = session()
            controller.testCompletionProvider = { await spelling.request($0) }
            key(controller, client, "nihao")
            try await wait { controller.testState.candidates.first?.text == "你好" && spelling.count == 1 }
            key(controller, client, " ", code: 49)
            try await wait { client.committed == "前文你好" }
            spelling.finish(["nihao"])
            try await Task.sleep(for: .milliseconds(30))
            try require(controller.testState.input.isEmpty && client.committed == "前文你好",
                        "Slow spelling blocked space selection or resurrected the committed composition")
            controller.deactivateServer(client)
        }
        do {
            let spelling = DeferredSpelling()
            let (controller, client) = session()
            controller.testCompletionProvider = { await spelling.request($0) }
            key(controller, client, "nihao")
            try await wait { controller.testState.candidates.count > 1 && spelling.count == 1 }
            key(controller, client, "", code: 125)
            let selected = controller.testState.candidates[controller.testState.selected]
            spelling.finish(["nihao"])
            try await Task.sleep(for: .milliseconds(30))
            try require(controller.testState.candidates[controller.testState.selected] == selected &&
                        !controller.testState.candidates.contains(where: { $0.text == "nihao" }),
                        "Late English candidate changed a choice the user was navigating")
            controller.deactivateServer(client)
        }
        do {
            let old = DeferredSpelling(), newer = DeferredSpelling()
            let (controller, client) = session()
            controller.testCompletionProvider = { prefix in
                if prefix == "niha" { return await old.request(prefix) }
                return await newer.request(prefix)
            }
            key(controller, client, "nihao")
            try await wait { old.count == 1 && !controller.testState.candidates.isEmpty }
            key(controller, client, "a")
            try await wait { newer.count == 1 && !controller.testState.candidates.isEmpty }
            let candidates = controller.testState.candidates
            old.finish(["nihao"])
            try await Task.sleep(for: .milliseconds(30))
            try require(controller.testState.input == "nihaoa" && controller.testState.candidates == candidates,
                        "Obsolete English result overwrote the new spelling")
            newer.finish([])
            controller.deactivateServer(client)
        }
        do {
            let spelling = DeferredSpelling()
            let (controller, firstClient) = session()
            controller.testCompletionProvider = { await spelling.request($0) }
            key(controller, firstClient, "nihao")
            try await wait { spelling.count == 1 && !controller.testState.candidates.isEmpty }
            controller.deactivateServer(firstClient)
            let nextClient = InputClient()
            controller.activateServer(nextClient)
            key(controller, nextClient, "ni")
            try await wait { !controller.testState.candidates.isEmpty }
            let nextCandidates = controller.testState.candidates
            spelling.finish(["nihao"])
            try await Task.sleep(for: .milliseconds(30))
            try require(controller.testState.input == "ni" && controller.testState.candidates == nextCandidates &&
                        nextClient.committed == "前文", "Late spelling reply leaked into the next host client")
            controller.deactivateServer(nextClient)
        }
        do {
            let spelling = DeferredSpelling()
            settings.english = true
            let (controller, client) = session()
            settings.english = false
            controller.testCompletionProvider = { await spelling.request($0) }
            key(controller, client, "appli")
            try await wait { spelling.count == 1 && controller.testState.candidates.first?.text == "appli" }
            spelling.finish(["application"])
            try await wait { controller.testState.candidates.contains(where: { $0.text == "application" }) }
            try require(controller.testState.candidates.first?.text == "appli", "English completion replaced original spelling")
            controller.deactivateServer(client)
        }
        do {
            let spelling = DeferredSpelling()
            let (controller, client) = session()
            controller.testCompletionProvider = { await spelling.request($0) }
            key(controller, client, "nihao")
            try await wait { spelling.count == 1 && !controller.testState.candidates.isEmpty }
            key(controller, client, "=", code: 24)
            let candidates = controller.testState.candidates
            spelling.finish(["nihao"])
            try await Task.sleep(for: .milliseconds(30))
            try require(controller.testExpanded && controller.testState.candidates == candidates,
                        "Late spelling reply reset expanded candidate browsing")
            controller.deactivateServer(client)
        }
        do {
            let (controller, client) = session()
            controller.testCompletionProvider = { _ in ["xian"] }
            key(controller, client, "xian")
            try await wait { controller.testState.candidates.contains(where: { $0.text == "仙" }) }
            try require(!controller.testState.candidates.contains(where: { $0.text == "xian" }),
                        "Unranked English xian was still shown in Chinese mode")
            let chosen = controller.testState.candidates[0].text
            key(controller, client, " ", code: 49)
            try await wait { client.committed == "前文" + chosen }
            try require(controller.testState.input.isEmpty && !chosen.unicodeScalars.allSatisfy(\.isASCII),
                        "Space committed raw English instead of the displayed Chinese candidate")
            controller.deactivateServer(client)
        }
        for editDuringRecovery in [false, true] {
            var localSettings = settings
            localSettings.english = false; localSettings.translationEnabled = true; localSettings.provider = .apple
            let client = InputClient(), service = ControllerAppleFixture()
            let controller = InputController()
            controller.testSettings = localSettings
            controller.testSetTranslator(MacTranslator(learnedURL: nil, appleServiceFactory: { service },
                appleAvailability: { _, _ in .installed }))
            controller.activateServer(client)
            key(controller, client, "nihao")
            try await wait { controller.testTranslationStatus == "正在恢复本机翻译…" }
            try require(!controller.testState.candidates.isEmpty && !controller.testTranslationCanRetry,
                        "First Apple failure hid candidates or prematurely required a manual retry")
            if editDuringRecovery { key(controller, client, "shijie") }
            try await wait { !controller.testIsTranslating && !controller.testTranslations.isEmpty }
            try require(controller.testTranslationStatus.isEmpty && !controller.testTranslationCanRetry && service.calls == 2,
                        "Recovered Apple translations did not finish cleanly")
            try require(controller.testState.input == (editDuringRecovery ? "nihaoshijie" : "nihao"),
                        "Local recovery restored an obsolete spelling")
            let selected = controller.testState.candidates[controller.testState.selected].text
            try require(controller.testTranslations[selected] == "Recovered", "Current candidate has no recovered translation")
            controller.deactivateServer(client)
        }
        // User-reported ordinary spellings must survive per-key refresh and
        // commit through the real Rime selection path, with fuzzy matching on.
        for (raw, target) in [("fasheng", "发生"), ("fasheng", "发声"), ("da", "大"), ("da", "打"),
                              ("weism", "为什么"), ("huangesaidao", "换个赛道"),
                              ("zhongwnecihui", "中文词汇"), ("zhomgwencihui", "中文词汇"), ("zhongwencihui", "中文词汇"), ("wne", "文"), ("nihaoo", "你好"),
                              ("zhongwenncihui", "中文词汇"), ("zhongwencihi", "中文词汇"), ("zhomgwnecihui", "中文词汇"),
                              ("woxuezhomgwnecihui", "我学中文词汇"), ("woaibeijinhdaxeu", "我爱北京大学")] {
            for slow in [false, true] {
                settings.fuzzyPinyinOptions = .all
                let (controller, client) = session()
                for letter in raw {
                    key(controller, client, String(letter))
                    if slow { try await Task.sleep(for: .milliseconds(40)) }
                }
                try await wait { controller.testState.visible.contains { $0.text == target } }
                if ["weism", "huangesaidao"].contains(raw) {
                    try require(controller.testState.visible.first?.text == target, "Expected \(target) first for \(raw)")
                }
                if ["zhomgwencihui", "zhongwnecihui", "zhomgwnecihui", "woxuezhomgwnecihui", "woaibeijinhdaxeu"].contains(raw) {
                    try require(controller.testState.visible.first?.text == target, "Typo correction must be first")
                    try require(!controller.testState.candidates.contains { $0.text == "中文了词汇" || $0.text == "中文呢词汇" }, "Extra-syllable sentence survived correction")
                }
                let index = controller.testState.visible.firstIndex { $0.text == target }!
                if index == 0 { key(controller, client, " ", code: 49) }
                else { controller.testClickCandidate(index) }
                try await wait { client.marked.isEmpty }
                try require(client.committed == "前文" + target, "Reported spelling failed to commit: \(raw) → \(target)")
                controller.deactivateServer(client)
            }
        }
        for (raw, matches) in [("zhomgwnecih", ["中文词汇"]), ("bushi", ["不是"]),
                                ("zihao", ["自豪", "字号"]), ("zhihao", ["只好"]),
                                ("iphone", ["iphone"]), ("jiandanlaishio", ["简单来说"]),
                                ("yibanlaishio", ["一般来说"]), ("nihaoa", ["你好啊"]),
                                ("shioba", ["说吧"]), ("nishioba", ["你说吧"]), ("shi'o'ba", ["是哦吧"]),
                                ("youdiogaoxing", ["有多高兴"]),
                                ("qingchulimshiwenjian", ["清楚临时文件"]),
                                ("shanchulimshiwenjian", ["删除临时文件"]),
                                ("zhegexiaofuohenhao", ["这个小火很好", "这个小伙很好"])] {
            // Full fuzzy matching still favors another segmentation for this input.
            settings.fuzzyPinyinOptions = raw == "shanchulimshiwenjian" ? [] : .all
            let (controller, client) = session()
            if raw.contains("'") {
                for letter in raw { key(controller, client, String(letter)) }
            } else {
                key(controller, client, raw)
            }
            try await wait({ controller.testState.input == raw && !controller.testState.visible.isEmpty },
                           diagnostics: { "Expected \(raw), got \(controller.testState.input)" })
            let first = controller.testState.visible.first?.text ?? ""
            try require(matches.contains(first), "Unexpected first candidate for \(raw): \(first)")
            key(controller, client, " ", code: 49)
            try await wait { client.marked.isEmpty }
            try require(client.committed == "前文" + first, "First candidate did not consume all of \(raw)")
            controller.deactivateServer(client)
        }
        print("PASS: native InputController scenarios, including exact Pinyin ranking, mixed input and sentence correction")
    }
}
