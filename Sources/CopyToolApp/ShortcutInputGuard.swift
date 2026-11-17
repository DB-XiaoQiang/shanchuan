import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// The policy stores no key codes, characters, or event objects. A new input
/// invalidates a particular generation; losing observation invalidates all of them.
struct ShortcutInputGuardPolicy {
    static let observedTypes: [CGEventType] = [
        .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel
    ]
    static var eventMask: CGEventMask {
        observedTypes.reduce(0) { $0 | (CGEventMask(1) << $1.rawValue) }
    }

    private let syntheticMarker: Int64
    private let startTimestamp: CGEventTimestamp
    private(set) var generation: UInt64 = 0
    private(set) var isValid = true

    init(syntheticMarker: Int64, startTimestamp: CGEventTimestamp) {
        self.syntheticMarker = syntheticMarker
        self.startTimestamp = startTimestamp
    }

    mutating func observe(type: CGEventType, timestamp: CGEventTimestamp, sourceMarker: Int64,
                          isRepeat: Bool = false) {
        guard isValid else { return }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            invalidate()
            return
        }
        guard Self.observedTypes.contains(type), sourceMarker != syntheticMarker else { return }
        guard timestamp != 0 else { invalidate(); return }
        guard timestamp > startTimestamp else { return }
        // A held shortcut's repeat is not a new operation. This matches the
        // Carbon release tracker and the previous counter's repeat semantics.
        guard !(type == .keyDown && isRepeat) else { return }
        guard generation < UInt64.max else { invalidate(); return }
        generation += 1
    }

    mutating func invalidate() { isValid = false }
    func isUnchanged(since baseline: UInt64) -> Bool { isValid && generation == baseline }
}

/// Exists only during one explicit copy/paste request. External input is observed
/// by a session filter on a dedicated run loop. The filter always returns the
/// original event; it never changes, suppresses, or retains input events.
@MainActor final class ShortcutInputGuard {
    private static let maximumLifetime: TimeInterval = 10
    private let syntheticMarker: Int64
    private var state: WorkerState?
    private var worker: Thread?
    private var localMonitor: Any?
    private var localExpiry: Timer?

    init(syntheticMarker: Int64) { self.syntheticMarker = syntheticMarker }

    /// No permission request is made here. External observation requires the
    /// accessibility permission which external copy/paste already requires.
    func start(localOnly: Bool = false) -> Bool {
        guard state == nil else { return false }
        let next = WorkerState(syntheticMarker: syntheticMarker, localOnly: localOnly)
        state = next
        if localOnly {
            let mask: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
            guard let monitor = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
                next.observe(type: CGEventType(rawValue: UInt32(event.type.rawValue)),
                             timestamp: UInt64(max(0, event.timestamp) * 1_000_000_000),
                             sourceMarker: event.cgEvent?.getIntegerValueField(.eventSourceUserData) ?? 0,
                             isRepeat: event.type == .keyDown && event.isARepeat)
                return event
            }) else { stop(); return false }
            localMonitor = monitor
            next.armLocal()
            let timer = Timer(timeInterval: Self.maximumLifetime, repeats: false) { _ in next.invalidate() }
            RunLoop.main.add(timer, forMode: .common)
            localExpiry = timer
            return true
        }
        guard AXIsProcessTrusted() else { stop(); return false }
        let thread = Thread { next.run(maximumLifetime: 10) }
        thread.name = "Shanchuan.ShortcutInputGuard"
        worker = thread
        thread.start()
        guard next.waitUntilReady(timeout: 1) else { stop(); return false }
        guard snapshot != nil else { stop(); return false }
        return true
    }

    /// A nil snapshot is a failure, not an empty/unmodified input window.
    var snapshot: UInt64? { state?.snapshot() }
    func isUnchanged(since baseline: UInt64) -> Bool { snapshot == baseline }
    func invalidate() { state?.invalidate() }

    func stop() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
        localExpiry?.invalidate()
        localExpiry = nil
        state?.requestStop()
        state?.waitUntilFinished(timeout: 1)
        state = nil
        worker = nil
    }

    deinit {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        localExpiry?.invalidate()
        state?.requestStop()
    }

    /// The worker owns this context until its tap/source have been removed. The
    /// outer guard is never captured by the thread or the C callback.
    private final class WorkerState: @unchecked Sendable {
        private static let creationLock = NSLock()
        private let condition = NSCondition()
        private let syntheticMarker: Int64
        private let localOnly: Bool
        private var policy: ShortcutInputGuardPolicy?
        private var ready = false
        private var finished = false
        private var stopping = false
        private var tap: CFMachPort?
        private var runLoop: CFRunLoop?

        init(syntheticMarker: Int64, localOnly: Bool) {
            self.syntheticMarker = syntheticMarker
            self.localOnly = localOnly
            // Establish the request boundary before installing observation.
            // Startup must never reset a generation which already saw input.
            policy = ShortcutInputGuardPolicy(syntheticMarker: syntheticMarker, startTimestamp: Self.currentTimestamp)
        }

        private static var currentTimestamp: CGEventTimestamp {
            DispatchTime.now().uptimeNanoseconds
        }

        func armLocal() {
            condition.lock()
            defer { condition.unlock() }
            guard !stopping else { return }
            ready = true
        }

        func observe(type: CGEventType?, timestamp: CGEventTimestamp, sourceMarker: Int64,
                     isRepeat: Bool = false) {
            condition.lock()
            defer { condition.unlock() }
            guard let type, !stopping else { return }
            policy?.observe(type: type, timestamp: timestamp, sourceMarker: sourceMarker, isRepeat: isRepeat)
        }

        func invalidate() {
            condition.lock()
            policy?.invalidate()
            condition.unlock()
        }

        func snapshot() -> UInt64? {
            condition.lock()
            let currentTap = tap
            let canRead = ready && !stopping && policy?.isValid == true
            condition.unlock()
            guard canRead else { return nil }
            if !localOnly {
                // Do not hold a lock during WindowServer IPC: its callback also
                // needs the lock and must always return promptly.
                guard AXIsProcessTrusted(), let currentTap, CFMachPortIsValid(currentTap),
                      CGEvent.tapIsEnabled(tap: currentTap) else { invalidate(); return nil }
            }
            condition.lock()
            defer { condition.unlock() }
            guard ready, !stopping, let policy, policy.isValid else { return nil }
            return policy.generation
        }

        func waitUntilReady(timeout: TimeInterval) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            condition.lock()
            defer { condition.unlock() }
            while !ready && !finished && !stopping {
                if !condition.wait(until: deadline) { break }
            }
            return ready && !finished && !stopping && policy?.isValid == true
        }

        func requestStop() {
            condition.lock()
            stopping = true
            policy?.invalidate()
            let currentLoop = runLoop
            let currentTap = tap
            if localOnly { finished = true }
            condition.broadcast()
            condition.unlock()
            // Disable observation immediately, even if startup is still waiting
            // for a WindowServer reply. The worker continues to own its context.
            if let currentTap { CFMachPortInvalidate(currentTap) }
            if let currentLoop { CFRunLoopStop(currentLoop); CFRunLoopWakeUp(currentLoop) }
        }

        func waitUntilFinished(timeout: TimeInterval) {
            let deadline = Date().addingTimeInterval(timeout)
            condition.lock()
            defer { condition.unlock() }
            // Failure before a thread starts has no worker to join.
            if localOnly || (tap == nil && runLoop == nil && !ready) { return }
            while !finished {
                if !condition.wait(until: deadline) { break }
            }
        }

        func run(maximumLifetime: TimeInterval) {
            defer {
                condition.lock()
                policy?.invalidate()
                ready = false
                tap = nil
                runLoop = nil
                finished = true
                condition.broadcast()
                condition.unlock()
            }
            Self.creationLock.lock()
            guard !isStopping, AXIsProcessTrusted(), let before = Self.tapInformation() else {
                Self.creationLock.unlock()
                return
            }
            let mask = ShortcutInputGuardPolicy.eventMask
            let context = Unmanaged.passUnretained(self).toOpaque()
            let createdTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, context in
                    if let context {
                        let state = Unmanaged<WorkerState>.fromOpaque(context).takeUnretainedValue()
                        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                            state.invalidate()
                        } else {
                            state.observe(type: type, timestamp: event.timestamp,
                                          sourceMarker: event.getIntegerValueField(.eventSourceUserData),
                                          isRepeat: type == .keyDown && event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
                        }
                    }
                    return Unmanaged.passUnretained(event)
                }, userInfo: context)
            guard let createdTap else { Self.creationLock.unlock(); return }
            let after = Self.tapInformation()
            let previousIDs = Set(before.map(\.eventTapID))
            let ownNewTaps = after?.filter {
                $0.tappingProcess == getpid() && !previousIDs.contains($0.eventTapID)
            } ?? []
            let maskVerified = ownNewTaps.count == 1 && ownNewTaps.allSatisfy {
                $0.tapPoint == .cgSessionEventTap && $0.options == .defaultTap
                    && $0.eventsOfInterest & mask == mask && $0.enabled
            }
            Self.creationLock.unlock()
            defer { CFMachPortInvalidate(createdTap) }
            guard maskVerified, !isStopping,
                  let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, createdTap, 0) else { return }
            let loop = CFRunLoopGetCurrent()!
            CFRunLoopAddSource(loop, source, .commonModes)
            defer { CFRunLoopRemoveSource(loop, source, .commonModes) }
            condition.lock()
            guard !stopping else { condition.unlock(); return }
            tap = createdTap
            runLoop = loop
            ready = true
            condition.broadcast()
            condition.unlock()
            // Independent upper bound, in addition to the caller's request
            // lifetime. Timeout never re-enables or silently replaces the tap.
            CFRunLoopRunInMode(.defaultMode, maximumLifetime, false)
        }

        private var isStopping: Bool {
            condition.lock()
            defer { condition.unlock() }
            return stopping
        }

        private static func tapInformation() -> [CGEventTapInformation]? {
            var count: UInt32 = 0
            guard CGGetEventTapList(0, nil, &count) == .success, count <= 4096 else { return nil }
            var information = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count) + 16)
            let capacity = UInt32(information.count)
            guard CGGetEventTapList(capacity, &information, &count) == .success,
                  count <= capacity else { return nil }
            return Array(information.prefix(Int(count)))
        }
    }
}
