import XCTest
@testable import CopyToolCore

final class TransferProgressTests: XCTestCase {
    func testDefaultSnapshotIsIdleAndPhasesDescribeLifecycle() {
        let initial = TransferProgressSnapshot()
        XCTAssertNil(initial.id)
        XCTAssertEqual(initial.phase, .idle)
        XCTAssertNil(initial.fraction)
        XCTAssertEqual(initial.uploadedBytes, 0)
        XCTAssertEqual(initial.totalBytes, 0)
        XCTAssertEqual(initial.queuedCount, 0)
        XCTAssertFalse(initial.isActive)
        XCTAssertFalse(initial.isTerminal)

        for phase: TransferProgressSnapshot.Phase in [.preparing, .uploading, .publishing, .cancelling] {
            let snapshot = TransferProgressSnapshot(phase: phase)
            XCTAssertTrue(snapshot.isActive)
            XCTAssertFalse(snapshot.isTerminal)
        }
        for phase: TransferProgressSnapshot.Phase in [.completed, .failed, .cancelled] {
            let snapshot = TransferProgressSnapshot(phase: phase)
            XCTAssertFalse(snapshot.isActive)
            XCTAssertTrue(snapshot.isTerminal)
        }
    }

    func testPayloadAndControlAreWeightedByBytes() {
        let progress = TransferByteProgress(fileSizes: [9_000, 1_000])
        let payloadHalf = progress.update(fileIndex: 0, fraction: 0.5)
        XCTAssertEqual(payloadHalf.uploadedBytes, 4_500)
        XCTAssertEqual(payloadHalf.totalBytes, 10_000)
        XCTAssertEqual(payloadHalf.fraction, 0.45, accuracy: 0.000_001)

        let payloadDone = progress.update(fileIndex: 0, fraction: 1)
        XCTAssertEqual(payloadDone.fraction, 0.9, accuracy: 0.000_001)
        let publishing = progress.update(fileIndex: 1, fraction: 0.5)
        XCTAssertEqual(publishing.uploadedBytes, 9_500)
        XCTAssertEqual(publishing.fraction, 0.95, accuracy: 0.000_001)
        XCTAssertEqual(progress.update(fileIndex: 1, fraction: 1),
                       TransferProgressValues(uploadedBytes: 10_000, totalBytes: 10_000, fraction: 1))
    }

    func testEachFileProgressNeverMovesBackwards() {
        let progress = TransferByteProgress(fileSizes: [100, 300])
        let first = progress.update(fileIndex: 1, fraction: 0.75)
        XCTAssertEqual(first.uploadedBytes, 225)
        XCTAssertEqual(progress.update(fileIndex: 1, fraction: 0.25), first)
        let second = progress.update(fileIndex: 0, fraction: 0.5)
        XCTAssertEqual(second.uploadedBytes, 275)
        XCTAssertEqual(second.fraction, 0.6875)
        XCTAssertEqual(progress.update(fileIndex: 0, fraction: 0), second)
        XCTAssertEqual(progress.update(fileIndex: 1, fraction: 0), second)
    }

    func testInvalidIndicesAndNonfiniteFractionsDoNotAdvance() {
        let progress = TransferByteProgress(fileSizes: [100])
        let initial = TransferProgressValues(uploadedBytes: 0, totalBytes: 100, fraction: 0)
        XCTAssertEqual(progress.update(fileIndex: -1, fraction: 1), initial)
        XCTAssertEqual(progress.update(fileIndex: Int.max, fraction: 1), initial)
        XCTAssertEqual(progress.update(fileIndex: 0, fraction: .nan), initial)
        XCTAssertEqual(progress.update(fileIndex: 0, fraction: .infinity), initial)
        XCTAssertEqual(progress.update(fileIndex: 0, fraction: -.infinity), initial)
        XCTAssertEqual(progress.update(fileIndex: 0, fraction: -10), initial)

        let middle = progress.update(fileIndex: 0, fraction: 0.5)
        XCTAssertEqual(progress.update(fileIndex: 0, fraction: .nan), middle)
        XCTAssertEqual(progress.update(fileIndex: 0, fraction: .infinity), middle)
        XCTAssertEqual(progress.update(fileIndex: 0, fraction: 10),
                       TransferProgressValues(uploadedBytes: 100, totalBytes: 100, fraction: 1))
    }

    func testNegativeAndZeroSizesRemainFiniteAndNeedCompletionCallback() {
        let progress = TransferByteProgress(fileSizes: [Int64.min, 0])
        let initial = progress.update(fileIndex: 0, fraction: 0)
        XCTAssertEqual(initial, TransferProgressValues(uploadedBytes: 0, totalBytes: 0, fraction: 0))
        XCTAssertEqual(progress.update(fileIndex: 0, fraction: 1), initial)
        XCTAssertEqual(progress.update(fileIndex: 1, fraction: 0.5), initial)
        let completed = progress.update(fileIndex: 1, fraction: 1)
        XCTAssertEqual(completed, TransferProgressValues(uploadedBytes: 0, totalBytes: 0, fraction: 1))
        XCTAssertEqual(progress.update(fileIndex: 1, fraction: 0), completed)

        let empty = TransferByteProgress(fileSizes: [])
        XCTAssertEqual(empty.update(fileIndex: 0, fraction: 1), initial)

        let mixed = TransferByteProgress(fileSizes: [0, 100, -50])
        XCTAssertEqual(mixed.update(fileIndex: 0, fraction: 1).fraction, 0)
        XCTAssertEqual(mixed.update(fileIndex: 1, fraction: 0.5),
                       TransferProgressValues(uploadedBytes: 50, totalBytes: 100, fraction: 0.5))
    }

    func testOverflowSaturatesByteCountsAndPreservesWeights() {
        let progress = TransferByteProgress(fileSizes: [.max, .max])
        let quarter = progress.update(fileIndex: 0, fraction: 0.5)
        XCTAssertEqual(quarter.totalBytes, Int64.max)
        XCTAssertGreaterThan(quarter.uploadedBytes, 0)
        XCTAssertLessThan(quarter.uploadedBytes, Int64.max)
        XCTAssertEqual(quarter.fraction, 0.25)

        let half = progress.update(fileIndex: 0, fraction: 1)
        XCTAssertEqual(half.uploadedBytes, Int64.max)
        XCTAssertEqual(half.fraction, 0.5)
        XCTAssertEqual(progress.update(fileIndex: 1, fraction: 1),
                       TransferProgressValues(uploadedBytes: .max, totalBytes: .max, fraction: 1))
    }

    func testHugePayloadDoesNotRoundAwayPendingControlFile() {
        let progress = TransferByteProgress(fileSizes: [.max, 1])
        let payloadDone = progress.update(fileIndex: 0, fraction: 1)
        XCTAssertEqual(payloadDone.totalBytes, Int64.max)
        XCTAssertTrue(payloadDone.fraction.isFinite)
        XCTAssertLessThan(payloadDone.fraction, 1)
        XCTAssertEqual(progress.update(fileIndex: 1, fraction: 1).fraction, 1)
    }

    func testConcurrentCallbacksPreserveEveryFileMaximum() {
        let progress = TransferByteProgress(fileSizes: Array(repeating: 100, count: 16))
        DispatchQueue.concurrentPerform(iterations: 16) { fileIndex in
            for fraction in [0.25, 0.75, 0.5, 1.0, 0.0] {
                let value = progress.update(fileIndex: fileIndex, fraction: fraction)
                XCTAssertTrue(value.fraction.isFinite)
                XCTAssertTrue((0...1).contains(value.fraction))
            }
        }
        XCTAssertEqual(progress.update(fileIndex: -1, fraction: 0),
                       TransferProgressValues(uploadedBytes: 1_600, totalBytes: 1_600, fraction: 1))
    }
}
