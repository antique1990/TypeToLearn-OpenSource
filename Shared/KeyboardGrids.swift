import SwiftUI

enum KeyboardLetterMetrics {
    // The built-in iPhone keyboard uses 45-point faces on a 56-point pitch.
    static let keyHeight: CGFloat = 45
    static let rowSpacing: CGFloat = 11
    static let headerSpacing: CGFloat = 8
    static let topInset: CGFloat = 4
    static let bottomInset: CGFloat = 8
    static let keySpacing: CGFloat = 6
    static let modifierSpacing: CGFloat = 12
    static let horizontalInset: CGFloat = 6
    static let middleRowInset: CGFloat = 14
    static let middleRowEdgeHitPadding = (horizontalInset + middleRowInset) / 2
    static let horizontalHitPadding = keySpacing / 2
    static let verticalHitPadding = rowSpacing / 2
    static let touchHeight = keyHeight + rowSpacing
    static let gridHeight = keyHeight * 3 + rowSpacing * 2
    static let keyboardHeight: CGFloat = topInset + 44 + headerSpacing + gridHeight + rowSpacing + keyHeight + bottomInset
}

/// One set of row geometry for the input extension and the in-app demonstration.
struct KeyboardLetterGrid<Key: View, Leading: View, Trailing: View>: View {
    @ViewBuilder var key: (Character, EdgeInsets) -> Key
    @ViewBuilder var leading: (EdgeInsets) -> Leading
    @ViewBuilder var trailing: (EdgeInsets) -> Trailing

    var body: some View {
        GeometryReader { geometry in
            // Bottom-row letters match the top row; modifiers share the remaining width.
            let letterWidth = (geometry.size.width - KeyboardLetterMetrics.keySpacing * 9) / 10
            let modifierWidth = (geometry.size.width - letterWidth * 7
                - KeyboardLetterMetrics.keySpacing * 6 - KeyboardLetterMetrics.modifierSpacing * 2) / 2
            let middleLetterWidth = (geometry.size.width - KeyboardLetterMetrics.middleRowInset * 2
                - KeyboardLetterMetrics.keySpacing * 8) / 9
            VStack(spacing: 0) {
                ForEach(Array(["qwertyuiop", "asdfghjkl", "zxcvbnm"].enumerated()), id: \.offset) { index, row in
                    HStack(spacing: 0) {
                        if index == 2 {
                            leading(EdgeInsets(top: KeyboardLetterMetrics.verticalHitPadding,
                                               leading: KeyboardLetterMetrics.horizontalHitPadding,
                                               bottom: KeyboardLetterMetrics.verticalHitPadding,
                                               trailing: KeyboardLetterMetrics.modifierSpacing / 2))
                                .frame(width: modifierWidth + KeyboardLetterMetrics.horizontalHitPadding + KeyboardLetterMetrics.modifierSpacing / 2,
                                       height: KeyboardLetterMetrics.touchHeight)
                        }
                        ForEach(Array(row), id: \.self) { char in
                            let insets = EdgeInsets(
                                top: KeyboardLetterMetrics.verticalHitPadding,
                                leading: char == "a" ? KeyboardLetterMetrics.middleRowEdgeHitPadding :
                                    (char == "z" ? KeyboardLetterMetrics.modifierSpacing / 2 : KeyboardLetterMetrics.horizontalHitPadding),
                                bottom: KeyboardLetterMetrics.verticalHitPadding,
                                trailing: char == "l" ? KeyboardLetterMetrics.middleRowEdgeHitPadding :
                                    (char == "m" ? KeyboardLetterMetrics.modifierSpacing / 2 : KeyboardLetterMetrics.horizontalHitPadding))
                            key(char, insets).frame(maxWidth: .infinity)
                                .frame(width: index == 0 ? nil : (index == 1 ? middleLetterWidth : letterWidth) + insets.leading + insets.trailing,
                                       height: KeyboardLetterMetrics.touchHeight)
                        }
                        if index == 2 {
                            trailing(EdgeInsets(top: KeyboardLetterMetrics.verticalHitPadding,
                                                leading: KeyboardLetterMetrics.modifierSpacing / 2,
                                                bottom: KeyboardLetterMetrics.verticalHitPadding,
                                                trailing: KeyboardLetterMetrics.horizontalHitPadding))
                                .frame(width: modifierWidth + KeyboardLetterMetrics.modifierSpacing / 2 + KeyboardLetterMetrics.horizontalHitPadding,
                                       height: KeyboardLetterMetrics.touchHeight)
                        }
                    }
                    .padding(.horizontal, index == 1 ? KeyboardLetterMetrics.middleRowInset
                        - (KeyboardLetterMetrics.middleRowEdgeHitPadding - KeyboardLetterMetrics.horizontalHitPadding) : 0)
                    .frame(height: KeyboardLetterMetrics.touchHeight)
                }
            }
            // Adjacent native buttons meet at each gap's midpoint; only their faces are inset.
            .padding(.horizontal, -KeyboardLetterMetrics.horizontalHitPadding)
            .padding(.vertical, -KeyboardLetterMetrics.verticalHitPadding)
        }.frame(height: KeyboardLetterMetrics.gridHeight)
    }
}

struct KeyboardNineKeyGrid<Key: View, Trailing: View>: View {
    @ViewBuilder var key: (String, Int, CGFloat) -> Key
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 6) {
            VStack(spacing: 2) {
                ForEach(["，", "。", "？", "…"], id: \.self) { key($0, 0, 35) }
            }.frame(maxWidth: 44)
            VStack(spacing: 8) {
                ForEach(0..<3) { row in
                    HStack(spacing: 6) {
                        ForEach(0..<3) { col in
                            let number = row * 3 + col + 1
                            key(["", "，。?!", "ABC", "DEF", "GHI", "JKL", "MNO", "PQRS", "TUV", "WXYZ"][number], number, 44)
                        }
                    }
                }
            }
            trailing().frame(maxWidth: 48)
        }.frame(height: 148)
    }
}
