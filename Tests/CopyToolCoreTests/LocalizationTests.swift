import XCTest
@testable import CopyToolCore

final class LocalizationTests: XCTestCase {
    func testMissingOrUnsupportedLanguageDefaultsToSimplifiedChinese() {
        XCTAssertEqual(AppLanguage.resolve(nil), .simplifiedChinese)
        XCTAssertEqual(AppLanguage.resolve(""), .simplifiedChinese)
        XCTAssertEqual(AppLanguage.resolve("fr"), .simplifiedChinese)
        XCTAssertEqual(AppLanguage.resolve("en"), .english)
        XCTAssertEqual(AppLanguage.resolve("zh-Hans"), .simplifiedChinese)
    }

    func testAppLanguagePreferenceSurvivesReopeningAndBootstrapsOnlyItsDomain() throws {
        let name = "Shanchuan.LocalizationTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        L10n.configureProcessLanguage(defaults: defaults)
        XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), ["zh-Hans"])
        defaults.set("en", forKey: AppLanguage.preferenceKey)
        let reopened = try XCTUnwrap(UserDefaults(suiteName: name))
        XCTAssertEqual(AppLanguage.resolve(reopened.string(forKey: AppLanguage.preferenceKey)), .english)
        L10n.configureProcessLanguage(defaults: reopened)
        XCTAssertEqual(reopened.stringArray(forKey: "AppleLanguages"), ["en"])
        reopened.set("invalid", forKey: AppLanguage.preferenceKey)
        L10n.configureProcessLanguage(defaults: reopened)
        XCTAssertEqual(reopened.stringArray(forKey: "AppleLanguages"), ["zh-Hans"])
    }

    func testActualResourcesTranslateAndFormatWithoutChangingUnknownUserText() {
        XCTAssertEqual(L10n.text("配置中心", language: .simplifiedChinese), "配置中心")
        XCTAssertEqual(L10n.text("配置中心", language: .english), "Settings")
        XCTAssertEqual(L10n.text("检查更新", language: .english), "Check for updates")
        XCTAssertEqual(L10n.format("%@ 条记录", language: .english, arguments: ["12"]), "12 records")
        XCTAssertEqual(L10n.format("历史保留：%@ 天", language: .simplifiedChinese, arguments: ["90"]), "历史保留：90 天")
        XCTAssertEqual(L10n.text("用户原始文件.txt", language: .english), "用户原始文件.txt")
    }

    func testAllResourcesHaveBothTranslationsAndCompatibleFormatArguments() throws {
        func table(_ language: String) throws -> [String: String] {
            let path = try XCTUnwrap(L10n.resources.path(forResource: language, ofType: "lproj")
                                    ?? L10n.resources.path(forResource: language.lowercased(), ofType: "lproj"))
            let data = try Data(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("Localizable.strings"))
            return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
        }
        let chinese = try table("zh-Hans"), english = try table("en")
        XCTAssertGreaterThan(chinese.count, 400)
        XCTAssertEqual(Set(chinese.keys), Set(english.keys))
        let pattern = try NSRegularExpression(pattern: "%[@dfius]")
        func arguments(_ text: String) -> [String] {
            let range = NSRange(text.startIndex..., in: text)
            return pattern.matches(in: text, range: range).map { (text as NSString).substring(with: $0.range) }
        }
        for (key, value) in chinese {
            let translated = try XCTUnwrap(english[key])
            XCTAssertFalse(translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, key)
            XCTAssertEqual(value, key, key)
            XCTAssertEqual(arguments(value), arguments(translated), "Format arguments differ: " + key)
        }
    }
}
