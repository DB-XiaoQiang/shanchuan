import XCTest
@testable import CopyToolCore

final class OriginalFTPConfigTests: XCTestCase {
    private var base: String {
        """
        ip = "192.0.2.10"
        port = 21
        dest = "/synthetic/share"
        username = "test-user"
        password = "synthetic-secret"
        """
    }

    func testImportsFTPFieldsAndPreservesIndependentSettings() throws {
        var previous = AppPreferences()
        previous.ttlDays = 31
        previous.syncEnabled = false
        previous.historyEnabled = false
        previous.restoreOnResend = true
        let config = base + """

        control_file = 'copy.transfer'
        auto_decrypt = false
        decrypt_prefix = '/synthetic/decrypt/'
        sync_enabled = true
        notifications_enabled = true
        license = 'ignored synthetic license'
        """
        let result = try OriginalFTPConfig.parse(config, preserving: previous)
        var expected = previous
        expected.host = "192.0.2.10"
        expected.port = 21
        expected.directory = "/synthetic/share"
        expected.username = "test-user"
        expected.textRemoteName = "copy.transfer"
        expected.autoDecrypt = false
        expected.decryptPrefix = "/synthetic/decrypt/"
        XCTAssertEqual(result.preferences, expected)
        XCTAssertEqual(result.password, "synthetic-secret")
    }

    func testQuotedEscapesCommentsAndDecimalIntegers() throws {
        let config = #"""
        # Synthetic configuration only.
        ip = '192.0.2.10' # trailing comment
        port = +2_121
        dest = "/synthetic/\u4E2D\u6587"
        username = "test#user"# '#' inside quotes is retained
        password = "quote\"slash\\hash#\U0001F511" # no secret logging
        ignored = "line\nreturn\rtab\tback\bform\f"
        """#.replacingOccurrences(of: "\n", with: "\r\n")
        let result = try OriginalFTPConfig.parse(config, preserving: AppPreferences())
        XCTAssertEqual(result.preferences.port, 2121)
        XCTAssertEqual(result.preferences.directory, "/synthetic/中文")
        XCTAssertEqual(result.preferences.username, "test#user")
        XCTAssertEqual(result.password, "quote\"slash\\hash#🔑")
    }

    func testAbsentOptionalFieldsRetainPreviousValues() throws {
        var previous = AppPreferences()
        previous.textRemoteName = "existing.control"
        previous.autoDecrypt = false
        previous.decryptPrefix = "/existing/decrypt"
        let result = try OriginalFTPConfig.parse(base, preserving: previous)
        XCTAssertEqual(result.preferences.textRemoteName, previous.textRemoteName)
        XCTAssertEqual(result.preferences.autoDecrypt, previous.autoDecrypt)
        XCTAssertEqual(result.preferences.decryptPrefix, previous.decryptPrefix)
    }

    func testRejectsUnsupportedSyntaxDuplicateKeysAndWrongTypes() throws {
        let additions = [
            "[ftp]", "nested.key = 'value'", "array = [1, 2]", "object = { a = 1 }",
            "float = 1.2", "hex = 0xFF", "leading_zero = 01", "integer = 1__2",
            "integer = 9223372036854775808", "value = TRUE", "value = \"bad\\q\"",
            "value = \"\\uD800\"", "value = '''multiline'''", "value = \"unterminated",
            "value = 'ok' trailing", "ip = '192.0.2.20'", "auto_decrypt = 'false'"
        ]
        for addition in additions {
            XCTAssertThrowsError(try OriginalFTPConfig.parse(base + "\n" + addition, preserving: AppPreferences()), addition)
        }
        XCTAssertThrowsError(try OriginalFTPConfig.parse(base.replacingOccurrences(of: "port = 21", with: "port = '21'"), preserving: AppPreferences()))
    }

    func testMissingOrUnsafeFieldsFailWithoutDisclosingSecret() throws {
        let secret = "synthetic-SECRET-do-not-disclose"
        let config = base.replacingOccurrences(of: "synthetic-secret", with: secret)
        let variants = [
            config.replacingOccurrences(of: "ip = \"192.0.2.10\"\n", with: ""),
            config.replacingOccurrences(of: "192.0.2.10", with: "ftp://192.0.2.10"),
            config.replacingOccurrences(of: "port = 21", with: "port = 65536"),
            config.replacingOccurrences(of: "/synthetic/share", with: "/synthetic/../share"),
            config.replacingOccurrences(of: "test-user", with: "user:password"),
            config + "\ncontrol_file = 'bad|control'",
            config + "\ndecrypt_prefix = 'relative'",
            config.replacingOccurrences(of: secret, with: secret + "\\n")
        ]
        for variant in variants {
            XCTAssertThrowsError(try OriginalFTPConfig.parse(variant, preserving: AppPreferences())) { error in
                XCTAssertFalse(error.localizedDescription.contains(secret))
            }
        }
    }

    func testLoadSyntheticFileAndRejectInvalidUTF8() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("synthetic.toml")
        try Data(base.utf8).write(to: file, options: .atomic)
        XCTAssertEqual(try OriginalFTPConfig.load(from: file, preserving: AppPreferences()).password, "synthetic-secret")
        try Data([0xFF, 0xFE]).write(to: file)
        XCTAssertThrowsError(try OriginalFTPConfig.load(from: file, preserving: AppPreferences())) { error in
            XCTAssertEqual(error as? OriginalFTPConfig.ImportError, .invalidEncoding)
        }
        XCTAssertThrowsError(try OriginalFTPConfig.load(from: root, preserving: AppPreferences()))
        XCTAssertThrowsError(try OriginalFTPConfig.load(from: URL(string: "https://example.invalid/config")!, preserving: AppPreferences()))
    }
}
