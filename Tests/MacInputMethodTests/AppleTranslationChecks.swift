// Physical-Mac integration check. Requires Chinese and English language downloads;
// uses the real Apple framework, no API double or cloud key.
import Foundation
import Translation
import DesktopCore

@main
struct AppleTranslationChecks {
    @MainActor
    static func main() async throws {
        let availability = TranslationService.availability()
        let state = await availability.status(from: Locale.Language(identifier: "zh-Hans"),
                                              to: Locale.Language(identifier: "en"))
        guard state == .installed else {
            print("BLOCKED: Apple zh-Hans → en language resources are \(state), not installed. Use 下载并验证语言 in the Mac app.")
            exit(2)
        }
        var settings = DesktopSettings()
        settings.provider = .apple
        settings.translationEnabled = true
        let translator = MacTranslator(learnedURL: nil, appleAvailability: { source, target in
            let state = await TranslationService.availability().status(from: Locale.Language(identifier: source),
                to: Locale.Language(identifier: target))
            FileHandle.standardError.write(Data("Recovery availability \(source) → \(target): \(state)\n".utf8))
            return state
        })
        let words = ["你好", "世界", "学习", "谢谢"]
        var callbacks: [String: String] = [:]
        let values = try await translator.translate(words, settings: settings) { text, value in
            callbacks[text] = value
        }
        for word in words {
            guard let value = values[word], !value.isEmpty, value != word, callbacks[word] == value else {
                fatalError("Missing real Apple translation/callback for \(word)")
            }
            print("\(word) → \(value)")
        }
        translator.cancelPending()
        guard translator.cached(words, settings: settings) == values else {
            fatalError("Cancel must preserve complete translations")
        }
        translator.reset()
        let resumed = try await translator.translate(["早上好"], settings: settings)
        guard let value = resumed["早上好"], !value.isEmpty, value != "早上好" else {
            fatalError("New Apple session failed after reset")
        }
        print("早上好 → \(value)")
        var mixedCallbacks: [String: String] = [:]
        let mixed = try await translator.translate(["hello", "你好", "world", "世界", "😀", "123"], settings: settings) {
            mixedCallbacks[$0] = $1
        }
        guard let hello = mixed["hello"], hello.unicodeScalars.contains(where: { (0x3400...0x9FFF).contains($0.value) }),
              let world = mixed["world"], world.unicodeScalars.contains(where: { (0x3400...0x9FFF).contains($0.value) }),
              mixed["你好"] == values["你好"], mixed["世界"] == values["世界"],
              mixed["😀"] == nil, mixed["123"] == nil else {
            fatalError("Mixed English/Chinese candidates must translate in opposite directions and skip symbols")
        }
        guard translator.cached(["hello", "你好", "world", "世界"], settings: settings) == mixed,
              mixedCallbacks["hello"] == hello, mixedCallbacks["world"] == world else {
            fatalError("Mixed-direction cache and callbacks must preserve both directions")
        }
        print("hello → \(hello); world → \(world)")
        let tanWords = ["tan", "谈", "贪", "弹", "坦"]
        let tan = try await translator.translate(tanWords, settings: settings)
        for text in tanWords {
            guard let value = tan[text], !value.isEmpty, value != text else {
                fatalError("User tan candidate has no translation: \(text)")
            }
            print("tan candidate \(text) → \(value)")
        }
        var changedModel = settings
        changedModel.cloudModel = .qwen25_7B
        guard translator.cached(["hello", "你好"], settings: changedModel).isEmpty else {
            fatalError("A model change must invalidate the previous cache even before a settings revision update")
        }
        if let option = CommandLine.arguments.firstIndex(of: "--idle-seconds"),
           CommandLine.arguments.indices.contains(option + 1),
           let seconds = Int(CommandLine.arguments[option + 1]), seconds > 0 {
            // Match leaving the host field: preserve the process/cache, release
            // native sessions so translationd can naturally become idle.
            translator.cancelPending()
            FileHandle.standardError.write(Data("IDLE_BEGIN \(Date()) seconds=\(seconds) nativeSessionsReleased=true\n".utf8))
            try await Task.sleep(for: .seconds(seconds))
            let start = ContinuousClock.now
            let fresh = ["天空晴朗", "准备出发", "请稍等一下", "明天见"]
            var recovered = 0
            let values = try await translator.translate(fresh, settings: settings, onProgress: nil,
                onLocalRecovery: { recovered += 1 }, onTranslation: nil)
            guard fresh.allSatisfy({ values[$0]?.isEmpty == false && values[$0] != $0 }) else {
                fatalError("Long-idle physical-Mac session failed to translate uncached candidates")
            }
            FileHandle.standardError.write(Data("IDLE_PASS \(Date()) elapsed=\(start.duration(to: .now)) recoveries=\(recovered) values=\(values)\n".utf8))
        }
        print("PASS: real Apple translations, callbacks, cancellation cache, fresh session, mixed directions, symbol filtering, and model cache invalidation on this physical Mac")
    }
}
