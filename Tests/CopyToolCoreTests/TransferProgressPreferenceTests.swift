import XCTest
@testable import CopyToolCore

final class TransferProgressPreferenceTests: XCTestCase {
    func testOldConfigurationEnablesProgressCardByDefault() throws {
        let old = try JSONDecoder().decode(AppPreferences.self, from: Data("{}".utf8))
        XCTAssertTrue(old.showTransferProgress)
    }

    func testDisabledProgressCardSurvivesRoundTrip() throws {
        var preferences = AppPreferences()
        preferences.showTransferProgress = false
        let restored = try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertFalse(restored.showTransferProgress)
    }
}
