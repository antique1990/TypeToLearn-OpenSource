import AppKit
import SwiftUI

/// Same three-dot Typing motion as iOS CandidateTypingIndicator.
/// Adapted from Loadersz 0.8.0 (MIT), credited in THIRD_PARTY_NOTICES.txt.
struct CandidateTypingView: NSViewRepresentable {
    let loading: Bool
    let color: NSColor
    func makeNSView(context: Context) -> CandidateTypingNSView { CandidateTypingNSView() }
    func updateNSView(_ view: CandidateTypingNSView, context: Context) { view.update(loading: loading, color: color) }
}

final class CandidateTypingNSView: NSView {
    private let dots = (0..<3).map { _ in CALayer() }
    private var loading = false
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(false)
        for dot in dots {
            dot.bounds = CGRect(x: 0, y: 0, width: 2.2, height: 2.2)
            dot.cornerRadius = 1.1
            layer?.addSublayer(dot)
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(updateMotion),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (index, dot) in dots.enumerated() {
            dot.position = CGPoint(x: bounds.midX + CGFloat(index - 1) * 5.5, y: bounds.midY)
        }
        CATransaction.commit()
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateMotion() }
    func update(loading: Bool, color: NSColor) {
        self.loading = loading; isHidden = !loading
        effectiveAppearance.performAsCurrentDrawingAppearance {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            for dot in dots { dot.backgroundColor = color.cgColor }
            CATransaction.commit()
        }
        updateMotion()
    }
    @objc private func updateMotion() {
        let animate = loading && window != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for (index, dot) in dots.enumerated() {
            guard animate else { dot.removeAllAnimations(); dot.opacity = 0.55; continue }
            guard dot.animation(forKey: "typing") == nil else { continue }
            let pulses = (0...60).map { sample -> Double in
                let phase = (Double(sample) / 60 + Double(index) / 3).truncatingRemainder(dividingBy: 1)
                return pow(sin(phase * .pi), 1.9)
            }
            let lift = CAKeyframeAnimation(keyPath: "transform.translation.y")
            lift.values = pulses.map { $0 * 2.788 }
            let scale = CAKeyframeAnimation(keyPath: "transform.scale")
            scale.values = pulses.map { 1 + $0 * 0.72 / 1.1 }
            let opacity = CAKeyframeAnimation(keyPath: "opacity")
            opacity.values = pulses.map { 0.28 + $0 * 0.68 }
            let group = CAAnimationGroup()
            group.animations = [lift, scale, opacity]; group.duration = 1 / 1.55
            [lift, scale, opacity].forEach { $0.duration = group.duration }
            group.repeatCount = .infinity
            dot.add(group, forKey: "typing")
        }
    }
}
