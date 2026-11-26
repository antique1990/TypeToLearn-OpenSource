import KeyboardCore
import SwiftUI

struct PunctuationKey: UIViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    let english: Bool
    var audience: KeyboardAudience = .chinese
    let short: () -> Void
    let long: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(short: short, long: long) }

    func makeUIView(context: Context) -> LetterKey.KeyView {
        let button = LetterKey.KeyView(type: .custom)
        button.titleLabel?.font = .systemFont(ofSize: 16)
        button.setTitleColor(.label, for: .normal)
        button.faceColor = Palette.keyUIColor
        button.layer.cornerRadius = 6
        button.addTarget(context.coordinator, action: #selector(Coordinator.pressed(_:)), for: .touchDown)
        button.addTarget(context.coordinator, action: #selector(Coordinator.released(_:)), for: .touchUpInside)
        for event: UIControl.Event in [.touchUpOutside, .touchCancel] {
            button.addTarget(context.coordinator, action: #selector(Coordinator.cancelled(_:)), for: event)
        }
        let press = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.longPressed(_:)))
        press.minimumPressDuration = 0.4
        press.cancelsTouchesInView = false
        button.addGestureRecognizer(press)
        button.isAccessibilityElement = true
        return button
    }

    func updateUIView(_ button: LetterKey.KeyView, context: Context) {
        context.coordinator.short = short
        context.coordinator.long = long
        context.coordinator.english = english
        button.isEnabled = isEnabled
        if !isEnabled { button.hidePopup(immediately: true) }
        button.setTitle(english ? ",." : "，。", for: .normal)
        button.accessibilityLabel = audience.isEnglishOnly ? "Comma, hold for period" : (english ? "英文逗号，长按句号" : "逗号，长按句号")
    }

    @MainActor final class Coordinator: NSObject {
        var short: () -> Void
        var long: () -> Void
        var english = false
        private var didLongPress = false
        init(short: @escaping () -> Void, long: @escaping () -> Void) {
            self.short = short
            self.long = long
        }
        @objc func pressed(_ sender: LetterKey.KeyView) {
            guard sender.isEnabled else { return }
            didLongPress = false
            sender.showPopup(english ? "," : "，")
        }
        @objc func released(_ sender: LetterKey.KeyView) {
            sender.hidePopup()
            if sender.isEnabled && !didLongPress { short() }
        }
        @objc func cancelled(_ sender: LetterKey.KeyView) { sender.hidePopup() }
        @objc func longPressed(_ gesture: UILongPressGestureRecognizer) {
            guard let button = gesture.view as? LetterKey.KeyView, button.isEnabled else { return }
            if gesture.state == .began {
                didLongPress = true
                button.showPopup(english ? "." : "。")
                long()
            } else if gesture.state == .cancelled || gesture.state == .failed {
                button.hidePopup()
            }
        }
    }
}

struct CandidateTouchKey: UIViewRepresentable {
    let text: String
    let identity: String
    let subtitle: String
    let highlighted: Bool
    let wrapSubtitle: Bool
    var audience: KeyboardAudience = .chinese
    let tap: () -> Void
    let longPress: () -> Void
    var identifierPrefix = "candidate"
    var loading = false
    var locked = false
    var unlock: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(tap: tap, longPress: longPress, unlock: unlock) }

    func makeUIView(context: Context) -> CandidateButton {
        let button = CandidateButton(type: .custom)
        button.addTarget(context.coordinator, action: #selector(Coordinator.pressed), for: .touchDown)
        button.addTarget(context.coordinator, action: #selector(Coordinator.released), for: .touchUpInside)
        let gesture = UILongPressGestureRecognizer(target: context.coordinator,
                                                   action: #selector(Coordinator.longPressed(_:)))
        gesture.minimumPressDuration = 0.48
        gesture.cancelsTouchesInView = false
        button.addGestureRecognizer(gesture)
        button.translationLabel.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.unlockTapped)))
        button.isAccessibilityElement = true
        button.accessibilityTraits = .button
        return button
    }

    func updateUIView(_ button: CandidateButton, context: Context) {
        context.coordinator.tap = tap
        context.coordinator.longPress = longPress
        context.coordinator.unlock = unlock
        if button.wordLabel.text != text { button.wordLabel.text = text }
        let wordColor: UIColor = highlighted ? .systemBlue : .label
        if button.wordLabel.textColor != wordColor { button.wordLabel.textColor = wordColor }
        button.translationLabel.isUserInteractionEnabled = locked
        button.typingIndicator.setLoading(loading && !locked)
        let renderedSubtitle = locked ? "" : subtitle
        if button.displayedSubtitle != renderedSubtitle || button.displayedLocked != locked || button.displayedAudience != audience {
            if locked {
                let icon = NSTextAttachment()
                icon.image = UIImage(systemName: "crown.fill")?.withTintColor(.systemOrange, renderingMode: .alwaysOriginal)
                icon.bounds = CGRect(x: 0, y: -1, width: 13, height: 12)
                let label = NSMutableAttributedString(attachment: icon)
                label.append(NSAttributedString(string: audience.isEnglishOnly ? " Unlock" : " 解锁"))
                button.translationLabel.attributedText = label
            } else {
                button.translationLabel.text = renderedSubtitle
            }
            button.displayedSubtitle = renderedSubtitle
            button.displayedLocked = locked
            button.displayedAudience = audience
        }
        let lines = wrapSubtitle ? 2 : 1
        if button.translationLabel.numberOfLines != lines { button.translationLabel.numberOfLines = lines }
        let height: CGFloat = wrapSubtitle ? 30 : 15
        if button.translationHeight.constant != height { button.translationHeight.constant = height }
        button.accessibilityIdentifier = "\(identifierPrefix).\(identity)"
        button.accessibilityLabel = subtitle.isEmpty ? text : text + (audience.isEnglishOnly ? ", " : "，") + subtitle
        button.accessibilityHint = locked ? (audience.isEnglishOnly ? "Type this word. Learning translations require membership." : "输入此候选词。学习译文需要会员解锁。") : audience.text("双击输入候选词，长按直接输入译文")
        button.accessibilityValue = locked ? (audience.isEnglishOnly ? "Learning locked" : "学习译文未解锁")
            : loading ? (audience.isEnglishOnly ? "Translating" : "正在翻译") : nil
        button.accessibilityCustomActions = locked ? [UIAccessibilityCustomAction(name: audience.isEnglishOnly ? "Unlock learning" : "解锁学习", target: context.coordinator, selector: #selector(Coordinator.unlockAccessibility))] : nil
    }

    final class CandidateButton: UIButton {
        let wordLabel = UILabel()
        let translationLabel = UILabel()
        let typingIndicator = CandidateTypingIndicator()
        var translationHeight: NSLayoutConstraint!
        var displayedSubtitle: String?
        var displayedLocked: Bool?
        var displayedAudience: KeyboardAudience?

        override init(frame: CGRect) {
            super.init(frame: frame)
            wordLabel.font = .systemFont(ofSize: 20)
            wordLabel.textAlignment = .center
            wordLabel.adjustsFontSizeToFitWidth = true
            wordLabel.minimumScaleFactor = 0.7
            translationLabel.font = .systemFont(ofSize: 12)
            translationLabel.textColor = .secondaryLabel
            translationLabel.textAlignment = .center
            wordLabel.translatesAutoresizingMaskIntoConstraints = false
            translationLabel.translatesAutoresizingMaskIntoConstraints = false
            addSubview(wordLabel)
            addSubview(translationLabel)
            typingIndicator.translatesAutoresizingMaskIntoConstraints = false
            addSubview(typingIndicator)
            translationHeight = translationLabel.heightAnchor.constraint(equalToConstant: 15)
            NSLayoutConstraint.activate([
                wordLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
                wordLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
                wordLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
                wordLabel.heightAnchor.constraint(equalToConstant: 25),
                translationLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
                translationLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
                translationLabel.bottomAnchor.constraint(equalTo: wordLabel.topAnchor, constant: -1),
                translationHeight,
                typingIndicator.centerXAnchor.constraint(equalTo: translationLabel.centerXAnchor),
                typingIndicator.centerYAnchor.constraint(equalTo: translationLabel.centerYAnchor),
                typingIndicator.widthAnchor.constraint(equalToConstant: 20),
                typingIndicator.heightAnchor.constraint(equalToConstant: 15)
            ])
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    }

    @MainActor final class Coordinator: NSObject {
        var tap: () -> Void
        var longPress: () -> Void
        var unlock: () -> Void
        private var didLongPress = false

        init(tap: @escaping () -> Void, longPress: @escaping () -> Void, unlock: @escaping () -> Void) {
            self.tap = tap
            self.longPress = longPress
            self.unlock = unlock
        }

        @objc func unlockTapped() { unlock() }
        @objc func unlockAccessibility() -> Bool { unlock(); return true }
        @objc func pressed() { didLongPress = false }
        @objc func released() { if !didLongPress { tap() } }
        @objc func longPressed(_ gesture: UILongPressGestureRecognizer) {
            if gesture.state == .began { didLongPress = true; longPress() }
        }
    }
}

/// The three-dot Typing motion chosen in the preview, rendered without a timer
/// or web view. The indicator uses the existing subtitle slot and never lays out text.
/// Motion adapted from Loadersz 0.8.0; see Resources/THIRD_PARTY_NOTICES.txt (MIT).
final class CandidateTypingIndicator: UIView {
    private let dots = (0..<3).map { _ in CALayer() }
    private var loading = false
    private var suspended = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isHidden = true
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        for dot in dots {
            dot.bounds = CGRect(x: 0, y: 0, width: 2.2, height: 2.2)
            dot.cornerRadius = 1.1
            layer.addSublayer(dot)
        }
        updateColors()
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) { (view: CandidateTypingIndicator, _) in
            view.updateColors()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(motionPreferenceChanged),
            name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(suspendAnimation),
            name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(resumeAnimation),
            name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setLoading(_ value: Bool) {
        guard loading != value else { return }
        loading = value
        isHidden = !value
        updateAnimation()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, dot) in dots.enumerated() {
            dot.position = CGPoint(x: bounds.midX + CGFloat(index - 1) * 5.5, y: bounds.midY)
        }
        CATransaction.commit()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateAnimation()
    }

    private func updateColors() {
        // Match the translation label, including appearance and contrast changes.
        let color = UIColor.secondaryLabel.resolvedColor(with: traitCollection).cgColor
        for dot in dots { dot.backgroundColor = color }
    }

    @objc private func motionPreferenceChanged() { updateAnimation() }
    @objc private func suspendAnimation() { suspended = true; updateAnimation() }
    @objc private func resumeAnimation() { suspended = false; updateAnimation() }

    private func updateAnimation() {
        let animate = loading && window != nil && !suspended && !UIAccessibility.isReduceMotionEnabled
        for (index, dot) in dots.enumerated() {
            guard animate else {
                dot.removeAllAnimations()
                dot.opacity = 0.55
                continue
            }
            guard dot.animation(forKey: "typing") == nil else { continue }
            let pulses = (0...60).map { sample -> Double in
                let phase = (Double(sample) / 60 + Double(index) / 3).truncatingRemainder(dividingBy: 1)
                return pow(sin(phase * .pi), 1.9)
            }
            let lift = CAKeyframeAnimation(keyPath: "transform.translation.y")
            lift.values = pulses.map { -$0 * 2.788 }
            let scale = CAKeyframeAnimation(keyPath: "transform.scale")
            scale.values = pulses.map { 1 + $0 * 0.72 / 1.1 }
            let opacity = CAKeyframeAnimation(keyPath: "opacity")
            opacity.values = pulses.map { 0.28 + $0 * 0.68 }
            let group = CAAnimationGroup()
            group.animations = [lift, scale, opacity]
            group.duration = 1 / 1.55
            [lift, scale, opacity].forEach { $0.duration = group.duration }
            group.repeatCount = .infinity
            dot.add(group, forKey: "typing")
        }
    }
}

struct CursorSpaceKey: UIViewRepresentable {
    let title: String
    var audience: KeyboardAudience = .chinese
    var faceInsets = EdgeInsets()
    let tap: () -> Void
    let begin: () -> Void
    let move: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(tap: tap, begin: begin, move: move) }

    func makeUIView(context: Context) -> LetterKey.KeyView {
        let button = LetterKey.KeyView(type: .custom)
        button.titleLabel?.font = .systemFont(ofSize: 17, weight: .regular)
        button.setTitleColor(.label, for: .normal)
        button.faceColor = Palette.keyUIColor
        button.layer.cornerRadius = 6
        button.addTarget(context.coordinator, action: #selector(Coordinator.pressed), for: .touchDown)
        button.addTarget(context.coordinator, action: #selector(Coordinator.released), for: .touchUpInside)
        let gesture = UILongPressGestureRecognizer(target: context.coordinator,
                                                   action: #selector(Coordinator.longPressed(_:)))
        gesture.minimumPressDuration = 0.38
        gesture.allowableMovement = 18
        gesture.cancelsTouchesInView = false
        button.addGestureRecognizer(gesture)
        button.isAccessibilityElement = true
        return button
    }

    func updateUIView(_ button: LetterKey.KeyView, context: Context) {
        context.coordinator.tap = tap
        context.coordinator.begin = begin
        context.coordinator.move = move
        button.setTitle(title, for: .normal)
        button.faceInsets = UIEdgeInsets(top: faceInsets.top, left: faceInsets.leading,
                                        bottom: faceInsets.bottom, right: faceInsets.trailing)
        button.accessibilityIdentifier = "key.\(title)"
        button.accessibilityLabel = audience.isEnglishOnly ? "\(title), hold to move cursor" : "\(title)，长按移动光标"
    }

    @MainActor final class Coordinator: NSObject {
        var tap: () -> Void
        var begin: () -> Void
        var move: (Int) -> Void
        private var didLongPress = false
        private var lastSteps = 0
        private var startingX: CGFloat = 0

        init(tap: @escaping () -> Void, begin: @escaping () -> Void, move: @escaping (Int) -> Void) {
            self.tap = tap
            self.begin = begin
            self.move = move
        }

        @objc func pressed() { didLongPress = false; lastSteps = 0 }
        @objc func released() { if !didLongPress { tap() } }

        @objc func longPressed(_ gesture: UILongPressGestureRecognizer) {
            switch gesture.state {
            case .began:
                didLongPress = true
                lastSteps = 0
                startingX = gesture.location(in: gesture.view).x
                begin()
            case .changed:
                let steps = Int((gesture.location(in: gesture.view).x - startingX) / 12)
                if steps != lastSteps {
                    move(steps - lastSteps)
                    lastSteps = steps
                }
            default: break
            }
        }
    }
}

struct RepeatingDeleteKey: UIViewRepresentable {
    var audience: KeyboardAudience = .chinese
    var faceInsets = EdgeInsets()
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeUIView(context: Context) -> LetterKey.KeyView {
        let button = LetterKey.KeyView(type: .custom)
        button.setImage(UIImage(systemName: "delete.left"), for: .normal)
        button.tintColor = .label
        button.faceColor = Palette.keyUIColor
        button.layer.cornerRadius = 6
        button.addTarget(context.coordinator, action: #selector(Coordinator.pressed), for: .touchDown)
        for event: UIControl.Event in [.touchUpInside, .touchUpOutside, .touchCancel] {
            button.addTarget(context.coordinator, action: #selector(Coordinator.released), for: event)
        }
        button.isAccessibilityElement = true
        button.accessibilityLabel = audience.text("退格")
        return button
    }

    func updateUIView(_ button: LetterKey.KeyView, context: Context) {
        context.coordinator.action = action
        button.accessibilityLabel = audience.text("退格")
        button.faceColor = Palette.keyUIColor
        button.faceInsets = UIEdgeInsets(top: faceInsets.top, left: faceInsets.leading,
                                        bottom: faceInsets.bottom, right: faceInsets.trailing)
    }

    @MainActor final class Coordinator: NSObject {
        var action: () -> Void
        private var repeatTask: Task<Void, Never>?

        init(action: @escaping () -> Void) { self.action = action }

        @objc func pressed() {
            repeatTask?.cancel()
            action()
            repeatTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(420))
                var count = 0
                while !Task.isCancelled, let self {
                    self.action()
                    count += 1
                    let delay = count > 12 ? 45 : (count > 5 ? 75 : 115)
                    try? await Task.sleep(for: .milliseconds(delay))
                }
            }
        }

        @objc func released() {
            repeatTask?.cancel()
            repeatTask = nil
        }
    }
}

struct LetterKey: UIViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    let title: String
    let hint: String?
    var faceInsets = EdgeInsets()
    var activatesOnTouchDown = true
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeUIView(context: Context) -> KeyView {
        let button = KeyView(type: .custom)
        button.addTarget(context.coordinator, action: #selector(Coordinator.pressed(_:)), for: .touchDown)
        button.addTarget(context.coordinator, action: #selector(Coordinator.released(_:)), for: .touchUpInside)
        for event: UIControl.Event in [.touchUpOutside, .touchCancel] {
            button.addTarget(context.coordinator, action: #selector(Coordinator.cancelled(_:)), for: event)
        }
        button.layer.cornerRadius = 6
        button.isAccessibilityElement = true
        return button
    }

    func updateUIView(_ button: KeyView, context: Context) {
        context.coordinator.action = action
        context.coordinator.activatesOnTouchDown = activatesOnTouchDown
        button.isEnabled = isEnabled
        if !isEnabled { button.hidePopup(immediately: true) }
        button.titleLabel?.font = .systemFont(ofSize: 20)
        button.setTitle(title, for: .normal)
        button.setTitleColor(.label, for: .normal)
        button.faceColor = button.popupIsVisible ? .systemGray4 : Palette.keyUIColor
        button.faceInsets = UIEdgeInsets(top: faceInsets.top, left: faceInsets.leading,
                                        bottom: faceInsets.bottom, right: faceInsets.trailing)
        button.hintLabel.text = hint
        button.hintLabel.isHidden = hint == nil
        button.accessibilityIdentifier = "key.\(title.lowercased())"
        button.accessibilityLabel = hint.map { "\(title)，\($0)" } ?? title
    }

    @MainActor final class Coordinator: NSObject {
        var action: () -> Void
        var activatesOnTouchDown = true
        init(action: @escaping () -> Void) { self.action = action }
        @objc func pressed(_ sender: KeyView) {
            guard sender.isEnabled else { return }
            sender.showPopup()
            if activatesOnTouchDown { action() }
        }
        @objc func released(_ sender: KeyView) {
            sender.hidePopup()
            if sender.isEnabled && !activatesOnTouchDown { action() }
        }
        @objc func cancelled(_ sender: KeyView) { sender.hidePopup() }
    }

    @MainActor final class KeyView: UIButton {
        private let faceView = UIView()
        let hintLabel = UILabel()
        var faceInsets = UIEdgeInsets.zero {
            didSet { if oldValue != faceInsets { setNeedsLayout() } }
        }
        var faceColor: UIColor? {
            get { faceView.backgroundColor }
            set { faceView.backgroundColor = newValue }
        }
        private var popup: PopupBalloonView?
        var popupIsVisible: Bool { popup != nil }

        override init(frame: CGRect) {
            super.init(frame: frame)
            faceView.isUserInteractionEnabled = false
            faceView.layer.cornerRadius = 6
            insertSubview(faceView, at: 0)
            hintLabel.font = .systemFont(ofSize: 9)
            hintLabel.textColor = .secondaryLabel
            hintLabel.textAlignment = .center
            addSubview(hintLabel)
            clipsToBounds = false
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layoutSubviews() {
            super.layoutSubviews()
            // UIButton may insert its image view below custom subviews after setImage.
            if subviews.first !== faceView { sendSubviewToBack(faceView) }
            let face = bounds.inset(by: faceInsets)
            faceView.frame = face
            if let imageView, let image = currentImage {
                // UIButton's symbol baseline layout can offset an inset key image.
                // Lay out the image itself at the visible key's center instead.
                imageView.contentMode = .scaleAspectFit
                imageView.frame = CGRect(x: face.midX - image.size.width / 2,
                                         y: face.midY - image.size.height / 2,
                                         width: image.size.width, height: image.size.height)
            }
            hintLabel.frame = CGRect(x: face.minX, y: face.maxY - 12, width: face.width, height: 10)
            popup?.frame = popupFrame
        }

        override func titleRect(forContentRect contentRect: CGRect) -> CGRect {
            super.titleRect(forContentRect: contentRect.inset(by: faceInsets))
        }

        private var popupFrame: CGRect {
            let face = bounds.inset(by: faceInsets)
            var x = face.midX - 30
            if let window {
                let visibleBounds = convert(window.bounds.insetBy(dx: 4, dy: 0), from: window)
                x = min(max(x, visibleBounds.minX), visibleBounds.maxX - 60)
            }
            return CGRect(x: x, y: face.minY - 62, width: 60, height: 72)
        }

        func showPopup(_ text: String? = nil) {
            hidePopup(immediately: true)
            let balloon = PopupBalloonView()
            balloon.title.text = text ?? title(for: .normal)
            balloon.frame = popupFrame
            addSubview(balloon)
            faceColor = .systemGray4
            layer.zPosition = 100
            popup = balloon
        }

        func hidePopup(immediately: Bool = false) {
            guard let balloon = popup else { return }
            popup = nil
            faceColor = Palette.keyUIColor
            if immediately {
                balloon.removeFromSuperview()
                layer.zPosition = 0
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) { [weak self, weak balloon] in
                    balloon?.removeFromSuperview()
                    if self?.popup == nil { self?.layer.zPosition = 0 }
                }
            }
        }
    }

    @MainActor final class PopupBalloonView: UIView {
        let title = UILabel()
        private let shape = CAShapeLayer()

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            backgroundColor = .clear
            layer.addSublayer(shape)
            layer.shadowColor = UIColor.black.cgColor
            layer.shadowOpacity = 0.18
            layer.shadowRadius = 3
            layer.shadowOffset = CGSize(width: 0, height: 2)
            title.font = .systemFont(ofSize: 27)
            title.textColor = .label
            title.textAlignment = .center
            addSubview(title)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layoutSubviews() {
            super.layoutSubviews()
            shape.frame = bounds
            let width = bounds.width
            let path = UIBezierPath()
            path.move(to: CGPoint(x: 12, y: 0))
            path.addLine(to: CGPoint(x: width - 12, y: 0))
            path.addQuadCurve(to: CGPoint(x: width - 1, y: 11), controlPoint: CGPoint(x: width - 1, y: 0))
            path.addLine(to: CGPoint(x: width - 1, y: 49))
            path.addQuadCurve(to: CGPoint(x: width - 12, y: 60), controlPoint: CGPoint(x: width - 1, y: 60))
            path.addLine(to: CGPoint(x: width / 2 + 13, y: 60))
            path.addCurve(to: CGPoint(x: width / 2 + 5, y: 69),
                          controlPoint1: CGPoint(x: width / 2 + 9, y: 60),
                          controlPoint2: CGPoint(x: width / 2 + 9, y: 69))
            path.addQuadCurve(to: CGPoint(x: width / 2 - 5, y: 69), controlPoint: CGPoint(x: width / 2, y: 71))
            path.addCurve(to: CGPoint(x: width / 2 - 13, y: 60),
                          controlPoint1: CGPoint(x: width / 2 - 9, y: 69),
                          controlPoint2: CGPoint(x: width / 2 - 9, y: 60))
            path.addLine(to: CGPoint(x: 12, y: 60))
            path.addQuadCurve(to: CGPoint(x: 1, y: 49), controlPoint: CGPoint(x: 1, y: 60))
            path.addLine(to: CGPoint(x: 1, y: 11))
            path.addQuadCurve(to: CGPoint(x: 12, y: 0), controlPoint: CGPoint(x: 1, y: 0))
            path.close()
            shape.path = path.cgPath
            shape.fillColor = Palette.keyUIColor.resolvedColor(with: traitCollection).cgColor
            layer.shadowPath = path.cgPath
            title.frame = CGRect(x: 0, y: 2, width: bounds.width, height: 54)
        }
    }
}

struct PressKeyStyle: ButtonStyle {
    var popup: String? = nil
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.8 : 1)
            .overlay(alignment: .top) {
                if configuration.isPressed, let popup {
                    Text(popup).font(.system(size: 27))
                        .foregroundStyle(.primary)
                        .frame(width: 58, height: 62)
                        .background(Palette.key, in: RoundedRectangle(cornerRadius: 9))
                        .shadow(color: .black.opacity(0.22), radius: 3, y: 2)
                        .offset(y: -57)
                        .allowsHitTesting(false)
                }
            }
            .zIndex(configuration.isPressed ? 10 : 0)
    }
}
