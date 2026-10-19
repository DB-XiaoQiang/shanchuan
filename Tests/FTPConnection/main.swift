import Foundation

let port = Int(CommandLine.arguments[1])!
let closedPort = Int(CommandLine.arguments[2])!
let secret = "p\"\\word:中文 rest"
let directory = "/研发中心/中文 file;type=A\"quote"
let base = FTPSettings(host: "127.0.0.1", port: port, username: "user\"\\name", password: secret, directory: directory)

func expect(_ expected: FTPConnectionTestError, settings: FTPSettings, tester: FTPConnectionTest = FTPConnectionTest()) {
    do {
        try tester.test(settings: settings)
        fatalError("Expected a connection test error")
    } catch {
        precondition(error as? FTPConnectionTestError == expected, "Unexpected error category")
        precondition(!error.localizedDescription.contains(secret), "Error must not contain a credential")
        precondition(!error.localizedDescription.contains(base.username), "Error must not contain a username")
    }
}

try FTPConnectionTest().test(settings: base)
print("FTP_CONNECTION_LOGIN_AND_DIRECTORY_PASS")

var rejected = base; rejected.username = "reject"
expect(.authenticationFailed, settings: rejected)
print("FTP_CONNECTION_AUTHENTICATION_AND_REDACTION_PASS")

var denied = base; denied.directory = "/deny"
expect(.directoryUnavailable, settings: denied)
print("FTP_CONNECTION_DIRECTORY_FAILURE_PASS")

var offline = base; offline.port = closedPort
expect(.unavailable, settings: offline)
print("FTP_CONNECTION_UNAVAILABLE_PASS")

var slow = base; slow.username = "timeout"
let timeoutStart = Date()
expect(.timedOut, settings: slow)
precondition(Date().timeIntervalSince(timeoutStart) <= 16)
print("FTP_CONNECTION_TIMEOUT_PASS")

var slowDirectory = base; slowDirectory.directory = "/timeout"
let totalTimeoutStart = Date()
expect(.timedOut, settings: slowDirectory)
precondition(Date().timeIntervalSince(totalTimeoutStart) <= 16)
print("FTP_CONNECTION_TOTAL_TIMEOUT_PASS")

var paused = base; paused.username = "cancel"
let cancellable = FTPConnectionTest()
let cancelStart = Date()
DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { cancellable.cancel() }
expect(.cancelled, settings: paused, tester: cancellable)
precondition(Date().timeIntervalSince(cancelStart) < 3)
// Cancellation stays local to this request; a subsequent independent worker is unaffected.
try FTPConnectionTest().test(settings: base)
print("FTP_CONNECTION_INDEPENDENT_CANCELLATION_PASS")

let alreadyCancelled = FTPConnectionTest()
alreadyCancelled.cancel()
expect(.cancelled, settings: base, tester: alreadyCancelled)
print("FTP_CONNECTION_PRESTART_CANCELLATION_PASS")
