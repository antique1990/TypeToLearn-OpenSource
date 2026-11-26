import AppKit
import InputMethodKit
import SwiftUI
import KeyboardCore
import DesktopCore

#if DEBUG
private enum InputInteractionLog {
    private static let queue = DispatchQueue(label: "com.learnkeyboard.input.interaction-log", qos: .utility)
    static func append(_ line: String) {
        queue.async {
            let directory = DesktopSettingsStore.directory
            let url = directory.appendingPathComponent("input-interactions.log")
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                }
                let file = try FileHandle(forWritingTo: url)
                defer { try? file.close() }
                if try file.seekToEnd() > 262_144 {
                    try file.truncate(atOffset: 0)
                    try file.seek(toOffset: 0)
                }
                try file.write(contentsOf: Data((line + "\n").utf8))
            } catch { /* Diagnostics must never interrupt input. */ }
        }
    }
}
#endif

@objc(TypeToLearnInputController)
@MainActor
class InputController: IMKInputController {
    private static let emptyCatalog = DesktopCandidateCatalog(metadataURL: nil, emojiURL: nil,
        emojiIndexURL: nil, structuralURL: nil)
    private static var sharedCatalog: DesktopCandidateCatalog?
    private static let catalogLoad = Task { @MainActor in
        let catalog = await Task.detached(priority: .userInitiated) { DesktopCandidateCatalog() }.value
        sharedCatalog = catalog
        return catalog
    }
    static func prepareCandidateResources() { _ = catalogLoad }

    private var state = DesktopComposition()
    private var settings = DesktopSettingsStore.load()
    private var lookup: Task<Void, Never>?
    private var moreLookup: Task<Void, Never>?
    private var candidateLimit = 48
    private var canLoadMore = false
    private var loadingMore = false
    private var selectionTask: Task<Void, Never>?
    private var translationTask: Task<Void, Never>?
    private var lexicon: Lexicon?
    private var translator = MacTranslator.shared
    private var translations: [String: String] = [:]
    private var status = ""
    private var panel: NSPanel?
    private var hosting: NSHostingView<CandidateView>?
    private var lastContent: CandidateView?
    private var translating = false
    private var pendingTranslation: (index: Int, generation: UUID)?
    private var hostClient: (any IMKTextInput)?
    private var pending: [NSEvent] = []
    private var waitingForSelection = false
    private var loading = false
    private var requestedSelection: Int?
    private var punctuationSuffix: String?
    private var punctuation = DesktopPunctuation()
    private var learningCode = ""
    private var learningText = ""
    private var active = false
    private var translationRequest: String?
    private var translationAttempt: UUID?
    private var translationRetryAvailable = false
    private var catalog: DesktopCandidateCatalog { Self.sharedCatalog ?? Self.emptyCatalog }
    private var catalogRefresh: Task<Void, Never>?
    private var candidateInteracted = false
    private var baseCandidates: [Candidate] = []
    private var category: DesktopCandidateCategory = .frequency
    private var categoriesVisible = false
    private var expanded = false
    private var expandedLayout: Bool { expanded || settings.candidateLayout == .vertical }
    private var emojiGroupID = ""
    private func traceInteraction(_ event: String, error: (any Error)? = nil) {
        #if DEBUG
        let mouseInside = panel.map { $0.isVisible && $0.frame.contains(NSEvent.mouseLocation) } ?? false
        let detail = error.map { let value = $0 as NSError; return " errorDomain=\(value.domain) errorCode=\(value.code)" } ?? ""
        InputInteractionLog.append("time=\(Date().timeIntervalSince1970) pid=\(ProcessInfo.processInfo.processIdentifier) session=\(ObjectIdentifier(self)) action=\(event) active=\(active) composing=\(!state.input.isEmpty) symbols=\(state.browsingSymbols) category=\(category.rawValue) candidates=\(state.candidates.count) visible=\(panel?.isVisible ?? false) mouseInside=\(mouseInside) event=\(NSApp.currentEvent?.type.rawValue ?? 0)\(detail)")
        #endif
    }
    #if DEBUG
    var testSettings: DesktopSettings?
    var testState: DesktopComposition { state }
    var testLearnedURL: URL?
    var testCompletionProvider: ((String) async -> [String]?)?
    static var testCatalogReady: Bool { sharedCatalog != nil }
    var testCategory: DesktopCandidateCategory { category }
    var testCategoriesVisible: Bool { categoriesVisible }
    var testExpanded: Bool { expanded }
    func testClickNextPage() { lastContent?.page(1) }
    var testTranslationStatus: String { status }
    var testTranslationCanRetry: Bool { translationRetryAvailable }
    var testTranslations: [String: String] { translations }
    var testIsTranslating: Bool { translating }
    func testSetTranslator(_ value: MacTranslator) { translator = value }
    func testRetryTranslation() { retryTranslation() }
    func testOpenEmoji() { openEmoji(nil) }
    func testShowEmojiGroup(_ id: String) { showEmojiGroup(id) }
    var testHostingIdentity: ObjectIdentifier? { hosting.map(ObjectIdentifier.init) }
    func testClickCandidate(_ offset: Int) { chooseVisible(offset) }
    func testSetTranslations(_ values: [String: String]) {
        translationTask?.cancel(); translationAttempt = nil; translating = false; translations = values
    }
    #endif
    private func currentSettings() -> DesktopSettings {
        #if DEBUG
        if let testSettings { return testSettings }
        #endif
        return DesktopSettingsStore.load()
    }
    private let replacement = NSRange(location: NSNotFound, length: NSNotFound)

    override func activateServer(_ sender: Any!) {
        traceInteraction("activate")
        #if DEBUG
        if testSettings == nil { super.activateServer(sender) }
        #else
        super.activateServer(sender)
        #endif
        hostClient = sender as? any IMKTextInput
        active = true
        catalogRefresh?.cancel()
        catalogRefresh = Task { @MainActor [weak self] in
            _ = await Self.catalogLoad.value
            guard let self, active, !Task.isCancelled, !waitingForSelection else { return }
            if state.browsingSymbols { showEmojiGroup(emojiGroupID); return }
            guard !state.input.isEmpty, !loading else { return }
            let selectedID = state.candidates.indices.contains(state.selected) ? state.candidates[state.selected].id : nil
            let values = settings.english ? baseCandidates : catalog.candidates(from: baseCandidates, input: state.input, category: category)
            _ = state.publish(values, generation: state.generation)
            if let selectedID, let index = state.candidates.firstIndex(where: { $0.id == selectedID }) { state.highlight(index) }
            show(); translateVisible()
        }
        settings = currentSettings()
        state.configure(layout: settings.layout, english: settings.english)
        if lexicon == nil, let url = Bundle.main.url(forResource: "lexicon", withExtension: "sqlite",
                                                    subdirectory: "DictionaryResources") {
            #if DEBUG
            let learnedURL = testSettings == nil ? DesktopSettingsStore.learnedURL : testLearnedURL
            #else
            let learnedURL: URL? = DesktopSettingsStore.learnedURL
            #endif
            lexicon = try? Lexicon(url: url, learnedURL: learnedURL)
        }
    }
    override func deactivateServer(_ sender: Any!) {
        traceInteraction("deactivate")
        catalogRefresh?.cancel()
        finish(); active = false; hostClient = nil
        #if DEBUG
        if testSettings == nil { super.deactivateServer(sender) }
        #else
        super.deactivateServer(sender)
        #endif
    }
    override func commitComposition(_ sender: Any!) { traceInteraction("commitComposition"); finish() }
    override func hidePalettes() { traceInteraction("hidePalettes"); panel?.orderOut(nil) }

    override func inputText(_ string: String!, key keyCode: Int, modifiers flags: Int, client sender: Any!) -> Bool {
        let string = string ?? ""
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(flags)), timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0, context: nil, characters: string, charactersIgnoringModifiers: string,
            isARepeat: false, keyCode: UInt16(clamping: keyCode)) else { return false }
        return process(event, client: sender)
    }
    private func process(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event, event.type == .keyDown else { return false }
        if !active { activateServer(sender) }
        hostClient = sender as? any IMKTextInput
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) || flags.contains(.control) { finish(); return false }
        if flags.contains(.capsLock) { finish(); return false }
        if flags.contains(.option) {
            if event.keyCode == 36, !state.input.isEmpty { select(state.selected, translated: true); return true }
            finish(); return false
        }
        if waitingForSelection, event.keyCode == 53 {
            pending = []; requestedSelection = nil; punctuationSuffix = nil
            clear(); mark(); return true
        }
        if interruptsPendingSelection(event) {
            // A command cannot be replayed as insertText after an asynchronous
            // selection. Cancel the unfinished choice and edit/navigate the
            // spelling still displayed; unhandled commands return to the host
            // synchronously. Earlier queued text retains its original order.
            var cancelled = false
            while waitingForSelection || pendingTranslation != nil {
                selectionTask?.cancel(); selectionTask = nil
                if pendingTranslation != nil {
                    translationTask?.cancel(); translationRequest = nil; translating = false
                    translationAttempt = nil; translationRetryAvailable = false; status = ""
                }
                pendingTranslation = nil; waitingForSelection = false
                requestedSelection = nil; punctuationSuffix = nil
                cancelled = true
                drain()
            }
            if cancelled { show() }
        }
        if waitingForSelection {
            // Preserve subsequent keystrokes until a fast space-before-lookup selection resolves.
            pending.append(event)
            return true
        }
        let text = event.characters ?? ""
        if state.input.isEmpty, !state.browsingSymbols {
            let next = currentSettings()
            if next.revision != settings.revision { translations = [:] }
            settings = next
            state.configure(layout: settings.layout, english: settings.english)
            category = .frequency; categoriesVisible = false; expanded = false; emojiGroupID = ""
        }
        if state.isActive, ["-", "+", "=", "[", "]"].contains(text) {
            focusRow(text == "-" || text == "[" ? -1 : 1)
            return true
        }
        if state.isActive, event.keyCode == 48 {
            let categories = DesktopCandidateCategory.allCases
            let current = categories.firstIndex(of: category) ?? 0
            let next = (current + (flags.contains(.shift) ? categories.count - 1 : 1)) % categories.count
            changeCategory(categories[next]); return true
        }
        if !settings.english, !state.input.isEmpty, event.keyCode == 49, flags.contains(.shift) {
            changeCategory(.decomposition); return true
        }
        if state.isActive, settings.translationEnabled, flags.contains(.shift),
           let digit = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9][Int(event.keyCode)] {
            if !loading, let index = numberedCandidate(digit) { select(index, translated: true) }
            return true
        }
        if state.browsingSymbols, text != " ", Int(text) == nil,
           ![36, 76, 53, 123, 124, 125, 126, 116, 121].contains(event.keyCode) {
            clear()
        }
        if !settings.english, (text != "'" || state.input.isEmpty), let symbol = punctuation.convert(text) {
            if state.input.isEmpty { hostClient?.insertText(symbol, replacementRange: replacement) }
            else if !loading, state.candidates.isEmpty {
                commitRaw()
                hostClient?.insertText(symbol, replacementRange: replacement)
            }
            else {
                punctuationSuffix = symbol
                if loading { waitingForSelection = true; requestedSelection = state.selected }
                else { select(state.selected, translated: false) }
            }
            return true
        }
        switch event.keyCode {
        case 53:
            guard state.isActive else { return false }
            if expanded { expanded = false; categoriesVisible = false; show(); return true }
            clear(); hostClient?.setMarkedText("", selectionRange: NSRange(location: 0, length: 0), replacementRange: replacement)
        case 51:
            guard !state.input.isEmpty else { return false }
            resetLearning()
            state.backspace(); refresh()
        case 117:
            guard !state.input.isEmpty else { return false }
            resetLearning()
            state.deleteForward(); refresh()
        case 115, 119:
            guard !state.input.isEmpty else { return false }
            state.moveCursor(event.keyCode == 115 ? Int.min : Int.max); mark()
        case 36, 76:
            guard state.isActive else { return false }
            if state.browsingSymbols { select(state.selected, translated: false) }
            else { commitRaw() }
        case 49:
            guard state.isActive else { return false }
            if loading { waitingForSelection = true; requestedSelection = state.selected }
            else if state.candidates.isEmpty { commitRaw() }
            else { select(state.selected, translated: false) }
        case 123, 124:
            guard state.isActive else { return false }
            if state.browsingSymbols { state.moveSelection(event.keyCode == 123 ? -1 : 1); show(); translateVisible() }
            else { state.moveCursor(event.keyCode == 123 ? -1 : 1); mark() }
        case 116, 121:
            guard state.isActive else { return false }
            page(event.keyCode == 116 ? -1 : 1)
        case 125, 126:
            guard state.isActive else { return false }
            candidateInteracted = true
            let amount = (event.keyCode == 125 ? 1 : -1) * (expandedLayout ? 4 : 1)
            state.moveSelection(amount); show(); translateVisible()
        default:
            if state.isActive, let digit = Int(text), (1...9).contains(digit) {
                if loading, !expandedLayout, digit <= DesktopComposition.pageSize { waitingForSelection = true; requestedSelection = state.pageStart + digit - 1 }
                else if !loading, let index = numberedCandidate(digit) { select(index, translated: false) }
            } else if !text.isEmpty, text.unicodeScalars.allSatisfy({ $0.isASCII && CharacterSet.letters.contains($0) }) || text == "'" {
                resetLearning()
                _ = state.append(text); refresh()
            } else {
                finish(); return false
            }
        }
        return true
    }
    private func numberedCandidate(_ digit: Int) -> Int? {
        let offset: Int
        if expandedLayout {
            guard (1...4).contains(digit) else { return nil }
            offset = (state.selected - state.pageStart) / 4 * 4 + digit - 1
        } else { offset = digit - 1 }
        guard state.visible.indices.contains(offset) else { return nil }
        return state.pageStart + offset
    }
    private func focusRow(_ direction: Int) {
        candidateInteracted = true
        guard expandedLayout else { page(direction); return }
        guard !loading, !state.visible.isEmpty else { return }
        let offset = state.selected - state.pageStart
        let row = offset / 4 + direction
        if row >= 0, row * 4 < state.visible.count {
            state.highlight(state.pageStart + min(row * 4 + offset % 4, state.visible.count - 1))
            show(); translateVisible()
        } else {
            let previous = state.pageStart
            page(direction)
            if direction < 0, state.pageStart != previous {
                state.highlight(state.pageStart + (state.visible.count - 1) / 4 * 4); show()
            }
        }
    }
    private func page(_ direction: Int) {
        candidateInteracted = true
        if direction < 0 { moreLookup?.cancel(); loadingMore = false }
        categoriesVisible = true
        if !expandedLayout { expanded = true; show(); translateVisible(); return }
        if direction > 0, !state.canPageForward, canLoadMore, category == .frequency {
            loadMoreCandidates(); return
        }
        let previous = state.pageStart
        state.movePage(direction)
        show()
        if state.pageStart != previous { translateVisible() }
    }
    private func loadMoreCandidates() {
        guard !loading, !loadingMore, !waitingForSelection, let lexicon, !state.input.isEmpty else { return }
        let token = state.generation, raw = state.input, spelling = state.displayInput, snapshot = settings
        let oldCount = baseCandidates.count, selected = state.selected
        let oldPage = state.pageStart
        let selectedID = state.candidates.indices.contains(selected) ? state.candidates[selected].id : nil
        let requested = candidateLimit + 48
        loadingMore = true; show()
        moreLookup = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let values = try await MacCandidateLookup.candidates(for: raw, layout: snapshot.layout, script: snapshot.script,
                    englishMode: snapshot.english, lexicon: lexicon, displayInput: spelling, limit: requested,
                    pinyinPolicy: .configured(snapshot.fuzzyPinyinOptions))
                guard active, !Task.isCancelled, token == state.generation, category == .frequency else { return }
                candidateLimit = requested; canLoadMore = values.count > oldCount
                loadingMore = false; baseCandidates = values
                let displayed = catalog.candidates(from: values, input: raw, category: category)
                guard state.publish(displayed, generation: token) else { return }
                let restored = selectedID.flatMap { id in state.candidates.firstIndex { $0.id == id } } ?? selected
                state.highlight(restored)
                show() // Rebuild pages before navigating into newly loaded choices.
                state.movePage(1)
                show()
                if state.pageStart != oldPage { translateVisible() }
            } catch {
                guard active, !Task.isCancelled, token == state.generation else { return }
                loadingMore = false; status = error.localizedDescription; show()
            }
        }
    }
    private func changeCategory(_ value: DesktopCandidateCategory) {
        candidateInteracted = true
        traceInteraction("category-\(value.rawValue)-begin")
        defer { traceInteraction("category-\(value.rawValue)-end") }
        guard !waitingForSelection else { return }
        moreLookup?.cancel(); loadingMore = false
        categoriesVisible = true; expanded = true; category = value; emojiGroupID = ""
        translationTask?.cancel(); translationRequest = nil; status = ""
        translationAttempt = nil; translationRetryAvailable = false; translating = false
        if state.browsingSymbols {
            if value == .emoji { showEmojiGroup("") }
            else { clear(); mark() }
            return
        }
        guard !loading else { show(); return }
        if baseCandidates.isEmpty, value != .emoji, !state.input.isEmpty {
            refresh(); return
        }
        _ = state.publish(catalog.candidates(from: baseCandidates, input: state.input, category: category), generation: state.generation)
        show(); translateVisible()
    }
    private func showEmojiGroup(_ id: String) {
        traceInteraction("emoji-group")
        guard !waitingForSelection else { return }
        // The user's explicit group wins over a keyword lookup already in flight.
        lookup?.cancel(); loading = false
        emojiGroupID = id; category = .emoji; categoriesVisible = true; expanded = true
        let symbols = catalog.emojiCategories.filter { id.isEmpty || $0.id == id }.flatMap(\.emojis)
        if state.input.isEmpty { state.presentSymbols(symbols) }
        else {
            _ = state.publish(symbols.map { Candidate(text: $0, reading: state.input, consumed: state.input.count) }, generation: state.generation)
        }
        translationTask?.cancel(); translationRequest = nil; status = ""
        translationAttempt = nil; translationRetryAvailable = false; translating = false
        show()
    }
    private func refresh() {
        candidateInteracted = false
        moreLookup?.cancel(); loadingMore = false; candidateLimit = 48
        canLoadMore = !settings.english && settings.layout == .pinyin && !state.input.isEmpty
        lookup?.cancel(); selectionTask?.cancel(); translationTask?.cancel(); translationRequest = nil; translating = false; status = ""; loading = false
        translationAttempt = nil; translationRetryAvailable = false
        mark()
        baseCandidates = []
        guard !state.input.isEmpty else { panel?.orderOut(nil); category = .frequency; categoriesVisible = false; expanded = false; return }
        let token = state.generation, raw = state.input, spelling = state.displayInput, snapshot = settings
        loading = true; show()
        lookup = Task { @MainActor [weak self] in
            guard let self else { return }
            var values: [Candidate] = []
            var publishedInitial = false
            if lexicon == nil, !snapshot.english { status = "词库未能加载，请重新安装输入法。" }
            do {
                values = try await MacCandidateLookup.candidates(for: raw, layout: snapshot.layout, script: snapshot.script,
                    englishMode: snapshot.english, lexicon: lexicon, displayInput: spelling, limit: 48,
                    pinyinPolicy: .configured(snapshot.fuzzyPinyinOptions),
                    completionProvider: lookupCompletionProvider,
                    onInitial: { [weak self] initial in
                        guard let self, active, !Task.isCancelled, token == state.generation else { return }
                        publishedInitial = true
                        publishLookup(initial, generation: token)
                    })
            } catch { if !Task.isCancelled { status = error.localizedDescription } }
            guard active, !Task.isCancelled, token == state.generation else { return }
            // A late spelling reply must not change a choice the user is
            // navigating, translating or resolving inside Rime.
            if publishedInitial {
                guard !waitingForSelection, !candidateInteracted, !loadingMore,
                      candidateLimit == 48, values != baseCandidates else { return }
            }
            publishLookup(values, generation: token)
        }
    }
    private var lookupCompletionProvider: ((String) async -> [String]?)? {
        #if DEBUG
        return testCompletionProvider
        #else
        return nil
        #endif
    }
    private func publishLookup(_ values: [Candidate], generation token: UUID) {
        baseCandidates = values
        let displayed = settings.english ? values : catalog.candidates(from: values, input: state.input, category: category)
        guard state.publish(displayed, generation: token) else { return }
        loading = false
        if waitingForSelection {
            // Fit the real current page before interpreting a queued number.
            show()
            waitingForSelection = false
            let index = requestedSelection ?? state.selected
            requestedSelection = nil
            if state.candidates.isEmpty {
                let suffix = punctuationSuffix ?? ""
                punctuationSuffix = nil
                commitRaw()
                if !suffix.isEmpty { hostClient?.insertText(suffix, replacementRange: replacement) }
            } else if state.visibleRange.contains(index) {
                select(index, translated: false)
            } else {
                punctuationSuffix = nil
                show(); translateVisible()
            }
            drain()
        } else { show(); translateVisible() }
    }
    private func select(_ index: Int, translated: Bool) {
        candidateInteracted = true
        traceInteraction("select-\(index)")
        guard state.candidates.indices.contains(index) else { return }
        let candidate = state.candidates[index]
        if state.browsingSymbols {
            guard let value = state.commit(index: index) else { return }
            hostClient?.insertText(value, replacementRange: replacement)
            clear(); return
        }
        if translated, translations[candidate.text] == nil {
            guard settings.translationEnabled, !catalog.isEmoji(candidate.text) else { return }
            state.highlight(index)
            pendingTranslation = (index, state.generation); waitingForSelection = true
            translationRequest = nil; status = ""
            translateVisible(); show(); return
        }
        // Resolving a Rime candidate actually selects it inside the engine and can
        // change learned ordering. Resolve only the user's chosen candidate.
        if candidate.consumed == 0, let lexicon {
            let token = state.generation, raw = state.input, snapshot = settings
            waitingForSelection = true
            selectionTask = Task { @MainActor [weak self] in
                guard let self else { return }
                let resolved = await lexicon.resolve(candidate, for: raw, layout: snapshot.layout, script: snapshot.script,
                                                     pinyinPolicy: .configured(snapshot.fuzzyPinyinOptions))
                guard active, !Task.isCancelled, token == state.generation else { return }
                waitingForSelection = false
                if let resolved, state.resolveCandidate(resolved, at: index, generation: token) {
                    select(index, translated: translated)
                } else {
                    status = "候选已变化，请重新选择。"; show()
                }
                drain()
            }
            return
        }
        let value: String
        if translated {
            guard let ready = translations[candidate.text] else { status = "译文尚未就绪，请稍后按 Option + 回车。"; show(); return }
            value = ready
        } else { value = candidate.text }
        let code = state.input
        guard state.commit(index: index) != nil else { return }
        if !translated, !settings.english {
            if !state.input.isEmpty {
                if learningCode.isEmpty { learningCode = code }
                learningText += candidate.text
            } else if !learningCode.isEmpty, let lexicon {
                let original = learningCode, phrase = learningText + candidate.text, snapshot = settings
                Task { try? await lexicon.learn(code: original, text: phrase, layout: snapshot.layout, script: snapshot.script,
                                               pinyinPolicy: .configured(snapshot.fuzzyPinyinOptions)) }
                resetLearning()
            }
        } else { resetLearning() }
        hostClient?.insertText(value + (settings.english && !translated ? " " : ""), replacementRange: replacement)
        if let suffix = punctuationSuffix {
            if state.input.isEmpty {
                punctuationSuffix = nil
                refresh()
                hostClient?.insertText(suffix, replacementRange: replacement)
            } else {
                waitingForSelection = true; requestedSelection = 0
                refresh()
            }
        } else { refresh() }
    }
    private func drain() {
        while !waitingForSelection, !pending.isEmpty {
            let event = pending.removeFirst()
            if !process(event, client: hostClient), let text = event.characters,
               !text.isEmpty, !containsCommandCharacters(text) {
                hostClient?.insertText(text, replacementRange: replacement)
            }
        }
    }
    private func interruptsPendingSelection(_ event: NSEvent) -> Bool {
        // Navigation, editing and native function keys must be handled while
        // their original event can still be passed through to the host app.
        if [24, 27, 30, 33, 36, 48, 51, 76, 115, 116, 117, 119, 121, 123, 124, 125, 126].contains(event.keyCode) {
            return true
        }
        let text = event.characters ?? ""
        return text.isEmpty || containsCommandCharacters(text)
    }
    private func containsCommandCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0) || (0xF700...0xF8FF).contains($0.value)
        }
    }
    private func commitRaw() {
        let raw = state.displayInput
        clear()
        if !raw.isEmpty { hostClient?.insertText(raw, replacementRange: replacement) }
    }
    private func finish() {
        traceInteraction("finish")
        let queued = pending; pending = []
        let suffix = punctuationSuffix ?? ""
        punctuationSuffix = nil
        let space = waitingForSelection && settings.english ? " " : ""
        commitRaw()
        if !space.isEmpty { hostClient?.insertText(space, replacementRange: replacement) }
        if !suffix.isEmpty { hostClient?.insertText(suffix, replacementRange: replacement) }
        // End the old client's session synchronously; never send late results into a new field.
        for event in queued {
            if let text = event.characters, !text.isEmpty, !containsCommandCharacters(text) {
                hostClient?.insertText(text, replacementRange: replacement)
            }
        }
        translator.cancelPending()
    }
    private func clear() {
        traceInteraction("clear")
        resetLearning()
        moreLookup?.cancel(); loadingMore = false; canLoadMore = false; candidateLimit = 48
        lookup?.cancel(); selectionTask?.cancel(); translationTask?.cancel(); translationRequest = nil; state.clear(); translations = [:]
        translationAttempt = nil; translationRetryAvailable = false
        loading = false; waitingForSelection = false; requestedSelection = nil; punctuationSuffix = nil; panel?.orderOut(nil)
        translating = false; pendingTranslation = nil; lastContent = nil
        baseCandidates = []; category = .frequency; categoriesVisible = false; expanded = false; emojiGroupID = ""
    }
    private func resetLearning() { learningCode = ""; learningText = "" }
    override func menu() -> NSMenu! {
        let menu = NSMenu(title: "伴语")
        let settingsItem = NSMenuItem(title: "伴语输入法设置…", action: #selector(openSettings(_:)), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)
        let emojiItem = NSMenuItem(title: "表情符号…", action: #selector(openEmoji(_:)), keyEquivalent: "")
        emojiItem.target = self
        menu.addItem(emojiItem)
        return menu
    }
    @objc private func openEmoji(_ sender: Any?) {
        if !state.input.isEmpty { changeCategory(.emoji) }
        else { showEmojiGroup("") }
    }
    @objc private func openSettings(_ sender: Any?) {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.learnkeyboard.app") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }
    private func mark() {
        let text = NSMutableAttributedString(string: state.displayInput)
        let range = NSRange(location: 0, length: text.length)
        // Use InputMethodKit's native raw-composition attributes. The host
        // owns the insertion caret; neither text nor panel contains a fake one.
        if text.length > 0,
           let attributes = mark(forStyle: kTSMHiliteSelectedRawText, at: range) as? [NSAttributedString.Key: Any] {
            text.setAttributes(attributes, range: range)
        }
        hostClient?.setMarkedText(text, selectionRange: NSRange(location: state.cursor, length: 0), replacementRange: replacement)
    }
    private func chooseVisible(_ offset: Int) {
        guard !loading, !waitingForSelection, state.visible.indices.contains(offset) else { return }
        select(state.pageStart + offset, translated: false)
    }
    @discardableResult private func commitWaitingTranslationIfReady() -> Bool {
        guard let waiting = pendingTranslation, waiting.generation == state.generation,
              state.candidates.indices.contains(waiting.index),
              translations[state.candidates[waiting.index].text] != nil else { return false }
        pendingTranslation = nil; waitingForSelection = false
        select(waiting.index, translated: true); drain()
        return true
    }
    private func retryTranslation() {
        guard active, !loading, !translating, !waitingForSelection, category != .emoji else { return }
        translationRequest = nil
        translationRetryAvailable = false
        status = ""
        traceInteraction("translation-manual-retry")
        translateVisible()
    }
    private func translateVisible() {
        guard settings.translationEnabled, category != .emoji, !state.visible.isEmpty else { return }
        let token = state.generation, page = state.pageStart, snapshot = settings
        let visible = state.visible.map(\.text)
        let priority = state.candidates[state.selected].text
        let texts = translator.translatableTexts(([priority] + visible.filter { $0 != priority })
            .filter { !catalog.isEmoji($0) }, settings: snapshot)
        // Include category and text identity; a different candidate set can
        // occupy the same numeric page range without changing the spelling.
        let requestID = "\(token)|\(category.rawValue)|\(state.visibleRange)|\(texts.sorted())"
        guard translationRequest != requestID else { return }
        translationTask?.cancel()
        translationAttempt = nil
        translationRetryAvailable = false
        translating = false
        status = ""
        translationRequest = requestID
        guard !texts.isEmpty else { show(); return }
        translations.merge(translator.cached(texts, settings: snapshot), uniquingKeysWith: { _, new in new })
        if commitWaitingTranslationIfReady() { return }
        translating = texts.contains(where: { translations[$0] == nil })
        if translating { status = "正在翻译…" }
        show()
        guard translating else { return }
        let attempt = UUID()
        translationAttempt = attempt
        traceInteraction("translation-start")
        translationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .milliseconds(snapshot.provider == .siliconFlow ? 150 : 40))
                let output = try await translator.translate(texts, settings: snapshot, onProgress: { [weak self] progress in
                    guard let self, active, !Task.isCancelled, translationAttempt == attempt,
                          token == state.generation, page == state.pageStart else { return }
                    switch progress {
                    case .requesting:
                        let complete = texts.filter { self.translations[$0] != nil }.count
                        status = "正在翻译 \(complete)/\(texts.count)…"
                    case .retrying(_, _, let reason):
                        status = reason == .timeout ? "翻译请求超时，正在自动重试（1/1）…" : "翻译暂时失败，正在自动重试（1/1）…"
                        traceInteraction("translation-auto-retry")
                    }
                    show()
                }, onLocalRecovery: { [weak self] in
                    guard let self, active, !Task.isCancelled, translationAttempt == attempt,
                          token == state.generation, page == state.pageStart else { return }
                    status = "正在恢复本机翻译…"
                    traceInteraction("translation-local-recovery")
                    show()
                }) { [weak self] text, value in
                    guard let self, active, !Task.isCancelled, translationAttempt == attempt,
                          token == state.generation, page == state.pageStart else { return }
                    translations[text] = value
                    let complete = texts.filter { self.translations[$0] != nil }.count
                    status = complete < texts.count ? "正在翻译 \(complete)/\(texts.count)…" : ""
                    if !commitWaitingTranslationIfReady() { show() }
                }
                guard active, !Task.isCancelled, translationAttempt == attempt,
                      token == state.generation, page == state.pageStart else { return }
                translations.merge(output, uniquingKeysWith: { _, new in new })
                guard texts.allSatisfy({ self.translations[$0]?.isEmpty == false }) else { throw MacTranslator.LocalFailure.incomplete }
                status = ""; translating = false; translationAttempt = nil; translationRetryAvailable = false
                traceInteraction("translation-complete")
                if !commitWaitingTranslationIfReady() {
                    if pendingTranslation != nil {
                        pendingTranslation = nil; waitingForSelection = false
                        status = "这个候选尚未返回译文，可重试 Shift + 数字，或直接输入原词。"
                        drain()
                    }
                    show()
                }
            } catch {
                guard active, !Task.isCancelled, translationAttempt == attempt,
                      token == state.generation, page == state.pageStart else { return }
                // Keep the failed request identity so layout/selection updates
                // do not cause an unbounded retry loop. The button starts anew.
                status = error.localizedDescription; translating = false
                translationAttempt = nil; translationRetryAvailable = true
                traceInteraction("translation-failed", error: error)
                if pendingTranslation != nil { pendingTranslation = nil; waitingForSelection = false; drain() }
                show()
            }
        }
    }
    private func show() {
        guard active, state.isActive else { traceInteraction("show-hide"); panel?.orderOut(nil); return }
        if loading, panel?.isVisible == true, var content = lastContent, !content.values.isEmpty {
            content.input = state.displayInput
            content.loading = true; content.translating = false
            lastContent = content
            hosting?.rootView = content
            return
        }
        if panel == nil {
            let value = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            value.level = .popUpMenu; value.hasShadow = true; value.isOpaque = false
            value.backgroundColor = .clear; value.hidesOnDeactivate = false
            value.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel = value
        }
        var caret = NSRect.zero
        _ = hostClient?.attributes(forCharacterIndex: 0, lineHeightRectangle: &caret)
        let screen = NSScreen.screens.first { $0.frame.intersects(caret) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let candidateWidthBudget = max(240, visible.width - 96)
        let maximumCellWidth = expandedLayout ? min(140, floor((visible.width - 46) / 4))
            : CandidateMetrics.maximumCellWidth(availableWidth: candidateWidthBudget, candidateCount: state.candidates.count)
        let previousRange = state.visibleRange
        if expandedLayout {
            state.paginate(widths: Array(repeating: 1, count: state.candidates.count), availableWidth: 12, maximumCount: 12)
        } else {
            let widths = state.candidates.map { candidate in
                Double(CandidateMetrics.width(candidate,
                    translation: settings.translationEnabled && category != .emoji ? translations[candidate.text] : nil,
                    maximum: maximumCellWidth) + 2)
            }
            state.paginate(widths: widths, availableWidth: Double(candidateWidthBudget))
        }
        let presentationGeneration = state.generation
        let content = CandidateView(input: state.displayInput, values: state.visible, translations: translations,
            selected: state.selected - state.pageStart, status: status,
            translationEnabled: settings.translationEnabled && category != .emoji, style: settings.candidateLayout,
            maximumCellWidth: maximumCellWidth,
            canPrevious: state.canPageBackward,
            canNext: state.canPageForward || (category == .frequency && canLoadMore && !loadingMore),
            highlight: { [weak self] offset in
                guard let self else { return }
                candidateInteracted = true
                state.highlight(state.pageStart + offset); show(); translateVisible()
            },
            choose: { [weak self] offset in
                guard let self, state.generation == presentationGeneration else { return }
                chooseVisible(offset)
            }, page: { [weak self] direction in self?.page(direction) },
            loading: loading, translating: translating,
            expanded: expandedLayout, category: category, categoriesVisible: categoriesVisible || expandedLayout,
            categoryDetail: state.candidates.indices.contains(state.selected)
                ? catalog.annotation(for: state.candidates[state.selected].text, category: category) ?? "" : "",
            emojiGroups: catalog.emojiCategories, emojiGroupID: emojiGroupID,
            setCategory: { [weak self] in self?.changeCategory($0) },
            toggleCategories: { [weak self] in
                guard let self else { return }; candidateInteracted = true; expanded.toggle(); categoriesVisible = expanded; show(); translateVisible()
            }, setEmojiGroup: { [weak self] in self?.showEmojiGroup($0) },
            openSettings: { [weak self] in self?.openSettings(nil) },
            canRetryTranslation: translationRetryAvailable,
            retryTranslation: { [weak self] in
                guard let self, state.generation == presentationGeneration else { return }
                retryTranslation()
            })
        lastContent = content
        if let hosting { hosting.rootView = content }
        else {
            let view = NSHostingView(rootView: content)
            hosting = view; panel?.contentView = view
        }
        guard let hosting else { return }
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        if caret == .zero { caret = NSRect(x: visible.midX, y: visible.midY, width: 1, height: 20) }
        let x = min(max(caret.minX, visible.minX), visible.maxX - size.width)
        let below = caret.minY - size.height - 6
        let y = max(visible.minY, min(below < visible.minY ? caret.maxY + 6 : below, visible.maxY - size.height))
        let frame = NSRect(origin: NSPoint(x: x, y: y), size: size)
        if panel?.frame != frame { panel?.setFrame(frame, display: true) }
        panel?.level = NSWindow.Level(rawValue: max(NSWindow.Level.floating.rawValue, Int(hostClient?.windowLevel() ?? 0) + 1))
        if panel?.isVisible != true { panel?.orderFrontRegardless() }
        if previousRange != state.visibleRange {
            Task { @MainActor [weak self] in self?.translateVisible() }
        }
    }
}
