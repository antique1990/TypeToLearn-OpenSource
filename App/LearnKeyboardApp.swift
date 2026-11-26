import SwiftUI

@main
struct LearnKeyboardApp: App {
    var body: some Scene {
        WindowGroup {
            AppRootView().tint(Palette.accent)
                .onAppear {
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--physical-device-ui-test") {
                        UIApplication.shared.isIdleTimerDisabled = true
                    }
                    #endif
                }
        }
    }
}
