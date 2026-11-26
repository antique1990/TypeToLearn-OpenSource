import AppKit
import SwiftUI
import KeyboardCore
import DesktopCore

@main struct VisualChecks {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cases: [(String, [String], [String], Bool)] = [
            ("single-word", ["国际化", "特征", "不可理解", "发展", "信息"], ["internationalization", "characteristics", "incomprehensibility", "development", "information"], true),
            ("short", ["你好", "你好吗", "你", "拟", "呢"], ["Hello", "How are you?", "You", "To draft", "A question particle"], true),
            ("long", ["你去哪里", "很高兴认识你", "我们明天再见", "今天愉快", "明天"], ["Where are you going after finishing your work today?", "I am very pleased to meet you and look forward to working with you.", "We will see each other again tomorrow.", "Have a wonderful day and enjoy your time with your friends.", "Tomorrow"], true),
            ("chinese-only", ["你好", "你好吗", "你", "拟", "呢"], [], false)
        ]
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            NSApp.appearance = NSAppearance(named: appearance)
            for (name, words, english, enabled) in cases {
                let candidates = words.map { Candidate(text: $0, reading: "", consumed: 1) }
                let translations = Dictionary(uniqueKeysWithValues: zip(words, english).map { ($0.0, $0.1) })
                let maximum = CandidateMetrics.maximumCellWidth(availableWidth: 700, candidateCount: candidates.count)
                let widths = candidates.map { Double(CandidateMetrics.width($0, translation: translations[$0.text], maximum: maximum) + 2) }
                var state = DesktopComposition(); state.append("n")
                state.publish(candidates, generation: state.generation)
                state.paginate(widths: widths, availableWidth: 700)
                let view = NSHostingView(rootView: CandidateView(input: "nihao", values: state.visible, translations: translations,
                    selected: 0, status: "", translationEnabled: enabled, style: .horizontal, maximumCellWidth: maximum,
                    canPrevious: false, canNext: state.canPageForward, highlight: {_ in}, choose: {_ in}, page: {_ in}))
                view.appearance = NSApp.appearance
                view.frame = NSRect(origin: .zero, size: view.fittingSize)
                view.layoutSubtreeIfNeeded()
                precondition(view.frame.height == (enabled ? 68 : 36))
                precondition(view.frame.width <= 780)
                precondition(state.visible.count >= 4)
                for candidate in state.visible {
                    let text = translations[candidate.text] ?? ""
                    let width = CandidateMetrics.width(candidate, translation: text, maximum: maximum) - 28
                    let size = CandidateMetrics.fittedTranslationSize(text, width: width)
                    precondition(CandidateMetrics.height(text, width: width, size: size) <= CandidateMetrics.twoLines(size: size))
                    if CandidateMetrics.isSingleWord(text) {
                        precondition((text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size)]).width <= width)
                    }
                }
                let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("\(name)-\(appearance.rawValue).png"))
                print(name, appearance.rawValue, view.frame.size, "visible candidates", state.visible.count)
            }
            let catalog = DesktopCandidateCatalog()
            let translatedWords = ["是", "时", "十", "事", "使", "市", "式", "识", "师", "诗", "石", "世"]
            let translatedCandidates = translatedWords.map { Candidate(text: $0, reading: "shi", consumed: 3) }
            let translatedValues = Dictionary(uniqueKeysWithValues: zip(translatedWords,
                ["Yes", "Time", "Ten", "Matter", "Make", "City", "Style", "Know", "Teacher", "Poem", "Stone", "World"]))
            let translatedView = NSHostingView(rootView: CandidateView(input: "shi", values: translatedCandidates,
                translations: translatedValues, selected: 0, status: "", translationEnabled: true,
                style: .horizontal, maximumCellWidth: 140, canPrevious: false, canNext: true,
                highlight: {_ in}, choose: {_ in}, page: {_ in}, expanded: true, categoriesVisible: true))
            translatedView.appearance = NSApp.appearance
            translatedView.frame = NSRect(origin: .zero, size: translatedView.fittingSize)
            translatedView.layoutSubtreeIfNeeded()
            precondition(translatedView.frame.width <= 360 && translatedView.frame.height <= 260)
            let translatedBitmap = translatedView.bitmapImageRepForCachingDisplay(in: translatedView.bounds)!
            translatedView.cacheDisplay(in: translatedView.bounds, to: translatedBitmap)
            try translatedBitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("expanded-translated-\(appearance.rawValue).png"))
            print("expanded-translated", appearance.rawValue, translatedView.frame.size)
            let waitingView = NSHostingView(rootView: CandidateView(input: "shi", values: Array(translatedCandidates.prefix(4)),
                translations: [:], selected: 0, status: "", translationEnabled: true,
                style: .horizontal, maximumCellWidth: 140, canPrevious: false, canNext: true,
                highlight: {_ in}, choose: {_ in}, page: {_ in}, translating: true))
            let window = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: 400, height: 68),
                styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = waitingView
            waitingView.frame = NSRect(origin: .zero, size: waitingView.fittingSize)
            waitingView.layoutSubtreeIfNeeded()
            func indicators(in view: NSView) -> [CandidateTypingNSView] {
                (view as? CandidateTypingNSView).map { [$0] } ?? view.subviews.flatMap { indicators(in: $0) }
            }
            let activeIndicators = indicators(in: waitingView).filter { !$0.isHidden }
            precondition(activeIndicators.count == 1, "Only the leading untranslated candidate owns the Typing indicator")
            let dots = activeIndicators[0].layer?.sublayers ?? []
            precondition(dots.count == 3)
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                precondition(dots.allSatisfy { $0.animation(forKey: "typing") != nil })
            }
            let waitingBitmap = waitingView.bitmapImageRepForCachingDisplay(in: waitingView.bounds)!
            waitingView.cacheDisplay(in: waitingView.bounds, to: waitingBitmap)
            try waitingBitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("typing-\(appearance.rawValue).png"))
            activeIndicators[0].update(loading: false, color: .secondaryLabelColor)
            precondition(dots.allSatisfy { $0.animation(forKey: "typing") == nil })
            print("typing animation", appearance.rawValue, "three native layers; starts/stops correctly")
            let base = ["时", "十", "是", "石", "事", "识", "式", "市"].map { Candidate(text: $0, reading: "shi", consumed: 3) }
            for category in DesktopCandidateCategory.allCases {
                let input = category == .decomposition ? "jiji" : "shi"
                let values = Array(catalog.candidates(from: base, input: input, category: category).prefix(8))
                let view = NSHostingView(rootView: CandidateView(input: input, values: values, translations: [:],
                    selected: 0, status: "", translationEnabled: false, style: .horizontal, maximumCellWidth: 173,
                    canPrevious: false, canNext: true, highlight: {_ in}, choose: {_ in}, page: {_ in},
                    expanded: true, category: category, categoriesVisible: true,
                    categoryDetail: values.first.flatMap { catalog.annotation(for: $0.text, category: category) } ?? "",
                    emojiGroups: catalog.emojiCategories))
                view.appearance = NSApp.appearance
                view.frame = NSRect(origin: .zero, size: view.fittingSize)
                view.layoutSubtreeIfNeeded()
                let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("category-\(category.id)-\(appearance.rawValue).png"))
                precondition(view.frame.height < 180 && view.frame.width <= 360,
                             "Short candidates must use a compact content-sized expanded panel")
                print(category.title, appearance.rawValue, view.frame.size)
            }
        }
    }
}
