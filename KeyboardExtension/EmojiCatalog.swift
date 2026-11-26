import Foundation

struct EmojiCategory: Decodable, Identifiable {
    let id: String
    let title: String
    let icon: String
    let emojis: [String]
}

enum EmojiCatalog {
    static let categories: [EmojiCategory] = {
        guard let url = Bundle.main.url(forResource: "emoji-catalog", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let categories = try? JSONDecoder().decode([EmojiCategory].self, from: data)
        else { return [] }
        return categories
    }()
}
