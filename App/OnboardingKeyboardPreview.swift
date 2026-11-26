import KeyboardCore
import SwiftUI

/// Uses the extension's actual key controls and row geometry. Samples are local,
/// so previewing a language never starts or implies completion of a download.
struct KeyboardPreview: View {
    let settings: KeyboardSettings
    let targetID: String?
    let locale: OnboardingLocale
    var revision = 0
    var identifier = "onboarding.preview"
    var allowsEnglishSwitch = false
    var showcaseLanguageIDs: [String] = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var sample = 0
    @State private var showcaseTarget: String?
    @State private var typed = ""
    @State private var committed = false
    @State private var highlighted: Character?
    @State private var paused = false
    @State private var visible = true
    @State private var englishOverride = false

    private var english: Bool { settings.audience.isEnglishOnly || englishOverride }
    private var cangjie: Bool { !english && settings.layout == .cangjie }
    private var target: String? { englishOverride ? settings.englishTargetLanguageID : (targetID ?? showcaseTarget) }
    private var source: String { KeyboardDemo.source(sample, english: english, script: settings.script, cangjie: cangjie) }
    private var input: String { KeyboardDemo.input(sample, english: english, layout: settings.layout) }
    private var translation: String { target.flatMap { KeyboardDemo.translation(sample, language: $0, cangjie: cangjie) } ?? "" }
    private var words: [String] { KeyboardDemo.candidates(sample, english: english, script: settings.script, cangjie: cangjie) }
    private var headerHeight: CGFloat { settings.wrapCandidateTranslations ? 60 : 44 }
    private var selectionID: String { "\(settings.audience)|\(settings.layout)|\(settings.script)|\(targetID ?? "")|\(revision)|\(english)" }
    private var animationID: String { "\(selectionID)|\(target ?? "")|\(sample)|\(paused)|\(reduceMotion)|\(scenePhase)|\(visible)" }
    private func t(_ s: String, _ h: String, _ e: String) -> String { locale.text(s, h, e) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(t("键盘预览", "鍵盤預覽", "Keyboard preview")).font(.caption.weight(.semibold))
                    Text(target.map { Locale(identifier: locale.rawValue).localizedString(forIdentifier: $0) ?? $0 }
                         ?? t("选择语言查看译文", "選擇語言查看譯文", "Choose a language to preview"))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        .accessibilityIdentifier(identifier + ".language")
                }
                Spacer(minLength: 0)
                Text("\(sample + 1)/\(KeyboardDemo.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .accessibilityIdentifier(identifier + ".position")
                Button { if reduceMotion { advanceSample() } else { paused.toggle() } } label: {
                    Image(systemName: paused || reduceMotion ? "play.fill" : "pause.fill").font(.system(size: 13))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(reduceMotion ? t("下一个示例", "下一個示例", "Next example") : t("暂停或继续预览", "暫停或繼續預覽", "Pause or resume preview"))
                .accessibilityIdentifier(identifier + ".replay")
                Button { advanceSample() } label: {
                    Image(systemName: "forward.end.fill").font(.system(size: 13)).frame(width: 44, height: 44)
                }
                .accessibilityLabel(t("下一个示例", "下一個示例", "Next example"))
                .accessibilityIdentifier(identifier + ".next")
            }.padding(.horizontal, 12)
            HStack {
                Text(committed ? source : (displayInput.isEmpty ? " " : displayInput))
                    .font(.system(size: 18)).lineLimit(1)
                    .accessibilityIdentifier(identifier + ".input")
                Spacer()
                Text(t("示例", "示例", "Sample")).font(.caption2).foregroundStyle(.tertiary)
            }.padding(.horizontal, 12).padding(.bottom, 12)

            VStack(spacing: KeyboardLetterMetrics.headerSpacing) {
                candidateStrip
                VStack(spacing: usesLetterLayout ? KeyboardLetterMetrics.rowSpacing : 8) {
                    if usesLetterLayout { letterKeys }
                    else { nineKeys }
                    bottomRow
                }
            }
            .padding(.horizontal, KeyboardLetterMetrics.horizontalInset).padding(.vertical, 4)
            .background(Palette.keyboardBackground)
            .tint(.blue)
        }
        .background(Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .buttonStyle(.plain)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
        .onAppear { chooseShowcaseLanguage() }
        .onChange(of: showcaseLanguageIDs) { _, _ in chooseShowcaseLanguage() }
        .onChange(of: selectionID) { _, _ in sample = 0; typed = paused ? input : ""; committed = paused }
        .onChange(of: sample) { _, _ in if paused { typed = input; committed = true } }
        .onChange(of: settings.audience) { _, _ in englishOverride = false }
        .onScrollVisibilityChange(threshold: 0.2) { visible = $0 }
        .task(id: animationID) {
            highlighted = nil
            guard visible, scenePhase == .active else { return }
            if reduceMotion { typed = input; committed = true; return }
            guard !paused else { return }
            typed = ""
            committed = false
            do {
                try await Task.sleep(for: .milliseconds(300))
                for letter in input {
                    try Task.checkCancellation()
                    highlighted = letter
                    typed.append(letter)
                    try await Task.sleep(for: .milliseconds(140))
                }
                highlighted = nil
                try await Task.sleep(for: .seconds(3))
                committed = true
                try await Task.sleep(for: .seconds(1))
                advanceSample()
            } catch { /* A different selection, hidden view or background cancels playback. */ }
        }
    }

    private var displayInput: String {
        KeyboardDemo.displayInput(typed, sample: sample, english: english, layout: settings.layout)
    }

    private var candidateStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                ForEach(Array(words.enumerated()), id: \.offset) { offset, word in
                    CandidateTouchKey(text: word, identity: "\(offset)", subtitle: subtitle(word, offset: offset),
                                      highlighted: offset == 0, wrapSubtitle: settings.wrapCandidateTranslations,
                                      audience: settings.audience, tap: { paused = true; typed = word; committed = offset == 0 },
                                      longPress: {}, identifierPrefix: identifier + ".candidate")
                        .frame(width: max(72, min(320, CGFloat(word.count) * 20 + 24)), height: headerHeight)
                }
            }
        }
        .scrollIndicators(.hidden).scrollEdgeEffectHidden()
        .frame(height: headerHeight)
        .id(selectionID + "|\(sample)")
        .accessibilityIdentifier(identifier + ".candidates")
    }

    private func chooseShowcaseLanguage() {
        guard targetID == nil, !showcaseLanguageIDs.isEmpty else { return }
        let choices = showcaseLanguageIDs.filter { $0 != showcaseTarget }
        showcaseTarget = (choices.isEmpty ? showcaseLanguageIDs : choices).randomElement()
    }

    private func advanceSample() {
        sample = (sample + 1) % KeyboardDemo.count
        if targetID == nil { chooseShowcaseLanguage() }
    }

    private func subtitle(_ word: String, offset: Int) -> String {
        guard settings.translationEnabled, let target else { return "" }
        return KeyboardDemo.candidateTranslation(word, language: target, english: english, script: settings.script) ?? ""
    }

    private var letterKeys: some View {
        KeyboardLetterGrid { char, insets in
            LetterKey(title: cangjie ? String(KeyCoding.cangjieRoots[char] ?? char) : String(char),
                      hint: cangjie ? String(char).uppercased() : nil, faceInsets: insets, action: {})
                .overlay(RoundedRectangle(cornerRadius: 6).fill(Color.blue.opacity(highlighted == char ? 0.18 : 0)).padding(insets))
        } leading: { insets in
            if english { icon("shift", height: KeyboardLetterMetrics.keyHeight, faceInsets: insets) }
            else { key("'", hint: "分隔", height: KeyboardLetterMetrics.keyHeight).padding(insets).opacity(cangjie ? 0.5 : 1) }
        } trailing: { insets in icon("delete.left", height: KeyboardLetterMetrics.keyHeight, faceInsets: insets) }
        .allowsHitTesting(false).accessibilityHidden(true)
    }

    private var nineKeys: some View {
        KeyboardNineKeyGrid { title, number, height in
            key(title, height: height)
                .overlay(RoundedRectangle(cornerRadius: 6).fill(Color.blue.opacity(String(number) == highlighted.map(String.init) ? 0.18 : 0)))
        } trailing: {
            VStack(spacing: 8) {
                icon("delete.left")
                key("符号")
                key("分词")
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }

    private var usesLetterLayout: Bool { english || settings.layout != .nineKey }

    private var bottomRow: some View {
        let height = usesLetterLayout ? KeyboardLetterMetrics.keyHeight : 44
        return HStack(spacing: 6) {
            key("123", height: height).frame(maxWidth: 56)
            if settings.audience.isEnglishOnly { icon("face.smiling", height: height).frame(maxWidth: 44).accessibilityHidden(true) }
            else {
                Button { if allowsEnglishSwitch { englishOverride.toggle() } } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text(english ? "EN" : "中").font(.system(size: 16))
                        Text(english ? "中" : "en").font(.system(size: 9))
                    }.frame(maxWidth: .infinity, minHeight: height)
                        .background(Palette.key, in: RoundedRectangle(cornerRadius: 6))
                }
                .foregroundStyle(.primary).frame(maxWidth: 44)
                .accessibilityLabel(t("切换中英文预览", "切換中英文預覽", "Switch preview input language"))
                .accessibilityIdentifier(identifier + ".mode")
                .accessibilityHidden(!allowsEnglishSwitch)
            }
            Text(committed ? (settings.audience.isEnglishOnly ? "space" : "空格") : (settings.audience.isEnglishOnly ? "Select" : "选定"))
                .font(.system(size: 17)).frame(maxWidth: .infinity).frame(height: height)
                .background(Palette.key, in: RoundedRectangle(cornerRadius: 6)).accessibilityHidden(true)
            key(english ? ",." : "，。", height: height).frame(maxWidth: 44)
            icon("return", accented: true, height: height).frame(maxWidth: 60).accessibilityHidden(true)
        }.frame(height: height)
    }

    private func key(_ title: String, hint: String? = nil, height: CGFloat = 44) -> some View {
        VStack(spacing: 0) {
            Text(title).font(.system(size: title.count > 2 ? 16 : 20)).lineLimit(1).minimumScaleFactor(0.7)
            if let hint { Text(hint).font(.system(size: 9)) }
        }.frame(maxWidth: .infinity).frame(height: height)
            .background(Palette.key, in: RoundedRectangle(cornerRadius: 6)).accessibilityHidden(true)
    }

    private func icon(_ name: String, accented: Bool = false, height: CGFloat = 44,
                      faceInsets: EdgeInsets = EdgeInsets()) -> some View {
        Image(systemName: name).font(.system(size: 19))
            .frame(maxWidth: .infinity).frame(height: height)
            .foregroundStyle(accented ? Color.white : Color.primary)
            .background(accented ? Color.blue : Palette.key, in: RoundedRectangle(cornerRadius: 6))
            .padding(faceInsets)
    }
}
