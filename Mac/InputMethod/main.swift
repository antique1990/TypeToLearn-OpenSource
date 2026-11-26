import AppKit
import InputMethodKit

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
Task { @MainActor in
    InputController.prepareCandidateResources()
    MacCandidateLookup.prepareEnglishService()
}
let server = IMKServer(name: Bundle.main.object(forInfoDictionaryKey: "InputMethodConnectionName") as? String,
                       bundleIdentifier: Bundle.main.bundleIdentifier)
application.run()
