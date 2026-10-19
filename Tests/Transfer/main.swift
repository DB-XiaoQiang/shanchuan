import Foundation

final class ProgressSamples: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []

    func append(_ value: Double) {
        lock.lock(); defer { lock.unlock() }
        values.append(value)
    }

    func snapshot() -> [Double] {
        lock.lock(); defer { lock.unlock() }
        return values
    }
}

let port = Int(CommandLine.arguments[1])!
let settings = FTPSettings(host: "127.0.0.1", port: port, username: "test", password: "p\"\\word", directory: "/uploads")
let worker = FTPTransfer()
try worker.upload(text: "本地 FTP 测试\n", remoteName: "中文 file;type=A.txt", settings: settings, progress: { value in
    precondition((0...1).contains(value))
})
let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
try Data("nested content".utf8).write(to: directory.appendingPathComponent("source.txt"))
let archive = directory.appendingPathExtension("zip")
defer { try? FileManager.default.removeItem(at: archive) }
try worker.zip(directory: directory, destination: archive)
try worker.upload(file: archive, remoteName: "folder.zip", settings: settings, progress: { _ in })
let large = directory.appendingPathComponent("large.bin")
let payloadSize = 16 * 1024 * 1024
try Data(repeating: 65, count: payloadSize).write(to: large)
let control = directory.appendingPathComponent("control.txt")
let controlContent = "publish progress fixture\n"
try Data(controlContent.utf8).write(to: control)
let weightedProgress = TransferByteProgress(fileSizes: [Int64(payloadSize), Int64(controlContent.utf8.count)])
let uploadSamples = ProgressSamples()
let weightedSamples = ProgressSamples()
try worker.upload(file: large, remoteName: "progress.bin", settings: settings, progress: { value in
    uploadSamples.append(value)
    weightedSamples.append(weightedProgress.update(fileIndex: 0, fraction: value).fraction)
})
let samples = uploadSamples.snapshot()
precondition(samples.allSatisfy { $0.isFinite && (0...1).contains($0) })
precondition(samples.first == 0 && samples.last == 1, "Upload must begin at 0 and finish at 1")
precondition(zip(samples, samples.dropFirst()).allSatisfy { $0.0 <= $0.1 }, "Curl upload progress must never decrease")
let intermediate = samples.filter { $0 > 0 && $0 < 1 }
precondition(Set(intermediate).count >= 2, "Slow curl upload must report multiple intermediate values, not only 0 and 1")
let payloadDone = weightedProgress.update(fileIndex: 0, fraction: 1)
let expectedPayloadFraction = Double(payloadSize) / Double(payloadSize + controlContent.utf8.count)
precondition(payloadDone.uploadedBytes == Int64(payloadSize))
precondition(abs(payloadDone.fraction - expectedPayloadFraction) < 0.000_000_001)
precondition(payloadDone.fraction > 0.99 && payloadDone.fraction < 1, "Tiny control file must retain only its byte weight")
try worker.upload(file: control, remoteName: "progress-control.txt", settings: settings, progress: { value in
    weightedSamples.append(weightedProgress.update(fileIndex: 1, fraction: value).fraction)
})
let combined = weightedSamples.snapshot()
precondition(zip(combined, combined.dropFirst()).allSatisfy { $0.0 <= $0.1 })
precondition(combined.last == 1)
let finished = weightedProgress.update(fileIndex: 1, fraction: 1)
precondition(finished.uploadedBytes == Int64(payloadSize + controlContent.utf8.count))
precondition(finished.uploadedBytes == finished.totalBytes)
print("REAL_CURL_INTERMEDIATE_PROGRESS_PASS samples=\(samples.count) intermediate=\(intermediate.count)")
print("PAYLOAD_CONTROL_BYTE_WEIGHT_PASS payloadBytes=\(payloadSize) controlBytes=\(controlContent.utf8.count)")
let cancellable = FTPTransfer()
DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { cancellable.cancel() }
do {
    try cancellable.upload(file: large, remoteName: "cancel.bin", settings: settings, progress: { _ in })
    fatalError("Expected cancellation")
} catch FTPTransferError.cancelled { print("CANCELLATION_PASS") }
var invalid = settings
invalid.password = "invalid\ncredential"
do {
    try worker.upload(file: large, remoteName: "invalid.bin", settings: invalid, progress: { _ in })
    fatalError("Expected invalid credential rejection")
} catch FTPTransferError.invalidSettings { print("CONTROL_CHARACTER_REJECTION_PASS") }
print("UPLOAD_AND_ZIP_PASS")
