import CoreGraphics
import XCTest
@testable import CopyToolApp

final class ShortcutInputGuardTests: XCTestCase {
    private let marker: Int64 = 0x43545053434D44

    private func makePolicy() -> ShortcutInputGuardPolicy {
        ShortcutInputGuardPolicy(syntheticMarker: marker, startTimestamp: 100)
    }

    func testReleasingKeysAndModifiersDoesNotChangeTheWindow() {
        var policy = makePolicy()
        for type: CGEventType in [.keyUp, .flagsChanged, .mouseMoved, .leftMouseUp] {
            policy.observe(type: type, timestamp: 101, sourceMarker: 0)
        }
        XCTAssertTrue(policy.isUnchanged(since: 0))
    }

    func testEveryNewProtectedInputChangesTheGeneration() {
        for type in ShortcutInputGuardPolicy.observedTypes {
            var policy = makePolicy()
            policy.observe(type: type, timestamp: 101, sourceMarker: 0)
            XCTAssertFalse(policy.isUnchanged(since: 0), "New \(type) must cancel the request")
            XCTAssertEqual(policy.generation, 1)
        }
    }

    func testOnlyOurSyntheticMarkerIsIgnored() {
        var policy = makePolicy()
        policy.observe(type: .keyDown, timestamp: 101, sourceMarker: marker)
        XCTAssertTrue(policy.isUnchanged(since: 0))
        policy.observe(type: .keyDown, timestamp: 102, sourceMarker: marker + 1)
        XCTAssertFalse(policy.isUnchanged(since: 0))
    }

    func testHeldKeyRepeatsDoNotHideANewNonrepeatingKeyPress() {
        var policy = makePolicy()
        policy.observe(type: .keyDown, timestamp: 101, sourceMarker: 0, isRepeat: true)
        policy.observe(type: .keyDown, timestamp: 102, sourceMarker: 0, isRepeat: true)
        XCTAssertTrue(policy.isUnchanged(since: 0))
        policy.observe(type: .keyDown, timestamp: 103, sourceMarker: 0, isRepeat: false)
        XCTAssertFalse(policy.isUnchanged(since: 0))
        XCTAssertEqual(policy.generation, 1)
    }

    func testRepeatMetadataNeverHidesOtherInputOrMissingTimestamps() {
        var mouse = makePolicy()
        mouse.observe(type: .leftMouseDown, timestamp: 101, sourceMarker: 0, isRepeat: true)
        XCTAssertFalse(mouse.isUnchanged(since: 0))
        var unknownTime = makePolicy()
        unknownTime.observe(type: .keyDown, timestamp: 0, sourceMarker: 0, isRepeat: true)
        XCTAssertFalse(unknownTime.isValid)
    }

    func testQueuedEventsFromBeforeTheWindowDoNotBecomeNewInput() {
        var policy = makePolicy()
        policy.observe(type: .keyDown, timestamp: 99, sourceMarker: 0)
        policy.observe(type: .keyDown, timestamp: 100, sourceMarker: 0)
        XCTAssertTrue(policy.isUnchanged(since: 0))
        policy.observe(type: .keyDown, timestamp: 101, sourceMarker: 0)
        XCTAssertFalse(policy.isUnchanged(since: 0))
    }

    func testDisabledTapFailsClosedEvenForSyntheticOrOldEventMetadata() {
        for type: CGEventType in [.tapDisabledByTimeout, .tapDisabledByUserInput] {
            var policy = makePolicy()
            policy.observe(type: type, timestamp: 0, sourceMarker: marker)
            XCTAssertFalse(policy.isValid)
            XCTAssertFalse(policy.isUnchanged(since: 0))
            policy.observe(type: .keyDown, timestamp: 101, sourceMarker: 0)
            XCTAssertFalse(policy.isUnchanged(since: policy.generation))
        }
    }

    func testCancellationAndRepeatedInvalidationNeverAuthorizeSending() {
        var policy = makePolicy()
        policy.invalidate()
        policy.invalidate()
        XCTAssertFalse(policy.isUnchanged(since: 0))
        policy.observe(type: .keyDown, timestamp: 101, sourceMarker: 0)
        XCTAssertFalse(policy.isUnchanged(since: policy.generation))
    }

    func testMissingTimestampCannotBeClassifiedAsOldInput() {
        var policy = makePolicy()
        policy.observe(type: .keyDown, timestamp: 0, sourceMarker: 0)
        XCTAssertFalse(policy.isValid)
        XCTAssertFalse(policy.isUnchanged(since: 0))
    }

    func testStaleSnapshotRemainsInvalidAfterFurtherInput() {
        var policy = makePolicy()
        policy.observe(type: .leftMouseDown, timestamp: 101, sourceMarker: 0)
        let newer = policy.generation
        policy.observe(type: .keyDown, timestamp: 102, sourceMarker: 0)
        XCTAssertFalse(policy.isUnchanged(since: 0))
        XCTAssertFalse(policy.isUnchanged(since: newer))
        XCTAssertEqual(policy.generation, 2)
    }
}
