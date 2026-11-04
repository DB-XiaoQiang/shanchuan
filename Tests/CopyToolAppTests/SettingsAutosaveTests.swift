import XCTest
import CopyToolCore
@testable import CopyToolApp

final class SettingsAutosaveTests: XCTestCase {
    @MainActor
    func testDirectoryRulesAutosaveAndInvalidEditPreservesSavedRules() async throws {
        let state = AutosaveState()
        let store = makeStore(state: state)
        store.draft.directoryExclusionRules = ".git/\nnode_modules/\n*.log"
        store.schedule(); store.flush()
        XCTAssertEqual(state.preferences.directoryExclusionRules, ".git/\nnode_modules/\n*.log")
        XCTAssertEqual(store.status, .saved)
        store.draft.directoryExclusionRules = "../outside"
        store.schedule(); store.flush()
        if case .failed(let message) = store.status { XCTAssertTrue(message.contains("目录排除规则")) }
        else { XCTFail("Invalid directory rules must not be saved") }
        XCTAssertEqual(state.preferences.directoryExclusionRules, ".git/\nnode_modules/\n*.log")
        store.draft.directoryExclusionRules = ""
        store.schedule(); store.flush()
        XCTAssertEqual(state.preferences.directoryExclusionRules, "")
        XCTAssertEqual(store.status, .saved)
    }

    @MainActor
    func testOpeningAndFlushingUnchangedSettingsDoNotWrite() async throws {
        let state = AutosaveState()
        let store = makeStore(state: state)

        XCTAssertEqual(store.draft, state.preferences)
        XCTAssertEqual(store.secret, state.secret)
        XCTAssertEqual(store.status, .ready)
        store.schedule()
        store.flush()

        XCTAssertTrue(state.attempts.isEmpty)
        XCTAssertEqual(store.status, .ready)
    }

    @MainActor
    func testRapidEditsPersistOnlyTheLatestValues() async throws {
        let state = AutosaveState()
        let store = makeStore(state: state, delay: 30_000_000)

        for value in ["first.invalid", "second.invalid", "last.invalid"] {
            store.draft.host = value
            store.schedule()
        }
        XCTAssertEqual(store.status, .pending)
        try await waitUntil { state.attempts.count == 1 }

        XCTAssertEqual(state.attempts.count, 1)
        XCTAssertEqual(state.preferences.host, "last.invalid")
        XCTAssertEqual(store.status, .saved)
    }

    @MainActor
    func testClosingFlushesPendingEditWithoutDelayedDuplicateWrite() async throws {
        let state = AutosaveState()
        let store = makeStore(state: state, delay: 40_000_000)

        store.draft.directory = "/synthetic/new-destination"
        store.schedule()
        store.flush() // 设置窗口关闭时调用同一入口。
        XCTAssertEqual(state.attempts.count, 1)
        XCTAssertEqual(state.preferences.directory, "/synthetic/new-destination")

        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(state.attempts.count, 1)
        XCTAssertEqual(store.status, .saved)
    }

    @MainActor
    func testRevertingAPendingEditClearsPendingStatusWithoutWriting() async throws {
        let state = AutosaveState()
        let original = state.preferences
        let store = makeStore(state: state, delay: 30_000_000)
        store.draft.host = "temporary.invalid"
        store.schedule()
        XCTAssertEqual(store.status, .pending)

        store.draft.host = original.host
        store.schedule()
        try await Task.sleep(nanoseconds: 90_000_000)

        XCTAssertEqual(state.preferences, original)
        XCTAssertTrue(state.attempts.isEmpty)
        XCTAssertEqual(store.status, .saved)
    }

    @MainActor
    func testRevertingAnInvalidEditClearsFailureWithoutWriting() async throws {
        let state = AutosaveState()
        let originalPort = String(state.preferences.port)
        let store = makeStore(state: state)
        store.portText = "invalid"
        store.schedule()
        assertFailed(store.status)

        store.portText = originalPort
        store.schedule()
        store.flush()

        XCTAssertTrue(state.attempts.isEmpty)
        XCTAssertEqual(state.preferences.port, Int(originalPort))
        XCTAssertEqual(store.status, .saved)
    }

    @MainActor
    func testInvalidHostPreservesSavedValuesAndCorrectionRecovers() async throws {
        let state = AutosaveState()
        let original = state.preferences
        let store = makeStore(state: state)

        for invalid in ["", "ftp://synthetic.invalid", "host name"] {
            store.draft.host = invalid
            store.schedule()
            store.flush()
            assertFailed(store.status)
            XCTAssertEqual(state.preferences, original)
            XCTAssertTrue(state.attempts.isEmpty)
        }

        store.draft.host = "corrected.invalid"
        store.flush()
        XCTAssertEqual(state.attempts.count, 1)
        XCTAssertEqual(state.preferences.host, "corrected.invalid")
        XCTAssertEqual(store.status, .saved)
    }

    @MainActor
    func testInvalidPortTextIsNotCoercedOrWrittenAndCorrectionRecovers() async throws {
        let state = AutosaveState()
        let original = state.preferences
        let store = makeStore(state: state)

        for invalid in ["", "0", "65536", "21x"] {
            store.portText = invalid
            store.schedule()
            store.flush()
            assertFailed(store.status)
            XCTAssertEqual(state.preferences, original)
            XCTAssertTrue(state.attempts.isEmpty)
            XCTAssertEqual(store.portText, invalid)
        }

        store.portText = "2121"
        store.flush()
        XCTAssertEqual(state.attempts.count, 1)
        XCTAssertEqual(state.preferences.port, 2121)
        XCTAssertEqual(store.status, .saved)
    }

    @MainActor
    func testGeneralSettingsMergeTheLatestIndependentlySavedShortcuts() async throws {
        let state = AutosaveState()
        let store = makeStore(state: state)
        store.draft.ttlDays = 42
        // 模拟快捷键编辑器已经独立保存，常规设置仍持有此前的草稿。
        state.preferences.shortcuts = CopyPasteShortcuts(
            enabled: false,
            copy: ShortcutBinding(keyCode: 0, modifiers: 6),
            paste: ShortcutBinding(keyCode: 2, modifiers: 6))
        state.preferences.syncEnabled = true
        let latestShortcuts = state.preferences.shortcuts

        store.flush()

        XCTAssertEqual(state.attempts.count, 1)
        XCTAssertEqual(state.preferences.ttlDays, 42)
        XCTAssertEqual(state.preferences.shortcuts, latestShortcuts)
        XCTAssertTrue(state.preferences.syncEnabled)
        store.flush()
        XCTAssertEqual(state.attempts.count, 1)
    }

    @MainActor
    func testFailedSaveKeepsTheDraftDirtySoIdenticalValuesCanRetry() async throws {
        let state = AutosaveState()
        let original = state.preferences
        state.failuresRemaining = 1
        let store = makeStore(state: state)
        store.draft.showTransferProgress = false
        store.secret = "synthetic-updated-secret"

        store.flush()
        XCTAssertEqual(state.attempts.count, 1)
        XCTAssertEqual(state.preferences, original)
        XCTAssertEqual(state.secret, "synthetic-old-secret")
        XCTAssertEqual(store.status, .failed("synthetic write failure"))

        store.flush() // 不再编辑任何字段，仍应重试此前未持久化的值。
        XCTAssertEqual(state.attempts.count, 2)
        XCTAssertFalse(state.preferences.showTransferProgress)
        XCTAssertEqual(state.secret, "synthetic-updated-secret")
        XCTAssertEqual(store.status, .saved)
        store.flush()
        XCTAssertEqual(state.attempts.count, 2)
    }

    @MainActor
    func testReloadCancelsStaleDraftAndReadsLatestConfigurationWithoutWriting() async throws {
        let state = AutosaveState()
        let store = makeStore(state: state, delay: 30_000_000)
        store.draft.host = "discarded.invalid"
        store.schedule()
        state.preferences.host = "latest.invalid"
        state.secret = "synthetic-latest-secret"

        store.reload()
        try await Task.sleep(nanoseconds: 90_000_000)

        XCTAssertEqual(store.draft, state.preferences)
        XCTAssertEqual(store.secret, state.secret)
        XCTAssertEqual(store.portText, String(state.preferences.port))
        XCTAssertEqual(store.status, .ready)
        XCTAssertTrue(state.attempts.isEmpty)
    }

    @MainActor
    private func makeStore(state: AutosaveState,
                           delay: UInt64 = 500_000_000) -> SettingsAutosaveStore {
        let store = SettingsAutosaveStore(delayNanoseconds: delay)
        store.connect(current: { (state.preferences, state.secret) }, save: { values, secret in
            state.attempts.append((values, secret))
            if state.failuresRemaining > 0 {
                state.failuresRemaining -= 1
                return "synthetic write failure"
            }
            state.preferences = values
            state.secret = secret
            return nil
        })
        return store
    }

    @MainActor
    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !predicate() && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(predicate(), "自动保存没有在限定时间内完成")
    }

    private func assertFailed(_ status: SettingsAutosaveStore.Status,
                              file: StaticString = #filePath, line: UInt = #line) {
        guard case .failed(let error) = status else {
            XCTFail("非法草稿必须显示未保存状态", file: file, line: line)
            return
        }
        XCTAssertFalse(error.isEmpty, file: file, line: line)
    }
}

@MainActor private final class AutosaveState {
    var preferences = syntheticPreferences()
    var secret = "synthetic-old-secret"
    var attempts: [(AppPreferences, String)] = []
    var failuresRemaining = 0
}

private func syntheticPreferences() -> AppPreferences {
    var preferences = AppPreferences()
    preferences.host = "synthetic.invalid"
    preferences.username = "synthetic-user"
    preferences.directory = "/synthetic"
    preferences.shortcuts.enabled = false
    return preferences
}

final class SettingsPersistenceTests: XCTestCase {
    @MainActor
    func testUnchangedPasswordDoesNotWriteTheVault() async throws {
        let vault = SyntheticVault()
        try withIsolatedModel(vault: vault) { model in
            var candidate = model.preferences
            candidate.ttlDays = 31

            XCTAssertTrue(model.saveSettings(preferences: candidate, password: vault.value))

            XCTAssertTrue(vault.writes.isEmpty)
            XCTAssertEqual(model.preferences, candidate)
            XCTAssertEqual(try readPreferences(root: model.root), candidate)
            XCTAssertTrue(model.settingsError.isEmpty)
        }
    }

    @MainActor
    func testVaultFailurePreservesLiveSettingsAndJSON() async throws {
        let vault = SyntheticVault()
        vault.rejectWrites = true
        try withIsolatedModel(vault: vault) { model in
            let original = model.preferences
            let originalJSON = try Data(contentsOf: model.root.appendingPathComponent("preferences.json"))
            var candidate = original
            candidate.host = "changed.invalid"

            XCTAssertFalse(model.saveSettings(preferences: candidate, password: "synthetic-new-secret"))

            XCTAssertEqual(vault.writes, ["synthetic-new-secret"])
            XCTAssertEqual(vault.value, "synthetic-old-secret")
            XCTAssertEqual(model.preferences, original)
            XCTAssertEqual(model.password, "synthetic-old-secret")
            XCTAssertEqual(try Data(contentsOf: model.root.appendingPathComponent("preferences.json")), originalJSON)
            XCTAssertFalse(model.settingsError.isEmpty)
        }
    }

    @MainActor
    func testJSONFailureRollsBackAnAlreadyUpdatedVaultAndPreservesLiveSettings() async throws {
        let vault = SyntheticVault()
        try withIsolatedModel(vault: vault) { model in
            let original = model.preferences
            let config = model.root.appendingPathComponent("preferences.json")
            try FileManager.default.removeItem(at: config)
            try FileManager.default.createDirectory(at: config, withIntermediateDirectories: false)
            let sentinel = config.appendingPathComponent("do-not-replace")
            try Data("synthetic directory sentinel".utf8).write(to: sentinel)
            var candidate = original
            candidate.host = "changed.invalid"

            XCTAssertFalse(model.saveSettings(preferences: candidate, password: "synthetic-new-secret"))

            XCTAssertEqual(vault.writes, ["synthetic-new-secret", "synthetic-old-secret"])
            XCTAssertEqual(vault.value, "synthetic-old-secret")
            XCTAssertEqual(model.preferences, original)
            XCTAssertEqual(model.password, "synthetic-old-secret")
            XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
            XCTAssertFalse(model.settingsError.isEmpty)
        }
    }

    @MainActor
    private func withIsolatedModel(vault: SyntheticVault,
                                   _ body: (AppModel) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CopyToolSettingsTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try JSONEncoder().encode(syntheticPreferences())
            .write(to: root.appendingPathComponent("preferences.json"))
        let model = AppModel(root: root, readPassword: { vault.value }, writePassword: { value in
            vault.writes.append(value)
            if vault.rejectWrites { throw SyntheticVaultError.rejected }
            vault.value = value
        })
        try body(model)
    }

    private func readPreferences(root: URL) throws -> AppPreferences {
        try JSONDecoder().decode(AppPreferences.self, from: Data(contentsOf: root.appendingPathComponent("preferences.json")))
    }
}

@MainActor private final class SyntheticVault {
    var value = "synthetic-old-secret"
    var writes: [String] = []
    var rejectWrites = false
}

private enum SyntheticVaultError: LocalizedError {
    case rejected
    var errorDescription: String? { "synthetic vault rejection" }
}
