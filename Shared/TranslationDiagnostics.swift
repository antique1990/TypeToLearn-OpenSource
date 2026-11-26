import Foundation
import OSLog

/// Only framework metadata; never persist the user's candidate or clipboard text.
enum TranslationDiagnostics {
    static func record(error: any Error, source: String, target: String, fullAccess: Bool? = nil) {
        let ns = error as NSError
        let detail = "source=\(source) target=\(target) domain=\(ns.domain) code=\(ns.code) fullAccess=\(fullAccess.map(String.init) ?? "app")"
        Logger(subsystem: "com.learnkeyboard.app", category: "Translation").error("\(detail, privacy: .public)")
        #if DEBUG
        if let container = SharedSettings.container {
            try? Data(detail.utf8).write(to: container.appendingPathComponent("Library/translation-diagnostic.txt"), options: .atomic)
        }
        #endif
    }
}
