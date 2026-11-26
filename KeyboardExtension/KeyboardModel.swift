import KeyboardCore
import SwiftUI
import UIKit

enum KeyFeedbackKind {
    case typing, delete
}

@MainActor
final class KeyboardModel: ObservableObject {
    @Published private(set) var composition = Composition()
    @Published private(set) var candidates: [Candidate] = []
    @Published var candidatesExpanded = false
    @Published private(set) var singleCandidateGroups: [SingleCandidateGroup] = []
    @Published private(set) var isQueryingCandidates = false
    @Published private(set) var translations: [String: String] = [:]
    @Published private(set) var translationEligibleTexts = Set<String>()
    @Published private(set) var settings = SharedSettings.load()
    @Published var status: String?
    @Published var translating = false
    @Published var showingMembership = false
    @Published private(set) var learningUnlocked = SharedMembership.load().hasAccess()
    @Published var showingClipboard = false
    @Published var showingSettings = false
    @Published var clipboardPreview: String?
    @Published var clips = SavedClips()
    @Published var fullAccess = false
    @Published var needsInputModeSwitchKey = false
    @Published private(set) var translationPlaceholder = ""
    @Published var english = false
    @Published private(set) var englishInput = "" {
        didSet { if englishInput.isEmpty { englishCursor = 0 } }
    }
    private var englishCursor = 0
    @Published var uppercase = false
    @Published var symbols = false
    @Published var alternateSymbols = false
    @Published var nineKeyNumbers = false
    @Published var showingEmoji = false
    @Published var isCommitting = false
    @Published var returnTitle = "换行"
    var onInsert: (String) -> Void = { _ in }
    var onDelete: () -> Void = {}
    var onCompositionChanged: (String, Int) -> Void = { _, _ in }
    var contextBeforeInput: () -> String? = { nil }
    var onNextKeyboard: () -> Void = {}
    var onDismissKeyboard: () -> Void = {}
    var onCursorMove: (Int) -> Void = { _ in }
    var onHeightNeedsUpdate: () -> Void = {}
    var usesLetterLayout: Bool { english || settings.layout != .nineKey }
    var onKeyClick: (KeyFeedbackKind) -> Void = { _ in }
    private let keyFeedback = UIImpactFeedbackGenerator(style: .light)
    private var visibleCandidateIDs = Set<String>()
    private var candidateQueryContext = ""
    private var candidateTranslationContext = ""
    private var lexicon: Lexicon?
    private lazy var translator = TranslationService(learnedURL: learnedURL)
    private lazy var segmentTranslator = TranslationService(learnedURL: learnedURL)
    private let englishChecker = UITextChecker()
    private let englishLanguageModel = EnglishLanguageModel.shared
    private var offlineEnglishWords = Set<String>()
    private var englishAutomaticReplacement: String?
    private var separateNextEnglishWord = false
    private var queryTask: Task<Void, Never>?
    private var singleQueryTask: Task<Void, Never>?
    private var segmentTranslationTask: Task<Void, Never>?
    private var segmentTranslationRoot = ""
    private var segmentTranslationContext = ""
    private var warmupTask: Task<Void, Never>?
    private var translationTask: Task<Void, Never>?
    private struct TranslationRequestKey: Hashable {
        let text: String
        let source: String
        let target: String
    }
    private var scheduledTranslations = Set<TranslationRequestKey>()
    private var commitTask: Task<Void, Never>?
    private var revision = UUID()
    private var translationRevision = UUID()
    private var sharedRevision: UUID?
    private var learningCode = ""
    private var learningText = ""
    private var learnedSegments = 0
    private var nineKeyMarkedDigits = ""
    private var nineKeyMarkedText = ""
    private var learnedURL: URL? { SharedSettings.container?.appendingPathComponent("learned-words.json") }
    private var pinyinPolicy: PinyinQueryPolicy { .mobile(fuzzy: settings.fuzzyPinyinEnabled) }
    private var clipURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("saved-clips.json")
    }

    init() {
        reloadSettings()
        if let url = clipURL, let data = try? Data(contentsOf: url), let clips = try? JSONDecoder().decode(SavedClips.self, from: data) {
            self.clips = clips
        }
    }

    private func prepareChineseLexiconIfNeeded() {
        guard lexicon == nil else { return }
        if let url = Bundle.main.url(forResource: "lexicon", withExtension: "sqlite") {
            do {
                lexicon = try Lexicon(url: url, learnedURL: learnedURL)
                status = nil
            }
            catch { status = self.text(error.localizedDescription) }
        } else { status = "词库未安装，请重新安装伴语输入法。" }
        if let lexicon, !settings.audience.isEnglishOnly {
            let layout: KeyboardLayout = settings.layout == .nineKey ? .nineKey : .pinyin
            let script = settings.script
            let policy = pinyinPolicy
            warmupTask = Task(priority: .utility) {
                _ = try? await lexicon.candidates(for: layout == .nineKey ? "64" : "ni",
                                                  layout: layout, script: script, limit: 1, pinyinPolicy: policy)
            }
        }
    }

    var isEnglishOnly: Bool { settings.audience.isEnglishOnly }
    func text(_ value: String) -> String { settings.audience.text(value) }

    func playKeyFeedback(_ kind: KeyFeedbackKind = .typing) {
        if settings.keySoundEnabled { onKeyClick(kind) }
        guard settings.keyHapticsEnabled else { return }
        let intensity: CGFloat
        switch settings.keyHapticStrength {
        case .light: intensity = 0.25
        case .medium: intensity = 0.45
        case .strong: intensity = 0.7
        }
        keyFeedback.impactOccurred(intensity: kind == .delete ? intensity * 0.7 : intensity)
    }

    var visibleCandidates: [Candidate] {
        let available = candidatesExpanded
            ? displayCandidates + singleCandidateGroups.flatMap(\.candidates) + expandedEnglishCandidates
            : displayCandidates
        return available.filter { visibleCandidateIDs.contains($0.id) }
    }
    var displayCandidates: [Candidate] {
        if let rawFallbackCandidate { return [rawFallbackCandidate] }
        return candidates
    }
    private var rawFallbackCandidate: Candidate? {
        guard !english, !isQueryingCandidates, candidates.isEmpty, !composition.input.isEmpty else { return nil }
        let raw = settings.layout == .nineKey ? nineKeyMarkedText : composition.input
        return Candidate(text: raw, reading: composition.input, consumed: composition.input.count)
    }
    var expandedEnglishCandidates: [Candidate] {
        guard !english, settings.layout == .pinyin, !composition.input.isEmpty else { return [] }
        let raw = composition.input
        let direct = Candidate(text: raw, reading: raw, consumed: raw.count)
        let completions = candidates.filter { $0.text.unicodeScalars.allSatisfy {
            $0.isASCII && CharacterSet.letters.contains($0)
        } }
        return [direct] + completions.filter { $0.text != raw }
    }
    var languageName: String { Locale(identifier: settings.audience.interfaceLocale).localizedString(forIdentifier: settings.targetLanguageID) ?? settings.targetLanguageID }
    var codeDisplay: String { KeyCoding.display(composition.input, layout: settings.layout) }
    var activeInput: String { english ? englishInput : composition.input }

    func toggleCandidateExpansion() {
        guard !english, !activeInput.isEmpty, !isCommitting else { return }
        candidatesExpanded.toggle()
        if candidatesExpanded { loadSingleCandidateGroups() }
        else { singleQueryTask?.cancel(); singleCandidateGroups = [] }
        visibleCandidateIDs = []
    }

    private func loadSingleCandidateGroups() {
        singleQueryTask?.cancel()
        singleCandidateGroups = []
        guard candidatesExpanded, !english, settings.layout == .pinyin,
              !composition.input.isEmpty, let lexicon else { return }
        let input = composition.input
        let script = settings.script
        let policy = pinyinPolicy
        let request = revision
        singleQueryTask = Task { [weak self] in
            let groups = await lexicon.singleCandidateGroups(for: input, script: script, pinyinPolicy: policy)
            guard let self, !Task.isCancelled, self.revision == request,
                  self.candidatesExpanded, self.composition.input == input else { return }
            self.singleCandidateGroups = groups
            self.prefetchFollowingSingles(groups, input: input)
        }
    }

    private func prefetchFollowingSingles(_ groups: [SingleCandidateGroup], input: String) {
        guard settings.translationEnabled, learningUnlocked, groups.count > 1 else { return }
        let texts = groups.dropFirst().filter { !$0.isCorrection }.prefix(3)
            .flatMap { $0.candidates.prefix(8).map(\.text) }
        guard !texts.isEmpty else { return }
        if !segmentTranslationRoot.isEmpty, segmentTranslationRoot.hasSuffix(input) { return }
        segmentTranslationTask?.cancel()
        segmentTranslator.cancel()
        segmentTranslationRoot = input
        segmentTranslationContext = candidateTranslationContext
        let context = segmentTranslationContext
        let source = settings.script.languageID
        let target = settings.targetLanguageID
        segmentTranslationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let output = try await self.segmentTranslator.translate(texts, sourceID: source, targetID: target) { [weak self] text, value in
                    guard let self, !Task.isCancelled, self.segmentTranslationContext == context,
                          input.hasSuffix(self.composition.input), !self.composition.input.isEmpty else { return }
                    self.translations[text] = value
                }
                guard !Task.isCancelled, self.segmentTranslationContext == context,
                      input.hasSuffix(self.composition.input), !self.composition.input.isEmpty else { return }
                self.translations.merge(output) { _, new in new }
            } catch {
                // The visible-candidate path still requests any missing translation.
            }
        }
    }

    private func showComposingCode() {
        let input = composition.input
        guard settings.layout == .nineKey else {
            nineKeyMarkedDigits = ""
            nineKeyMarkedText = ""
            onCompositionChanged(input, composition.cursor)
            return
        }
        if input.hasPrefix(nineKeyMarkedDigits) {
            nineKeyMarkedText += KeyCoding.nineKeyFallback(String(input.dropFirst(nineKeyMarkedDigits.count)))
        } else if nineKeyMarkedDigits.hasPrefix(input) {
            nineKeyMarkedText = String(nineKeyMarkedText.prefix(input.count))
        } else {
            nineKeyMarkedText = KeyCoding.nineKeyFallback(input)
        }
        nineKeyMarkedDigits = input
        onCompositionChanged(nineKeyMarkedText, composition.cursor)
    }
    var directionLabel: String {
        let target = english ? settings.englishTargetLanguageID : settings.targetLanguageID
        let code = Locale(identifier: target).language.languageCode?.identifier ?? target
        let shortName: String
        switch code {
        case "zh": shortName = "中"
        case "en": shortName = "英"
        case "ja": shortName = "日"
        case "ko": shortName = "韩"
        default:
            let localized = Locale(identifier: settings.audience.interfaceLocale).localizedString(forLanguageCode: code) ?? code
            shortName = String(localized.prefix(1))
        }
        return isEnglishOnly ? "English → \(Locale(identifier: "en").localizedString(forIdentifier: target) ?? target)" : "\(english ? "英" : "中")/\(shortName)"
    }

    func refreshMembership() {
        let active = SharedMembership.load().hasAccess()
        guard learningUnlocked != active else { return }
        learningUnlocked = active
        translations = [:]
        translateVisible()
    }

    func reloadSettings() {
        refreshMembership()
        let loaded = SharedSettings.load()
        if sharedRevision != loaded.revision {
            let audienceChanged = settings.audience != loaded.audience
            if audienceChanged {
                disappear()
                symbols = false
                alternateSymbols = false
                nineKeyNumbers = false
                uppercase = false
            }
            settings = loaded
            sharedRevision = loaded.revision
            if UserDefaults.standard.string(forKey: "settingsRevision") == loaded.revision.uuidString,
               let raw = UserDefaults.standard.string(forKey: "localLayout"), let layout = KeyboardLayout(rawValue: raw) {
                settings.layout = layout
            }
            composition.switchLayout(settings.layout)
            if isEnglishOnly { english = true }
            else if audienceChanged { english = false }
            prepareChineseLexiconIfNeeded()
            refresh()
        }
    }

    func setLayout(_ layout: KeyboardLayout) {
        guard !isCommitting, !isEnglishOnly else { return }
        if !activeInput.isEmpty { commitRaw() }
        settings.layout = layout
        composition.switchLayout(layout)
        english = false
        symbols = false
        alternateSymbols = false
        nineKeyNumbers = false
        showingEmoji = false
        showingSettings = false
        resetLearning()
        UserDefaults.standard.set(layout.rawValue, forKey: "localLayout")
        UserDefaults.standard.set(sharedRevision?.uuidString, forKey: "settingsRevision")
        refresh()
        onHeightNeedsUpdate()
    }

    func cycleLayout() {
        guard !isEnglishOnly else { return }
        guard let index = KeyboardLayout.allCases.firstIndex(of: settings.layout) else { return }
        let next = KeyboardLayout.allCases[(index + 1) % KeyboardLayout.allCases.count]
        setLayout(next)
    }

    func key(_ value: String) {
        guard !isCommitting else { return }
        if english {
            guard englishInput.count < 32 else { return }
            resetLearning()
            if englishInput.isEmpty, separateNextEnglishWord {
                if let last = contextBeforeInput()?.last, last.isLetter { onInsert(" ") }
                separateNextEnglishWord = false
            }
            let inserted = uppercase ? value.uppercased() : value
            englishInput.insert(contentsOf: inserted, at: englishInput.index(englishInput.startIndex, offsetBy: englishCursor))
            englishCursor += inserted.count
            onCompositionChanged(englishInput, englishCursor)
            refresh()
            return
        }
        guard composition.append(value) else {
            status = settings.layout == .cangjie ? "仓颉最多五码，请先选字。" : "已输入 256 个编码，请先选词后继续。"
            return
        }
        if !learningCode.isEmpty { learningCode += value }
        showComposingCode()
        refresh()
        onHeightNeedsUpdate()
    }

    func backspace() {
        guard !isCommitting else { return }
        resetLearning()
        if english {
            separateNextEnglishWord = false
            if englishInput.isEmpty { onDelete() }
            else {
                guard englishCursor > 0 else { return }
                let previous = englishCursor - 1
                englishInput.remove(at: englishInput.index(englishInput.startIndex, offsetBy: previous))
                englishCursor = previous
                onCompositionChanged(englishInput, englishCursor)
                refresh()
            }
            return
        }
        if composition.backspace() { onDelete() }
        else { showComposingCode() }
        refresh()
    }

    func select(_ candidate: Candidate, translation: Bool = false) {
        refreshMembership()
        if translation && !learningUnlocked { showingMembership = true; return }
        if english {
            guard !isCommitting, candidates.contains(candidate), candidate.reading == englishInput else { return }
            let output = translation ? translations[candidate.text] : candidate.text
            guard let output else { return }
            let prefix = englishInput.isEmpty && contextBeforeInput()?.last?.isLetter == true ? " " : ""
            englishInput = ""
            onInsert(prefix + output)
            separateNextEnglishWord = !translation
            refresh()
            return
        }
        let selectableSingles = singleCandidateGroups.enumerated().filter { index, group in
            index == 0 || group.isCorrection
        }.flatMap { $0.element.candidates }
        if !isCommitting, !translation, candidate == rawFallbackCandidate {
            commitRaw()
            return
        }
        let available = candidates.contains(candidate) ||
            (candidatesExpanded && (selectableSingles.contains(candidate) || expandedEnglishCandidates.contains(candidate)))
        guard !isCommitting, !isQueryingCandidates, available, let lexicon else { return }
        let output = translation ? translations[candidate.text] : candidate.text
        guard let output else { return }
        let snapshot = composition
        let script = settings.script
        let policy = pinyinPolicy
        invalidateTasks()
        isCommitting = true
        commitTask = Task { [weak self] in
            let resolved = await lexicon.resolve(candidate, for: snapshot.input, layout: snapshot.layout,
                                                 script: script, pinyinPolicy: policy)
            guard let self, !Task.isCancelled, self.composition == snapshot else { return }
            self.isCommitting = false
            guard let resolved, self.composition.commit(resolved) != nil else {
                self.status = "选词状态已更新，请重新选择。"
                return
            }
            if translation { self.resetLearning() }
            else if !self.composition.input.isEmpty {
                if self.learningCode.isEmpty { self.learningCode = snapshot.input }
                self.learningText += resolved.text
                self.learnedSegments += 1
            } else if self.learnedSegments > 0 {
                let code = self.learningCode
                let text = self.learningText + resolved.text
                if !code.isEmpty {
                    do {
                        try await lexicon.learn(code: code, text: text, layout: snapshot.layout,
                                                script: script, pinyinPolicy: policy)
                    }
                    catch { self.status = "词组未保存：\(error.localizedDescription)" }
                }
                self.resetLearning()
            }
            self.onInsert(output)
            if !self.composition.input.isEmpty { self.showComposingCode() }
            self.refresh()
        }
    }

    func selectTranslation(_ candidate: Candidate) {
        refreshMembership()
        guard learningUnlocked else { showingMembership = true; return }
        guard translations[candidate.text] != nil else {
            status = self.text("译文尚未就绪，请稍后再长按。")
            return
        }
        select(candidate, translation: true)
    }

    func space() {
        guard !isCommitting else { return }
        if english { finishComposition(suffix: " "); return }
        if composition.input.isEmpty { onInsert(" ") }
        else if isQueryingCandidates { finishComposition(suffix: "", firstOnly: true) }
        else if let candidate = candidates.first { select(candidate) }
        else { finishComposition(suffix: "", firstOnly: true) }
    }

    func enter() {
        guard !isCommitting else { return }
        if activeInput.isEmpty {
            onInsert("\n")
            separateNextEnglishWord = false
            refresh()
        }
        else { commitRaw() }
    }

    func punctuation(_ text: String) {
        resetLearning()
        finishComposition(suffix: text)
    }

    /// Resolve each remaining segment before punctuation/paste; never swallow leftover code.
    func finishComposition(suffix: String, firstOnly: Bool = false) {
        guard !isCommitting else { return }
        resetLearning()
        if english {
            let text = [" ", ",", ".", "!", "?", ";", ":"].contains(suffix)
                ? (englishAutomaticReplacement ?? englishInput) : englishInput
            let output = text + suffix
            englishInput = ""
            separateNextEnglishWord = false
            onInsert(output)
            refresh()
            return
        }
        guard !composition.input.isEmpty else { onInsert(suffix); return }
        guard let lexicon else {
            onInsert(composition.input + suffix)
            composition.clear()
            refresh()
            return
        }
        let snapshot = composition
        let script = settings.script
        let policy = pinyinPolicy
        invalidateTasks()
        isCommitting = true
        commitTask = Task { [weak self] in
            guard let self else { return }
            var pending = snapshot
            var output = ""
            while !pending.input.isEmpty {
                let found: [Candidate]
                do {
                    found = try await chineseCandidates(for: pending.input, layout: pending.layout, script: script,
                                                        policy: policy, lexicon: lexicon, limit: 1).candidates
                } catch {
                    guard !Task.isCancelled else { return }
                    self.isCommitting = false
                    self.status = self.text(error.localizedDescription)
                    return
                }
                guard !Task.isCancelled else { return }
                if let best = found.first,
                   let resolved = await lexicon.resolve(best, for: pending.input, layout: pending.layout,
                                                        script: script, pinyinPolicy: policy),
                   let text = pending.commit(resolved) { output += text }
                else { output += pending.input; pending.clear() }
                if firstOnly { break }
            }
            guard !Task.isCancelled else { return }
            self.onInsert(output + suffix)
            self.composition = pending
            if !pending.input.isEmpty { self.showComposingCode() }
            self.isCommitting = false
            self.refresh()
        }
    }

    func commitRaw() {
        guard !isCommitting else { return }
        if english {
            guard !englishInput.isEmpty else { return }
            onInsert(englishInput)
            englishInput = ""
            separateNextEnglishWord = false
            refresh()
            return
        }
        guard !composition.input.isEmpty else { return }
        onInsert(settings.layout == .nineKey ? nineKeyMarkedText : composition.input)
        resetLearning()
        composition.clear()
        refresh()
    }

    func toggleEnglish() {
        guard !isCommitting, !isEnglishOnly else { return }
        if !activeInput.isEmpty { commitRaw() }
        english.toggle()
        separateNextEnglishWord = false
        englishAutomaticReplacement = nil
        symbols = false
        alternateSymbols = false
        nineKeyNumbers = false
        showingEmoji = false
        refresh()
        onHeightNeedsUpdate()
    }

    func toggleEmoji() {
        guard !isCommitting else { return }
        if !activeInput.isEmpty { commitRaw() }
        showingEmoji.toggle()
        showingSettings = false
        symbols = false
        onHeightNeedsUpdate()
    }

    func setSymbols(_ visible: Bool) {
        symbols = visible
        alternateSymbols = false
        nineKeyNumbers = false
        showingEmoji = false
        onHeightNeedsUpdate()
    }

    func toggleNineKeyNumbers() {
        guard !isCommitting, !isEnglishOnly else { return }
        if !activeInput.isEmpty { finishComposition(suffix: "") }
        nineKeyNumbers.toggle()
        symbols = false
        onHeightNeedsUpdate()
    }

    func openSettings() {
        showingSettings = true
        showingEmoji = false
        closeClipboard()
        onHeightNeedsUpdate()
    }

    func closeSettings() { showingSettings = false; onHeightNeedsUpdate() }

    func beginCursorMovement() {
        guard !isCommitting else { return }
        resetLearning()
        // Both Chinese and English stay marked while the user repositions the caret.
    }

    func moveCursor(by offset: Int) {
        guard !isCommitting, offset != 0 else { return }
        if !activeInput.isEmpty {
            if english {
                englishCursor += min(englishInput.count - englishCursor, max(-englishCursor, offset))
                onCompositionChanged(englishInput, englishCursor)
            } else {
                composition.moveCursor(by: offset)
                showComposingCode()
            }
            return
        }
        onCursorMove(offset)
        separateNextEnglishWord = false
        refresh()
    }

    func moveCompositionCursor(to offset: Int) {
        guard !isCommitting, !activeInput.isEmpty else { return }
        resetLearning()
        if english { englishCursor = min(englishInput.count, max(0, offset)) }
        else { composition.moveCursor(by: offset - composition.cursor) }
    }

    func resumeHostComposition(input: String, cursor: Int) {
        guard activeInput.isEmpty, !isCommitting else { return }
        if english {
            englishInput = input
            englishCursor = min(input.count, max(0, cursor))
        } else {
            guard composition.append(input) else { return }
            composition.moveCursor(by: cursor - composition.cursor)
        }
        refresh()
    }

    /// The host already contains the raw composing text. Forget local state without
    /// inserting it again or deleting it at the host's newly selected position.
    func hostDidEndComposition() {
        composition.clear()
        englishInput = ""
        disappear()
    }

    func insertEmoji(_ emoji: String) {
        guard !isCommitting else { return }
        onInsert(emoji)
        separateNextEnglishWord = false
        refresh()
    }

    func updateVisibleCandidates(_ ids: [String], input: String) {
        guard input == activeInput, !isQueryingCandidates else { return }
        let available = candidatesExpanded
            ? displayCandidates + singleCandidateGroups.flatMap(\.candidates) + expandedEnglishCandidates
            : displayCandidates
        let visible = Set(ids).intersection(available.map(\.id))
        guard visible != visibleCandidateIDs else { return }
        visibleCandidateIDs = visible
        translateVisible()
    }

    func refresh() {
        refreshMembership()
        invalidateTasks()
        let input = activeInput
        if input.isEmpty || (!segmentTranslationRoot.isEmpty && !segmentTranslationRoot.hasSuffix(input)) {
            segmentTranslationTask?.cancel()
            segmentTranslator.cancel()
            segmentTranslationRoot = ""
            segmentTranslationContext = ""
        }
        if input.isEmpty && candidatesExpanded {
            candidatesExpanded = false
            singleCandidateGroups = []
        }
        let querying = !english && !input.isEmpty && lexicon != nil
        let queryContext = "\(english)|\(settings.layout.rawValue)|\(settings.script.rawValue)|\(settings.fuzzyPinyinEnabled)"
        let retainingCandidates = querying && candidateQueryContext == queryContext
        candidateQueryContext = queryContext
        isQueryingCandidates = querying
        if !retainingCandidates { candidates = [] }
        let translationContext = "\(english)|\(settings.script.languageID)|\(settings.targetLanguageID)|\(settings.englishTargetLanguageID)|\(settings.translationEnabled)"
        if input.isEmpty || candidateTranslationContext != translationContext {
            translations = [:]
            translationEligibleTexts = []
            segmentTranslationTask?.cancel()
            segmentTranslator.cancel()
            segmentTranslationRoot = ""
            segmentTranslationContext = ""
        }
        candidateTranslationContext = translationContext
        visibleCandidateIDs = []
        if candidatesExpanded { loadSingleCandidateGroups() }
        offlineEnglishWords = []
        status = lexicon == nil ? "词库未就绪" : nil
        if composition.input.isEmpty || settings.layout != .nineKey {
            nineKeyMarkedDigits = ""
            nineKeyMarkedText = ""
        }
        if english {
            let context = committedEnglishContext()
            let result = englishPhraseSuggestions(context: context)
            englishAutomaticReplacement = result.automaticReplacement
            candidates = result.words.map {
                Candidate(text: $0, reading: englishInput, consumed: englishInput.count)
            }
            retainTranslationsForCurrentCandidates()
            status = nil
            if let lexicon, englishInput.count >= 2 {
                let request = revision
                queryTask = Task { [weak self] in
                    let offline = await lexicon.englishWords(prefix: input)
                    guard let self, !Task.isCancelled, self.revision == request else { return }
                    self.offlineEnglishWords = Set(offline.completions.map { $0.lowercased() })
                    if offline.known { self.offlineEnglishWords.insert(input.lowercased()) }
                    let updated = self.englishPhraseSuggestions(context: context, offline: offline)
                    if updated == result {
                        if self.visibleCandidates.contains(where: {
                            self.offlineEnglishWords.contains($0.text.lowercased()) &&
                                !self.translationEligibleTexts.contains($0.text)
                        }) { self.translateVisible() }
                        return
                    }
                    self.englishAutomaticReplacement = updated.automaticReplacement
                    self.candidates = updated.words.map {
                        Candidate(text: $0, reading: input, consumed: input.count)
                    }
                    self.retainTranslationsForCurrentCandidates()
                }
            }
            return
        }
        guard !composition.input.isEmpty, let lexicon else { return }
        let layout = settings.layout
        let script = settings.script
        let policy = pinyinPolicy
        let request = revision
        queryTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await chineseCandidates(for: input, layout: layout, script: script,
                                                         policy: policy, lexicon: lexicon)
                guard !Task.isCancelled, self.revision == request else { return }
                self.offlineEnglishWords = result.englishWords
                self.candidates = result.candidates
                self.retainTranslationsForCurrentCandidates()
                self.isQueryingCandidates = false
                if layout == .nineKey,
                   let preedit = await lexicon.nineKeyPreedit(for: input,
                       preferred: result.candidates.first?.text, script: script),
                   !Task.isCancelled, self.revision == request {
                    self.nineKeyMarkedDigits = input
                    self.nineKeyMarkedText = preedit
                    self.onCompositionChanged(preedit, self.composition.cursor)
                }
            } catch {
                guard !Task.isCancelled, self.revision == request else { return }
                self.candidates = []
                self.isQueryingCandidates = false
                self.status = self.text(error.localizedDescription)
            }
        }
    }

    private func chineseCandidates(for input: String, layout: KeyboardLayout, script: ChineseScript,
                                   policy: PinyinQueryPolicy, lexicon: Lexicon, limit: Int? = nil) async throws
        -> (candidates: [Candidate], englishWords: Set<String>) {
        let offline = layout == .pinyin ? await lexicon.englishWords(prefix: input) : (known: false, completions: [])
        let word = layout == .pinyin ? englishSuggestions(for: input, offline: offline).first : nil
        var englishWords = Set(offline.completions.map { $0.lowercased() })
        if let word { englishWords.insert(word.lowercased()) }
        let exactPinyin = if word != nil { await lexicon.hasExactPinyinReading(input, script: script) } else { false }
        try Task.checkCancellation()
        if let word, word.lowercased() == input.lowercased(), !exactPinyin {
            return ([Candidate(text: word, reading: input, consumed: input.count)], englishWords)
        }
        let found = try await lexicon.candidates(for: input, layout: layout, script: script,
                                                 limit: limit, pinyinPolicy: policy)
        guard let word else { return (found, englishWords) }
        let mixed = EnglishSuggestionPolicy.mergingMixedSuggestion(word, for: input, into: found,
                                                                  hasExactPinyinReading: exactPinyin, limit: limit)
        return (mixed, englishWords)
    }

    private func retainTranslationsForCurrentCandidates() {
        let texts = Set(candidates.map(\.text))
        // Keep prefetched suffix translations across partial selections.
        translationEligibleTexts.formIntersection(texts)
    }

    private func englishSuggestions(for input: String, offline: (known: Bool, completions: [String])) -> [String] {
        guard !input.isEmpty else { return [] }
        let range = NSRange(location: 0, length: (input as NSString).length)
        let completions = englishChecker.completions(forPartialWordRange: range, in: input, language: "en_US") ?? []
        return EnglishSuggestionPolicy.suggestions(for: input,
            knownWord: offline.known || isKnownEnglishWord(input),
            completions: completions + offline.completions,
            englishMode: false)
    }

    private func committedEnglishContext() -> String {
        guard var context = contextBeforeInput() else { return "" }
        // The host proxy includes the current marked text. Only earlier text is context.
        let markedPrefix = String(englishInput.prefix(englishCursor))
        if !markedPrefix.isEmpty, context.hasSuffix(markedPrefix) { context.removeLast(markedPrefix.count) }
        return String(context.suffix(160))
    }

    private func englishPhraseSuggestions(context: String,
                                          offline: (known: Bool, completions: [String]) = (false, [])) -> EnglishSuggestions {
        guard !englishInput.isEmpty else {
            return englishLanguageModel.suggestions(for: "", context: context, knownWord: false,
                                                    completions: [], corrections: [])
        }
        let range = NSRange(location: 0, length: (englishInput as NSString).length)
        let known = isKnownEnglishWord(englishInput) || offline.known
        let completions = englishChecker.completions(forPartialWordRange: range, in: englishInput, language: "en_US") ?? []
        let corrections = known ? [] : (englishChecker.guesses(forWordRange: range, in: englishInput, language: "en_US") ?? [])
        return englishLanguageModel.suggestions(for: englishInput, context: context, knownWord: known,
                                                completions: completions + offline.completions, corrections: corrections)
    }

    private func isTranslatableEnglish(_ text: String) -> Bool {
        guard EnglishLanguageModel.isEnglishText(text) else { return false }
        return text.split(separator: " ").allSatisfy {
            englishLanguageModel.contains(String($0)) || offlineEnglishWords.contains($0.lowercased()) ||
                isKnownEnglishWord(String($0))
        }
    }

    private func isKnownEnglishWord(_ word: String) -> Bool {
        if englishLanguageModel.contains(word) { return true }
        guard word.count > 1, word.count <= 32,
              word.unicodeScalars.allSatisfy({ $0.isASCII && CharacterSet.letters.contains($0) }) else { return false }
        let prefix = String(word.dropLast())
        let range = NSRange(location: 0, length: prefix.utf16.count)
        let completions = englishChecker.completions(forPartialWordRange: range, in: prefix, language: "en_US") ?? []
        if EnglishSuggestionPolicy.hasWordEvidence(for: word, dictionaryKnown: false, completions: completions) { return true }
        let guesses = englishChecker.guesses(forWordRange: NSRange(location: 0, length: word.utf16.count),
                                            in: word, language: "en_US") ?? []
        return EnglishSuggestionPolicy.hasWordEvidence(for: word, dictionaryKnown: false, completions: guesses)
    }

    func retryTranslation() { cancelVisibleTranslation(); translateVisible() }

    private func translateVisible() {
        guard settings.translationEnabled, !visibleCandidates.isEmpty else {
            cancelVisibleTranslation()
            translationEligibleTexts = []
            return
        }
        let visible = visibleCandidates.map(\.text)
        let englishWords = visible.filter { text in
            isTranslatableEnglish(text)
        }
        let chineseWords = english ? [] : visible.filter { text in
            text.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) }
        }
        let englishTarget = english ? settings.englishTargetLanguageID : settings.script.languageID
        let groups: [([String], String, String)] = [
            (chineseWords, settings.script.languageID, settings.targetLanguageID),
            (englishWords, "en", englishTarget)
        ].filter { !$0.0.isEmpty }
        translationEligibleTexts = Set(englishWords + chineseWords)
        guard learningUnlocked, !groups.isEmpty else {
            cancelVisibleTranslation()
            translations = [:]
            return
        }
        for (texts, source, target) in groups {
            translations.merge(translator.cached(texts, sourceID: source, targetID: target)) { _, new in new }
        }
        let pendingGroups = groups.compactMap { texts, source, target -> ([String], String, String)? in
            let missing = texts.filter { translations[$0] == nil }
            return missing.isEmpty ? nil : (missing, source, target)
        }
        guard !pendingGroups.isEmpty else { cancelVisibleTranslation(); status = nil; return }
        let requests = Set(groups.flatMap { texts, source, target in
            texts.map { TranslationRequestKey(text: $0, source: source, target: target) }
        })
        // Different candidate IDs can represent the same text and language pair.
        // Compare the full set: streaming results shrink only the missing subset.
        if translationTask != nil, requests == scheduledTranslations { return }
        cancelVisibleTranslation()
        status = nil
        let request = translationRevision
        scheduledTranslations = requests
        translationTask = Task { [weak self] in
            // Coalesce nearby layout updates without adding a noticeable typing pause.
            try? await Task.sleep(for: .milliseconds(40))
            guard let self, !Task.isCancelled, self.translationRevision == request else { return }
            self.translating = true
            self.translationPlaceholder = "…"
            var retryGroups = pendingGroups
            // A newly launched keyboard can see transient system translation failures
            // before the installed language pair becomes available again.
            let retryDelays = [350, 700, 1100]
            for attempt in 0...retryDelays.count {
                var remaining: [([String], String, String)] = []
                for (texts, source, target) in retryGroups {
                    let missing = texts.filter { self.translations[$0] == nil }
                    guard !missing.isEmpty else { continue }
                    do {
                        let output = try await self.translator.translate(missing, sourceID: source, targetID: target) { [weak self] text, value in
                            guard let self, !Task.isCancelled, self.translationRevision == request else { return }
                            self.translations[text] = value
                        }
                        guard !Task.isCancelled, self.translationRevision == request else { return }
                        self.translations.merge(output) { _, new in new }
                        if missing.contains(where: { self.translations[$0] == nil }) {
                            remaining.append((texts, source, target))
                        }
                    } catch {
                        guard !Task.isCancelled, self.translationRevision == request else { return }
                        if (error as? TranslationService.Failure) == .unsupported {
                            self.reportTranslationFailure(error, source: source, target: target)
                        } else {
                            remaining.append((texts, source, target))
                            if attempt == retryDelays.count {
                                self.reportTranslationFailure(error, source: source, target: target)
                            }
                        }
                    }
                }
                guard !remaining.isEmpty else { break }
                if attempt == retryDelays.count {
                    for (_, source, target) in remaining where self.status == nil {
                        self.reportTranslationFailure(TranslationService.Failure.emptyResponse,
                                                      source: source, target: target)
                    }
                    break
                }
                do { try await Task.sleep(for: .milliseconds(retryDelays[attempt])) } catch { return }
                guard self.translationRevision == request else { return }
                self.translator.cancel()
                retryGroups = remaining
            }
            self.translating = false
            self.translationTask = nil
            self.scheduledTranslations = []
            if self.status == nil { self.translationPlaceholder = "" }
        }
    }

    private func cancelVisibleTranslation() {
        translationTask?.cancel()
        translationTask = nil
        if translating { translator.cancel() }
        translating = false
        translationPlaceholder = ""
        translationRevision = UUID()
        scheduledTranslations = []
    }

    private func reportTranslationFailure(_ error: any Error, source: String, target: String) {
        translationPlaceholder = (error as? TranslationService.Failure) == .notInstalled ? text("待下载") : ""
        status = text((error as? TranslationService.Failure)?.localizedDescription ?? "系统翻译暂不可用，请重试。")
        TranslationDiagnostics.record(error: error, source: source, target: target, fullAccess: fullAccess)
    }

    private func invalidateTasks() {
        revision = UUID()
        queryTask?.cancel()
        singleQueryTask?.cancel()
        cancelVisibleTranslation()
    }

    func disappear() {
        invalidateTasks()
        segmentTranslationTask?.cancel()
        segmentTranslator.cancel()
        segmentTranslationRoot = ""
        segmentTranslationContext = ""
        commitTask?.cancel()
        isCommitting = false
        if !activeInput.isEmpty { onCompositionChanged("", 0) }
        composition.clear()
        nineKeyMarkedDigits = ""
        nineKeyMarkedText = ""
        englishInput = ""
        englishAutomaticReplacement = nil
        separateNextEnglishWord = false
        showingEmoji = false
        showingSettings = false
        candidates = []
        candidatesExpanded = false
        singleCandidateGroups = []
        isQueryingCandidates = false
        translations = [:]
        translationEligibleTexts = []
        closeClipboard()
        resetLearning()
        // Reopening the keyboard can reuse recent translations synchronously.
        // Only the bounded in-process cache survives; no new text is written to disk.
        translator.cancel()
    }

    func reduceMemory() {
        cancelVisibleTranslation()
        translator.releaseResources()
        segmentTranslationTask?.cancel()
        segmentTranslator.releaseResources()
        segmentTranslationRoot = ""
        segmentTranslationContext = ""
        translations = [:]
        translating = false
        clipboardPreview = nil
        // Keep the user's unfinished code and Chinese candidates intact.
    }

    func closeClipboard() { clipboardPreview = nil; showingClipboard = false; status = nil; onHeightNeedsUpdate() }

    func openClipboard() {
        showingClipboard = true
        onHeightNeedsUpdate()
        clipboardPreview = nil
        status = nil
        guard fullAccess else {
            status = self.text("读取当前复制内容需要开启「允许完全访问」；收藏内容仍可查看。")
            return
        }
        // Present the saved-items panel before iOS can interrupt the extension
        // with a paste-permission alert for the explicit current-content read.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, self.showingClipboard else { return }
            guard let text = UIPasteboard.general.string, !text.isEmpty else {
                self.status = self.text("当前剪贴板没有可用文字；若刚允许粘贴，请重新点击剪贴板图标。")
                return
            }
            self.receivePaste(text)
        }
    }

    func receivePaste(_ text: String) {
        guard text.count <= 16000 else { status = self.text("文本超过 16,000 字，请分段粘贴。"); return }
        showingClipboard = true
        clipboardPreview = text
        status = nil
    }

    func savePreview() {
        guard let text = clipboardPreview else { return }
        do {
            var updated = clips
            try updated.save(text)
            try persist(updated)
            clips = updated
            status = self.text("已收藏在本机")
        } catch { status = self.text(error.localizedDescription) }
    }

    func deleteClip(_ id: UUID) {
        var updated = clips
        updated.remove(id)
        do { try persist(updated); clips = updated }
        catch { status = self.text("删除失败，请重试。") }
    }

    func deleteAllClips() {
        do { try persist(SavedClips()); clips.removeAll() }
        catch { status = self.text("清空失败，请重试。") }
    }

    private func persist(_ value: SavedClips) throws {
        guard let url = clipURL else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: url, options: [.atomic, .completeFileProtection])
        var protected = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try protected.setResourceValues(values)
    }

    private func resetLearning() {
        learningCode = ""
        learningText = ""
        learnedSegments = 0
    }
}
