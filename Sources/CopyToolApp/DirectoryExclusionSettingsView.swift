import SwiftUI
import CopyToolCore

struct DirectoryExclusionSettingsView: View {
    @Binding var rules: String
    var saveStatus: SettingsAutosaveStore.Status = .ready
    var onEditingFinished: () -> Void = {}
    @State private var showingEditor = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("每行一条；留空发送全部内容。适用于快捷键、拖入和重发目录，直接发送单个文件不受影响。")
                .font(.caption).foregroundStyle(.secondary)
            Text(rules.isEmpty ? "尚未设置排除规则" : rules)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(rules.isEmpty ? .secondary : .primary)
                .lineLimit(4)
                .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
                .padding(10)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.secondary.opacity(0.3)))
                .accessibilityLabel("目录排除规则预览")
                .accessibilityIdentifier("exclusion-rules-preview")
            HStack {
                Button("展开编辑…") { showingEditor = true }
                    .accessibilityIdentifier("edit-exclusion-rules")
                Button("添加常用规则", action: addCommonRules)
                Button("清空规则") { rules = "" }.disabled(rules.isEmpty)
            }
            Text("名称匹配任意层级；带 / 的路径相对于所选目录。支持 *、? 和跨层级 **；末尾 / 仅匹配文件夹。区分大小写，空行和 # 注释忽略。")
                .font(.caption).foregroundStyle(.secondary)
            if let error = validationError { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .sheet(isPresented: $showingEditor, onDismiss: onEditingFinished) {
            DirectoryExclusionEditorView(rules: $rules, saveStatus: saveStatus,
                addCommonRules: addCommonRules, finishEditing: {
                    onEditingFinished()
                    showingEditor = false
                })
        }
    }

    private func addCommonRules() {
        let existing = Set(rules.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) })
        let additions = [".git/", "node_modules/", ".DS_Store", "*.log"].filter { !existing.contains($0) }
        guard !additions.isEmpty else { return }
        rules += (rules.isEmpty || rules.hasSuffix("\n") ? "" : "\n") + additions.joined(separator: "\n")
    }

    private var validationError: String? {
        do { _ = try DirectoryExclusions(rules); return nil }
        catch { return error.localizedDescription }
    }
}
