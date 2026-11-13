import AppKit
import ApplicationServices
import Carbon
import CopyToolCore
import OSLog

/// Registers only the configured combinations. There is no global keyboard monitor or event tap.
/// The synthetic command goes to the application that was frontmost when the shortcut was pressed.
@MainActor final class GlobalCopyPasteShortcuts {
    private enum Action: String {
        case copy = "复制"
        case paste = "粘贴"

        // Keep the raw identifiers stable; only the user-facing label is localized.
        var displayName: String { L10n.text(rawValue) }

        var commandKeyCode: CGKeyCode { self == .copy ? CGKeyCode(kVK_ANSI_C) : CGKeyCode(kVK_ANSI_V) }
    }

    private struct Binding: Hashable {
        let keyCode: UInt32
        let modifiers: UInt32

        init(_ binding: ShortcutBinding) {
            keyCode = binding.keyCode
            modifiers = binding.modifiers
        }

        var carbonModifiers: UInt32 {
            var result: UInt32 = 0
            if modifiers & 1 != 0 { result |= UInt32(cmdKey) }
            if modifiers & 2 != 0 { result |= UInt32(optionKey) }
            if modifiers & 4 != 0 { result |= UInt32(controlKey) }
            if modifiers & 8 != 0 { result |= UInt32(shiftKey) }
            return result
        }

        func matches(_ event: NSEvent) -> Bool {
            guard UInt32(event.keyCode) == keyCode else { return false }
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            var bits: UInt32 = 0
            if flags.contains(.command) { bits |= 1 }
            if flags.contains(.option) { bits |= 2 }
            if flags.contains(.control) { bits |= 4 }
            if flags.contains(.shift) { bits |= 8 }
            return bits == modifiers
        }
    }

    private struct Registration {
        let reference: EventHotKeyRef
        let id: UInt32
    }

    private struct ShortcutError: LocalizedError {
        let origin: L10n.Snapshot
        init(message: String) { origin = L10n.capture(message) }
        init(origin: L10n.Snapshot) { self.origin = origin }
        var errorDescription: String? { origin.rendered }
    }

    struct MenuItemMetadata: Equatable {
        let commandCharacter: String?
        let virtualKey: Int?
        let modifiers: Int?
        let enabled: Bool
        let supportsPress: Bool
    }

    enum MenuItemSelection: Equatable {
        case noMatch, unsupported, disabled, ambiguous
        case unique(Int)
    }

    enum MenuDispatchResult: Equatable {
        case success, definitelyNotPerformed, disabled, uncertain
    }

    enum CopyReadyDecision: Equatable {
        case notCopy, notDispatched, cancelled, inputChanged, expired, unchanged, ready
    }

    struct ReleaseTracker {
        private var targets: [UInt32: pid_t] = [:]

        mutating func press(id: UInt32, target: pid_t?) -> Bool {
            guard targets[id] == nil, let target else { return false }
            targets[id] = target
            return true
        }

        mutating func release(id: UInt32) -> pid_t? { targets.removeValue(forKey: id) }
        mutating func reset() { targets.removeAll() }
    }

    private struct CopyDispatchBaseline {
        let changeCount: Int
        let inputCounters: [UInt32]
    }

    private static let signature: OSType = 0x43545053 // CTPS
    static let syntheticEventMarker: Int64 = 0x43545053434D44
    private let onStatus: (String) -> Void
    private let onLocalizedStatus: ((L10n.Snapshot) -> Void)?
    private let onCopyReady: (Int) -> Void
    private let logger = Logger(subsystem: "local.copytool.independent", category: "GlobalShortcuts")
    private var handler: EventHandlerRef?
    private var localMonitor: Any?
    private var registrations: [Binding: Registration] = [:]
    private var actions: [UInt32: Action] = [:]
    private var releases = ReleaseTracker()
    private var nextID: UInt32 = 1
    private var configuration: CopyPasteShortcuts?
    private var recordingShortcut = false
    private var pendingCommand: Task<Void, Never>?
    private var pendingCommandID: UUID?

    init(onStatus: @escaping (String) -> Void, onCopyReady: @escaping (Int) -> Void = { _ in },
         onLocalizedStatus: ((L10n.Snapshot) -> Void)? = nil) {
        self.onStatus = onStatus
        self.onLocalizedStatus = onLocalizedStatus
        self.onCopyReady = onCopyReady
    }

    var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    func copyInFrontmostApplication() { perform(.copy) }

    func pasteInFrontmostApplication() { perform(.paste) }

    func openAccessibilitySettings() {
        // Request only when the user presses the permission button; launching the app never prompts.
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Existing registrations stay live until *both* requested bindings have been acquired.
    /// Unchanged bindings and swapped copy/paste bindings reuse their Carbon registrations.
    func apply(_ config: CopyPasteShortcuts) throws {
        if let error = config.validationError { throw ShortcutError(message: error) }
        let copy = Binding(config.copy)
        let paste = Binding(config.paste)
        if recordingShortcut {
            configuration = config
            return
        }
        guard config.enabled else {
            releaseRegistrations()
            removeHandlers()
            configuration = config
            return
        }

        try installHandlersIfNeeded()
        let requested: [(Binding, Action)] = [(copy, .copy), (paste, .paste)]
        var replacements: [Binding: Registration] = [:]
        var acquired: [Registration] = []
        do {
            for (binding, action) in requested {
                if let existing = registrations[binding] {
                    replacements[binding] = existing
                    continue
                }
                let id = nextID
                nextID &+= 1
                if nextID == 0 { nextID = 1 }
                var reference: EventHotKeyRef?
                let status = RegisterEventHotKey(binding.keyCode, binding.carbonModifiers,
                    EventHotKeyID(signature: Self.signature, id: id), GetApplicationEventTarget(),
                    OptionBits(kEventHotKeyExclusive), &reference)
                guard status == noErr, let reference else {
                    if status == eventHotKeyExistsErr {
                        throw ShortcutError(origin: L10n.snapshotCompose("%@快捷键已被其他应用或系统占用，请换一个组合", .snapshot(L10n.snapshot(action.rawValue))))
                    }
                    throw ShortcutError(origin: L10n.snapshotCompose("无法注册%@快捷键（系统错误 %@），请换一个组合", .snapshot(L10n.snapshot(action.rawValue)), .literal(String(describing: status))))
                }
                let registration = Registration(reference: reference, id: id)
                acquired.append(registration)
                replacements[binding] = registration
            }
        } catch {
            for registration in acquired { UnregisterEventHotKey(registration.reference) }
            if registrations.isEmpty { removeHandlers() }
            throw error
        }

        cancelPendingCommand()
        for (binding, registration) in registrations where replacements[binding] == nil {
            UnregisterEventHotKey(registration.reference)
        }
        registrations = replacements
        actions = Dictionary(uniqueKeysWithValues: requested.compactMap { binding, action in
            replacements[binding].map { ($0.id, action) }
        })
        configuration = config
    }

    /// A recorder must receive the old combination as ordinary input, so pause Carbon while recording.
    /// Resume may throw if another application acquired a combination in the meantime.
    func setRecordingShortcut(_ isRecording: Bool) throws {
        guard recordingShortcut != isRecording else { return }
        if isRecording {
            recordingShortcut = true
            releaseRegistrations()
            removeHandlers()
        } else {
            recordingShortcut = false
            if let configuration { try apply(configuration) }
        }
    }

    func stop() {
        releaseRegistrations()
        removeHandlers()
        configuration = nil
        recordingShortcut = false
    }

    private func installHandlersIfNeeded() throws {
        if handler == nil {
            var eventTypes = [
                EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
            ]
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
                guard status == noErr, hotKeyID.signature == GlobalCopyPasteShortcuts.signature else {
                    return OSStatus(eventNotHandledErr)
                }
                let service = Unmanaged<GlobalCopyPasteShortcuts>.fromOpaque(context).takeUnretainedValue()
                return MainActor.assumeIsolated {
                    service.receiveHotKey(id: hotKeyID.id, released: GetEventKind(event) == UInt32(kEventHotKeyReleased))
                }
            }, eventTypes.count, &eventTypes, Unmanaged.passUnretained(self).toOpaque(), &handler)
            guard status == noErr else {
                throw ShortcutError(origin: L10n.snapshotFormat("无法启动快捷键服务（系统错误 %@）", String(describing: status)))
            }
        }
        if localMonitor == nil {
            // This observes only events already dispatched to this app; external keyboard input is never monitored.
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
                var result: NSEvent? = event
                MainActor.assumeIsolated {
                    guard let self else { return }
                    result = self.receiveLocalEvent(event)
                }
                return result
            }
        }
    }

    private func receiveHotKey(id: UInt32, released: Bool) -> OSStatus {
        guard actions[id] != nil, !recordingShortcut else { return OSStatus(eventNotHandledErr) }
        if released {
            finishHotKey(id: id)
        } else if releases.press(id: id, target: NSWorkspace.shared.frontmostApplication?.processIdentifier), let action = actions[id] {
            logger.info("Carbon hotkey received: id=\(id, privacy: .public) action=\(action.rawValue, privacy: .public)")
        }
        return noErr
    }

    private func receiveLocalEvent(_ event: NSEvent) -> NSEvent? {
        guard !recordingShortcut,
              event.cgEvent?.getIntegerValueField(.eventSourceUserData) != Self.syntheticEventMarker else { return event }
        if event.type == .keyUp {
            for (binding, registration) in registrations where binding.keyCode == UInt32(event.keyCode) {
                finishHotKey(id: registration.id)
            }
            return event
        }
        guard let pair = registrations.first(where: { $0.key.matches(event) }),
              let action = actions[pair.value.id] else { return event }
        if !event.isARepeat, releases.press(id: pair.value.id, target: NSWorkspace.shared.frontmostApplication?.processIdentifier) {
            logger.info("Local hotkey received: id=\(pair.value.id, privacy: .public) action=\(action.rawValue, privacy: .public)")
        }
        return nil
    }

    /// A shortcut is committed on release, once. Its own held-key repeats must not be
    /// mistaken for a later user command; never redirect it to a different application.
    private func finishHotKey(id: UInt32) {
        guard let originalPID = releases.release(id: id) else { return }
        guard let action = actions[id] else { return }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == originalPID else {
            reportNotPerformed(L10n.snapshot("快捷键已取消：按键期间前台应用已切换"), action: action, target: nil)
            return
        }
        perform(action)
    }

    private func perform(_ action: Action) {
        guard pendingCommand == nil, !recordingShortcut else {
            logger.notice("Shortcut skipped: command pending or shortcut recording active")
            reportNotPerformed(L10n.snapshotCompose("%@操作未执行：请等待当前操作或录制结束", .snapshot(L10n.snapshot(action.rawValue))), action: action, target: nil)
            return
        }
        let requestInputCounters = Self.newInputCounters()
        guard let target = NSWorkspace.shared.frontmostApplication, !target.isTerminated else {
            logger.notice("Shortcut cancelled: no running frontmost application")
            reportNotPerformed(L10n.snapshotCompose("%@操作已取消：没有可用的前台应用", .snapshot(L10n.snapshot(action.rawValue))), action: action, target: nil)
            return
        }
        let pid = target.processIdentifier
        let isLocal = pid == ProcessInfo.processInfo.processIdentifier
        let bundleID = target.bundleIdentifier ?? "unknown"
        logger.info("Shortcut target: action=\(action.rawValue, privacy: .public) bundleID=\(bundleID, privacy: .public) pid=\(pid, privacy: .public) local=\(isLocal, privacy: .public)")
        let accessibilityTrusted = isAccessibilityTrusted
        let postEventAccess = CGPreflightPostEventAccess()
        logger.info("Permission preflight: AXIsProcessTrusted=\(accessibilityTrusted, privacy: .public) CGPreflightPostEventAccess=\(postEventAccess, privacy: .public)")
        guard isLocal || accessibilityTrusted else {
            logger.error("Shortcut denied: Accessibility permission missing; pid=\(pid, privacy: .public)")
            reportNotPerformed(L10n.snapshotCompose("%@快捷键未执行：请在系统设置的辅助功能中允许闪传", .snapshot(L10n.snapshot(action.rawValue))), action: action, target: target)
            return
        }
        let commandID = UUID()
        pendingCommandID = commandID
        pendingCommand = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.pendingCommandID == commandID {
                    self.pendingCommand = nil
                    self.pendingCommandID = nil
                }
            }
            let modifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift, .maskSecondaryFn]
            // Releasing the configured modifiers prevents Option/Control/Shift from altering Cmd+C/V.
            // A timeout cancels the action without activating or delivering input to another window.
            for _ in 0..<120 {
                guard !Task.isCancelled, !self.recordingShortcut else {
                    self.logger.info("Shortcut cancelled before dispatch: task cancelled or recorder active; pid=\(pid, privacy: .public)")
                    self.reportNotPerformed(L10n.snapshotCompose("%@操作已取消", .snapshot(L10n.snapshot(action.rawValue))), action: action, target: target)
                    return
                }
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid, !target.isTerminated else {
                    self.logger.notice("Shortcut cancelled: frontmost application changed or target terminated; pid=\(pid, privacy: .public)")
                    self.reportNotPerformed(L10n.snapshotCompose("%@快捷键已取消：前台应用已切换", .snapshot(L10n.snapshot(action.rawValue))), action: action, target: target)
                    return
                }
                if CGEventSource.flagsState(.hidSystemState).intersection(modifiers).isEmpty { break }
                do { try await Task.sleep(nanoseconds: 25_000_000) } catch {
                    self.logger.info("Shortcut cancelled while waiting for modifier release; pid=\(pid, privacy: .public)")
                    self.reportNotPerformed(L10n.snapshotCompose("%@操作已取消", .snapshot(L10n.snapshot(action.rawValue))), action: action, target: target)
                    return
                }
            }
            guard CGEventSource.flagsState(.hidSystemState).intersection(modifiers).isEmpty else {
                self.logger.notice("Shortcut cancelled: modifier release timeout; pid=\(pid, privacy: .public)")
                self.reportNotPerformed(L10n.snapshotCompose("%@快捷键已取消：请松开修饰键后重试", .snapshot(L10n.snapshot(action.rawValue))), action: action, target: target)
                return
            }
            guard !Task.isCancelled, !self.recordingShortcut,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == pid, !target.isTerminated else {
                self.logger.notice("Shortcut cancelled at final dispatch check; pid=\(pid, privacy: .public)")
                self.reportNotPerformed(L10n.snapshotCompose("%@快捷键已取消：目标或录制状态已改变", .snapshot(L10n.snapshot(action.rawValue))), action: action, target: target)
                return
            }
            guard Self.newInputCounters() == requestInputCounters else {
                let observedCounters = Self.newInputCounters().description
                let initialCounters = requestInputCounters.description
                self.logger.notice("Shortcut input counters changed: initial=\(initialCounters, privacy: .public) observed=\(observedCounters, privacy: .public)")
                self.logger.notice("Shortcut cancelled: new physical operation while waiting for modifier release")
                self.reportNotPerformed(L10n.snapshot("等待快捷键释放期间检测到新的操作"), action: action, target: target)
                return
            }
            if isLocal {
                let selector = NSSelectorFromString(action == .copy ? "copy:" : "paste:")
                let copyBaseline = action == .copy ? Self.captureCopyDispatchBaseline() : nil
                guard (copyBaseline?.inputCounters ?? Self.newInputCounters()) == requestInputCounters else {
                    self.reportNotPerformed(L10n.snapshot("复制前检测到新的操作"), action: action, target: target)
                    return
                }
                let handled = NSApp.sendAction(selector, to: nil, from: self)
                self.logger.info("Local responder dispatch: action=\(action.rawValue, privacy: .public) handled=\(handled, privacy: .public)")
                if handled && action == .copy {
                    await self.confirmCopyReady(baseline: copyBaseline, target: target, commandID: commandID)
                } else if handled {
                    self.report(L10n.snapshotCompose("已向当前输入框发送%@操作", .snapshot(L10n.snapshot(action.rawValue))), target: target)
                } else {
                    self.reportNotPerformed(L10n.snapshotCompose("当前控件不支持%@操作", .snapshot(L10n.snapshot(action.rawValue))), action: action, target: target)
                }
                return
            }
            let accessibilityTrusted = self.isAccessibilityTrusted
            let postEventAccess = CGPreflightPostEventAccess()
            self.logger.info("Permission dispatch check: AXIsProcessTrusted=\(accessibilityTrusted, privacy: .public) CGPreflightPostEventAccess=\(postEventAccess, privacy: .public)")
            guard accessibilityTrusted else {
                self.logger.error("Shortcut denied at dispatch: Accessibility permission missing; pid=\(pid, privacy: .public)")
                self.reportNotPerformed(L10n.snapshotCompose("%@快捷键未执行：辅助功能权限未授权", .snapshot(L10n.snapshot(action.rawValue))), action: action, target: target)
                return
            }
            self.logger.info("Accessibility permission confirmed; pid=\(pid, privacy: .public)")
            var menuCopyBaseline: CopyDispatchBaseline?
            let menuResult = self.performMenuCommand(action, target: target, willDispatch: {
                if action == .copy { menuCopyBaseline = Self.captureCopyDispatchBaseline() }
                return (menuCopyBaseline?.inputCounters ?? Self.newInputCounters()) == requestInputCounters
            }) {
                !Task.isCancelled && !self.recordingShortcut && self.isAccessibilityTrusted
                    && NSWorkspace.shared.frontmostApplication?.processIdentifier == pid && !target.isTerminated
                    && CGEventSource.flagsState(.hidSystemState).intersection(modifiers).isEmpty
                    && Self.newInputCounters() == requestInputCounters
            }
            switch menuResult {
            case .success:
                if action == .copy {
                    await self.confirmCopyReady(baseline: menuCopyBaseline, target: target, commandID: commandID)
                } else {
                    self.report(L10n.snapshotCompose("已执行%@操作", .snapshot(L10n.snapshot(action.rawValue))), target: target)
                }
                return
            case .uncertain:
                self.reportNotPerformed(L10n.snapshotCompose("%@操作未能确认，已停止以避免重复执行", .snapshot(L10n.snapshot(action.rawValue))), action: action, target: target)
                return
            case .disabled:
                self.reportNotPerformed(L10n.snapshotCompose("当前内容不可%@", .snapshot(L10n.snapshot(action.rawValue))), action: action, target: target)
                return
            case .definitelyNotPerformed:
                break
            }
            guard !Task.isCancelled, !self.recordingShortcut, self.isAccessibilityTrusted,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == pid, !target.isTerminated,
                  CGEventSource.flagsState(.hidSystemState).intersection(modifiers).isEmpty else {
                self.logger.notice("Keyboard fallback cancelled: target, permission, modifiers or recording changed; pid=\(pid, privacy: .public)")
                self.reportNotPerformed(L10n.snapshotCompose("%@操作已取消：目标或授权状态已改变", .snapshot(L10n.snapshot(action.rawValue))), action: action, target: target)
                return
            }
            guard CGPreflightPostEventAccess() else {
                self.logger.error("Keyboard fallback denied: event posting permission missing; pid=\(pid, privacy: .public)")
                self.reportNotPerformed(L10n.snapshotCompose("%@操作未执行：系统尚未允许发送按键", .snapshot(L10n.snapshot(action.rawValue))), action: action, target: target)
                return
            }
            guard let events = Self.makeCommandEvents(keyCode: action.commandKeyCode) else {
                self.logger.error("Shortcut failed: could not construct command events; pid=\(pid, privacy: .public)")
                self.reportNotPerformed(L10n.snapshotCompose("无法生成%@按键，请重试", .snapshot(L10n.snapshot(action.rawValue))), action: action, target: target)
                return
            }
            guard Self.newInputCounters() == requestInputCounters else {
                self.reportNotPerformed(L10n.snapshot("发送按键前检测到新的操作"), action: action, target: target)
                return
            }
            let keyboardCopyBaseline = action == .copy ? Self.captureCopyDispatchBaseline() : nil
            guard (keyboardCopyBaseline?.inputCounters ?? Self.newInputCounters()) == requestInputCounters else {
                self.reportNotPerformed(L10n.snapshot("发送按键前检测到新的操作"), action: action, target: target)
                return
            }
            for event in events { event.postToPid(pid) }
            self.logger.info("Posted four command events: action=\(action.rawValue, privacy: .public) bundleID=\(bundleID, privacy: .public) pid=\(pid, privacy: .public) source=combinedSession route=postToPid")
            // Posting alone is insufficient: require a fresh clipboard update in the same
            // bounded window with no intervening physical input or application switch.
            if action == .copy {
                await self.confirmCopyReady(baseline: keyboardCopyBaseline, target: target, commandID: commandID)
            } else {
                self.report(L10n.snapshotCompose("已发送%@按键", .snapshot(L10n.snapshot(action.rawValue))), target: target)
            }
        }
    }

    static func prefersKeyboardDispatch(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return bundleID == "com.jetbrains.intellij" || bundleID.hasPrefix("com.jetbrains.intellij.")
    }

    /// Selects by declared standard Command+C/V metadata, never by localized menu titles.
    static func selectMenuItem(keyCode: CGKeyCode, items: [MenuItemMetadata]) -> MenuItemSelection {
        let matching = items.indices.filter { index in
            let item = items[index]
            return item.modifiers == 0 && matchesMenuCommand(keyCode: keyCode,
                commandCharacter: item.commandCharacter, virtualKey: item.virtualKey)
        }
        guard matching.count <= 1 else { return .ambiguous }
        guard let index = matching.first else { return .noMatch }
        guard items[index].enabled else { return .disabled }
        return items[index].supportsPress ? .unique(index) : .unsupported
    }

    /// A declared character is authoritative even on keyboard layouts whose physical codes differ.
    /// Falling back to the virtual key is safe only when no character was supplied.
    static func matchesMenuCommand(keyCode: CGKeyCode, commandCharacter: String?, virtualKey: Int?) -> Bool {
        guard keyCode == CGKeyCode(kVK_ANSI_C) || keyCode == CGKeyCode(kVK_ANSI_V) else { return false }
        if let character = commandCharacter, !character.isEmpty {
            return character.lowercased() == (keyCode == CGKeyCode(kVK_ANSI_C) ? "c" : "v")
        }
        return virtualKey == Int(keyCode)
    }

    /// An AX messaging timeout can occur after the receiver acted; never retry that operation with keys.
    static func classifyMenuActionResult(_ status: AXError) -> MenuDispatchResult {
        switch status {
        case .success: return .success
        case .actionUnsupported: return .definitelyNotPerformed
        default: return .uncertain
        }
    }

    private func performMenuCommand(_ action: Action, target: NSRunningApplication,
                                    willDispatch: () -> Bool,
                                    mayDispatch: () -> Bool) -> MenuDispatchResult {
        let pid = target.processIdentifier
        // IDEA's Java accessibility menu lookup can fail before any AX action runs.
        // Use its normal editor shortcut without traversing that menu.
        if Self.prefersKeyboardDispatch(bundleID: target.bundleIdentifier) {
            logger.info("IDEA compatibility: bypass AX menu lookup; use protected keyboard copy; pid=\(pid, privacy: .public)")
            return .definitelyNotPerformed
        }
        let application = AXUIElementCreateApplication(pid)
        // Bound each IPC call and the scan; a stalled application must not freeze the shortcut service.
        AXUIElementSetMessagingTimeout(application, 0.15)
        var menuBarValue: CFTypeRef?
        let menuStatus = AXUIElementCopyAttributeValue(application, kAXMenuBarAttribute as CFString, &menuBarValue)
        guard menuStatus == .success, let menuBarValue,
              CFGetTypeID(menuBarValue) == AXUIElementGetTypeID() else {
            self.logger.notice("AX menu unavailable: status=\(menuStatus.rawValue, privacy: .public) pid=\(pid, privacy: .public)")
            return .definitelyNotPerformed // No AX action has been attempted.
        }
        let menuBar = menuBarValue as! AXUIElement
        let deadline = Date().addingTimeInterval(1.0)
        var pending: [(AXUIElement, Int)] = [(menuBar, 0)]
        var visited: [AXUIElement] = []
        var elements: [AXUIElement] = []
        var metadata: [MenuItemMetadata] = []
        var complete = true

        func attribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
            guard Date() < deadline else { complete = false; return nil }
            var value: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(element, name, &value)
            if status != .success && status != .attributeUnsupported && status != .noValue { complete = false }
            return status == .success ? value : nil
        }

        while let (element, depth) = pending.popLast() {
            guard Date() < deadline, visited.count < 512, depth <= 10 else { complete = false; break }
            if visited.contains(where: { CFEqual($0, element) }) { continue }
            visited.append(element)
            AXUIElementSetMessagingTimeout(element, 0.15)
            let role = attribute(element, kAXRoleAttribute as CFString) as? String
            if role == kAXMenuItemRole as String {
                let character = attribute(element, kAXMenuItemCmdCharAttribute as CFString) as? String
                let virtualKey = (attribute(element, kAXMenuItemCmdVirtualKeyAttribute as CFString) as? NSNumber)?.intValue
                let modifiers = (attribute(element, kAXMenuItemCmdModifiersAttribute as CFString) as? NSNumber)?.intValue
                if Self.matchesMenuCommand(keyCode: action.commandKeyCode,
                                           commandCharacter: character, virtualKey: virtualKey) {
                    // Missing standard-command metadata is not evidence of a safe, unambiguous command.
                    if modifiers == nil { complete = false }
                    if modifiers == 0 {
                        let enabled = (attribute(element, kAXEnabledAttribute as CFString) as? NSNumber)?.boolValue
                        if enabled == nil { complete = false }
                        var supportsPress = false
                        if enabled == true {
                            var names: CFArray?
                            let status: AXError
                            if Date() < deadline { status = AXUIElementCopyActionNames(element, &names) }
                            else { status = .cannotComplete }
                            if status == .success, let names = names as? [String] {
                                supportsPress = names.contains(kAXPressAction as String)
                            } else if status != .actionUnsupported && status != .notImplemented {
                                complete = false
                            }
                        }
                        elements.append(element)
                        metadata.append(MenuItemMetadata(commandCharacter: character, virtualKey: virtualKey,
                            modifiers: modifiers, enabled: enabled == true, supportsPress: supportsPress))
                    }
                }
            }
            if let childrenValue = attribute(element, kAXChildrenAttribute as CFString) {
                guard let children = childrenValue as? [AXUIElement] else { complete = false; break }
                pending.append(contentsOf: children.map { ($0, depth + 1) })
            }
        }
        guard mayDispatch() else { return .uncertain }
        guard complete, Date() < deadline else {
            logger.notice("AX read-only menu scan incomplete; keyboard fallback permitted; pid=\(pid, privacy: .public)")
            return .definitelyNotPerformed
        }
        switch Self.selectMenuItem(keyCode: action.commandKeyCode, items: metadata) {
        case .noMatch, .unsupported:
            logger.info("AX menu command unavailable before action; keyboard fallback permitted; pid=\(pid, privacy: .public)")
            return .definitelyNotPerformed
        case .ambiguous:
            logger.notice("AX menu command ambiguous; no action or keyboard retry; pid=\(pid, privacy: .public)")
            return .uncertain
        case .disabled:
            logger.info("AX menu command disabled; no action or keyboard retry; pid=\(pid, privacy: .public)")
            return .disabled
        case .unique(let index):
            // Recheck immediately before the sole state-changing AX call.
            guard mayDispatch() else { return .uncertain }
            guard willDispatch() else { return .uncertain }
            let status = AXUIElementPerformAction(elements[index], kAXPressAction as CFString)
            let result = Self.classifyMenuActionResult(status)
            logger.info("AX menu action: action=\(action.rawValue, privacy: .public) pid=\(pid, privacy: .public) status=\(status.rawValue, privacy: .public)")
            return result
        }
    }

    /// Constructs without posting, so the full modifier lifecycle can be checked without touching the clipboard.
    /// CoreGraphics CGEvent.h requires every keystroke, including COMMAND, to be entered and released.
    static func makeCommandEvents(keyCode: CGKeyCode) -> [CGEvent]? {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let commandDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Command), keyDown: true),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false),
              let commandUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Command), keyDown: false) else {
            return nil
        }
        let events = [commandDown, keyDown, keyUp, commandUp]
        for (index, event) in events.enumerated() {
            event.flags = index == events.count - 1 ? [] : .maskCommand
            event.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
        }
        return events
    }

    /// Pure policy: a stale clipboard, paste, failed dispatch or changed target must never authorize sending.
    static func copyReadyDecision(isCopy: Bool, dispatchSucceeded: Bool, baseline: Int?, current: Int,
                                  cancelled: Bool, targetUnchanged: Bool, inputChanged: Bool = false,
                                  windowExpired: Bool = false) -> CopyReadyDecision {
        guard isCopy else { return .notCopy }
        guard dispatchSucceeded, let baseline else { return .notDispatched }
        guard !inputChanged else { return .inputChanged }
        guard !cancelled, targetUnchanged else { return .cancelled }
        guard !windowExpired else { return .expired }
        return current != baseline ? .ready : .unchanged
    }

    /// Counts new physical operations without observing key values or contents. Key-up and flags are
    /// deliberately excluded: finishing the custom shortcut's normal release must not cancel its copy.
    private static func newInputCounters() -> [UInt32] {
        let types: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        return types.map { CGEventSource.counterForEventType(.hidSystemState, eventType: $0) }
    }

    private static func captureCopyDispatchBaseline() -> CopyDispatchBaseline {
        let counters = newInputCounters()
        return CopyDispatchBaseline(changeCount: NSPasteboard.general.changeCount, inputCounters: counters)
    }

    /// A dispatched copy gets a bounded window for asynchronous clipboard writes.
    /// Any new physical operation or target change closes the window; posting alone never sends.
    private func confirmCopyReady(baseline: CopyDispatchBaseline?, target: NSRunningApplication, commandID: UUID) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while ContinuousClock.now < deadline {
            // Check physical operations before considering a new clipboard counter, including when both changed.
            let inputChanged = baseline.map { $0.inputCounters != Self.newInputCounters() } ?? true
            let cancelled = Task.isCancelled || recordingShortcut || pendingCommandID != commandID
            let targetUnchanged = !target.isTerminated
                && NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier
            let observedCount = NSPasteboard.general.changeCount
            let decision = Self.copyReadyDecision(isCopy: true, dispatchSucceeded: true, baseline: baseline?.changeCount,
                current: observedCount, cancelled: cancelled, targetUnchanged: targetUnchanged,
                inputChanged: inputChanged, windowExpired: ContinuousClock.now >= deadline)
            switch decision {
            case .ready:
                guard ContinuousClock.now < deadline, !Task.isCancelled, !recordingShortcut,
                      pendingCommandID == commandID, !target.isTerminated,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier,
                      baseline?.inputCounters == Self.newInputCounters() else {
                    reportNotPerformed(L10n.snapshot("复制确认已取消"), action: .copy, target: target)
                    return
                }
                logger.info("Copy clipboard update confirmed within protected input window; notifying send flow once; pid=\(target.processIdentifier, privacy: .public)")
                onCopyReady(observedCount)
                report(L10n.snapshot("已确认复制，已交给发送流程"), target: target)
                return
            case .cancelled:
                logger.notice("Explicit copy send cancelled: task or frontmost target changed")
                reportNotPerformed(L10n.snapshot("复制确认已取消"), action: .copy, target: target)
                return
            case .inputChanged:
                logger.notice("Explicit copy send cancelled: new physical input inside protected confirmation window")
                reportNotPerformed(L10n.snapshot("复制期间检测到新的操作"), action: .copy, target: target)
                return
            case .notCopy, .notDispatched:
                reportNotPerformed(L10n.snapshot("复制操作未能确认"), action: .copy, target: target)
                return
            case .expired:
                report(L10n.snapshot("复制确认超时，未发送"), target: target)
                return
            case .unchanged:
                break
            }
            do { try await Task.sleep(nanoseconds: 25_000_000) } catch {
                reportNotPerformed(L10n.snapshot("复制确认已取消"), action: .copy, target: target)
                return
            }
        }
        logger.notice("Dispatched copy produced no confirmed update within protected one-second window; no send")
        report(L10n.snapshot("剪贴板未更新，未发送"), target: target)
    }

    private func reportNotPerformed(_ text: L10n.Snapshot, action: Action, target: NSRunningApplication?) {
        report(action == .copy ? text.appending(L10n.snapshot("，未发送")) : text, target: target)
    }

    private func report(_ text: L10n.Snapshot, target: NSRunningApplication?) {
        let appName = target?.localizedName.map(L10n.Snapshot.verbatim) ?? L10n.snapshot("前台应用")
        let origin = L10n.snapshotCompose("%@ · %@ · %@", .time(Date()), .snapshot(appName), .snapshot(text))
        if let onLocalizedStatus { onLocalizedStatus(origin) }
        else { onStatus(origin.rendered) }
    }

    private func cancelPendingCommand() {
        if pendingCommand != nil { logger.info("Pending shortcut cancelled by registration lifecycle") }
        pendingCommand?.cancel()
        pendingCommand = nil
        pendingCommandID = nil
        releases.reset()
    }

    private func releaseRegistrations() {
        cancelPendingCommand()
        for registration in registrations.values { UnregisterEventHotKey(registration.reference) }
        registrations.removeAll()
        actions.removeAll()
    }

    private func removeHandlers() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
        if let handler { RemoveEventHandler(handler); self.handler = nil }
    }

    deinit {
        pendingCommand?.cancel()
        for registration in registrations.values { UnregisterEventHotKey(registration.reference) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let handler { RemoveEventHandler(handler) }
    }
}
