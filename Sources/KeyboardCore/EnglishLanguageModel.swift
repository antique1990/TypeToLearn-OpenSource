import Foundation

public struct EnglishSuggestions: Equatable, Sendable {
    public var words: [String]
    /// Only unambiguous spacing repairs may be committed by the space key.
    public var automaticReplacement: String?
}

/// A bounded, offline baseline. Counts come from authored everyday phrases, never
/// from the user's input. UIKit supplies the broader spelling/completion lexicon.
public struct EnglishLanguageModel: Sendable {
    public static let shared = EnglishLanguageModel()
    private let frequencies: [String: Int]
    private let successors: [String: [String: Int]]

    public init() {
        var frequencies: [String: Int] = [:]
        var successors: [String: [String: Int]] = [:]
        for line in Self.phrases.split(separator: "\n") {
            let words = line.lowercased().split(separator: " ").map(String.init)
            for (index, word) in words.enumerated() {
                frequencies[word, default: 0] += 1
                for length in 1...2 where index >= length {
                    let key = words[(index - length)..<index].joined(separator: " ")
                    successors[key, default: [:]][word, default: 0] += 1
                }
            }
        }
        self.frequencies = frequencies
        self.successors = successors
    }

    public func contains(_ word: String) -> Bool { frequencies[word.lowercased()] != nil }

    public static func isEnglishText(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= 128 else { return false }
        let words = text.split(separator: " ", omittingEmptySubsequences: false)
        return words.count <= 8 && words.allSatisfy { word in
            !word.isEmpty && word.first?.isASCIIEnglishLetter == true &&
            word.last?.isASCIIEnglishLetter == true &&
            word.allSatisfy { $0.isASCIIEnglishLetter || $0 == "'" || $0 == "’" }
        }
    }

    /// Stops at punctuation/newlines/non-English text. No cross-field or stored history.
    public static func contextWords(_ context: String) -> [String] {
        let tail = context.suffix(160).reversed().prefix {
            $0.isASCIIEnglishLetter || $0 == " " || $0 == "'" || $0 == "’"
        }.reversed()
        return String(tail).lowercased().split(separator: " ").suffix(2).map(String.init)
    }

    public func predictions(after context: String, prefix: String = "") -> [String] {
        let words = Self.contextWords(context)
        guard !words.isEmpty else { return [] }
        var scores: [String: Int] = [:]
        for length in 1...words.count {
            let key = words.suffix(length).joined(separator: " ")
            for (word, count) in successors[key] ?? [:] where word.hasPrefix(prefix.lowercased()) {
                scores[word, default: 0] += count * (length == 2 ? 10 : 1)
            }
        }
        return scores.keys.sorted {
            scores[$0] == scores[$1] ? $0 < $1 : scores[$0, default: 0] > scores[$1, default: 0]
        }.prefix(3).map { $0 == "i" ? "I" : $0 }
    }

    public func suggestions(for input: String, context: String = "", knownWord: Bool,
                            completions: [String], corrections: [String]) -> EnglishSuggestions {
        guard !input.isEmpty else {
            return EnglishSuggestions(words: predictions(after: context), automaticReplacement: nil)
        }
        guard input.count <= 32, input.allSatisfy(\.isASCIIEnglishLetter) else {
            return EnglishSuggestions(words: [input], automaticReplacement: nil)
        }
        let lower = input.lowercased()
        let known = knownWord || contains(lower)
        // Do not reinterpret names/identifiers with internal capitals.
        let regularCase = input == lower || input == input.uppercased() ||
            input == lower.prefix(1).uppercased() + lower.dropFirst()
        let segments = known || !regularCase ? [] : segment(lower, context: context)
        let spacing = segments.prefix(2).map { restoreCase($0.words.joined(separator: " "), from: input) }
        let confident = segments.first.map { best in
            let unambiguous = segments.count == 1 || best.score - segments[1].score >= 1.5
            return unambiguous && zip(best.words, best.words.dropFirst()).allSatisfy {
                successors[$0.0]?[$0.1] != nil
            }
        } ?? false
        let contextual = predictions(after: context, prefix: lower).filter { $0.lowercased() != lower }
            .map { restoreCase($0, from: input) }
        let guesses = known || !regularCase ? [] : corrections.filter {
            Self.isEnglishText($0) && $0.lowercased() != lower
        }.prefix(2).map { restoreCase($0, from: input) }
        let completed = completions.filter {
            Self.isEnglishText($0) && $0.lowercased().hasPrefix(lower) && $0.count > input.count
        }.prefix(3).map { restoreCase($0, from: input) }
        // Spacing repairs replace the redundant raw candidate. Return still commits
        // the untouched composition; valid words and incomplete prefixes stay visible.
        let hasSpacingRepair = !spacing.isEmpty || guesses.contains {
            $0.contains(" ") && $0.replacingOccurrences(of: " ", with: "").lowercased() == lower
        }
        let original = hasSpacingRepair ? [] : [input]
        var seen = Set<String>()
        let words = (spacing + original + contextual + guesses + completed).filter {
            seen.insert($0.lowercased()).inserted
        }
        return EnglishSuggestions(words: Array(words.prefix(8)),
                                  automaticReplacement: confident ? spacing.first : nil)
    }

    private struct Path {
        var words: [String]
        var score: Double
    }

    private func segment(_ input: String, context: String) -> [Path] {
        let letters = Array(input)
        var paths = Array(repeating: [Path](), count: letters.count + 1)
        paths[0] = [Path(words: [], score: 0)]
        let previous = Self.contextWords(context).last
        for end in 1...letters.count {
            var choices: [Path] = []
            for start in max(0, end - 20)..<end where !paths[start].isEmpty {
                let word = String(letters[start..<end])
                guard let frequency = frequencies[word], word.count > 1 || word == "a" || word == "i" else { continue }
                for path in paths[start] where path.words.count < 8 {
                    let last = path.words.last ?? previous ?? ""
                    let pairCount = successors[last]?[word] ?? 0
                    let score = path.score + log(Double(frequency + 1)) - 6 +
                        (pairCount > 0 ? 3 + log(Double(pairCount)) : 0)
                    choices.append(Path(words: path.words + [word], score: score))
                }
            }
            paths[end] = Array(choices.sorted {
                $0.score == $1.score ? $0.words.joined(separator: " ") < $1.words.joined(separator: " ") : $0.score > $1.score
            }.prefix(4))
        }
        return paths[letters.count].filter { $0.words.count > 1 }
    }

    private func restoreCase(_ text: String, from input: String) -> String {
        if input.count > 1 && input == input.uppercased() { return text.uppercased() }
        let words = text.lowercased().split(separator: " ").map { $0 == "i" ? "I" : String($0) }
        let output = words.joined(separator: " ")
        if input.first?.isUppercase == true { return output.prefix(1).uppercased() + output.dropFirst() }
        return output
    }

    // Original seed examples covering conversation, travel, work and learning.
    // This intentionally small model is a baseline, not a system-scale predictor.
    private static let phrases = """
    you are welcome
    you are right
    you are ready
    you are very kind
    you are doing well
    you are learning english
    you can do it
    you can help me
    you have a message
    you have a nice day
    you need to rest
    i am fine
    i am ready
    i am here
    i am learning thai
    i am going home
    i am looking for a hotel
    i am sorry
    i am happy to help
    i love you
    i love this place
    i like this food
    i like learning languages
    i want to learn thai
    i want to go home
    i want a cup of tea
    i would like some water
    i would like to book a room
    i need your help
    i need more time
    i have a question
    i have a meeting today
    i will see you tomorrow
    i will be there soon
    i can speak english
    i can help you
    i don't know
    i don't understand
    i think so
    i think you are right
    we are ready
    we are going home
    we can meet tomorrow
    we have time
    we need to talk
    they are here
    they are waiting for us
    they have arrived
    he is my friend
    he is working today
    she is my teacher
    she is coming soon
    it is nice to meet you
    it is a good idea
    it is very good
    it is raining today
    this is my first visit
    this is very helpful
    that is a good question
    that sounds great
    there is a restaurant nearby
    there are two rooms
    how are you
    how are you doing
    how much is it
    how much does it cost
    how do i get there
    how do you say this
    how long does it take
    what is your name
    what is the time
    what are you doing
    what do you mean
    what do you think
    what would you like
    where are you
    where are you from
    where is the station
    where is the bathroom
    when can we meet
    when will you arrive
    why do you ask
    who is calling
    can you help me
    can you say that again
    can you speak slowly
    can i have the menu
    can i pay by card
    could you please help me
    could you send me the address
    would you like some coffee
    would you like to join us
    do you speak english
    do you have time
    do you understand
    did you get my message
    are you ready
    are you free tomorrow
    are you coming today
    is there a bus stop nearby
    please help me
    please wait a moment
    please speak slowly
    please send me a message
    please let me know
    please call me later
    thank you
    thank you very much
    thank you for your help
    thanks for coming
    good morning
    good afternoon
    good evening
    good night
    good to see you
    have a good day
    have a nice trip
    see you later
    see you soon
    see you tomorrow
    talk to you later
    nice to meet you
    no problem
    no thank you
    yes please
    yes i do
    not right now
    of course
    take your time
    take care
    let's go
    let's meet at the station
    i'm on my way
    it's all right
    don't worry
    hello world
    hello everyone
    happy birthday
    happy new year
    welcome back
    enjoy your meal
    the meeting starts at nine
    the train leaves at five
    the weather is nice today
    my name is john
    my phone is here
    your order is ready
    learning a new language takes time
    practice makes progress
    open the door
    close the window
    turn left at the next street
    turn right at the traffic light
    go straight ahead
    send the document by email
    check the address before sending
    book a table for two
    drink some water
    eat breakfast before work
    read a book every day
    listen to the music
    write down the number
    see you next week
    see you next month
    come back in ten minutes
    one two three four five six seven eight nine ten
    monday tuesday wednesday thursday friday saturday sunday
    """
}

private extension Character {
    var isASCIIEnglishLetter: Bool {
        unicodeScalars.count == 1 && unicodeScalars.allSatisfy {
            (65...90).contains($0.value) || (97...122).contains($0.value)
        }
    }
}
