import AItingjiCore
import AppKit
import SwiftUI

struct AgentSettingsView: View {
    @State private var section = AgentSettingsSection.skills
    @State private var snapshot = PiAgentConfigurationSnapshot()
    @State private var isLoading = true
    @State private var isBusy = false
    @State private var statusMessage = "正在读取全局 Pi Agent 配置。"
    @State private var errorMessage: String?

    private let store = PiAgentConfigurationStore()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            Group {
                if isLoading {
                    ProgressView("正在读取 Pi Agent 配置…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    content
                }
            }

            Divider()
            HStack(spacing: 8) {
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                Button {
                    refresh()
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .disabled(isBusy)
            }
            .padding(.horizontal, 24)
            .frame(height: 42)
        }
        .navigationTitle("Agent 设置")
        .task { refresh() }
        .alert("Agent 设置操作失败", isPresented: errorPresented) {
            Button("好") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "未知错误")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Agent 设置")
                    .font(.title2.bold())
                Text("全局 Pi Agent · ~/.pi/agent")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("配置类别", selection: $section) {
                ForEach(AgentSettingsSection.allCases) { item in
                    Label(item.title, systemImage: item.systemImage)
                        .tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 390)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .skills:
            PiSkillsSettingsView(
                skills: snapshot.skills,
                onCreate: createSkill,
                onSave: saveSkill,
                onDelete: deleteSkill
            )
        case .mcp:
            PiMCPSettingsView(
                servers: snapshot.mcpServers,
                onSave: saveMCPServer,
                onDelete: deleteMCPServer
            )
        case .plugins:
            PiPluginsSettingsView(
                plugins: snapshot.plugins,
                isBusy: isBusy,
                onInstall: installPlugin,
                onUpdatePackage: updatePlugin,
                onRemovePackage: removePlugin,
                onCreateLocal: createLocalExtension,
                onSaveLocal: saveLocalExtension,
                onDeleteLocal: deleteLocalExtension
            )
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func refresh(successMessage: String? = nil) {
        isLoading = snapshot == PiAgentConfigurationSnapshot()
        let store = store
        Task {
            do {
                let loaded = try await Task.detached { try store.loadSnapshot() }.value
                snapshot = loaded
                statusMessage = successMessage
                    ?? "已读取 \(loaded.skills.count) 个技能、\(loaded.mcpServers.count) 个 MCP、\(loaded.plugins.count) 个插件。"
            } catch {
                errorMessage = error.localizedDescription
                statusMessage = "读取失败。"
            }
            isLoading = false
        }
    }

    private func createSkill(name: String, description: String, instructions: String) {
        performSync(success: "技能已创建。") {
            _ = try store.createSkill(name: name, description: description, instructions: instructions)
        }
    }

    private func saveSkill(_ skill: PiAgentSkill, content: String) {
        performSync(success: "技能已保存，新的 Pi 会话将使用最新内容。") {
            _ = try store.updateSkill(skill, content: content)
        }
    }

    private func deleteSkill(_ skill: PiAgentSkill) {
        performSync(success: "技能已删除，并已保留备份。") {
            try store.deleteSkill(skill)
        }
    }

    private func saveMCPServer(name: String, configurationJSON: String) {
        performSync(success: "MCP 配置已保存。") {
            _ = try store.upsertMCPServer(name: name, configurationJSON: configurationJSON)
        }
    }

    private func deleteMCPServer(_ server: PiMCPServer) {
        performSync(success: "MCP 配置已删除，并已保留备份。") {
            try store.deleteMCPServer(name: server.name)
        }
    }

    private func createLocalExtension(name: String, content: String) {
        performSync(success: "本地插件已创建。") {
            _ = try store.createLocalExtension(name: name, content: content)
        }
    }

    private func saveLocalExtension(_ plugin: PiPlugin, content: String) {
        performSync(success: "本地插件已保存，新的 Pi 会话将重新加载。") {
            _ = try store.updateLocalExtension(plugin, content: content)
        }
    }

    private func deleteLocalExtension(_ plugin: PiPlugin) {
        performSync(success: "本地插件已删除，并已保留备份。") {
            try store.deleteLocalExtension(plugin)
        }
    }

    private func installPlugin(_ source: String) {
        performAsync(success: "插件安装完成。") {
            try await store.installPlugin(source: source)
        }
    }

    private func updatePlugin(_ plugin: PiPlugin) {
        performAsync(success: "插件更新完成。") {
            try await store.updatePlugin(source: plugin.source)
        }
    }

    private func removePlugin(_ plugin: PiPlugin) {
        performAsync(success: "插件卸载完成。") {
            try await store.removePlugin(source: plugin.source)
        }
    }

    private func performSync(success: String, operation: () throws -> Void) {
        do {
            try operation()
            refresh(successMessage: success)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func performAsync(
        success: String,
        operation: @escaping @Sendable () async throws -> Void
    ) {
        isBusy = true
        statusMessage = "Pi 正在处理插件操作…"
        Task {
            defer { isBusy = false }
            do {
                try await operation()
                refresh(successMessage: success)
            } catch {
                errorMessage = error.localizedDescription
                statusMessage = "插件操作失败。"
            }
        }
    }
}

private enum AgentSettingsSection: String, CaseIterable, Identifiable {
    case skills
    case mcp
    case plugins

    var id: Self { self }

    var title: String {
        switch self {
        case .skills: "技能"
        case .mcp: "MCP"
        case .plugins: "插件"
        }
    }

    var systemImage: String {
        switch self {
        case .skills: "wand.and.stars"
        case .mcp: "point.3.connected.trianglepath.dotted"
        case .plugins: "puzzlepiece.extension"
        }
    }
}

private struct PiSkillsSettingsView: View {
    let skills: [PiAgentSkill]
    let onCreate: (String, String, String) -> Void
    let onSave: (PiAgentSkill, String) -> Void
    let onDelete: (PiAgentSkill) -> Void

    @State private var selectedID: PiAgentSkill.ID?
    @State private var showingCreateSheet = false

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Text("技能")
                        .font(.headline)
                    Spacer()
                    Button {
                        showingCreateSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .help("新增技能")
                }
                .padding(12)
                Divider()
                List(selection: $selectedID) {
                    ForEach(skills) { skill in
                        PiSkillRow(skill: skill)
                            .tag(skill.id)
                    }
                }
            }
            .frame(minWidth: 250, idealWidth: 300, maxWidth: 360)

            Group {
                if let skill = selectedSkill {
                    PiSkillEditor(skill: skill, onSave: onSave, onDelete: onDelete)
                        .id(skill.id + skill.content)
                } else {
                    ContentUnavailableView(
                        "暂无技能",
                        systemImage: "wand.and.stars",
                        description: Text("点击加号创建全局 Pi 技能。")
                    )
                }
            }
            .frame(minWidth: 500, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { selectFirstIfNeeded() }
        .onChange(of: skills) { _, _ in selectFirstIfNeeded() }
        .sheet(isPresented: $showingCreateSheet) {
            NewPiSkillSheet { name, description, instructions in
                onCreate(name, description, instructions)
                showingCreateSheet = false
            }
        }
    }

    private var selectedSkill: PiAgentSkill? {
        skills.first { $0.id == selectedID }
    }

    private func selectFirstIfNeeded() {
        if selectedSkill == nil {
            selectedID = skills.first?.id
        }
    }
}

private struct PiSkillRow: View {
    let skill: PiAgentSkill

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: skill.isEditable ? "wand.and.stars" : "lock")
                .foregroundStyle(skill.isEditable ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(skill.name)
                    .font(.body.weight(.medium))
                Text(originTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
        }
        .padding(.vertical, 4)
    }

    private var originTitle: String {
        switch skill.origin {
        case .user: "全局用户技能"
        case .shared: "共享技能 · 只读"
        case .package(let package): "\(package) · 只读"
        }
    }
}

private struct PiSkillEditor: View {
    let skill: PiAgentSkill
    let onSave: (PiAgentSkill, String) -> Void
    let onDelete: (PiAgentSkill) -> Void

    @State private var content: String
    @State private var showingDeleteConfirmation = false

    init(
        skill: PiAgentSkill,
        onSave: @escaping (PiAgentSkill, String) -> Void,
        onDelete: @escaping (PiAgentSkill) -> Void
    ) {
        self.skill = skill
        self.onSave = onSave
        self.onDelete = onDelete
        _content = State(initialValue: skill.content)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(skill.name)
                        .font(.title3.bold())
                    Text(skill.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([skill.fileURL])
                } label: {
                    Image(systemName: "folder")
                }
                .help("在 Finder 中显示")
            }
            .padding(18)

            Divider()

            TextEditor(text: $content)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(14)
                .disabled(!skill.isEditable)

            Divider()
            HStack {
                if skill.isEditable {
                    Button(role: .destructive) {
                        showingDeleteConfirmation = true
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                } else {
                    Label("由共享目录或插件提供", systemImage: "lock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    onSave(skill, content)
                } label: {
                    Label("保存", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!skill.isEditable || content == skill.content)
            }
            .padding(14)
        }
        .confirmationDialog(
            "删除技能“\(skill.name)”？",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("删除技能", role: .destructive) { onDelete(skill) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会小纪会先保留备份，新的 Pi 会话将不再加载该技能。")
        }
    }
}

private struct NewPiSkillSheet: View {
    let onCreate: (String, String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var description = ""
    @State private var instructions = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("新增技能")
                .font(.title2.bold())
            Form {
                TextField("技能名称", text: $name, prompt: Text("meeting-review"))
                TextField("用途说明", text: $description)
                TextEditor(text: $instructions)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 180)
            }
            .formStyle(.grouped)
            HStack {
                Button("取消") { dismiss() }
                Spacer()
                Button("创建") { onCreate(name, description, instructions) }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.isEmpty || description.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 560, height: 430)
    }
}

private struct PiMCPSettingsView: View {
    let servers: [PiMCPServer]
    let onSave: (String, String) -> Void
    let onDelete: (PiMCPServer) -> Void

    @State private var selectedID: PiMCPServer.ID?
    @State private var isCreating = false

    var body: some View {
        VStack(spacing: 0) {
            Label(
                "当前 Pi 核心不直接加载 mcpServers；配置是否可用取决于已安装的 MCP 适配插件。",
                systemImage: "exclamationmark.triangle"
            )
            .font(.caption)
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .frame(height: 40)
            .background(.orange.opacity(0.07))

            Divider()
            HSplitView {
                VStack(spacing: 0) {
                    HStack {
                        Text("MCP")
                            .font(.headline)
                        Spacer()
                        Button {
                            isCreating = true
                            selectedID = nil
                        } label: {
                            Image(systemName: "plus")
                        }
                        .help("新增 MCP")
                    }
                    .padding(12)
                    Divider()
                    List(selection: $selectedID) {
                        ForEach(servers) { server in
                            Label(server.name, systemImage: "point.3.connected.trianglepath.dotted")
                                .tag(server.id)
                        }
                    }
                }
                .frame(minWidth: 250, idealWidth: 300, maxWidth: 360)

                Group {
                    if isCreating {
                        PiMCPEditor(server: nil, onSave: save, onDelete: onDelete)
                            .id("new-mcp")
                    } else if let server = selectedServer {
                        PiMCPEditor(server: server, onSave: save, onDelete: onDelete)
                            .id(server.id + server.configurationJSON)
                    } else {
                        ContentUnavailableView(
                            "暂无 MCP 配置",
                            systemImage: "point.3.connected.trianglepath.dotted",
                            description: Text("点击加号添加全局 MCP 配置。")
                        )
                    }
                }
                .frame(minWidth: 500, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { selectFirstIfNeeded() }
        .onChange(of: servers) { _, _ in selectFirstIfNeeded() }
    }

    private var selectedServer: PiMCPServer? {
        servers.first { $0.id == selectedID }
    }

    private func save(name: String, json: String) {
        onSave(name, json)
        isCreating = false
        selectedID = name
    }

    private func selectFirstIfNeeded() {
        guard !isCreating else { return }
        if selectedServer == nil {
            selectedID = servers.first?.id
        }
    }
}

private struct PiMCPEditor: View {
    let server: PiMCPServer?
    let onSave: (String, String) -> Void
    let onDelete: (PiMCPServer) -> Void

    @State private var name: String
    @State private var configurationJSON: String
    @State private var showingDeleteConfirmation = false

    init(
        server: PiMCPServer?,
        onSave: @escaping (String, String) -> Void,
        onDelete: @escaping (PiMCPServer) -> Void
    ) {
        self.server = server
        self.onSave = onSave
        self.onDelete = onDelete
        _name = State(initialValue: server?.name ?? "")
        _configurationJSON = State(initialValue: server?.configurationJSON ?? "{\n  \"command\": \"/path/to/server\",\n  \"args\": []\n}")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(server == nil ? "新增 MCP" : server?.name ?? "MCP")
                    .font(.title3.bold())
                Spacer()
            }
            .padding(18)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                TextField("MCP 名称", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .disabled(server != nil)
                Text("JSON 配置")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextEditor(text: $configurationJSON)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(.secondary.opacity(0.3), lineWidth: 1)
                    }
            }
            .padding(18)
            Divider()
            HStack {
                if server != nil {
                    Button(role: .destructive) {
                        showingDeleteConfirmation = true
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
                Spacer()
                Button {
                    onSave(name, configurationJSON)
                } label: {
                    Label("保存", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(14)
        }
        .confirmationDialog(
            "删除 MCP“\(server?.name ?? "")”？",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            if let server {
                Button("删除 MCP", role: .destructive) { onDelete(server) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会小纪会保留 settings.json 备份。")
        }
    }
}

private struct PiPluginsSettingsView: View {
    let plugins: [PiPlugin]
    let isBusy: Bool
    let onInstall: (String) -> Void
    let onUpdatePackage: (PiPlugin) -> Void
    let onRemovePackage: (PiPlugin) -> Void
    let onCreateLocal: (String, String) -> Void
    let onSaveLocal: (PiPlugin, String) -> Void
    let onDeleteLocal: (PiPlugin) -> Void

    @State private var selectedID: PiPlugin.ID?
    @State private var showingInstallSheet = false
    @State private var showingCreateSheet = false

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Text("插件")
                        .font(.headline)
                    Spacer()
                    Menu {
                        Button("安装 Pi Package", systemImage: "shippingbox") {
                            showingInstallSheet = true
                        }
                        Button("新建本地扩展", systemImage: "doc.badge.plus") {
                            showingCreateSheet = true
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(isBusy)
                }
                .padding(12)
                Divider()
                List(selection: $selectedID) {
                    ForEach(plugins) { plugin in
                        PiPluginRow(plugin: plugin)
                            .tag(plugin.id)
                    }
                }
            }
            .frame(minWidth: 250, idealWidth: 300, maxWidth: 360)

            Group {
                if let plugin = selectedPlugin {
                    PiPluginEditor(
                        plugin: plugin,
                        isBusy: isBusy,
                        onUpdatePackage: onUpdatePackage,
                        onRemovePackage: onRemovePackage,
                        onSaveLocal: onSaveLocal,
                        onDeleteLocal: onDeleteLocal
                    )
                    .id(plugin.id + (plugin.content ?? "") + (plugin.version ?? ""))
                } else {
                    ContentUnavailableView(
                        "暂无插件",
                        systemImage: "puzzlepiece.extension",
                        description: Text("点击加号安装 Pi Package 或创建本地扩展。")
                    )
                }
            }
            .frame(minWidth: 500, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { selectFirstIfNeeded() }
        .onChange(of: plugins) { _, _ in selectFirstIfNeeded() }
        .sheet(isPresented: $showingInstallSheet) {
            InstallPiPluginSheet { source in
                onInstall(source)
                showingInstallSheet = false
            }
        }
        .sheet(isPresented: $showingCreateSheet) {
            NewLocalExtensionSheet { name, content in
                onCreateLocal(name, content)
                showingCreateSheet = false
            }
        }
    }

    private var selectedPlugin: PiPlugin? {
        plugins.first { $0.id == selectedID }
    }

    private func selectFirstIfNeeded() {
        if selectedPlugin == nil {
            selectedID = plugins.first?.id
        }
    }
}

private struct PiPluginRow: View {
    let plugin: PiPlugin

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: plugin.kind == .package ? "shippingbox" : "doc.text")
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 3) {
                Text(plugin.name)
                    .font(.body.weight(.medium))
                Text(plugin.kind == .package ? "Package \(plugin.version ?? "")" : "本地扩展")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
        }
        .padding(.vertical, 4)
    }
}

private struct PiPluginEditor: View {
    let plugin: PiPlugin
    let isBusy: Bool
    let onUpdatePackage: (PiPlugin) -> Void
    let onRemovePackage: (PiPlugin) -> Void
    let onSaveLocal: (PiPlugin, String) -> Void
    let onDeleteLocal: (PiPlugin) -> Void

    @State private var content: String
    @State private var showingDeleteConfirmation = false

    init(
        plugin: PiPlugin,
        isBusy: Bool,
        onUpdatePackage: @escaping (PiPlugin) -> Void,
        onRemovePackage: @escaping (PiPlugin) -> Void,
        onSaveLocal: @escaping (PiPlugin, String) -> Void,
        onDeleteLocal: @escaping (PiPlugin) -> Void
    ) {
        self.plugin = plugin
        self.isBusy = isBusy
        self.onUpdatePackage = onUpdatePackage
        self.onRemovePackage = onRemovePackage
        self.onSaveLocal = onSaveLocal
        self.onDeleteLocal = onDeleteLocal
        _content = State(initialValue: plugin.content ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(plugin.name)
                        .font(.title3.bold())
                    Text(plugin.source)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                if let fileURL = plugin.fileURL {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                    } label: {
                        Image(systemName: "folder")
                    }
                    .help("在 Finder 中显示")
                }
            }
            .padding(18)
            Divider()

            if plugin.kind == .localExtension {
                TextEditor(text: $content)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(14)
            } else {
                Form {
                    LabeledContent("版本", value: plugin.version ?? "未知")
                    LabeledContent("技能", value: "\(plugin.skillCount)")
                    LabeledContent("扩展", value: "\(plugin.extensionCount)")
                }
                .formStyle(.grouped)
            }

            Divider()
            HStack {
                Button(role: .destructive) {
                    showingDeleteConfirmation = true
                } label: {
                    Label(plugin.kind == .package ? "卸载" : "删除", systemImage: "trash")
                }
                .disabled(isBusy)
                Spacer()
                if plugin.kind == .package {
                    Button {
                        onUpdatePackage(plugin)
                    } label: {
                        Label("更新", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isBusy)
                } else {
                    Button {
                        onSaveLocal(plugin, content)
                    } label: {
                        Label("保存", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(content == plugin.content)
                }
            }
            .padding(14)
        }
        .confirmationDialog(
            plugin.kind == .package ? "卸载插件“\(plugin.name)”？" : "删除插件“\(plugin.name)”？",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(plugin.kind == .package ? "卸载插件" : "删除插件", role: .destructive) {
                if plugin.kind == .package {
                    onRemovePackage(plugin)
                } else {
                    onDeleteLocal(plugin)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(plugin.kind == .package
                ? "Pi 会移除全局 Package，其他 Pi 项目也将无法使用。"
                : "会小纪会先保留本地扩展备份。")
        }
    }
}

private struct InstallPiPluginSheet: View {
    let onInstall: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var source = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("安装 Pi Package")
                .font(.title2.bold())
            TextField("Package 来源", text: $source, prompt: Text("npm:package-name"))
                .textFieldStyle(.roundedBorder)
            Label("插件拥有当前用户权限，安装前应确认来源可信。", systemImage: "exclamationmark.shield")
                .font(.caption)
                .foregroundStyle(.orange)
            Spacer()
            HStack {
                Button("取消") { dismiss() }
                Spacer()
                Button("安装") { onInstall(source) }
                    .buttonStyle(.borderedProminent)
                    .disabled(source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 520, height: 220)
    }
}

private struct NewLocalExtensionSheet: View {
    let onCreate: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var content = "export default function (pi) {\n  // Register tools or hooks here.\n}\n"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("新建本地扩展")
                .font(.title2.bold())
            TextField("扩展名称", text: $name, prompt: Text("meeting-tools"))
                .textFieldStyle(.roundedBorder)
            TextEditor(text: $content)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 220)
                .padding(8)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(.secondary.opacity(0.3), lineWidth: 1)
                }
            HStack {
                Button("取消") { dismiss() }
                Spacer()
                Button("创建") { onCreate(name, content) }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.isEmpty || content.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 620, height: 440)
    }
}
