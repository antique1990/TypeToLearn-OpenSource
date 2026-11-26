import SwiftUI
import UIKit
import KeyboardCore

private final class KeyboardInputView: UIInputView, UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
}

@MainActor
final class KeyboardViewController: UIInputViewController {
    private let model = KeyboardModel()
    private let keyClickSound = KeyClickSound()
    private var host: UIHostingController<KeyboardView>?
    private var heightConstraint: NSLayoutConstraint?
    private var applyingKeyboardEdit = false
    private var compositionDocumentIdentifier: UUID?
    private var compositionContext: ComposingTextContext?
    private var selectionUpdate: Task<Void, Never>?
    private struct EndedComposition {
        var context: ComposingTextContext
        var document: UUID
        var input: String
        var english: Bool
        var layout: KeyboardLayout
    }
    private var endedComposition: EndedComposition?
    private var ownSelection: (cursor: Int, time: TimeInterval)?

    override func loadView() {
        let keyboardInputView = KeyboardInputView(frame: .zero, inputViewStyle: .keyboard)
        inputView = keyboardInputView
        view = keyboardInputView
    }

    private func applyKeyboardEdit(_ edit: () -> Void) {
        selectionUpdate?.cancel()
        endedComposition = nil
        applyingKeyboardEdit = true
        defer { applyingKeyboardEdit = false }
        edit()
    }

    private func showComposition(_ input: String, cursor: Int) {
        let proxy = textDocumentProxy
        let cursor = min(input.count, max(0, cursor))
        if let context = compositionContext, compositionDocumentIdentifier == proxy.documentIdentifier {
            guard let previousCursor = context.editingCursor(preceding: proxy.documentContextBeforeInput,
                following: proxy.documentContextAfterInput, selected: proxy.selectedText, includingEnd: true) else {
                finishHostComposition()
                return
            }
            replaceComposition(context.text, at: previousCursor, with: input, cursor: cursor)
            compositionContext?.text = input
        } else if !input.isEmpty {
            compositionContext = ComposingTextContext(text: input,
                preceding: proxy.documentContextBeforeInput ?? "",
                following: proxy.documentContextAfterInput ?? "")
            compositionDocumentIdentifier = proxy.documentIdentifier
            applyKeyboardEdit {
                proxy.insertText(input)
                if cursor != input.count { proxy.adjustTextPosition(byCharacterOffset: cursor - input.count) }
            }
        }
        if input.isEmpty {
            compositionContext = nil
            compositionDocumentIdentifier = nil
            ownSelection = nil
        } else {
            ownSelection = (cursor, Date.timeIntervalSinceReferenceDate)
        }
    }

    // Keep composing code readable through the public proxy. With setMarkedText,
    // UIKit can suppress selection callbacks and hide the code from proxy context.
    // Replace only the differing portion of a verified, owned composing span.
    private func replaceComposition(_ old: String, at oldCursor: Int, with new: String, cursor: Int) {
        if old == new {
            if cursor != oldCursor {
                applyKeyboardEdit { textDocumentProxy.adjustTextPosition(byCharacterOffset: cursor - oldCursor) }
            }
            return
        }
        let prefix = zip(old, new).prefix(while: { $0 == $1 }).count
        let suffix = zip(old.dropFirst(prefix).reversed(), new.dropFirst(prefix).reversed())
            .prefix(while: { $0 == $1 }).count
        let removalEnd = old.count - suffix
        let inserted = String(new.dropFirst(prefix).dropLast(suffix))
        let proxy = textDocumentProxy
        applyKeyboardEdit {
            if removalEnd != oldCursor { proxy.adjustTextPosition(byCharacterOffset: removalEnd - oldCursor) }
            for _ in prefix..<removalEnd { proxy.deleteBackward() }
            if !inserted.isEmpty { proxy.insertText(inserted) }
            let resultingCursor = prefix + inserted.count
            if cursor != resultingCursor { proxy.adjustTextPosition(byCharacterOffset: cursor - resultingCursor) }
        }
    }

    private func insert(_ text: String) {
        let proxy = textDocumentProxy
        if let context = compositionContext, compositionDocumentIdentifier == proxy.documentIdentifier {
            guard let cursor = context.editingCursor(preceding: proxy.documentContextBeforeInput,
                following: proxy.documentContextAfterInput, selected: proxy.selectedText, includingEnd: true) else {
                finishHostComposition()
                return
            }
            replaceComposition(context.text, at: cursor, with: text, cursor: text.count)
        } else {
            applyKeyboardEdit { proxy.insertText(text) }
        }
        compositionDocumentIdentifier = nil
        compositionContext = nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        model.onInsert = { [weak self] in self?.insert($0) }
        model.onDelete = { [weak self] in self?.applyKeyboardEdit { self?.textDocumentProxy.deleteBackward() } }
        model.onCompositionChanged = { [weak self] in self?.showComposition($0, cursor: $1) }
        model.contextBeforeInput = { [weak self] in self?.textDocumentProxy.documentContextBeforeInput }
        model.onNextKeyboard = { [weak self] in
            self?.finishHostComposition()
            self?.advanceToNextInputMode()
        }
        model.onDismissKeyboard = { [weak self] in self?.dismissKeyboard() }
        model.onCursorMove = { [weak self] offset in
            self?.applyKeyboardEdit { self?.textDocumentProxy.adjustTextPosition(byCharacterOffset: offset) }
        }
        model.onHeightNeedsUpdate = { [weak self] in self?.updateKeyboardHeight() }
        model.onKeyClick = { [weak self] kind in
            guard let self else { return }
            let settings = self.model.settings
            if !self.keyClickSound.play(kind, style: settings.keySoundStyle, volume: settings.keySoundVolume) {
                UIDevice.current.playInputClick()
            }
        }
        let host = UIHostingController(rootView: KeyboardView(model: model))
        // The system draws the rounded tray. Keep controller layers clear and let
        // KeyboardView provide one hittable background matched to the tray color.
        view.backgroundColor = .clear
        inputView?.backgroundColor = .clear
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(host)
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        host.didMove(toParent: self)
        self.host = host
        let height = view.heightAnchor.constraint(equalToConstant: 260)
        height.priority = .defaultHigh
        height.isActive = true
        heightConstraint = height
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        model.fullAccess = hasFullAccess
        model.needsInputModeSwitchKey = needsInputModeSwitchKey
        model.reloadSettings()
        if model.settings.keySoundEnabled {
            keyClickSound.prepare(style: model.settings.keySoundStyle, volume: model.settings.keySoundVolume)
        }
        model.refresh()
        updateReturnKey()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateKeyboardHeight()
        let needsSwitch = needsInputModeSwitchKey
        if model.needsInputModeSwitchKey != needsSwitch {
            model.needsInputModeSwitchKey = needsSwitch
        }
    }

    private func updateKeyboardHeight() {
        let largeType = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        let typingHeight = model.usesLetterLayout ? KeyboardLetterMetrics.keyboardHeight : 260
        let desired = (largeType ? max(typingHeight, 300) : typingHeight) + (model.settings.wrapCandidateTranslations ? 16 : 0)
        if heightConstraint?.constant != desired { heightConstraint?.constant = desired }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        keyClickSound.stop()
        // The host may already have detached the proxy. Preserve visible raw code
        // instead of attempting a late deletion in a different input session.
        finishHostComposition()
    }

    override func textWillChange(_ textInput: (any UITextInput)?) {
        super.textWillChange(textInput)
        // Wait for the updated proxy context before deciding whether the caret
        // moved within composing text or the host ended composition.
    }

    override func textDidChange(_ textInput: (any UITextInput)?) {
        super.textDidChange(textInput)
        updateReturnKey()
        if !applyingKeyboardEdit {
            if compositionContext != nil || endedComposition != nil { scheduleHostSelection() }
            else { model.refresh() }
        }
    }

    override func selectionDidChange(_ textInput: (any UITextInput)?) {
        super.selectionDidChange(textInput)
        if !applyingKeyboardEdit { scheduleHostSelection() }
    }

    private func scheduleHostSelection() {
        if let ownSelection, Date.timeIntervalSinceReferenceDate - ownSelection.time < 0.15,
           compositionDocumentIdentifier == textDocumentProxy.documentIdentifier,
           compositionContext?.editingCursor(preceding: textDocumentProxy.documentContextBeforeInput,
               following: textDocumentProxy.documentContextAfterInput,
               selected: textDocumentProxy.selectedText, includingEnd: true) == ownSelection.cursor {
            // Host edits can echo asynchronously after the proxy call returns.
            // Do not mistake that echo at the trailing edge for a blank-area tap.
            return
        }
        ownSelection = nil
        selectionUpdate?.cancel()
        selectionUpdate = Task { [weak self] in
            // UIKit may first report the old caret, then the resolved tap position.
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            self?.reconcileHostSelection()
        }
    }

    private func reconcileHostSelection() {
        let proxy = textDocumentProxy
        if let context = compositionContext {
            if compositionDocumentIdentifier == proxy.documentIdentifier,
               let cursor = context.editingCursor(preceding: proxy.documentContextBeforeInput,
                   following: proxy.documentContextAfterInput, selected: proxy.selectedText, includingEnd: true) {
                if cursor < context.text.count { model.moveCompositionCursor(to: cursor) }
                else {
                    let ended = EndedComposition(context: context, document: proxy.documentIdentifier,
                        input: model.english ? model.englishInput : model.composition.input,
                        english: model.english, layout: model.settings.layout)
                    finishHostComposition()
                    endedComposition = ended
                }
            } else { finishHostComposition() }
        } else if let ended = endedComposition {
            guard ended.document == proxy.documentIdentifier, ended.english == model.english,
                  ended.english || ended.layout == model.settings.layout,
                  let cursor = ended.context.editingCursor(preceding: proxy.documentContextBeforeInput,
                    following: proxy.documentContextAfterInput, selected: proxy.selectedText, includingEnd: true) else {
                endedComposition = nil
                return
            }
            if cursor < ended.context.text.count {
                // A host caret gesture may first report the word boundary before
                // resolving its interior position. Resume only the unchanged span.
                compositionContext = ended.context
                compositionDocumentIdentifier = ended.document
                endedComposition = nil
                model.resumeHostComposition(input: ended.input, cursor: cursor)
            }
        }
    }

    private func finishHostComposition() {
        selectionUpdate?.cancel()
        ownSelection = nil
        endedComposition = nil
        compositionDocumentIdentifier = nil
        compositionContext = nil
        model.hostDidEndComposition()
    }

    private func updateReturnKey() {
        switch textDocumentProxy.returnKeyType ?? .default {
        case .send: model.returnTitle = model.text("发送")
        case .search, .google, .yahoo: model.returnTitle = model.text("搜索")
        case .go: model.returnTitle = model.text("前往")
        case .done: model.returnTitle = model.text("完成")
        case .next: model.returnTitle = model.text("下一项")
        default: model.returnTitle = model.text("换行")
        }
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        model.reduceMemory()
    }
}
