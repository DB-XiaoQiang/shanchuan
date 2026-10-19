import AppKit
import Carbon
import CopyToolCore

@main enum RegistrationProbe {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        for keyCode in [CGKeyCode(kVK_ANSI_C), CGKeyCode(kVK_ANSI_V)] {
            guard let events = GlobalCopyPasteShortcuts.makeCommandEvents(keyCode: keyCode) else {
                preconditionFailure("Could not construct command events")
            }
            precondition(events.count == 4, "A command requires Command down, key down/up, Command up")
            precondition(events.map(\.type) == [.flagsChanged, .keyDown, .keyUp, .flagsChanged],
                         "Unexpected event order")
            let expectedKeyCodes = [Int64(kVK_Command), Int64(keyCode), Int64(keyCode), Int64(kVK_Command)]
            precondition(events.map { $0.getIntegerValueField(.keyboardEventKeycode) } == expectedKeyCodes,
                         "Unexpected virtual key sequence")
            precondition(events.map(\.flags) == [.maskCommand, .maskCommand, .maskCommand, []],
                         "Command must be released by the last event")
            precondition(events.allSatisfy {
                $0.getIntegerValueField(.eventSourceUserData) == GlobalCopyPasteShortcuts.syntheticEventMarker
            }, "All synthetic events require the recursion-prevention marker")
            let sourceIDs = Set(events.map { $0.getIntegerValueField(.eventSourceStateID) })
            precondition(sourceIDs == [Int64(CGEventSourceStateID.combinedSessionState.rawValue)],
                         "Command fallback must use the combined login-session source")
        }
        print("PASS copy and paste construct four ordered, marked events with complete Command release; not posted")
        typealias Item = GlobalCopyPasteShortcuts.MenuItemMetadata
        func item(_ character: String? = nil, key: Int? = nil, modifiers: Int? = 0,
                  enabled: Bool = true, press: Bool = true) -> Item {
            Item(commandCharacter: character, virtualKey: key, modifiers: modifiers,
                 enabled: enabled, supportsPress: press)
        }
        let copyCode = CGKeyCode(kVK_ANSI_C)
        let pasteCode = CGKeyCode(kVK_ANSI_V)
        precondition(GlobalCopyPasteShortcuts.selectMenuItem(keyCode: copyCode, items: [item("C")]) == .unique(0))
        precondition(GlobalCopyPasteShortcuts.selectMenuItem(keyCode: pasteCode, items: [item(key: 9)]) == .unique(0))
        precondition(GlobalCopyPasteShortcuts.selectMenuItem(keyCode: pasteCode, items: [item("C")]) == .noMatch)
        precondition(GlobalCopyPasteShortcuts.selectMenuItem(keyCode: copyCode, items: [item("C", modifiers: 1)]) == .noMatch)
        precondition(GlobalCopyPasteShortcuts.selectMenuItem(keyCode: copyCode, items: [item("C", modifiers: 8)]) == .noMatch)
        precondition(GlobalCopyPasteShortcuts.selectMenuItem(keyCode: copyCode, items: [item("C", modifiers: nil)]) == .noMatch)
        precondition(GlobalCopyPasteShortcuts.selectMenuItem(keyCode: copyCode, items: [item("C", enabled: false)]) == .disabled)
        precondition(GlobalCopyPasteShortcuts.selectMenuItem(keyCode: copyCode, items: [item("C", press: false)]) == .unsupported)
        precondition(GlobalCopyPasteShortcuts.selectMenuItem(keyCode: copyCode, items: [item("C"), item(key: 8)]) == .ambiguous)
        precondition(GlobalCopyPasteShortcuts.selectMenuItem(keyCode: copyCode, items: [item("x", key: 8)]) == .noMatch,
                     "A physical key code must not override the menu's explicit Cut command character")
        precondition(GlobalCopyPasteShortcuts.selectMenuItem(keyCode: pasteCode, items: [item("x", key: 9)]) == .noMatch)
        precondition(GlobalCopyPasteShortcuts.selectMenuItem(keyCode: copyCode, items: [item("", key: 8)]) == .unique(0))
        precondition(GlobalCopyPasteShortcuts.selectMenuItem(keyCode: copyCode, items: [item("C", key: 9)]) == .unique(0))
        precondition(GlobalCopyPasteShortcuts.selectMenuItem(keyCode: pasteCode, items: [item("C", key: 9)]) == .noMatch)
        precondition(GlobalCopyPasteShortcuts.selectMenuItem(keyCode: copyCode,
                     items: [item("C", enabled: false), item(key: 8)]) == .ambiguous,
                     "Mixed enabled/disabled candidates remain ambiguous")
        precondition(GlobalCopyPasteShortcuts.classifyMenuActionResult(.success) == .success)
        precondition(GlobalCopyPasteShortcuts.classifyMenuActionResult(.actionUnsupported) == .definitelyNotPerformed)
        precondition(GlobalCopyPasteShortcuts.classifyMenuActionResult(.cannotComplete) == .uncertain)
        precondition(GlobalCopyPasteShortcuts.classifyMenuActionResult(.failure) == .uncertain)
        print("PASS pure AX metadata selection, character precedence, disabled/ambiguous commands and uncertain-action retry prevention; no AX calls")
        func copyDecision(isCopy: Bool = true, dispatched: Bool = true, baseline: Int? = 100,
                          current: Int = 101, cancelled: Bool = false, targetUnchanged: Bool = true,
                          inputChanged: Bool = false, windowExpired: Bool = false)
            -> GlobalCopyPasteShortcuts.CopyReadyDecision {
            GlobalCopyPasteShortcuts.copyReadyDecision(isCopy: isCopy, dispatchSucceeded: dispatched,
                baseline: baseline, current: current, cancelled: cancelled, targetUnchanged: targetUnchanged,
                inputChanged: inputChanged, windowExpired: windowExpired)
        }
        precondition(copyDecision() == .ready)
        precondition(copyDecision(current: 100) == .unchanged, "Unchanged clipboard must never send old content")
        precondition(copyDecision(isCopy: false) == .notCopy, "Paste must never authorize an upload")
        precondition(copyDecision(baseline: nil) == .notDispatched)
        precondition(copyDecision(dispatched: false) == .notDispatched)
        precondition(copyDecision(cancelled: true) == .cancelled)
        precondition(copyDecision(targetUnchanged: false) == .cancelled)
        precondition(copyDecision(inputChanged: true) == .inputChanged,
                     "A new physical Command+C or mouse operation during dispatch must prevent sending")
        precondition(copyDecision(current: 102, inputChanged: true) == .inputChanged,
                     "New physical input takes priority even when clipboard contents also changed")
        precondition(copyDecision(windowExpired: true) == .expired,
                     "A changed clipboard after the protected deadline must never authorize sending")
        for result in [GlobalCopyPasteShortcuts.MenuDispatchResult.disabled, .uncertain, .definitelyNotPerformed] {
            precondition(copyDecision(dispatched: result == .success) == .notDispatched,
                         "Disabled, uncertain and failed copy dispatch must not send")
        }
        precondition(copyDecision(current: 100) == .unchanged)
        precondition(copyDecision(current: 101) == .ready,
                     "An acknowledged asynchronous copy may complete while its physical input fingerprint is unchanged")
        precondition(copyDecision(dispatched: false, current: 102) == .notDispatched,
                     "An unacknowledged keyboard fallback must never authorize sending even if the clipboard changes")
        print("PASS protected copy window permits acknowledged delayed writes but blocks new input, expiry and unacknowledged dispatch; no clipboard access")
        var nextID: UInt32 = 100
        let modifiers = UInt32(controlKey | optionKey | shiftKey)
        func reserve(_ code: UInt32) -> (OSStatus, EventHotKeyRef?) {
            nextID += 1
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(code, modifiers,
                EventHotKeyID(signature: 0x50524F42, id: nextID),
                GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &ref)
            return (status, ref)
        }
        func expectOccupied(_ code: UInt32) {
            let (status, ref) = reserve(code)
            if let ref { UnregisterEventHotKey(ref) }
            precondition(status == eventHotKeyExistsErr, "Expected registered key \(code), got \(status)")
        }
        func expectAvailable(_ code: UInt32) {
            let (status, ref) = reserve(code)
            if let ref { UnregisterEventHotKey(ref) }
            precondition(status == noErr && ref != nil, "Expected free key \(code), got \(status)")
        }
        let initial = CopyPasteShortcuts(enabled: true,
            copy: .init(keyCode: 101, modifiers: 14), paste: .init(keyCode: 109, modifiers: 14))
        var statuses: [String] = []
        let compatibleDefaultCallback = GlobalCopyPasteShortcuts(onStatus: { _ in })
        compatibleDefaultCallback.stop()
        var observedCopyCounts: [Int] = []
        var service: GlobalCopyPasteShortcuts? = GlobalCopyPasteShortcuts(onStatus: { statuses.append($0) },
            onCopyReady: { observedCopyCounts.append($0) })
        try service!.apply(initial)
        expectOccupied(101); expectOccupied(109)
        print("PASS paired registration")

        let swapped = CopyPasteShortcuts(enabled: true, copy: initial.paste, paste: initial.copy)
        try service!.apply(swapped)
        expectOccupied(101); expectOccupied(109)
        print("PASS atomic swap reuses registration")

        let (conflictStatus, conflictRef) = reserve(111)
        precondition(conflictStatus == noErr && conflictRef != nil)
        let proposed = CopyPasteShortcuts(enabled: true,
            copy: .init(keyCode: 103, modifiers: 14), paste: .init(keyCode: 111, modifiers: 14))
        do {
            try service!.apply(proposed)
            preconditionFailure("Expected conflict")
        } catch {
            precondition(error.localizedDescription.contains("占用"))
        }
        expectAvailable(103)
        expectOccupied(101); expectOccupied(109)
        UnregisterEventHotKey(conflictRef!)
        print("PASS failed pair rolls back newly acquired key and preserves old pair")

        try service!.setRecordingShortcut(true)
        expectAvailable(101); expectAvailable(109)
        try service!.setRecordingShortcut(false)
        expectOccupied(101); expectOccupied(109)
        print("PASS recorder suspension and restore")

        service!.stop()
        expectAvailable(101); expectAvailable(109)
        print("PASS stop unregisters pair")

        try service!.apply(initial)
        try service!.apply(CopyPasteShortcuts(enabled: false))
        expectAvailable(101); expectAvailable(109)
        try service!.setRecordingShortcut(true)
        try service!.setRecordingShortcut(false)
        expectAvailable(101); expectAvailable(109)
        print("PASS disabling persists across recorder resume")

        try service!.apply(initial)
        service = nil
        expectAvailable(101); expectAvailable(109)
        precondition(statuses.isEmpty)
        precondition(observedCopyCounts.isEmpty, "Registration lifecycle must never authorize sending clipboard data")
        print("PASS deinit unregisters pair; no commands generated")
    }
}
