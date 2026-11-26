import KeyboardCore
import Foundation

enum SharedSettings {
    static var container: URL? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "LearnKeyboardAppGroup") as? String else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
    }

    private static var isolatedUITest: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--onboarding-test-store")
        #else
        false
        #endif
    }
    static func load() -> KeyboardSettings {
        if isolatedUITest, let data = UserDefaults.standard.data(forKey: "onboarding.test.settings"),
           let settings = try? JSONDecoder().decode(KeyboardSettings.self, from: data) { return settings }
        guard let url = container?.appendingPathComponent("settings.json"),
              let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(KeyboardSettings.self, from: data)
        else { return KeyboardSettings() }
        return settings
    }

    static func save(_ settings: KeyboardSettings) throws {
        if isolatedUITest {
            UserDefaults.standard.set(try JSONEncoder().encode(settings), forKey: "onboarding.test.settings")
            return
        }
        guard let container else { throw SettingsError.noContainer }
        var copy = settings
        copy.revision = UUID()
        let data = try JSONEncoder().encode(copy)
        try data.write(to: container.appendingPathComponent("settings.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    enum SettingsError: LocalizedError {
        case noContainer
        var errorDescription: String? { "设置未能与键盘共享。请检查应用的 App Group 签名配置。" }
    }
}
