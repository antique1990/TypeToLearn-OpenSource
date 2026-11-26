import XCTest
import Foundation
import KeyboardCore
@testable import DesktopCore

final class FuzzyPinyinSettingsTests: XCTestCase {
    private let pairs: [PinyinFuzzyOptions] = [.zZh, .cCh, .sSh, .nL, .fH, .anAng, .enEng, .inIng]

    func testNewSettingsOnlyEnableCommonRetroflexPairs() {
        let settings = DesktopSettings()
        XCTAssertEqual(settings.fuzzyPinyinOptions, .retroflex)
        for option in [PinyinFuzzyOptions.zZh, .cCh, .sSh] {
            XCTAssertTrue(settings.fuzzyPinyinOptions.contains(option))
        }
        for option in [PinyinFuzzyOptions.nL, .fH, .anAng, .enEng, .inIng] {
            XCTAssertFalse(settings.fuzzyPinyinOptions.contains(option))
        }
    }

    func testLegacySettingsKeepAllPreviousPreferences() throws {
        var original = DesktopSettings()
        original.provider = .siliconFlow
        original.cloudConsent = true
        original.cloudModel = .qwen25_7B
        original.candidateLayout = .vertical
        original.layout = .cangjie
        original.script = .traditional
        original.targetLanguage = "ja"
        original.englishTargetLanguage = "ko"
        original.english = true
        original.translationEnabled = false
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        json.removeValue(forKey: "fuzzyPinyinPreference")
        let restored = try JSONDecoder().decode(DesktopSettings.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(restored, original)
        XCTAssertEqual(restored.fuzzyPinyinOptions, .retroflex)
    }

    func testEveryPairCanBePersistedIndependently() throws {
        for pair in pairs {
            var settings = DesktopSettings()
            settings.fuzzyPinyinOptions = pair
            let restored = try JSONDecoder().decode(DesktopSettings.self, from: JSONEncoder().encode(settings))
            XCTAssertEqual(restored.fuzzyPinyinOptions, pair)
            for other in pairs where other != pair {
                XCTAssertFalse(restored.fuzzyPinyinOptions.contains(other))
            }
        }
    }

    func testExplicitAllOffDoesNotRevertToDefaultsOnReload() throws {
        var settings = DesktopSettings()
        settings.fuzzyPinyinOptions = []
        let restored = try JSONDecoder().decode(DesktopSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertNotNil(restored.fuzzyPinyinPreference)
        XCTAssertTrue(restored.fuzzyPinyinOptions.isEmpty)
    }
}
