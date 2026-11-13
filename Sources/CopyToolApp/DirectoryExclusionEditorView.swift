import AppKit
import SwiftUI
import CopyToolCore

/// 独立的大编辑区直接编辑同一份设置草稿，自动保存仍由配置页面统一负责。
struct DirectoryExclusionEditorView: View {
    @Binding var rules: String
    let saveStatus: SettingsAutosaveStore.Status
    let addCommonRules: () -> Void
    let finishEditing: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("编辑目录排除规则").font(.title2).bold()
            Text("每行一条，修改后自动保存。留空发送全部内容；直接发送单个文件不受影响。")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("添加常用规则") {
                    commitInput()
                    addCommonRules()
                }
                Button("清空规则") { commitInput(); rules = "" }.disabled(rules.isEmpty)
                Spacer()
                Text("支持 # 注释").font(.caption).foregroundStyle(.secondary)
            }
            DirectoryRuleTextEditor(text: $rules)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(.secondary.opacity(0.35)))
            Text("名称匹配任意层级；带 / 的路径相对于所选目录。支持 *、? 和跨层级 **；末尾 / 仅匹配文件夹。区分大小写。")
                .font(.caption).foregroundStyle(.secondary)
            if let validationError {
                Text(validationError).font(.callout).foregroundStyle(.red)
                    .accessibilityIdentifier("exclusion-editor-error")
            }
            HStack {
                Text(saveStatus.text).font(.caption)
                    .foregroundStyle(saveFailed ? .red : .secondary)
                    .accessibilityIdentifier("exclusion-editor-save-status")
                Spacer()
                Button("完成", action: finish)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(validationError != nil)
                    .accessibilityIdentifier("finish-exclusion-editor")
            }
        }
        .padding(22)
        .frame(minWidth: 640, idealWidth: 820, maxWidth: .infinity,
               minHeight: 440, idealHeight: 600, maxHeight: .infinity)
        .interactiveDismissDisabled(validationError != nil)
        .onExitCommand { if validationError == nil { finish() } }
        .accessibilityIdentifier("directory-exclusion-editor")
    }

    private func finish() {
        // 结束输入法的未提交文本，再由原有自动保存入口同步提交。
        commitInput()
        guard validationError == nil else { return }
        finishEditing()
    }

    private func commitInput() {
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    private var validationError: String? {
        do { _ = try DirectoryExclusions(rules); return nil }
        catch { return error.localizedDescription }
    }

    private var saveFailed: Bool {
        if case .failed = saveStatus { return true }
        return false
    }
}
