import Carbon
import CoreGraphics
import Foundation

/// A command-line timing probe. It registers one explicit hotkey only; it never
/// installs an event tap, posts events, reads the clipboard, or accesses FTP.
private struct ProbeConfiguration {
    var keyCode: UInt32 = UInt32(kVK_F12)
    var modifiers: UInt32 = UInt32(controlKey | optionKey | shiftKey)
    var duration: TimeInterval = 30

    static let usage = """
    Usage: timing-probe [--key-code 0...127] [--modifiers control,option,shift,command] [--duration 1...300]
    Default: Control+Option+Shift+F12, 30 seconds. Emits JSON Lines.
    Registers only the requested combination. An occupied shortcut fails without replacing its owner.
    Records event counters and configured-key state only. No event posting, clipboard access, or FTP.
    """

    static func parse(_ arguments: [String]) throws -> ProbeConfiguration {
        var configuration = ProbeConfiguration()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            guard index + 1 < arguments.count else { throw ProbeError.invalidArguments }
            let value = arguments[index + 1]
            switch argument {
            case "--key-code":
                guard let code = UInt32(value), code <= 127 else { throw ProbeError.invalidArguments }
                configuration.keyCode = code
            case "--duration":
                guard let duration = Double(value), duration.isFinite, duration >= 1, duration <= 300 else {
                    throw ProbeError.invalidArguments
                }
                configuration.duration = duration
            case "--modifiers":
                var modifiers: UInt32 = 0
                let names = value.lowercased().split(separator: ",", omittingEmptySubsequences: false)
                for name in names {
                    switch name {
                    case "control", "ctrl": modifiers |= UInt32(controlKey)
                    case "option", "opt", "alt": modifiers |= UInt32(optionKey)
                    case "shift": modifiers |= UInt32(shiftKey)
                    case "command", "cmd": modifiers |= UInt32(cmdKey)
                    default: throw ProbeError.invalidArguments
                    }
                }
                guard modifiers != 0 else { throw ProbeError.invalidArguments }
                configuration.modifiers = modifiers
            default: throw ProbeError.invalidArguments
            }
            index += 2
        }
        return configuration
    }
}

private enum ProbeError: Error {
    case invalidArguments
    case installHandler(OSStatus)
    case registerHotKey(OSStatus)
}

private final class TimingProbe {
    private static let signature: OSType = 0x54505242 // TPRB
    private let configuration: ProbeConfiguration
    private var handler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    private var sequence = 0
    private let startedUptime = ProcessInfo.processInfo.systemUptime
    private struct DelayedSample {
        let sequence: Int
        let eventName: String
        let eventTime: EventTime
        let receivedUptime: TimeInterval
        let delayMilliseconds: Int
        var due: TimeInterval { receivedUptime + Double(delayMilliseconds) / 1000 }
    }
    private var delayedSamples: [DelayedSample] = []
    private let counterTypes: [(String, CGEventType)] = [
        ("keyDown", .keyDown), ("keyUp", .keyUp), ("flagsChanged", .flagsChanged),
        ("leftMouseDown", .leftMouseDown), ("rightMouseDown", .rightMouseDown),
        ("otherMouseDown", .otherMouseDown), ("scrollWheel", .scrollWheel)
    ]

    init(configuration: ProbeConfiguration) { self.configuration = configuration }

    func run() throws {
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            return Unmanaged<TimingProbe>.fromOpaque(context).takeUnretainedValue().receive(event)
        }, types.count, &types, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else { throw ProbeError.installHandler(status) }
        let registration = RegisterEventHotKey(configuration.keyCode, configuration.modifiers,
            EventHotKeyID(signature: Self.signature, id: 1), GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive), &hotKey)
        guard registration == noErr, hotKey != nil else {
            stop()
            throw ProbeError.registerHotKey(registration)
        }
        defer { stop() }
        emit(["type": "started", "pid": ProcessInfo.processInfo.processIdentifier,
              "keyCode": configuration.keyCode, "carbonModifiers": configuration.modifiers,
              "durationSeconds": configuration.duration, "uptime": startedUptime])
        let deadline = ProcessInfo.processInfo.systemUptime + configuration.duration
        // Pump only hotkey events for this process. The legacy Carbon
        // RunApplicationEventLoop entry point is unavailable to 64-bit tools.
        while ProcessInfo.processInfo.systemUptime < deadline {
            let now = ProcessInfo.processInfo.systemUptime
            let nextDue = min(delayedSamples.map(\.due).min() ?? deadline, deadline)
            let timeout = max(0, min(0.02, nextDue - now))
            var event: EventRef?
            let received = ReceiveNextEvent(types.count, &types, timeout, true, &event)
            if received == noErr, let event {
                _ = SendEventToEventTarget(event, GetEventDispatcherTarget())
                ReleaseEvent(event)
            } else if received != OSStatus(eventLoopTimedOutErr) {
                emit(["type": "eventLoopError", "status": received])
                break
            }
            let sampleNow = ProcessInfo.processInfo.systemUptime
            let ready = delayedSamples.filter { $0.due <= sampleNow }
            delayedSamples.removeAll { $0.due <= sampleNow }
            for pending in ready {
                sample(sequence: pending.sequence, eventName: pending.eventName,
                       eventTime: pending.eventTime, receivedUptime: pending.receivedUptime,
                       delayMilliseconds: pending.delayMilliseconds)
            }
        }
        emit(["type": "finished", "receivedHotKeyEvents": sequence,
              "elapsedSeconds": ProcessInfo.processInfo.systemUptime - startedUptime])
    }

    private func receive(_ event: EventRef) -> OSStatus {
        var identifier = EventHotKeyID()
        let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
        guard status == noErr, identifier.signature == Self.signature, identifier.id == 1 else {
            return OSStatus(eventNotHandledErr)
        }
        let kind = GetEventKind(event)
        guard kind == UInt32(kEventHotKeyPressed) || kind == UInt32(kEventHotKeyReleased) else {
            return OSStatus(eventNotHandledErr)
        }
        sequence += 1
        let eventSequence = sequence
        let eventName = kind == UInt32(kEventHotKeyPressed) ? "pressed" : "released"
        let eventTime = GetEventTime(event)
        let receivedUptime = ProcessInfo.processInfo.systemUptime
        sample(sequence: eventSequence, eventName: eventName, eventTime: eventTime,
               receivedUptime: receivedUptime, delayMilliseconds: 0)
        for delay in [5, 25, 100] {
            delayedSamples.append(DelayedSample(sequence: eventSequence, eventName: eventName,
                eventTime: eventTime, receivedUptime: receivedUptime, delayMilliseconds: delay))
        }
        return noErr
    }

    private func sample(sequence: Int, eventName: String, eventTime: EventTime,
                        receivedUptime: TimeInterval, delayMilliseconds: Int) {
        let before = ProcessInfo.processInfo.systemUptime
        let currentCarbonTime = GetCurrentEventTime()
        let hid = sourceSnapshot(.hidSystemState)
        let combined = sourceSnapshot(.combinedSessionState)
        let after = ProcessInfo.processInfo.systemUptime
        emit(["type": "sample", "sequence": sequence, "hotKeyEvent": eventName,
              "carbonEventTime": eventTime, "carbonCurrentEventTime": currentCarbonTime,
              "receivedUptime": receivedUptime,
              "requestedDelayMs": delayMilliseconds, "sampleUptimeStart": before,
              "sampleUptimeEnd": after, "actualDelayMs": (before - receivedUptime) * 1000,
              "hid": hid, "combined": combined])
    }

    private func sourceSnapshot(_ state: CGEventSourceStateID) -> [String: Any] {
        var counters: [String: UInt32] = [:]
        for (name, type) in counterTypes {
            counters[name] = CGEventSource.counterForEventType(state, eventType: type)
        }
        let flags = CGEventSource.flagsState(state)
        return ["counters": counters,
                "secondsSinceLastKeyDown": CGEventSource.secondsSinceLastEventType(state, eventType: .keyDown),
                "configuredKeyDown": CGEventSource.keyState(state, key: CGKeyCode(configuration.keyCode)),
                "flagsRaw": flags.rawValue,
                "command": flags.contains(.maskCommand), "option": flags.contains(.maskAlternate),
                "control": flags.contains(.maskControl), "shift": flags.contains(.maskShift)]
    }

    private func emit(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else { return }
        print(line)
        fflush(stdout)
    }

    private func stop() {
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        if let handler { RemoveEventHandler(handler); self.handler = nil }
    }
}

@main private enum TimingProbeMain {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--help"] || arguments == ["-h"] {
            print(ProbeConfiguration.usage)
            return
        }
        do {
            let configuration = try ProbeConfiguration.parse(arguments)
            try withExtendedLifetime(TimingProbe(configuration: configuration)) { probe in try probe.run() }
        } catch {
            let message: String
            switch error {
            case ProbeError.invalidArguments:
                message = ProbeConfiguration.usage
            case ProbeError.installHandler(let status):
                message = "Cannot install Carbon hotkey handler (status \(status))."
            case ProbeError.registerHotKey(let status):
                if status == OSStatus(eventHotKeyExistsErr) {
                    message = "Requested shortcut is already registered (status \(status)); its owner is left unchanged."
                } else if status == OSStatus(eventInternalErr) {
                    message = "Carbon returned an internal registration error (status \(status)); this does not establish a shortcut conflict. Check the desktop session and execution environment."
                } else {
                    message = "Cannot register requested shortcut (status \(status)); no shortcut conflict has been established."
                }
            default:
                message = String(describing: error)
            }
            FileHandle.standardError.write(Data((message + "\n").utf8))
            exit(2)
        }
    }
}
