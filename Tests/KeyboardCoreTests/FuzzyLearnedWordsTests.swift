import XCTest
@testable import KeyboardCore

final class FuzzyLearnedWordsTests: XCTestCase {
    func testFuzzyAliasOnlyAppearsWhileItsRulesAreEnabled() throws {
        var store = LearnedWords()
        store.learn(code: "sizihao", text: "狮子好", layout: .pinyin, script: .simplified,
                    pinyinPolicy: .configured(.sSh))
        let persisted = try JSONDecoder().decode(LearnedWords.self, from: JSONEncoder().encode(store))
        for policy in [PinyinQueryPolicy.legacy, .configured([]), .configured(.zZh)] {
            XCTAssertTrue(persisted.candidates(for: "sizihao", layout: .pinyin, script: .simplified,
                                              pinyinPolicy: policy).isEmpty)
        }
        for options in [PinyinFuzzyOptions.sSh, .retroflex, .all] {
            XCTAssertEqual(persisted.candidates(for: "sizihao", layout: .pinyin, script: .simplified,
                                                pinyinPolicy: .configured(options)).map(\.text), ["狮子好"])
        }
    }

    func testExistingWordsSurviveMigrationAndScopesDoNotDuplicateCandidates() throws {
        var original = LearnedWords()
        original.learn(code: "nihao", text: "你好", layout: .pinyin, script: .simplified)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        var items = try XCTUnwrap(json["items"] as? [[String: Any]])
        items[0].removeValue(forKey: "requiredFuzzyOptions")
        json["items"] = items
        var migrated = try JSONDecoder().decode(LearnedWords.self, from: JSONSerialization.data(withJSONObject: json))
        migrated.learn(code: "nihao", text: "你好", layout: .pinyin, script: .simplified,
                       pinyinPolicy: .configured(.retroflex))
        for policy in [PinyinQueryPolicy.legacy, .configured([]), .configured(.retroflex)] {
            XCTAssertEqual(migrated.candidates(for: "nihao", layout: .pinyin, script: .simplified,
                                               pinyinPolicy: policy).map(\.text), ["你好"])
        }
        XCTAssertEqual(migrated.items.count, 2, "Keep historical and scoped learning entries separately")
    }

    func testCangjieLearningIsIndependentOfPinyinOptions() {
        var store = LearnedWords()
        store.learn(code: "onf", text: "你好", layout: .cangjie, script: .traditional,
                    pinyinPolicy: .configured(.all))
        XCTAssertEqual(store.candidates(for: "onf", layout: .cangjie, script: .traditional).map(\.text), ["你好"])
        XCTAssertNil(store.items.first?.requiredFuzzyOptions)
    }
}
