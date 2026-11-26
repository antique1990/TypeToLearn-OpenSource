import Foundation
import Translation
import DesktopCore

enum MacKeychain {
    static func load() throws -> String? { throw RecoveryFailure(message: "Unexpected Keychain access") }
}
struct RecoveryFailure: Error { let message: String }

@MainActor private final class LocalFixture: MacAppleTranslationService {
    enum Mode { case cold, partial, empty, alwaysFail, missing, unsupported }
    let mode: Mode
    var calls: [[String]] = []
    var resets = 0
    var values: [String: String] = [:]
    init(_ mode: Mode) { self.mode = mode }
    func translate(_ texts: [String], sourceID: String, targetID: String,
                   onTranslation: (@MainActor (String, String) -> Void)?) async throws -> [String: String] {
        calls.append(texts)
        if mode == .missing { throw TranslationService.Failure.notInstalled }
        if mode == .unsupported { throw TranslationService.Failure.unsupported }
        if calls.count == 1 || mode == .alwaysFail || resets == 0 {
            if mode == .partial {
                values["你好"] = "Hello"; onTranslation?("你好", "Hello")
                return ["你好": "Hello"]
            }
            if mode == .empty { return [:] }
            // Actual physical-Mac error captured after idle at 19:38.
            throw NSError(domain: "TranslationErrorDomain", code: 16)
        }
        var result: [String: String] = [:]
        for text in texts {
            let value = text == "你好" ? "Hello" : "World"
            values[text] = value; result[text] = value; onTranslation?(text, value)
        }
        return result
    }
    func cached(_ texts: [String], sourceID: String, targetID: String) -> [String: String] {
        values.filter { texts.contains($0.key) }
    }
    func cancel() { resets += 1 }
    func releaseResources() { cancel(); values = [:] }
}

@main struct LocalTranslationRecoveryChecks {
    @MainActor static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw RecoveryFailure(message: message) }
    }
    @MainActor static func main() async throws {
        var settings = DesktopSettings()
        settings.provider = .apple; settings.translationEnabled = true
        for mode in [LocalFixture.Mode.cold, .partial, .empty] {
            let service = LocalFixture(mode)
            let translator = MacTranslator(learnedURL: nil, appleServiceFactory: { service }, appleAvailability: { _, _ in .installed })
            var callbacks: [String: Int] = [:]
            var recoveries = 0
            let result: [String: String]
            do {
                result = try await translator.translate(["你好", "世界"], settings: settings, onProgress: nil,
                    onLocalRecovery: { recoveries += 1 }, onTranslation: { text, _ in callbacks[text, default: 0] += 1 })
            } catch { throw RecoveryFailure(message: "Installed local service did not recover from \(mode): \(error)") }
            try require(result == ["你好": "Hello", "世界": "World"], "Recovery lost results")
            try require(service.resets == 1 && service.calls.count == 2 && recoveries == 1, "Recovery must rebuild once")
            try require(callbacks == ["你好": 1, "世界": 1], "Successful items were republished during retry")
            if mode == .partial { try require(service.calls[1] == ["世界"], "Retry sent already translated text") }
            try require(translator.cached(["你好", "世界"], settings: settings) == result, "Recovery dropped successful cache")
            print("PASS: installed \(mode) error recovers once and retains completed translations")
        }
        do {
            let service = LocalFixture(.cold)
            var checks = 0
            var recoveries = 0
            let translator = MacTranslator(learnedURL: nil, appleServiceFactory: { service }, appleAvailability: { _, _ in
                checks += 1
                // After daemon startup the package is supported before its
                // installed inventory becomes available. Never download it.
                return checks < 3 ? .supported : .installed
            })
            let result = try await translator.translate(["你好"], settings: settings, onProgress: nil,
                onLocalRecovery: { recoveries += 1 }, onTranslation: nil)
            try require(result["你好"] == "Hello" && checks == 3 && service.calls.count == 2 && recoveries == 1,
                        "A temporarily supported resource status blocked recovery")
            print("PASS: supported → supported → installed waits and recovers without another keystroke")
        }
        for mode in [LocalFixture.Mode.alwaysFail, .missing, .unsupported] {
            let service = LocalFixture(mode)
            let translator = MacTranslator(learnedURL: nil, appleServiceFactory: { service },
                appleAvailability: { _, _ in mode == .missing ? .supported : .installed })
            do {
                _ = try await translator.translate(["你好"], settings: settings)
                throw RecoveryFailure(message: "Persistent/missing/unsupported error was swallowed")
            } catch is RecoveryFailure { throw RecoveryFailure(message: "Error was swallowed") }
            catch {}
            try require(service.calls.count == (mode == .alwaysFail ? 2 : 1), "Retry limit/permanent-error policy violated: \(mode)")
            try require(service.resets == (mode == .alwaysFail ? 1 : 0), "A missing/unsupported language was rebuilt")
            print("PASS: \(mode) remains visible with bounded/no retries")
        }
        for cancelTask in [true, false] {
            let service = LocalFixture(.cold)
            var gate: CheckedContinuation<LanguageAvailability.Status, Never>?
            let translator = MacTranslator(learnedURL: nil, appleServiceFactory: { service }, appleAvailability: { _, _ in
                await withCheckedContinuation { gate = $0 }
            })
            let request = Task { @MainActor in try await translator.translate(["你好"], settings: settings) }
            for _ in 0..<2000 where gate == nil { try await Task.sleep(for: .milliseconds(1)) }
            try require(gate != nil, "Local recovery never checked resource availability")
            if cancelTask { request.cancel() } else { translator.cancelPending() }
            gate?.resume(returning: .installed)
            do {
                _ = try await request.value
                throw RecoveryFailure(message: "A cancelled local request resumed")
            } catch is CancellationError {}
            try require(service.calls.count == 1 && service.resets == (cancelTask ? 0 : 1), "Cancellation caused a fresh local session")
            print("PASS: \(cancelTask ? "typing cancellation" : "host deactivation") cannot resurrect recovery")
        }
        print("PASS: 9 local translation recovery scenarios; no network, real key or simulator")
    }
}
