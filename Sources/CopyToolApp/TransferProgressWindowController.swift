import AppKit
import Combine
import CopyToolCore
import SwiftUI

/// 只负责卡片的展示与收起；传输状态始终来自 AppModel 的快照。
@MainActor
final class TransferProgressWindowController {
    private weak var model: AppModel?
    private var observation: AnyCancellable?
    private var panel: TransferProgressPanel?
    private var hostingView: TransferProgressHostingView?
    private var observedTaskID: UUID?
    private var dismissedTaskID: UUID?
    private var manuallyShownTaskID: UUID?
    private var terminalHideTask: Task<Void, Never>?
    private var scheduledHideID: UUID?
    private var previewTask: Task<Void, Never>?
    private var previewSnapshot: TransferProgressSnapshot?
    private var stopped = false

    init(model: AppModel) {
        self.model = model
        observation = Publishers.CombineLatest3(
            model.$transferSnapshot,
            model.$preferences.map(\.showTransferProgress).removeDuplicates(),
            model.$privacy.removeDuplicates()
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] snapshot, enabled, privacy in
            self?.receive(snapshot, enabled: enabled, privacy: privacy)
        }
    }

    /// 菜单中的手动显示可以重新打开本次已隐藏的卡片。
    func showCurrent() {
        guard !stopped, let model else { return }
        endPreview(hidePanel: false)
        let snapshot = model.transferSnapshot
        guard snapshot.phase != .idle, let id = snapshot.id else {
            panel?.orderOut(nil)
            return
        }
        dismissedTaskID = nil
        manuallyShownTaskID = id
        observedTaskID = id
        present(snapshot, privacy: model.privacy, preview: false, reposition: true)
        scheduleTerminalHide(for: snapshot)
    }

    /// 五秒钟的本地演示，不读剪贴板，不进入上传队列。
    func preview() {
        guard !stopped, let model else { return }
        guard !model.transferSnapshot.isActive else {
            showCurrent()
            return
        }
        endPreview(hidePanel: false)
        cancelTerminalHide()
        let id = UUID()
        updatePreview(id: id, phase: .preparing, fraction: nil, uploadedBytes: 0,
                      detail: "预览 · 正在准备示例文件", reposition: true)
        previewTask = Task { @MainActor [weak self] in
            let steps: [(UInt64, Double?, Int64, String)] = [
                (800_000_000, 0.26, 2_181_038, "预览 · 正在上传示例文件"),
                (900_000_000, 0.61, 5_117_051, "预览 · 正在上传示例文件"),
                (900_000_000, 0.94, 7_885_292, "预览 · 正在上传示例文件")
            ]
            for (delay, fraction, uploaded, detail) in steps {
                do { try await Task.sleep(nanoseconds: delay) } catch { return }
                guard let self, self.previewSnapshot?.id == id,
                      self.model?.transferSnapshot.isActive != true else { return }
                self.updatePreview(id: id, phase: .uploading, fraction: fraction,
                                   uploadedBytes: uploaded, detail: detail)
            }
            do { try await Task.sleep(nanoseconds: 650_000_000) } catch { return }
            guard let self, self.previewSnapshot?.id == id,
                  self.model?.transferSnapshot.isActive != true else { return }
            self.updatePreview(id: id, phase: .publishing, fraction: 0.99,
                               uploadedBytes: 8_388_608, detail: "预览 · 正在完成投递")
            do { try await Task.sleep(nanoseconds: 650_000_000) } catch { return }
            guard self.previewSnapshot?.id == id,
                  self.model?.transferSnapshot.isActive != true else { return }
            self.updatePreview(id: id, phase: .completed, fraction: 1,
                               uploadedBytes: 8_388_608, detail: "预览 · 示例已完成，没有发送任何文件")
            do { try await Task.sleep(nanoseconds: 1_100_000_000) } catch { return }
            guard self.previewSnapshot?.id == id else { return }
            self.endPreview(hidePanel: true)
        }
    }

    func stop() {
        stopped = true
        observation?.cancel()
        observation = nil
        cancelTerminalHide()
        endPreview(hidePanel: true)
        panel?.close()
        panel = nil
        hostingView = nil
    }

    deinit {
        terminalHideTask?.cancel()
        previewTask?.cancel()
    }

    private func receive(_ snapshot: TransferProgressSnapshot, enabled: Bool, privacy: Bool) {
        guard !stopped else { return }
        let newTask = snapshot.id != observedTaskID
        if newTask {
            observedTaskID = snapshot.id
            dismissedTaskID = nil
            manuallyShownTaskID = nil
            cancelTerminalHide()
        }
        // 真实任务的准备阶段就接管卡片，不等待第一个上传进度。
        if snapshot.isActive || (newTask && snapshot.phase != .idle) {
            endPreview(hidePanel: false)
        }
        if let previewSnapshot {
            present(previewSnapshot, privacy: privacy, preview: true, reposition: false)
            return
        }
        guard snapshot.phase != .idle, let id = snapshot.id else {
            cancelTerminalHide()
            panel?.orderOut(nil)
            return
        }
        guard enabled || manuallyShownTaskID == id else {
            panel?.orderOut(nil)
            return
        }
        guard dismissedTaskID != id else { return }
        present(snapshot, privacy: privacy, preview: false, reposition: newTask)
        scheduleTerminalHide(for: snapshot)
    }

    private func present(_ snapshot: TransferProgressSnapshot, privacy: Bool,
                         preview: Bool, reposition: Bool) {
        let view = TransferProgressCardView(
            snapshot: snapshot, privacy: privacy, isPreview: preview,
            close: { [weak self] in self?.dismissCurrent(id: snapshot.id, preview: preview) },
            cancel: { [weak self] in self?.cancelCurrent(id: snapshot.id, preview: preview) }
        )
        var created = false
        if let hostingView {
            hostingView.rootView = view
        } else {
            let hostingView = TransferProgressHostingView(rootView: view)
            let panel = TransferProgressPanel(
                contentRect: NSRect(x: 0, y: 0, width: 360, height: 244),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered, defer: false
            )
            panel.title = "传输进度"
            panel.isReleasedWhenClosed = false
            panel.isRestorable = false
            panel.isFloatingPanel = true
            panel.becomesKeyOnlyIfNeeded = true
            panel.hidesOnDeactivate = false
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.isMovableByWindowBackground = true
            panel.animationBehavior = .utilityWindow
            panel.contentView = hostingView
            self.hostingView = hostingView
            self.panel = panel
            created = true
        }
        guard let panel else { return }
        if created || reposition { positionAtTopRight(panel) }
        // 非激活面板：显示时不调用 activate、makeKey 或 makeMain。
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func positionAtTopRight(_ panel: NSPanel) {
        let cursor = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(cursor) })
                ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let inset: CGFloat = 16
        panel.setFrameOrigin(NSPoint(
            x: max(visible.minX + inset, visible.maxX - panel.frame.width - inset),
            y: max(visible.minY + inset, visible.maxY - panel.frame.height - inset)
        ))
    }

    private func dismissCurrent(id: UUID?, preview: Bool) {
        if preview {
            guard previewSnapshot?.id == id else { return }
            endPreview(hidePanel: true)
            return
        }
        // 回调绑定当前绘制的任务，避免发布下一任务时误隐藏新任务。
        guard observedTaskID == id else { return }
        dismissedTaskID = id
        manuallyShownTaskID = nil
        cancelTerminalHide()
        panel?.orderOut(nil)
    }

    private func cancelCurrent(id: UUID?, preview: Bool) {
        if preview {
            guard previewSnapshot?.id == id else { return }
            endPreview(hidePanel: true)
        } else if model?.transferSnapshot.id == id,
                  model?.transferSnapshot.isActive == true {
            model?.cancelAll()
        }
    }

    private func scheduleTerminalHide(for snapshot: TransferProgressSnapshot) {
        let delay: UInt64
        switch snapshot.phase {
        case .completed: delay = 4_000_000_000
        case .cancelled: delay = 3_000_000_000
        default:
            cancelTerminalHide()
            return
        }
        guard let id = snapshot.id, scheduledHideID != id else { return }
        cancelTerminalHide()
        scheduledHideID = id
        let terminalPhase = snapshot.phase
        terminalHideTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: delay) } catch { return }
            guard let self, !Task.isCancelled, self.previewSnapshot == nil,
                  self.model?.transferSnapshot.id == id,
                  self.model?.transferSnapshot.phase == terminalPhase else { return }
            // 自动收起也记住本次任务，后续隐私或偏好更新不会重新弹出。
            self.dismissedTaskID = id
            self.manuallyShownTaskID = nil
            self.panel?.orderOut(nil)
            self.terminalHideTask = nil
            self.scheduledHideID = nil
        }
    }

    private func cancelTerminalHide() {
        terminalHideTask?.cancel()
        terminalHideTask = nil
        scheduledHideID = nil
    }

    private func endPreview(hidePanel: Bool) {
        let wasPreviewing = previewSnapshot != nil
        previewTask?.cancel()
        previewTask = nil
        previewSnapshot = nil
        if hidePanel {
            panel?.orderOut(nil)
            guard wasPreviewing, !stopped, let model else { return }
            let snapshot = model.transferSnapshot
            if snapshot.phase == .failed {
                // 演示结束后保留尚未被关闭的真实失败提示。
                receive(snapshot, enabled: model.preferences.showTransferProgress, privacy: model.privacy)
            } else if snapshot.isTerminal {
                // 示例结束后也不因下一次偏好更新重新弹出旧完成任务。
                dismissedTaskID = snapshot.id
                manuallyShownTaskID = nil
            }
        }
    }

    private func updatePreview(id: UUID, phase: TransferProgressSnapshot.Phase,
                               fraction: Double?, uploadedBytes: Int64,
                               detail: String, reposition: Bool = false) {
        var snapshot = TransferProgressSnapshot()
        snapshot.id = id
        snapshot.phase = phase
        snapshot.title = "示例.zip"
        snapshot.currentItem = "示例.zip"
        snapshot.fraction = fraction
        snapshot.uploadedBytes = uploadedBytes
        snapshot.totalBytes = 8_388_608
        snapshot.queuedCount = phase == .completed ? 0 : 2
        snapshot.detail = detail
        previewSnapshot = snapshot
        present(snapshot, privacy: model?.privacy ?? false, preview: true, reposition: reposition)
    }
}

private final class TransferProgressPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class TransferProgressHostingView: NSHostingView<TransferProgressCardView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct TransferProgressCardView: View {
    let snapshot: TransferProgressSnapshot
    let privacy: Bool
    let isPreview: Bool
    let close: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Image(systemName: phaseIcon)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(phaseColor)
                    .frame(width: 28, height: 28)
                Text("传输进度").font(.system(size: 13, weight: .semibold))
                if isPreview {
                    Text("预览")
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                }
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isPreview ? "关闭预览" : "关闭卡片，传输继续")
                .accessibilityLabel(isPreview ? "关闭预览" : "关闭进度卡片")
            }

            VStack(alignment: .leading, spacing: 7) {
                Text(itemName)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1).truncationMode(.middle)
                    .help(privacy ? "内容已隐藏" : itemName)
                HStack {
                    Text(phaseTitle).foregroundStyle(phaseColor)
                    Spacer()
                    Text(progressLabel).monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.system(size: 12))
                Group {
                    if let fraction {
                        ProgressView(value: fraction, total: 1)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                }
                .tint(phaseColor)
                .accessibilityLabel("传输进度")
                .accessibilityValue(progressLabel)
                Text(byteLabel)
                    .font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(.secondary)
                Text(privacy ? "隐私模式已隐藏文件名称和传输详情" : snapshot.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(height: 30, alignment: .topLeading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer(minLength: 0)
            HStack {
                Label(queueLabel, systemImage: "list.bullet")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                if isPreview || snapshot.isActive {
                    Button(isPreview ? "结束预览" : snapshot.phase == .cancelling ? "取消中…" : "取消传输", action: cancel)
                        .font(.system(size: 11, weight: .medium))
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!isPreview && snapshot.phase == .cancelling)
                }
            }
            .frame(height: 24)
        }
        .padding(16)
        .frame(width: 360, height: 244)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.primary.opacity(0.08), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    private var itemName: String {
        guard !privacy else { return "内容已隐藏" }
        let name = snapshot.currentItem.isEmpty ? snapshot.title : snapshot.currentItem
        let filename = (name as NSString).lastPathComponent
        return filename.isEmpty ? "传输内容" : filename
    }

    private var fraction: Double? {
        guard snapshot.phase != .preparing, snapshot.phase != .idle else { return nil }
        guard let value = snapshot.fraction, value.isFinite else { return nil }
        return min(snapshot.phase == .publishing ? 0.99 : 1, max(0, value))
    }

    private var progressLabel: String {
        if let fraction { return "\(Int((fraction * 100).rounded(.down)))%" }
        switch snapshot.phase {
        case .preparing: return "准备中"
        case .publishing: return "确认中"
        case .cancelling: return "取消中"
        default: return "—"
        }
    }

    private var byteLabel: String {
        let uploaded = max(0, snapshot.uploadedBytes)
        let total = max(0, snapshot.totalBytes)
        let sent = ByteCountFormatter.string(fromByteCount: uploaded, countStyle: .file)
        if total > 0 {
            return sent + " / " + ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        }
        if uploaded > 0 { return "已上传 " + sent }
        return snapshot.phase == .preparing ? "正在统计文件大小" : "暂无字节统计"
    }

    private var queueLabel: String {
        snapshot.queuedCount > 0 ? "等待 \(snapshot.queuedCount) 项" : "没有等待任务"
    }

    private var phaseTitle: String {
        switch snapshot.phase {
        case .idle: return "等待发送"
        case .preparing: return "准备文件"
        case .uploading: return "上传中"
        case .publishing: return "正在完成"
        case .cancelling: return "正在取消"
        case .completed: return "发送完成"
        case .failed: return "发送失败"
        case .cancelled: return "已取消"
        }
    }

    private var phaseIcon: String {
        switch snapshot.phase {
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        case .cancelled, .cancelling: return "xmark.circle.fill"
        case .preparing: return "shippingbox.circle.fill"
        default: return "arrow.up.circle.fill"
        }
    }

    private var phaseColor: Color {
        switch snapshot.phase {
        case .completed: return .green
        case .failed: return .red
        case .cancelled, .cancelling: return .secondary
        default: return .accentColor
        }
    }
}
