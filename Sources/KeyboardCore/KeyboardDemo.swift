import Foundation

/// Curated offline examples. The order is shared by every language, so switching
/// the target never pairs a phrase with a translation of a different example.
public enum KeyboardDemo {
    public static let count = 5
    public static let supportedLanguageIDs = Array(phrases.keys).sorted()
    public static func translation(_ index: Int, language identifier: String, cangjie: Bool = false) -> String? {
        guard (0..<count).contains(index) else { return nil }
        let language = Locale.Language(identifier: identifier)
        let code = language.languageCode?.identifier ?? identifier
        let key = code == "zh" ? (language.script?.identifier == "Hant" ? "zh-Hant" : "zh-Hans") : (code == "nb" || code == "nn" ? "no" : code)
        return (cangjie ? roots : phrases)[key]?[index]
    }

    public static func source(_ index: Int, english: Bool, script: ChineseScript, cangjie: Bool = false) -> String {
        if cangjie { return ["日", "月", "水", "木", "人"][index] }
        if english { return ["how are you", "hello", "thank you", "good morning", "goodbye"][index] }
        return (script == .traditional ? ["你好嗎", "你好", "謝謝", "早上好", "再見"] : ["你好吗", "你好", "谢谢", "早上好", "再见"])[index]
    }

    public static func input(_ index: Int, english: Bool, layout: KeyboardLayout) -> String {
        if english { return source(index, english: true, script: .simplified).replacingOccurrences(of: " ", with: "") }
        if layout == .cangjie { return ["a", "b", "e", "d", "o"][index] }
        let pinyin = ["nihaoma", "nihao", "xiexie", "zaoshanghao", "zaijian"][index]
        return layout == .nineKey ? KeyCoding.nineKey(pinyin) : pinyin
    }

    /// The nine-key digits drive key highlights, while the composing field shows
    /// the prepared example's pinyin, just like marked text in the real keyboard.
    public static func displayInput(_ typed: String, sample: Int, english: Bool, layout: KeyboardLayout) -> String {
        guard !english else { return typed }
        if layout == .cangjie { return String(typed.map { KeyCoding.cangjieRoots[$0] ?? $0 }) }
        if layout == .nineKey, !typed.isEmpty, typed.allSatisfy({ $0.isNumber }) {
            return String(input(sample, english: false, layout: .pinyin).prefix(typed.count))
        }
        return typed
    }

    /// Prepared demonstration words, each with an explicit translation in every
    /// supported preview language. This does not replace the real IME's ranking.
    public static func candidates(_ index: Int, english: Bool, script: ChineseScript, cangjie: Bool = false) -> [String] {
        let phraseWords = (0..<count).map { source($0, english: english, script: script) }
        let rootWords = english ? ["sun", "moon", "water", "wood", "person"] : ["日", "月", "水", "木", "人"]
        let main = cangjie ? rootWords : phraseWords
        return (0..<count).map { main[(index + $0) % count] } + (cangjie ? phraseWords : rootWords)
    }

    public static func candidateTranslation(_ word: String, language: String, english: Bool, script: ChineseScript) -> String? {
        if let index = (0..<count).first(where: { source($0, english: english, script: script) == word }) {
            return translation(index, language: language)
        }
        let words = english ? ["sun", "moon", "water", "wood", "person"] : ["日", "月", "水", "木", "人"]
        guard let index = words.firstIndex(of: word) else { return nil }
        return translation(index, language: language, cangjie: true)
    }

    private static let phrases: [String: [String]] = [
        "zh-Hans": ["你好吗？", "你好", "谢谢", "早上好", "再见"],
        "zh-Hant": ["你好嗎？", "你好", "謝謝", "早安", "再見"],
        "en": ["How are you?", "Hello", "Thank you", "Good morning", "Goodbye"],
        "es": ["¿Cómo estás?", "Hola", "Gracias", "Buenos días", "Adiós"],
        "fr": ["Comment vas-tu ?", "Bonjour", "Merci", "Bonjour", "Au revoir"],
        "de": ["Wie geht es dir?", "Hallo", "Danke", "Guten Morgen", "Auf Wiedersehen"],
        "it": ["Come stai?", "Ciao", "Grazie", "Buongiorno", "Arrivederci"],
        "pt": ["Como você está?", "Olá", "Obrigado", "Bom dia", "Até logo"],
        "ja": ["元気ですか？", "こんにちは", "ありがとう", "おはようございます", "さようなら"],
        "ko": ["잘 지내세요?", "안녕하세요", "감사합니다", "좋은 아침이에요", "안녕히 가세요"],
        "th": ["คุณสบายดีไหม", "สวัสดี", "ขอบคุณ", "อรุณสวัสดิ์", "ลาก่อน"],
        "vi": ["Bạn khỏe không?", "Xin chào", "Cảm ơn", "Chào buổi sáng", "Tạm biệt"],
        "id": ["Apa kabar?", "Halo", "Terima kasih", "Selamat pagi", "Selamat tinggal"],
        "ms": ["Apa khabar?", "Helo", "Terima kasih", "Selamat pagi", "Selamat tinggal"],
        "ar": ["كيف حالك؟", "مرحبًا", "شكرًا", "صباح الخير", "إلى اللقاء"],
        "hi": ["आप कैसे हैं?", "नमस्ते", "धन्यवाद", "सुप्रभात", "अलविदा"],
        "ru": ["Как дела?", "Привет", "Спасибо", "Доброе утро", "До свидания"],
        "uk": ["Як справи?", "Привіт", "Дякую", "Доброго ранку", "До побачення"],
        "pl": ["Jak się masz?", "Cześć", "Dziękuję", "Dzień dobry", "Do widzenia"],
        "nl": ["Hoe gaat het met je?", "Hallo", "Dank je", "Goedemorgen", "Tot ziens"],
        "tr": ["Nasılsın?", "Merhaba", "Teşekkürler", "Günaydın", "Hoşça kal"],
        "cs": ["Jak se máš?", "Ahoj", "Děkuji", "Dobré ráno", "Na shledanou"],
        "da": ["Hvordan har du det?", "Hej", "Tak", "Godmorgen", "Farvel"],
        "fi": ["Mitä kuuluu?", "Hei", "Kiitos", "Hyvää huomenta", "Näkemiin"],
        "sv": ["Hur mår du?", "Hej", "Tack", "God morgon", "Hej då"],
        "no": ["Hvordan har du det?", "Hei", "Takk", "God morgen", "Ha det"],
        "el": ["Πώς είσαι;", "Γεια σου", "Ευχαριστώ", "Καλημέρα", "Αντίο"],
        "he": ["מה שלומך?", "שלום", "תודה", "בוקר טוב", "להתראות"],
        "ro": ["Ce mai faci?", "Salut", "Mulțumesc", "Bună dimineața", "La revedere"],
        "hu": ["Hogy vagy?", "Szia", "Köszönöm", "Jó reggelt", "Viszontlátásra"]
    ]
    private static let roots: [String: [String]] = [
        "zh-Hans": ["太阳", "月亮", "水", "木头", "人"], "zh-Hant": ["太陽", "月亮", "水", "木頭", "人"],
        "en": ["Sun", "Moon", "Water", "Wood", "Person"], "es": ["Sol", "Luna", "Agua", "Madera", "Persona"],
        "fr": ["Soleil", "Lune", "Eau", "Bois", "Personne"], "de": ["Sonne", "Mond", "Wasser", "Holz", "Person"],
        "it": ["Sole", "Luna", "Acqua", "Legno", "Persona"], "pt": ["Sol", "Lua", "Água", "Madeira", "Pessoa"],
        "ja": ["太陽", "月", "水", "木", "人"], "ko": ["태양", "달", "물", "나무", "사람"],
        "th": ["ดวงอาทิตย์", "ดวงจันทร์", "น้ำ", "ไม้", "คน"], "vi": ["Mặt trời", "Mặt trăng", "Nước", "Gỗ", "Người"],
        "id": ["Matahari", "Bulan", "Air", "Kayu", "Orang"], "ms": ["Matahari", "Bulan", "Air", "Kayu", "Orang"],
        "ar": ["شمس", "قمر", "ماء", "خشب", "شخص"], "hi": ["सूरज", "चाँद", "पानी", "लकड़ी", "व्यक्ति"],
        "ru": ["Солнце", "Луна", "Вода", "Дерево", "Человек"], "uk": ["Сонце", "Місяць", "Вода", "Деревина", "Людина"],
        "pl": ["Słońce", "Księżyc", "Woda", "Drewno", "Osoba"], "nl": ["Zon", "Maan", "Water", "Hout", "Persoon"],
        "tr": ["Güneş", "Ay", "Su", "Ahşap", "Kişi"], "cs": ["Slunce", "Měsíc", "Voda", "Dřevo", "Osoba"],
        "da": ["Sol", "Måne", "Vand", "Træ", "Person"], "fi": ["Aurinko", "Kuu", "Vesi", "Puu", "Ihminen"],
        "sv": ["Sol", "Måne", "Vatten", "Trä", "Person"], "no": ["Sol", "Måne", "Vann", "Tre", "Person"],
        "el": ["Ήλιος", "Σελήνη", "Νερό", "Ξύλο", "Άνθρωπος"], "he": ["שמש", "ירח", "מים", "עץ", "אדם"],
        "ro": ["Soare", "Lună", "Apă", "Lemn", "Persoană"], "hu": ["Nap", "Hold", "Víz", "Fa", "Ember"]
    ]
}
