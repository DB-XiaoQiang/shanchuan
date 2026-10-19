import Foundation

/// 一次传输在主界面和浮动进度卡片之间共享的状态。
public struct TransferProgressSnapshot: Equatable, Sendable {
    public enum Phase: String, Equatable, Sendable {
        case idle, preparing, uploading, publishing, cancelling, completed, failed, cancelled
    }

    public var id: UUID?
    public var phase: Phase
    public var title: String
    public var currentItem: String
    public var fraction: Double?
    public var uploadedBytes: Int64
    public var totalBytes: Int64
    public var queuedCount: Int
    public var detail: String

    public init(
        id: UUID? = nil,
        phase: Phase = .idle,
        title: String = "",
        currentItem: String = "",
        fraction: Double? = nil,
        uploadedBytes: Int64 = 0,
        totalBytes: Int64 = 0,
        queuedCount: Int = 0,
        detail: String = ""
    ) {
        self.id = id
        self.phase = phase
        self.title = title
        self.currentItem = currentItem
        self.fraction = fraction
        self.uploadedBytes = uploadedBytes
        self.totalBytes = totalBytes
        self.queuedCount = queuedCount
        self.detail = detail
    }

    public var isActive: Bool {
        switch phase {
        case .preparing, .uploading, .publishing, .cancelling: return true
        case .idle, .completed, .failed, .cancelled: return false
        }
    }

    public var isTerminal: Bool {
        switch phase {
        case .completed, .failed, .cancelled: return true
        case .idle, .preparing, .uploading, .publishing, .cancelling: return false
        }
    }
}

public struct TransferProgressValues: Equatable, Sendable {
    public let uploadedBytes: Int64
    public let totalBytes: Int64
    public let fraction: Double

    public init(uploadedBytes: Int64, totalBytes: Int64, fraction: Double) {
        self.uploadedBytes = uploadedBytes
        self.totalBytes = totalBytes
        self.fraction = fraction
    }
}

/// 将各文件真实上传回调合并为字节加权进度；包含载荷和控制文件。
/// 此统计器不会自行推进进度，每个文件的回调只接受有限数值并保持单调。
public final class TransferByteProgress: @unchecked Sendable {
    private let lock = NSLock()
    private let fileSizes: [Int64]
    private let totalBytes: Int64
    private let weightedTotalBytes: Double
    private var fileFractions: [Double]

    public init(fileSizes: [Int64]) {
        let sizes = fileSizes.map { max(0, $0) }
        self.fileSizes = sizes
        self.fileFractions = Array(repeating: 0, count: sizes.count)
        self.weightedTotalBytes = sizes.reduce(0) { $0 + Double($1) }
        self.totalBytes = sizes.reduce(Int64(0)) { sum, size in
            let (value, overflow) = sum.addingReportingOverflow(size)
            return overflow ? Int64.max : value
        }
    }

    public func update(fileIndex: Int, fraction: Double) -> TransferProgressValues {
        lock.lock()
        defer { lock.unlock() }

        if fileFractions.indices.contains(fileIndex), fraction.isFinite {
            fileFractions[fileIndex] = max(fileFractions[fileIndex], min(1, max(0, fraction)))
        }

        // 空文件没有可衡量的字节，须等到明确完成回调才显示完成。
        guard weightedTotalBytes > 0 else {
            let completed = !fileFractions.isEmpty && fileFractions.allSatisfy { $0 == 1 }
            return TransferProgressValues(uploadedBytes: 0, totalBytes: 0, fraction: completed ? 1 : 0)
        }

        let uploaded = zip(fileSizes, fileFractions).reduce(0.0) { sum, item in
            sum + Double(item.0) * item.1
        }
        let allBytesCompleted = zip(fileSizes, fileFractions).allSatisfy { size, fraction in
            size == 0 || fraction == 1
        }
        // 极大载荷与极小控制文件相加可能发生浮点舍入，不能提前显示 100%。
        let combinedFraction = allBytesCompleted ? 1 : min(Double(1).nextDown, max(0, uploaded / weightedTotalBytes))

        // Double(Int64.max) 会向上取整，先判断再转换，避免超出 Int64 范围。
        // 总量溢出时字节数饱和，但比例仍使用所有文件的真实字节权重。
        let uploadedBytes: Int64
        if combinedFraction == 1 {
            uploadedBytes = totalBytes
        } else if uploaded >= Double(Int64.max) {
            uploadedBytes = Int64.max
        } else {
            uploadedBytes = min(totalBytes, Int64(uploaded))
        }
        return TransferProgressValues(uploadedBytes: uploadedBytes, totalBytes: totalBytes, fraction: combinedFraction)
    }
}
