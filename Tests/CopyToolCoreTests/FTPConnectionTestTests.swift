import XCTest
@testable import CopyToolCore

final class FTPConnectionTestTests: XCTestCase {
    private let valid = FTPSettings(host: "127.0.0.1", username: "test", password: "secret", directory: "/uploads")

    func testConfigurationUsesReadOnlyRootURLAndExplicitAbsoluteDirectory() throws {
        var settings = valid
        settings.directory = "研发中心/中文 file;type=A"
        let configuration = try FTPConnectionTest.configuration(settings: settings)
        XCTAssertTrue(configuration.contains("url = \"ftp://127.0.0.1:21/\"\n"))
        XCTAssertTrue(configuration.contains("quote = \"CWD /研发中心/中文 file;type=A\"\n"))
        XCTAssertFalse(configuration.contains("upload" + "-file"))
        XCTAssertFalse(configuration.contains("create-dirs"))
    }

    func testQuotedCredentialsCannotIntroduceConfigOptions() throws {
        var settings = valid
        settings.username = "user\"\\name"
        settings.password = "p\"\\word: rest"
        let configuration = try FTPConnectionTest.configuration(settings: settings)
        XCTAssertTrue(configuration.contains("user = \"user\\\"\\\\name:p\\\"\\\\word: rest\"\n"))
        XCTAssertEqual(configuration.components(separatedBy: "\n").count, 4)
    }

    func testInvalidHostsAndPortsAreRejectedBeforeNetwork() {
        for host in ["", "ftp://127.0.0.1", "host/user", "user@host", "host:21", "host\n", "host\t", "ho st", "host%0d", "-host", "host..com", "host?x", "[bad]"] {
            var settings = valid; settings.host = host
            XCTAssertThrowsError(try FTPConnectionTest.configuration(settings: settings), host)
        }
        for port in [0, -1, 65536] {
            var settings = valid; settings.port = port
            XCTAssertThrowsError(try FTPConnectionTest.configuration(settings: settings))
        }
    }

    func testIPv6AndDNSHostsCanBeConfigured() throws {
        for host in ["localhost", "ftp.example.com", "example.com.", "::1", "[::1]"] {
            var settings = valid; settings.host = host
            XCTAssertNoThrow(try FTPConnectionTest.configuration(settings: settings), host)
        }
    }

    func testCredentialControlCharactersAndUsernameColonAreRejected() {
        for value in ["bad\nvalue", "bad\rvalue", "bad\tvalue", "bad\u{0}value", "bad\u{7f}value"] {
            var settings = valid; settings.password = value
            XCTAssertThrowsError(try FTPConnectionTest.configuration(settings: settings))
            settings = valid; settings.username = value
            XCTAssertThrowsError(try FTPConnectionTest.configuration(settings: settings))
        }
        for username in ["", "user:name"] {
            var settings = valid; settings.username = username
            XCTAssertThrowsError(try FTPConnectionTest.configuration(settings: settings))
        }
    }

    func testDirectoryCannotInjectCommandsOrEscapeToParent() {
        for directory in ["/ok\r\nDELE x", "/ok\nMKD x", "/ok\u{0}", "/ok\tbad", "/a/../b", "..", "/a\\..\\b"] {
            var settings = valid; settings.directory = directory
            XCTAssertThrowsError(try FTPConnectionTest.configuration(settings: settings))
        }
    }

    func testEmptyDirectoryNormalizesToRootAndEmptyPasswordIsAllowed() throws {
        var settings = valid
        settings.directory = ""; settings.password = ""
        let configuration = try FTPConnectionTest.configuration(settings: settings)
        XCTAssertTrue(configuration.contains("quote = \"CWD /\"\n"))
        XCTAssertTrue(configuration.contains("user = \"test:\"\n"))
    }

    func testOversizedConfigurationIsRejected() {
        var settings = valid
        settings.password = String(repeating: "x", count: 16_385)
        XCTAssertThrowsError(try FTPConnectionTest.configuration(settings: settings))
    }

    func testCancellationBeforeStartNeverConnects() {
        let tester = FTPConnectionTest()
        tester.cancel()
        XCTAssertThrowsError(try tester.test(settings: valid)) { error in
            XCTAssertEqual(error as? FTPConnectionTestError, .cancelled)
        }
    }
}
