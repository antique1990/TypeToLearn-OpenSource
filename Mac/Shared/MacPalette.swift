import AppKit
import SwiftUI

enum MacPalette {
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.37, green: 0.85, blue: 0.76, alpha: 1)
            : NSColor(red: 0.02, green: 0.39, blue: 0.35, alpha: 1)
    })
}
