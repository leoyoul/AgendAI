import AItingjiCore
import SwiftUI

struct PeopleView: View {
    @Environment(AppState.self) private var appState
    @State private var selectedPersonID: VoiceprintPerson.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            libraryHeader
                .padding(.horizontal, 24)
                .padding(.vertical, 18)

            Divider()

            HSplitView {
                List(selection: $selectedPersonID) {
                    ForEach(appState.people) { person in
                        PersonLibraryRow(
                            person: person,
                            isCurrentUser: appState.currentUserPersonID == person.id
                        )
                            .tag(person.id)
                    }
                }
                .frame(minWidth: 250, idealWidth: 300, maxWidth: 360)

                Group {
                    if let person = selectedPerson {
                        PersonEditorView(
                            person: person,
                            sampleCount: appState.voiceprintSamples.filter { $0.personID == person.id }.count,
                            onDelete: {
                                if appState.deletePerson(person.id) {
                                    selectedPersonID = appState.people.first?.id
                                }
                            }
                        )
                        .id(person.id)
                    } else {
                        ContentUnavailableView(
                            "暂无人员",
                            systemImage: "person.2",
                            description: Text("点击新增人员开始配置。")
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
        .navigationTitle("人员配置")
        .onAppear {
            if selectedPerson == nil {
                selectedPersonID = appState.people.first?.id
            }
        }
    }

    private var libraryHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("人员配置")
                    .font(.title2.bold())
                Text("\(appState.people.filter(\.isActive).count) 名启用人员")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                selectedPersonID = appState.addPerson()
            } label: {
                Label("新增人员", systemImage: "person.badge.plus")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var selectedPerson: VoiceprintPerson? {
        appState.people.first { $0.id == selectedPersonID }
    }
}

private struct PersonLibraryRow: View {
    let person: VoiceprintPerson
    let isCurrentUser: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: person.isActive ? "person.crop.circle.fill" : "person.crop.circle")
                .foregroundStyle(person.isActive ? Color.accentColor : .secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                Text(person.displayName)
                    .font(.body.weight(.medium))
                Text(person.jobTitle.isEmpty ? "岗位未设置" : person.jobTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !person.responsibilities.isEmpty {
                    Text(person.responsibilities)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if isCurrentUser {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .help("当前用户")
            }
            if !person.zentaoAccount.isEmpty {
                Image(systemName: "link")
                    .foregroundStyle(.secondary)
                    .help("已映射禅道账号")
            }
        }
        .padding(.vertical, 4)
    }
}

private struct PersonEditorView: View {
    @Environment(AppState.self) private var appState
    @State private var draft: VoiceprintPerson
    @State private var aliasesText: String
    @State private var rolesText: String
    @State private var showsDeleteConfirmation = false

    let sampleCount: Int
    let onDelete: () -> Void

    init(person: VoiceprintPerson, sampleCount: Int, onDelete: @escaping () -> Void) {
        _draft = State(initialValue: person)
        _aliasesText = State(initialValue: person.aliases.joined(separator: "、"))
        _rolesText = State(initialValue: person.roleTags.joined(separator: "、"))
        self.sampleCount = sampleCount
        self.onDelete = onDelete
    }

    var body: some View {
        Form {
            Section("身份") {
                TextField("姓名", text: $draft.displayName)
                TextField("岗位", text: $draft.jobTitle)
                TextField("角色标签", text: $rolesText)
                Toggle("启用", isOn: $draft.isActive)
                Toggle("设为当前用户", isOn: Binding(
                    get: { appState.currentUserPersonID == draft.id },
                    set: { isCurrent in
                        _ = appState.setCurrentUserPerson(isCurrent ? draft.id : nil)
                    }
                ))
                .disabled(!draft.isActive)
            }

            Section("称呼") {
                TextField("简称与其他称呼", text: $aliasesText)
            }

            Section("职责") {
                TextField(
                    "描述此人负责的业务、项目或交付范围",
                    text: $draft.responsibilities,
                    axis: .vertical
                )
                .lineLimit(3...8)
            }

            Section("禅道映射") {
                TextField("禅道账号", text: $draft.zentaoAccount)
                TextField("禅道用户 ID", text: $draft.zentaoUserID)
            }

            Section("本地资料") {
                LabeledContent("声纹样本", value: "\(sampleCount) 个")
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
                    draft.roleTags = Self.parseList(rolesText)
                    if appState.savePerson(draft),
                       let persisted = appState.people.first(where: { $0.id == draft.id }) {
                        draft = persisted
                        aliasesText = persisted.aliases.joined(separator: "、")
                        rolesText = persisted.roleTags.joined(separator: "、")
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
        .alert("删除人员“\(draft.displayName)”？", isPresented: $showsDeleteConfirmation) {
            Button("删除", role: .destructive, action: onDelete)
            Button("取消", role: .cancel) {}
        } message: {
            Text("人员资料和声纹样本将被删除，已有会议转写不会改动。")
        }
    }

    private static func parseList(_ value: String) -> [String] {
        value.components(separatedBy: CharacterSet(charactersIn: "、,，;；\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
