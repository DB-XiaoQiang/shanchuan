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

    func testRuntimeSelectionPersistsAndNotifiesWithoutRestarting() throws {
        let name = "Shanchuan.LocalizationRuntimeTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let previous = L10n.language
        defer { L10n.setLanguage(previous, defaults: defaults); defaults.removePersistentDomain(forName: name) }
        L10n.setLanguage(.simplifiedChinese, defaults: defaults)
        let observed = expectation(forNotification: L10n.languageDidChange, object: nil) { ($0.object as? String) == "en" }
        L10n.setLanguage(.english, defaults: defaults)
        wait(for: [observed], timeout: 1)
        XCTAssertEqual(L10n.language, .english)
        XCTAssertEqual(defaults.string(forKey: AppLanguage.preferenceKey), "en")
        XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), ["en"])
        XCTAssertEqual(L10n.text("检查更新"), "Check for updates")
    }

    func testFieldSnapshotSurvivesCacheEvictionAndSameRenderedTextOrigins() throws {
        let name = "Shanchuan.LocalizationSnapshotTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let previous = L10n.language
        defer { L10n.setLanguage(previous, defaults: defaults); defaults.removePersistentDomain(forName: name) }
        L10n.setLanguage(.simplifiedChinese, defaults: defaults)
        let literalParameter = L10n.snapshotFormat("%@%@", "更新", "")
        let localizedLabel = L10n.snapshot("更新")
        XCTAssertEqual(literalParameter.rendered, localizedLabel.rendered)
        let filename = "配置中心{0}%中文.zip"
        let downloading = L10n.snapshotFormat("正在下载更新：%@", filename)
        for index in 0..<2200 { _ = L10n.format("opaque status %@", String(index)) }
        XCTAssertLessThanOrEqual(L10n.displayCacheCount, 2048)
        XCTAssertLessThanOrEqual(L10n.displayCacheBytes, 8 * 1024 * 1024)
        L10n.clearDisplayCache()
        XCTAssertEqual(L10n.displayCacheCount, 0)
        L10n.setLanguage(.english, defaults: defaults)
        XCTAssertEqual(literalParameter.rendered, "更新", "User parameters must not become UI keys")
        XCTAssertEqual(localizedLabel.rendered, "Update")
        XCTAssertEqual(downloading.rendered, "Downloading update: " + filename)
    }

    func testSnapshotSanitizesEveryLanguageAndFreezesMutableStringArguments() throws {
        let name = "Shanchuan.LocalizationSanitizingTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let previous = L10n.language
        defer { L10n.setLanguage(previous, defaults: defaults); defaults.removePersistentDomain(forName: name) }
        let parameter = NSMutableString(string: "secret-password\n/private/file")
        let status = L10n.snapshotFormat("正在下载更新：%@", parameter)
            .sanitized(secrets: ["secret-password"], singleLine: true, maximumLength: 200)
        parameter.setString("unexpected mutable replacement")
        L10n.clearDisplayCache()
        L10n.setLanguage(.english, defaults: defaults)
        XCTAssertEqual(status.rendered, "Downloading update: [hidden] /private/file")
        L10n.setLanguage(.simplifiedChinese, defaults: defaults)
        XCTAssertEqual(status.rendered, "正在下载更新：[已隐藏] /private/file")
        XCTAssertFalse(status.rendered.contains("secret-password"))
    }

    func testConcurrentFormattingAndSelectionKeepCacheBoundedAndPreferencesConsistent() throws {
        let name = "Shanchuan.LocalizationConcurrentTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let previous = L10n.language
        defer { L10n.setLanguage(previous, defaults: defaults); defaults.removePersistentDomain(forName: name) }
        final class Failures: @unchecked Sendable {
            let lock = NSLock()
            var values: [String] = []
            func append(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
        }
        let failures = Failures()
        DispatchQueue.concurrentPerform(iterations: 120) { index in
            let selected: AppLanguage = index.isMultiple(of: 2) ? .english : .simplifiedChinese
            L10n.setLanguage(selected, defaults: defaults)
            let result = L10n.format("%@ 条记录", language: selected, arguments: [String(index)])
            let expected = selected == .english ? "\(index) records" : "\(index) 条记录"
            if result != expected { failures.append(result) }
            _ = L10n.display(result)
        }
        XCTAssertTrue(failures.values.isEmpty)
        XCTAssertEqual(defaults.string(forKey: AppLanguage.preferenceKey), L10n.language.rawValue)
        XCTAssertLessThanOrEqual(L10n.displayCacheCount, 2048)
    }
}
