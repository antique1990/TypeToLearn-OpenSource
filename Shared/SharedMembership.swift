import Foundation
import KeyboardCore

enum SharedMembership {
    private static var url: URL? { SharedSettings.container?.appendingPathComponent("membership.json") }
    static func load() -> MembershipSnapshot {
        guard let url, let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(MembershipSnapshot.self, from: data) else { return MembershipSnapshot() }
        return snapshot
    }
    static func save(_ snapshot: MembershipSnapshot) throws {
        guard let url else { throw SharedSettings.SettingsError.noContainer }
        try JSONEncoder().encode(snapshot).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
