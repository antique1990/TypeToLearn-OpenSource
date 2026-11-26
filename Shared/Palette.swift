import SwiftUI

enum Palette {
    // White badge text retains contrast in both appearance modes.
    static let offerRed = Color(red: 0.76, green: 0.12, blue: 0.16)
    static let accent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.37, green: 0.85, blue: 0.76, alpha: 1)
            : UIColor(red: 0.02, green: 0.39, blue: 0.35, alpha: 1)
    })
    static let background = Color(uiColor: .systemGroupedBackground)
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    static let keyUIColor = UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 0.40, alpha: 1) : .white
    }
    static let key = Color(uiColor: keyUIColor)
    static let keyboardBackground = Color(uiColor: .systemGray5)
    static let modifierKey = key
    static let secondary = Color(uiColor: .secondaryLabel)
}
