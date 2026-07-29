import AItingjiCore
import SwiftUI

struct VocabularyView: View {
    @Environment(AppState.self) private var appState
    @State private var selectedEntryID: TerminologyEntry.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("常用词库")
                        .font(.title2.bold())
                    Text("\(appState.terminologyEntries.filter(\.isActive).count) 个启用词条")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    selectedEntryID = appState.addTerminologyEntry()
                } label: {
                    Label("新增词条", systemImage: "text.badge.plus")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)

            Divider()

            HSplitView {
                List(selection: $selectedEntryID) {
                    ForEach(appState.terminologyEntries) { entry in
                        VocabularyRow(entry: entry)
                            .tag(entry.id)
                    }
                }
                .frame(minWidth: 250, idealWidth: 300, maxWidth: 360)

                Group {
                    if let entry = selectedEntry {
                        VocabularyEditorView(
                            entry: entry,
                            onDelete: {
                                if appState.deleteTerminologyEntry(entry.id) {
                                    selectedEntryID = appState.terminologyEntries.first?.id
                                }
                            }
                        )
                        .id(entry.id)
                    } else {
                        ContentUnavailableView(
                            "暂无常用词",
                            systemImage: "character.book.closed",
                            description: Text("点击新增词条开始配置。")
                        )
                    }
                }
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()
            Text(appState.libraryStatusMessage.isEmpty ? " " : appState.libraryStatusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
        }
        .navigationTitle("常用词库")
        .onAppear {
            if selectedEntry == nil {
                selectedEntryID = appState.terminologyEntries.first?.id
            }
        }
    }

    private var selectedEntry: TerminologyEntry? {
        appState.terminologyEntries.first { $0.id == selectedEntryID }
    }
}

private struct VocabularyRow: View {
    let entry: TerminologyEntry

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: entry.isActive ? "character.book.closed.fill" : "character.book.closed")
                .foregroundStyle(entry.isActive ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.canonicalName)
                    .font(.body.weight(.medium))
                Text(entry.category.isEmpty ? "未分类" : entry.category)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text("\(entry.aliases.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

private struct VocabularyEditorView: View {
    @Environment(AppState.self) private var appState
    @State private var draft: TerminologyEntry
    @State private var aliasesText: String
    @State private var showsDeleteConfirmation = false

    let onDelete: () -> Void

    init(entry: TerminologyEntry, onDelete: @escaping () -> Void) {
        _draft = State(initialValue: entry)
        _aliasesText = State(initialValue: entry.aliases.joined(separator: "、"))
        self.onDelete = onDelete
    }

    var body: some View {
        Form {
            Section("词条") {
                TextField("标准名称", text: $draft.canonicalName)
                TextField("类别", text: $draft.category, prompt: Text("公司、产品、项目、技术"))
                Toggle("启用", isOn: $draft.isActive)
            }

            Section("别称") {
                TextField("简称与其他称呼", text: $aliasesText, prompt: Text("示例、ExampleTech、示例技术"))
            }

            Section("备注") {
                TextEditor(text: $draft.notes)
                    .frame(minHeight: 90)
            }

            HStack {
                Button(role: .destructive) {
                    showsDeleteConfirmation = true
                } label: {
                    Label("删除", systemImage: "trash")
                }
                Spacer()
                Button {
                    draft.aliases = Self.parseList(aliasesText)
                    if appState.saveTerminologyEntry(draft),
                       let persisted = appState.terminologyEntries.first(where: { $0.id == draft.id }) {
                        draft = persisted
                        aliasesText = persisted.aliases.joined(separator: "、")
                    }
                } label: {
                    Label("保存", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("s", modifiers: .command)
            }
        }
        .formStyle(.grouped)
        .padding(16)
        .alert("删除常用词“\(draft.canonicalName)”？", isPresented: $showsDeleteConfirmation) {
            Button("删除", role: .destructive, action: onDelete)
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后，新生成的会议纪要不再使用这条映射。")
        }
    }

    private static func parseList(_ value: String) -> [String] {
        value.components(separatedBy: CharacterSet(charactersIn: "、,，;；\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
