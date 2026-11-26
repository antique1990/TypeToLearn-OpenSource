import KeyboardCore
import SwiftUI

struct KeyboardView: View {
    @ObservedObject var model: KeyboardModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var candidateMotion
    @State private var confirmClear = false
    @State private var selectedEmojiCategory = "smileys"
    @State private var emojiPage: String? = "smileys-0"
    @State private var recentEmoji = UserDefaults.standard.stringArray(forKey: "recentEmoji") ?? []
    @State private var candidateScrollResetInput: String?
    @State private var visibleCandidateSlots: [Int] = []
    @State private var expandedSection = 0
    @State private var expandedSingleGroup = 0
    private var headerHeight: CGFloat { model.settings.wrapCandidateTranslations ? 60 : 44 }
    private var typingRowSpacing: CGFloat { model.usesLetterLayout ? KeyboardLetterMetrics.rowSpacing : 8 }
    private var bottomKeyHeight: CGFloat { model.usesLetterLayout ? KeyboardLetterMetrics.keyHeight : 44 }
    private var expandedHeaderHeight: CGFloat { 44 }
    private var candidateAnimation: Animation? {
        reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.88)
    }
    private func text(_ value: String) -> String { model.text(value) }

    var body: some View {
        VStack(spacing: 8) {
            if model.showingMembership {
                membershipPanel
            } else if model.showingClipboard {
                clipboardPanel
            } else if model.showingSettings {
                settingsPanel
            } else if model.showingEmoji {
                emojiPanel
                emojiCategoryBar
            } else {
                if model.candidatesExpanded {
                    expandedCandidateBrowser
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -8)))
                } else {
                    VStack(spacing: 0) {
                        if model.activeInput.isEmpty { toolbar }
                        else { candidateStrip }
                        VStack(spacing: typingRowSpacing) {
                            if model.nineKeyNumbers { nineKeyNumberKeys }
                            else if model.symbols { symbolKeys }
                            else if !model.usesLetterLayout { nineKeys }
                            else { letterKeys }
                            if model.nineKeyNumbers { numberBottomRow }
                            else { bottomRow }
                        }.padding(.top, KeyboardLetterMetrics.headerSpacing)
                    }
                    .transition(.opacity)
                }
            }
        }
        .padding(.horizontal, KeyboardLetterMetrics.horizontalInset)
        .padding(.top, KeyboardLetterMetrics.topInset)
        .padding(.bottom, model.usesLetterLayout ? KeyboardLetterMetrics.bottomInset : 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Palette.keyboardBackground.opacity(0.01))
        .contentShape(Rectangle())
        .tint(.blue)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .environment(\.locale, Locale(identifier: model.settings.audience.interfaceLocale))
        .task {
            while !Task.isCancelled {
                model.refreshMembership()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    private var membershipPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(model.isEnglishOnly ? "Unlock learning" : "解锁学习译文", systemImage: "crown.fill")
                    .font(.headline).foregroundStyle(Palette.accent)
                Spacer()
                iconTool("keyboard", label: model.isEnglishOnly ? "Back to keyboard" : "返回键盘") { model.showingMembership = false }
            }
            Text(model.isEnglishOnly ? "Open TypeToLearn and tap the crown in the top-left corner to subscribe or restore your purchase." : "打开伴语输入法 App，点击首页左上角皇冠，即可订阅或恢复购买。")
                .font(.subheadline)
            Text(model.isEnglishOnly ? "Basic typing remains available. Learning translations need active access and a downloaded language pack." : "基础打字可以继续使用。学习译文需要有效会员和已下载的语言包。")
                .font(.footnote).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }.padding(.horizontal, 12).frame(maxHeight: .infinity, alignment: .top)
            .accessibilityIdentifier("keyboard.membership")
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            if model.english && !model.candidates.isEmpty {
                candidateStrip.frame(minWidth: 0, maxWidth: .infinity)
            } else {
                Spacer(minLength: 0)
            }
            if !model.isEnglishOnly {
                iconTool("face.smiling", label: text("表情符号")) { model.toggleEmoji() }
                    .foregroundStyle(Palette.secondary)
                    .accessibilityIdentifier("emoji.toolbar")
            }
            pasteIcon.foregroundStyle(Palette.secondary)
            if !model.isEnglishOnly {
                iconTool("keyboard", label: "切换中文输入方式") { model.cycleLayout() }
                    .foregroundStyle(Palette.secondary)
            }
            iconTool("chevron.down", label: self.text("收起键盘")) { model.onDismissKeyboard() }
                .foregroundStyle(Palette.secondary)
        }.frame(height: headerHeight)
    }

    private func iconTool(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: { model.playKeyFeedback(); action() }) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .regular))
                .frame(width: 22, height: 22)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }.buttonStyle(PressKeyStyle()).accessibilityLabel(label)
    }

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(self.text("键盘设置")).font(.headline)
                Spacer()
                iconTool("keyboard", label: self.text("返回键盘")) { model.closeSettings() }
            }
            HStack {
                Text(self.text("翻译方向"))
                Spacer()
                Text(model.directionLabel).foregroundStyle(.secondary)
            }.font(.subheadline).frame(height: 32)
            if !model.isEnglishOnly {
                Text("中文输入方式").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ForEach(KeyboardLayout.allCases) { layout in
                        Button(layout.shortTitle) { model.setLayout(layout) }
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(model.settings.layout == layout ? Palette.key : .clear,
                                        in: RoundedRectangle(cornerRadius: 8))
                            .accessibilityIdentifier("settings.layout.\(layout.rawValue)")
                    }
                }
            }
            Text(self.text("翻译语言和离线资源请在伴语输入法 App 中调整。"))
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var candidateStrip: some View {
        let displayed = model.displayCandidates
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                if displayed.isEmpty {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel(self.text("正在查找候选词"))
                        .frame(maxWidth: .infinity)
                }
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 0) {
                            ForEach(displayed.indices, id: \.self) { slot in
                                animatedCandidateButton(displayed[slot], slot: slot, expanded: false)
                                    .id(slot)
                            }
                        }.scrollTargetLayout()
                    }
                    .scrollIndicators(.hidden)
                    .scrollEdgeEffectHidden()
                    .accessibilityIdentifier("candidate.strip")
                    .onScrollTargetVisibilityChange(idType: Int.self, threshold: 0.1) {
                        [input = model.activeInput] slots in
                        visibleCandidateSlots = slots
                        model.updateVisibleCandidates(slots.compactMap { displayed.indices.contains($0) ? displayed[$0].id : nil },
                                                      input: input)
                    }
                    .onChange(of: model.activeInput) { _, input in
                        guard !input.isEmpty else { return }
                        if model.isQueryingCandidates {
                            candidateScrollResetInput = input
                        } else if !displayed.isEmpty {
                            var transaction = Transaction()
                            transaction.disablesAnimations = true
                            withTransaction(transaction) { proxy.scrollTo(0, anchor: .leading) }
                        }
                    }
                    .onChange(of: model.isQueryingCandidates) { _, querying in
                        guard !querying, candidateScrollResetInput == model.activeInput,
                              !displayed.isEmpty else { return }
                        candidateScrollResetInput = nil
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) { proxy.scrollTo(0, anchor: .leading) }
                        model.updateVisibleCandidates(Array(displayed.prefix(6).map(\.id)), input: model.activeInput)
                    }
                    .onChange(of: displayed.map(\.id)) { _, _ in
                        guard !model.isQueryingCandidates else { return }
                        let ids = visibleCandidateSlots.isEmpty ? Array(displayed.prefix(6).map(\.id)) : visibleCandidateSlots.compactMap {
                            displayed.indices.contains($0) ? displayed[$0].id : nil
                        }
                        model.updateVisibleCandidates(ids, input: model.activeInput)
                    }
                }
                if !model.english {
                    Button {
                        model.playKeyFeedback()
                        expandedSection = 0
                        expandedSingleGroup = 0
                        withAnimation(candidateAnimation) { model.toggleCandidateExpansion() }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 44, height: headerHeight)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("展开候选词")
                    .accessibilityIdentifier("candidate.expand")
                }
            }.frame(height: headerHeight)
        }
        .frame(height: headerHeight)
        .contentShape(Rectangle())
        .disabled(model.isCommitting || model.isQueryingCandidates)
    }

    private func candidateButton(_ candidate: Candidate, slot: Int, expanded: Bool = false) -> some View {
        let isEnglishCompletion = !model.english && candidate.text.unicodeScalars.allSatisfy {
            $0.isASCII && CharacterSet.letters.contains($0)
        }
        let translated = model.translations[candidate.text]
        let eligible = model.translationEligibleTexts.contains(candidate.text)
        let waiting = model.translationPlaceholder == "…"
        let subtitle = eligible ? (translated ?? (waiting ? "" : model.translationPlaceholder)) : ""
        // Only the first slot owns the indicator. Its streamed translation hides
        // it immediately, even while the other candidates are still translating.
        let loading = slot == 0 && eligible && translated == nil && waiting
        let width = isEnglishCompletion
            ? max(96, min(260, CGFloat(candidate.text.count) * 12 + 24))
            : max(72, min(320, CGFloat(candidate.text.count) * 20 + 24))
        return CandidateTouchKey(text: candidate.text, identity: candidate.text, subtitle: subtitle,
                                 highlighted: candidate == model.candidates.first,
                                 wrapSubtitle: model.settings.wrapCandidateTranslations,
                                 audience: model.settings.audience,
                                 tap: {
                                     model.playKeyFeedback()
                                     model.select(candidate)
                                 },
                                 longPress: {
                                     model.playKeyFeedback()
                                     model.selectTranslation(candidate)
                                 }, loading: loading,
                                 locked: model.settings.translationEnabled && !model.learningUnlocked,
                                 unlock: { model.showingMembership = true })
            // Stable widths prevent translation updates from moving words under the finger.
            .frame(width: expanded ? nil : width, height: expanded ? max(48, headerHeight) : headerHeight)
            .frame(maxWidth: expanded ? .infinity : nil)
    }

    @ViewBuilder
    private func animatedCandidateButton(_ candidate: Candidate, slot: Int, expanded: Bool) -> some View {
        if !reduceMotion && slot < 8 {
            candidateButton(candidate, slot: slot, expanded: expanded)
                .matchedGeometryEffect(id: candidate.id, in: candidateMotion, properties: .frame)
        } else {
            candidateButton(candidate, slot: slot, expanded: expanded)
        }
    }

    private var expandedCandidateBrowser: some View {
        let phrases = model.displayCandidates.filter { $0.text.count > 1 && !$0.text.unicodeScalars.allSatisfy(\.isASCII) }
        let englishWords = model.expandedEnglishCandidates
        let fallbackSingles = model.displayCandidates.filter { $0.text.count == 1 && !$0.text.unicodeScalars.allSatisfy(\.isASCII) }
        let groups = model.singleCandidateGroups
        let selectedGroup = groups.indices.contains(expandedSingleGroup) ? expandedSingleGroup : 0
        let items: [Candidate] = switch expandedSection {
        case 1: groups.isEmpty ? fallbackSingles : groups[selectedGroup].candidates
        case 2: englishWords
        default: phrases
        }
        return ScrollView(.vertical) {
            VStack(spacing: 2) {
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        ForEach(Array(["词组", "单字", "英文"].enumerated()), id: \.offset) { index, title in
                            Button {
                                model.playKeyFeedback()
                                withAnimation(candidateAnimation) {
                                    expandedSection = index
                                    expandedSingleGroup = 0
                                }
                            } label: {
                                Text(title)
                                    .font(.system(size: 15, weight: expandedSection == index ? .semibold : .regular))
                                    .frame(maxWidth: .infinity, minHeight: 30)
                                    .background(expandedSection == index ? Palette.key : .clear,
                                                in: Capsule())
                                    .frame(height: expandedHeaderHeight)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("candidate.category.\(index)")
                        }
                    }
                    .padding(.horizontal, 2)
                    .frame(width: geometry.size.width * 0.75, height: expandedHeaderHeight)
                    .background { Capsule().fill(Palette.key.opacity(0.35)).frame(height: 30) }
                }
                .frame(height: expandedHeaderHeight)

                HStack(alignment: .top, spacing: 4) {
                    if expandedSection == 1 && groups.count > 1 {
                        LazyVStack(spacing: 2) {
                            ForEach(groups.indices, id: \.self) { index in
                                Button {
                                    model.playKeyFeedback()
                                    withAnimation(candidateAnimation) { expandedSingleGroup = index }
                                } label: {
                                    Text(groups[index].label)
                                        .font(.system(size: 13, weight: selectedGroup == index ? .semibold : .regular))
                                        .minimumScaleFactor(0.8)
                                        .lineLimit(2)
                                        .frame(maxWidth: .infinity, minHeight: 44)
                                        .background(selectedGroup == index ? Palette.key : .clear,
                                                    in: RoundedRectangle(cornerRadius: 8))
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("candidate.single.group.\(index)")
                            }
                        }
                        .frame(width: 62)
                    }
                    VStack(spacing: 0) {
                        if expandedSection == 1 && selectedGroup > 0 && !groups[selectedGroup].isCorrection {
                            Text("请先选择 \(groups[0].label) 对应的字")
                                .font(.footnote).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                        }
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3), spacing: 2) {
                            ForEach(items.indices, id: \.self) { index in
                                animatedCandidateButton(items[index], slot: index, expanded: true)
                                    .id(index)
                                    .allowsHitTesting(expandedSection != 1 || selectedGroup == 0 || groups[selectedGroup].isCorrection)
                                    .opacity(expandedSection == 1 && selectedGroup > 0 && !groups[selectedGroup].isCorrection ? 0.55 : 1)
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .scrollIndicators(.hidden)
        .scrollEdgeEffectHidden()
        .accessibilityIdentifier("candidate.expanded.list")
        .overlay(alignment: .topTrailing) {
            Button {
                model.playKeyFeedback()
                withAnimation(candidateAnimation) { model.toggleCandidateExpansion() }
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: expandedHeaderHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(width: 44, height: expandedHeaderHeight)
            .accessibilityLabel("收起候选词")
            .accessibilityIdentifier("candidate.collapse")
        }
        .onScrollTargetVisibilityChange(idType: Int.self, threshold: 0.2) { slots in
            model.updateVisibleCandidates(slots.compactMap { items.indices.contains($0) ? items[$0].id : nil }, input: model.activeInput)
        }
        .onChange(of: items.map(\.id)) { _, _ in
            guard !model.isQueryingCandidates else { return }
            model.updateVisibleCandidates(Array(items.prefix(12).map(\.id)), input: model.activeInput)
        }
        .onChange(of: model.isQueryingCandidates) { _, querying in
            guard !querying else { return }
            model.updateVisibleCandidates(Array(items.prefix(12).map(\.id)), input: model.activeInput)
        }
        .id("\(model.activeInput)|\(expandedSection)|\(selectedGroup)")
        .onChange(of: model.activeInput) { _, _ in expandedSingleGroup = 0 }
        .frame(maxHeight: .infinity, alignment: .top)
        .disabled(model.isCommitting || model.isQueryingCandidates)
    }

    private var letterKeys: some View {
        KeyboardLetterGrid { char, insets in
            LetterKey(title: letterTitle(char), hint: rootHint(char), faceInsets: insets) {
                model.playKeyFeedback()
                model.key(String(char))
            }
        } leading: { insets in
            if model.english {
                iconKey(model.uppercase ? "shift.fill" : "shift", label: self.text("切换大小写"), height: KeyboardLetterMetrics.keyHeight, faceInsets: insets) { model.uppercase.toggle() }
            } else {
                LetterKey(title: "'", hint: "分隔", faceInsets: insets, activatesOnTouchDown: false) {
                    model.playKeyFeedback()
                    model.key("'")
                }.disabled(model.settings.layout == .cangjie)
            }
        } trailing: { insets in deleteButton(height: KeyboardLetterMetrics.keyHeight, faceInsets: insets) }
        .disabled(model.isCommitting)
    }

    private var nineKeys: some View {
        KeyboardNineKeyGrid { title, number, height in
            keyButton(title, height: height, popup: number == 0 ? title : nil) {
                if number == 0 { model.punctuation(title) }
                else if number == 1 { model.setSymbols(true) }
                else { model.key(String(number)) }
            }
        } trailing: {
            VStack(spacing: 8) {
                deleteKey.frame(height: 44)
                keyButton(self.text("符号")) { model.setSymbols(true) }
                keyButton("分词") { model.space() }
            }
        }.disabled(model.isCommitting)
    }

    private var nineKeyNumberKeys: some View {
        HStack(spacing: 6) {
            VStack(spacing: 2) {
                ForEach(["，", "。", "-", "/"], id: \.self) { mark in
                    keyButton(mark, height: 35, popup: mark) { model.punctuation(mark) }
                }
            }.frame(maxWidth: 44)
            VStack(spacing: 8) {
                ForEach(0..<3) { row in
                    HStack(spacing: 6) {
                        ForEach(0..<3) { col in
                            let digit = row * 3 + col + 1
                            keyButton(String(digit), popup: String(digit)) { model.punctuation(String(digit)) }
                        }
                    }
                }
            }
            VStack(spacing: 8) {
                deleteKey.frame(height: 44)
                keyButton(self.text("符号")) { model.setSymbols(true) }
                keyButton("#", popup: "#") { model.punctuation("#") }
            }.frame(maxWidth: 48)
        }.frame(height: 148)
    }

    private var symbolFaceInsets: EdgeInsets {
        let verticalPadding = typingRowSpacing / 2
        return EdgeInsets(top: verticalPadding, leading: KeyboardLetterMetrics.horizontalHitPadding,
                          bottom: verticalPadding, trailing: KeyboardLetterMetrics.horizontalHitPadding)
    }

    private var symbolKeys: some View {
        let insets = symbolFaceInsets
        return VStack(spacing: 0) {
            ForEach(Array(symbolRows.enumerated()), id: \.offset) { index, row in
                HStack(spacing: 0) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, symbol in
                        keyButton(symbol, height: bottomKeyHeight, faceInsets: insets, popup: symbol) { model.punctuation(symbol) }
                    }
                    if index == 2 {
                        deleteButton(height: bottomKeyHeight, faceInsets: insets)
                            .frame(maxWidth: 44 + insets.leading + insets.trailing)
                    }
                }
            }
        }
        .padding(.horizontal, -insets.leading)
        .padding(.vertical, -insets.top)
        .frame(height: model.usesLetterLayout ? KeyboardLetterMetrics.gridHeight : 148).disabled(model.isCommitting)
    }

    private var symbolRows: [[String]] {
        if model.alternateSymbols {
            return [
                ["【", "】", "{", "}", "#", "%", "^", "*", "+", "="],
                ["_", "\\", "|", "《", "》", "¥", "$", "&", "·", "'"],
                ["…", "~", "`", "?", "!", ".", "/", "<", ">"]
            ]
        }
        if model.english {
            return [Array("1234567890").map { String($0) }, Array("@#$%&-+()/").map { String($0) },
                    Array("!\"':;?.,").map { String($0) }]
        }
        return [Array("1234567890").map { String($0) }, Array("@#¥%&-+（）").map { String($0) },
                Array("，。？！：；、‘’").map { String($0) }]
    }

    private var emojiCategoryBar: some View {
        HStack(spacing: 4) {
            iconTool("keyboard", label: self.text("返回字母键盘")) { model.toggleEmoji() }
            ScrollView(.horizontal) {
                HStack(spacing: 2) {
                    emojiCategoryButton(id: "recent", title: self.text("最近使用"))
                    ForEach(EmojiCatalog.categories) { category in
                        emojiCategoryButton(id: category.id, title: category.title)
                    }
                }
            }.scrollIndicators(.hidden).scrollEdgeEffectHidden()
        }.frame(height: headerHeight)
    }

    private func emojiCategoryButton(id: String, title: String) -> some View {
        Button { selectedEmojiCategory = id; emojiPage = "\(id)-0" } label: {
            Image(systemName: emojiCategorySymbol(id))
                .font(.system(size: 20, weight: .regular))
                .foregroundColor(Color(uiColor: selectedEmojiCategory == id ? .label : .secondaryLabel))
                .frame(width: 44, height: 44)
                .background(selectedEmojiCategory == id ? Palette.key : .clear,
                            in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(text(title))
        .accessibilityIdentifier("emoji.category.\(id)")
        .accessibilityValue(selectedEmojiCategory == id ? text("已选中") : "")
    }

    private func emojiCategorySymbol(_ id: String) -> String {
        switch id {
        case "recent": "clock"
        case "smileys": "face.smiling"
        case "people": "hand.raised"
        case "component": "circle.lefthalf.filled"
        case "nature": "pawprint"
        case "food": "fork.knife"
        case "travel": "car"
        case "activities": "sportscourt"
        case "objects": "lightbulb"
        case "symbols": "heart"
        default: "flag"
        }
    }

    private struct EmojiPage: Identifiable {
        let categoryID: String
        let index: Int
        let emojis: [String]
        var id: String { "\(categoryID)-\(index)" }
    }

    private var emojiPages: [EmojiPage] {
        let groups = [("recent", recentEmoji)] + EmojiCatalog.categories.map { ($0.id, $0.emojis) }
        return groups.flatMap { id, emojis in
            (0..<max(1, (emojis.count + 31) / 32)).map { index in
                EmojiPage(categoryID: id, index: index,
                          emojis: Array(emojis.dropFirst(index * 32).prefix(32)))
            }
        }
    }

    private var emojiPanel: some View {
        GeometryReader { geometry in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(emojiPages) { page in
                        if page.emojis.isEmpty {
                            Text(self.text("还没有最近使用的表情"))
                                .font(.subheadline).foregroundStyle(.secondary)
                                .frame(width: geometry.size.width, height: geometry.size.height)
                                .id(page.id)
                        } else {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 8), spacing: 2) {
                                ForEach(Array(page.emojis.enumerated()), id: \.offset) { _, item in
                                    Button { insertEmoji(item) } label: {
                                        Text(item).font(.system(size: 26))
                                            .frame(maxWidth: .infinity, minHeight: 48)
                                    }.accessibilityLabel(model.isEnglishOnly ? "Insert emoji \(item)" : "输入表情 \(item)")
                                }
                            }
                            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
                            .id(page.id)
                        }
                    }
                }
                .scrollTargetLayout()
            }
            .scrollPosition(id: $emojiPage)
            .scrollTargetBehavior(.paging)
            .scrollIndicators(.hidden)
            .scrollEdgeEffectHidden()
            .accessibilityIdentifier("emoji.pages")
            .onChange(of: emojiPage) { _, pageID in
                guard let category = emojiPages.first(where: { $0.id == pageID })?.categoryID else { return }
                selectedEmojiCategory = category
            }
        }
        .frame(height: 200)
    }

    private func insertEmoji(_ item: String) {
        model.playKeyFeedback()
        model.insertEmoji(item)
        recentEmoji.removeAll(where: { $0 == item })
        recentEmoji.insert(item, at: 0)
        recentEmoji = Array(recentEmoji.prefix(64))
        UserDefaults.standard.set(recentEmoji, forKey: "recentEmoji")
    }

    private var bottomRow: some View {
        let insets = model.symbols ? symbolFaceInsets : EdgeInsets()
        let horizontalPadding = insets.leading + insets.trailing
        return HStack(spacing: model.symbols ? 0 : 6) {
            keyButton(model.symbols ? self.text("返回") : "123", height: bottomKeyHeight, faceInsets: insets) {
                if model.symbols { model.setSymbols(false) }
                else if model.settings.layout == .nineKey && !model.english { model.toggleNineKeyNumbers() }
                else { model.setSymbols(true) }
            }.frame(maxWidth: 56 + horizontalPadding)
            if model.symbols {
                keyButton(model.alternateSymbols ? "123" : "#+=", height: bottomKeyHeight, faceInsets: insets) {
                    model.alternateSymbols.toggle()
                }.frame(maxWidth: 48 + horizontalPadding)
            }
            if model.needsInputModeSwitchKey {
                iconKey("globe", label: self.text("切换到下一个系统键盘"), height: bottomKeyHeight, faceInsets: insets) { model.onNextKeyboard() }.frame(maxWidth: 44 + horizontalPadding)
            }
            if !model.symbols {
                if model.isEnglishOnly {
                    iconKey("face.smiling", label: text("表情符号"), height: bottomKeyHeight) { model.toggleEmoji() }
                        .accessibilityIdentifier("emoji.bottom")
                        .frame(maxWidth: 44)
                } else { modeKey.frame(maxWidth: 44) }
            }
            CursorSpaceKey(title: model.activeInput.isEmpty ? self.text("空格") : self.text("选定"),
                           audience: model.settings.audience,
                           faceInsets: insets,
                           tap: { model.playKeyFeedback(); model.space() },
                           begin: { model.playKeyFeedback(); model.beginCursorMovement() },
                           move: { model.moveCursor(by: $0) })
            if !model.symbols { punctuationKey.frame(maxWidth: 44) }
            iconKey("return", label: model.activeInput.isEmpty ? model.returnTitle : self.text("确认"), accented: true, height: bottomKeyHeight, faceInsets: insets) { model.enter() }
                .accessibilityIdentifier("key.\(model.activeInput.isEmpty ? model.returnTitle : self.text("确认"))")
                .frame(maxWidth: 60 + horizontalPadding)
        }
        .padding(.horizontal, -insets.leading)
        .padding(.vertical, -insets.top)
        .frame(height: bottomKeyHeight)
        .disabled(model.isCommitting)
        .transaction { $0.disablesAnimations = true }
    }

    private var numberBottomRow: some View {
        HStack(spacing: 6) {
            keyButton(self.text("返回")) { model.toggleNineKeyNumbers() }.frame(maxWidth: 56)
            keyButton("0", popup: "0") { model.punctuation("0") }.frame(maxWidth: 52)
            if model.needsInputModeSwitchKey {
                iconKey("globe", label: self.text("切换到下一个系统键盘")) { model.onNextKeyboard() }.frame(maxWidth: 44)
            }
            CursorSpaceKey(title: self.text("空格"), tap: { model.playKeyFeedback(); model.space() },
                           begin: { model.playKeyFeedback(); model.beginCursorMovement() },
                           move: { model.moveCursor(by: $0) })
            punctuationKey.frame(maxWidth: 44)
            iconKey("return", label: model.returnTitle, accented: true) { model.enter() }.frame(maxWidth: 60)
        }.frame(height: 44)
    }

    private var modeKey: some View {
        Button { model.playKeyFeedback(); model.toggleEnglish() } label: {
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(model.english ? "EN" : "中").font(.system(size: 16, weight: .regular))
                Text(model.english ? "中" : "en").font(.system(size: 9))
            }
            .frame(maxWidth: .infinity, minHeight: bottomKeyHeight)
            .background(Palette.modifierKey, in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(PressKeyStyle()).accessibilityLabel("切换中英文")
    }

    private var punctuationKey: some View {
        PunctuationKey(english: model.english, audience: model.settings.audience,
                       short: { model.playKeyFeedback(); model.punctuation(model.english ? "," : "，") },
                       long: { model.playKeyFeedback(); model.punctuation(model.english ? "." : "。") })
    }

    private var deleteKey: some View {
        deleteButton(height: 44)
    }

    private func deleteButton(height: CGFloat, faceInsets: EdgeInsets = EdgeInsets()) -> some View {
        RepeatingDeleteKey(audience: model.settings.audience, faceInsets: faceInsets) {
            model.playKeyFeedback(.delete)
            model.backspace()
        }.frame(height: height + faceInsets.top + faceInsets.bottom)
    }

    private func letterTitle(_ char: Character) -> String {
        if model.settings.layout == .cangjie && !model.english { return String(KeyCoding.cangjieRoots[char] ?? char) }
        return model.english && model.uppercase ? String(char).uppercased() : String(char)
    }

    private func rootHint(_ char: Character) -> String? {
        model.settings.layout == .cangjie && !model.english ? String(char).uppercased() : nil
    }

    @ViewBuilder
    private func keyButton(_ text: String, hint: String? = nil, accented: Bool = false, height: CGFloat = 44,
                           faceInsets: EdgeInsets = EdgeInsets(), popup: String? = nil, action: @escaping () -> Void) -> some View {
        if let popup {
            LetterKey(title: popup, hint: hint, faceInsets: faceInsets, activatesOnTouchDown: false) {
                model.playKeyFeedback()
                action()
            }.frame(maxWidth: .infinity).frame(height: height + faceInsets.top + faceInsets.bottom)
        } else {
            Button(action: { model.playKeyFeedback(); action() }) {
                VStack(spacing: 0) {
                    Text(text).font(.system(size: text == self.text("返回") ? 16 : (text.count > 2 ? 16 : 20), weight: .regular)).lineLimit(1).minimumScaleFactor(0.7)
                    if let hint { Text(hint).font(.system(size: 9)).lineLimit(1) }
                }
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .foregroundStyle(accented ? Color.white : Color.primary)
                .background(accented ? Color.blue : Palette.key, in: RoundedRectangle(cornerRadius: 6))
                .padding(faceInsets)
                .contentShape(Rectangle())
            }.buttonStyle(PressKeyStyle()).accessibilityIdentifier("key.\(text.lowercased())").accessibilityLabel(hint.map { "\(text)，\($0)" } ?? text)
        }
    }

    private func iconKey(_ symbol: String, label: String, accented: Bool = false, height: CGFloat = 44,
                         faceInsets: EdgeInsets = EdgeInsets(), action: @escaping () -> Void) -> some View {
        Button(action: { model.playKeyFeedback(); action() }) {
            Image(systemName: symbol).font(.system(size: 19))
                .frame(maxWidth: .infinity, minHeight: height)
                .foregroundStyle(accented ? Color.white : Color.primary)
                .background(accented ? Color.blue : Palette.modifierKey, in: RoundedRectangle(cornerRadius: 6))
                .padding(faceInsets)
                .contentShape(Rectangle())
        }.buttonStyle(PressKeyStyle()).accessibilityLabel(label)
    }

    private var clipboardPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(self.text("当前剪贴板与收藏")).font(.headline)
                Spacer()
                iconTool("keyboard", label: self.text("返回键盘")) { model.closeClipboard() }
            }
            if !model.fullAccess {
                Text(self.text("使用剪贴板需要在系统设置为伴语输入法开启「允许完全访问」。基本中文输入无需开启。"))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let status = model.status { Text(status).font(.caption).foregroundStyle(.secondary) }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if let preview = model.clipboardPreview {
                        HStack {
                            Button { model.finishComposition(suffix: preview); model.closeClipboard() } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(self.text("当前复制内容")).font(.caption).foregroundStyle(.secondary)
                                    Text(preview).font(.subheadline).lineLimit(4).foregroundStyle(.primary)
                                }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            }.accessibilityHint(self.text("点击直接粘贴"))
                            Button { model.savePreview() } label: {
                                Image(systemName: "bookmark").frame(width: 44, height: 44)
                            }.accessibilityLabel(self.text("收藏当前复制内容"))
                        }.padding(12).background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
                    }
                    if model.clips.items.isEmpty {
                        Text(self.text("暂无收藏\n点击粘贴后，可将常用文本手动留下。"))
                            .font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 12)
                    }
                    ForEach(model.clips.items) { clip in
                        HStack {
                            Button { model.finishComposition(suffix: clip.text); model.closeClipboard() } label: {
                                Text(clip.text).font(.subheadline).lineLimit(3).foregroundStyle(.primary)
                                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            }.accessibilityHint(self.text("粘贴收藏文本"))
                            Button(role: .destructive) { model.deleteClip(clip.id) } label: {
                                Image(systemName: "trash").frame(width: 44, height: 44)
                            }.accessibilityLabel(self.text("删除收藏"))
                        }.padding(8).background(Palette.surface, in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            HStack {
                Text(self.text("仅本机保存 · 不自动读取")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !model.clips.items.isEmpty {
                    Button(self.text("清空收藏"), role: .destructive) { confirmClear = true }.font(.caption).frame(minHeight: 44)
                }
            }
        }.padding(.horizontal, 8).frame(maxHeight: .infinity, alignment: .top)
        .confirmationDialog(self.text("删除全部收藏？"), isPresented: $confirmClear, titleVisibility: .visible) {
            Button(self.text("删除全部"), role: .destructive) { model.deleteAllClips() }
        }
    }

    private var pasteIcon: some View {
        Button(action: { model.playKeyFeedback(); model.openClipboard() }) {
            SingleFoldPasteIcon()
                .stroke(style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                .frame(width: 17, height: 21)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressKeyStyle())
        .accessibilityLabel(self.text("打开剪贴板"))
    }
}

/// Keep the two-sheet paste outline, with only the front sheet folded.
private struct SingleFoldPasteIcon: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        // The rear sheet has an ordinary rounded corner, visible at the right/bottom.
        path.move(to: CGPoint(x: 19, y: 5))
        path.addLine(to: CGPoint(x: 20, y: 5))
        path.addQuadCurve(to: CGPoint(x: 22, y: 7), control: CGPoint(x: 22, y: 5))
        path.addLine(to: CGPoint(x: 22, y: 20))
        path.addQuadCurve(to: CGPoint(x: 20, y: 22), control: CGPoint(x: 22, y: 22))
        path.addLine(to: CGPoint(x: 7, y: 22))
        path.addQuadCurve(to: CGPoint(x: 5, y: 20), control: CGPoint(x: 5, y: 22))
        path.addLine(to: CGPoint(x: 5, y: 19))
        // Front sheet and its single upper-left fold.
        path.move(to: CGPoint(x: 2, y: 7))
        path.addLine(to: CGPoint(x: 7, y: 2))
        path.addLine(to: CGPoint(x: 17, y: 2))
        path.addQuadCurve(to: CGPoint(x: 19, y: 4), control: CGPoint(x: 19, y: 2))
        path.addLine(to: CGPoint(x: 19, y: 17))
        path.addQuadCurve(to: CGPoint(x: 17, y: 19), control: CGPoint(x: 19, y: 19))
        path.addLine(to: CGPoint(x: 4, y: 19))
        path.addQuadCurve(to: CGPoint(x: 2, y: 17), control: CGPoint(x: 2, y: 19))
        path.closeSubpath()
        path.move(to: CGPoint(x: 2, y: 7))
        path.addLine(to: CGPoint(x: 6, y: 7))
        path.addQuadCurve(to: CGPoint(x: 7, y: 6), control: CGPoint(x: 7, y: 7))
        path.addLine(to: CGPoint(x: 7, y: 2))
        return path.applying(CGAffineTransform(a: rect.width / 24, b: 0, c: 0,
                                              d: rect.height / 24, tx: rect.minX, ty: rect.minY))
    }
}
