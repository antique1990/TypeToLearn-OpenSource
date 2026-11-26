import AVFoundation
import KeyboardCore

@MainActor
final class KeyClickSound {
    private var typingPlayer: AVAudioPlayer?
    private var deletePlayer: AVAudioPlayer?
    private var selectedStyle: KeyboardSoundStyle?
    private var prepared = false

    private static func loadSound(_ name: String) -> AVAudioPlayer? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "wav") else { return nil }
        return try? AVAudioPlayer(contentsOf: url)
    }

    func prepare(style: KeyboardSoundStyle, volume: Double) {
        if selectedStyle != style {
            stop()
            selectedStyle = style
            let suffix: String
            switch style {
            case .system: suffix = "-systemlike"
            case .crisp: suffix = ""
            case .soft: suffix = "-soft"
            case .mechanical: suffix = "-mechanical"
            }
            typingPlayer = Self.loadSound("key-click\(suffix)")
            deletePlayer = Self.loadSound("key-delete\(suffix)")
        }
        let level = Float(min(max(volume, 0), 1))
        typingPlayer?.volume = level
        deletePlayer?.volume = level
        guard !prepared, typingPlayer != nil || deletePlayer != nil else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default,
                                                             options: .mixWithOthers)
            prepared = true
            _ = typingPlayer?.prepareToPlay()
            _ = deletePlayer?.prepareToPlay()
        } catch {
            // Fall back to the system click when audio setup is unavailable.
        }
    }

    @discardableResult
    func play(_ kind: KeyFeedbackKind, style: KeyboardSoundStyle, volume: Double) -> Bool {
        prepare(style: style, volume: volume)
        guard prepared, let player = kind == .delete ? deletePlayer : typingPlayer else { return false }
        player.currentTime = 0
        return player.play()
    }

    func stop() {
        typingPlayer?.stop()
        deletePlayer?.stop()
        if prepared {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        prepared = false
    }
}
