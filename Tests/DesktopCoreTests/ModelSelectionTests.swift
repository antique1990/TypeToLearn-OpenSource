import XCTest
import Foundation
@testable import DesktopCore

final class ModelSelectionTests: XCTestCase {
    func testLegacySettingsPreserveExistingValuesAndDefaultTo32B() throws {
        var original = DesktopSettings()
        original.provider = .siliconFlow
        original.targetLanguage = "ja"
        original.cloudConsent = true
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        json.removeValue(forKey: "cloudModelPreference")
        let restored = try JSONDecoder().decode(DesktopSettings.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(restored.cloudModel, .qwen25_32B)
        XCTAssertEqual(restored.provider, .siliconFlow)
        XCTAssertEqual(restored.targetLanguage, "ja")
        XCTAssertTrue(restored.cloudConsent)
        XCTAssertEqual(restored.revision, original.revision)
    }

    func testBothModelsPersistWithTheirExactProviderID() throws {
        for model in SiliconFlowModel.allCases {
            var settings = DesktopSettings()
            settings.cloudModel = model
            let data = try JSONEncoder().encode(settings)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(json["cloudModelPreference"] as? String, model.rawValue)
            let restored = try JSONDecoder().decode(DesktopSettings.self, from: data)
            XCTAssertEqual(restored.cloudModel, model)
        }
    }
}
