import AItingjiCore
import SwiftUI

struct ModelSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var meetingMinutesPromptDraft = ""
    @State private var meetingAnalysisPromptDraft = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                realtimePolicyCard
                ForEach(activeModelSourceTypes, id: \.self) { type in
                    modelSection(type: type)
                }
            }
            .padding(28)
        }
        .navigationTitle("模型配置")
        .onAppear {
            meetingMinutesPromptDraft = appState.meetingMinutesPrompt
            meetingAnalysisPromptDraft = appState.meetingAnalysisPrompt
        }
        .onChange(of: appState.meetingMinutesPrompt) { _, newValue in
            meetingMinutesPromptDraft = newValue
        }
        .onChange(of: appState.meetingAnalysisPrompt) { _, newValue in
            meetingAnalysisPromptDraft = newValue
        }
        .disabled(!appState.isPersistenceAvailable)
        .overlay(alignment: .top) {
            if !appState.isPersistenceAvailable {
                Text("本地数据库不可用，模型配置已锁定。")
                    .font(.caption.bold())
                    .padding(8)
                    .background(.red.opacity(0.15), in: Capsule())
                    .padding(.top, 8)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("模型配置")
                .font(.largeTitle.bold())
            Text("统一管理实时转写和 Agent 模型。")
                .foregroundStyle(.secondary)
        }
    }

    private var activeModelSourceTypes: [ModelSourceType] {
        [.asr, .agent]
    }

    private var realtimePolicyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("分阶段处理", systemImage: "bolt.waveform")
                .font(.title2.bold())
            Text("默认转写模型负责实时记录；录音结束后，Agent 模型仅依据本场资料生成结构化原始会议纪要。")
                .foregroundStyle(.secondary)
        }
        .panelStyle()
    }

    private func modelSection(type: ModelSourceType) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(type.displayName)
                    .font(.title2.bold())
                Spacer()
                Button("新增\(type.displayName)服务") {
                    appState.addModelSource(type: type)
                }
            }
            if type == .asr {
                Text("转写服务同一时间只允许启用一个；启用某个服务后，它会自动成为默认服务，其他转写服务会停用。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if type == .meetingMinutes {
                Text("录音结束后自动生成，也可手动重新生成；输出按固定模板渲染为 MD 和 HTML，原始转写保持不变。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if type == .agent {
                Text("供原始会议纪要、AI 分析会议纪要和 Agent 聊天使用；包含图片笔记时必须使用多模态模型。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("会议结束后整理口水词和可读性；未启用时保留转写原文。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            let sources = appState.modelSources.filter { $0.type == type }
            if sources.isEmpty {
                ContentUnavailableView(
                    unavailableTitle(for: type),
                    systemImage: "server.rack",
                    description: Text(unavailableDescription(for: type))
                )
                .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ForEach(sources) { source in
                    ModelSourceCard(source: source)
                }
            }
            if type == .agent {
                Divider()
                meetingMinutesPromptEditor
                Divider()
                meetingAnalysisPromptEditor
            }
        }
        .panelStyle()
    }

    private var meetingMinutesPromptEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("原始会议纪要提示词", systemImage: "text.quote")
                    .font(.headline)
                Spacer()
                Text("\(meetingMinutesPromptDraft.count) 字")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TextEditor(text: $meetingMinutesPromptDraft)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 360, maxHeight: 480)
                .padding(8)
                .background(.background)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
                }

            HStack {
                Button {
                    appState.updateMeetingMinutesPrompt(meetingMinutesPromptDraft)
                } label: {
                    Label("保存提示词", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    meetingMinutesPromptDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || meetingMinutesPromptDraft == appState.meetingMinutesPrompt
                )

                Button {
                    meetingMinutesPromptDraft = PostprocessPrompt.meetingMinutes
                    appState.updateMeetingMinutesPrompt(PostprocessPrompt.meetingMinutes)
                } label: {
                    Label("恢复默认", systemImage: "arrow.counterclockwise")
                }
                .disabled(appState.meetingMinutesPrompt == PostprocessPrompt.meetingMinutes)

                Spacer()
            }
        }
    }

    private var meetingAnalysisPromptEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("AI 分析提示词", systemImage: "sparkles.rectangle.stack")
                    .font(.headline)
                Spacer()
                Text("\(meetingAnalysisPromptDraft.count) 字")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("用于 AI 分析结论与职责型待办；不会影响原始会议纪要。")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextEditor(text: $meetingAnalysisPromptDraft)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 320, maxHeight: 480)
                .padding(8)
                .background(.background)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
                }

            HStack {
                Button {
                    appState.updateMeetingAnalysisPrompt(meetingAnalysisPromptDraft)
                } label: {
                    Label("保存提示词", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    meetingAnalysisPromptDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || meetingAnalysisPromptDraft == appState.meetingAnalysisPrompt
                )

                Button {
                    meetingAnalysisPromptDraft = PostprocessPrompt.meetingAnalysis
                    appState.updateMeetingAnalysisPrompt(PostprocessPrompt.meetingAnalysis)
                } label: {
                    Label("恢复默认", systemImage: "arrow.counterclockwise")
                }
                .disabled(appState.meetingAnalysisPrompt == PostprocessPrompt.meetingAnalysis)

                Spacer()
            }
        }
    }

    private func unavailableTitle(for type: ModelSourceType) -> String {
        switch type {
        case .asr:
            return "未配置转写模型"
        case .postprocess:
            return "未配置后处理模型"
        case .meetingMinutes:
            return "未配置会议纪要模型"
        case .voiceprint:
            return "未配置声纹模型"
        case .agent:
            return "未配置 Agent 模型"
        }
    }

    private func unavailableDescription(for type: ModelSourceType) -> String {
        switch type {
        case .asr:
            return "请配置 OpenAI 兼容 ASR 服务，例如本地 OMLX 转写服务。"
        case .postprocess:
            return "请新增 OpenAI 兼容服务；未配置时会保留转写原文。"
        case .meetingMinutes:
            return "请新增 OpenAI 兼容文本模型，用于生成正式会议纪要。"
        case .voiceprint:
            return "声纹模型由会小纪内置服务管理。"
        case .agent:
            return "请新增 OpenAI 兼容文本模型，供会议 Agent 聊天使用。"
        }
    }
}

private struct ModelSourceCard: View {
    @Environment(AppState.self) private var appState
    let source: ModelSource
    @State private var draft: ModelSource
    @State private var showingDeleteConfirmation = false

    init(source: ModelSource) {
        self.source = source
        _draft = State(initialValue: source)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("配置名称", text: $draft.name)
                    .font(.headline)
                    .textFieldStyle(.roundedBorder)
                if source.isDefault {
                    Text("默认")
                        .font(.caption.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.blue.opacity(0.14), in: Capsule())
                }
                Spacer()
                Text(source.enabled ? "启用" : "停用")
                    .font(.caption)
                    .foregroundStyle(source.enabled ? .green : .secondary)
            }

            TextField("Base URL", text: $draft.baseURL)
                .font(.system(.body, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .disabled(isBundledVoiceprint)

            if usesInsecureRemoteHTTP {
                Label(
                    "此 HTTP 地址会明文传输 API Key、会议转写和纪要，请优先改用 HTTPS。",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption.bold())
                .foregroundStyle(.orange)
            }

            if supportsTextAPIProtocol {
                Picker("API 协议", selection: $draft.apiProtocol) {
                    ForEach(ModelAPIProtocol.allCases, id: \.self) { apiProtocol in
                        Text(apiProtocol.displayName).tag(apiProtocol)
                    }
                }
                .pickerStyle(.segmented)
                Text(apiProtocolDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SecureField(apiKeyPlaceholder, text: $draft.apiKey)
                .textFieldStyle(.roundedBorder)
            if !isBundledVoiceprint {
                Text("API Key 仅明文保存在本机会小纪数据库，不再使用 macOS 钥匙串。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Picker("模型", selection: selectedModelBinding) {
                    Text("未选择").tag("")
                    ForEach(modelOptions, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
                .frame(maxWidth: 320)

                Toggle("启用", isOn: $draft.enabled)
                    .toggleStyle(.switch)

                Toggle("默认", isOn: defaultBinding)
                    .toggleStyle(.switch)

                if draft.type == .agent || draft.type == .meetingMinutes {
                    Toggle("支持视觉输入", isOn: $draft.supportsVision)
                        .toggleStyle(.checkbox)
                }

                Spacer()
            }

            if (draft.type == .agent || draft.type == .meetingMinutes) && !draft.supportsVision {
                Label(
                    "包含图片笔记的会议不能使用此模型生成纪要，请确认模型支持图片理解。",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }

            HStack {
                Button("保存") {
                    appState.updateModelSource(draft)
                }
                .buttonStyle(.borderedProminent)

                Button(testButtonTitle) {
                    appState.updateModelSource(draft)
                    appState.testModelSource(draft.id)
                }
                .disabled(!canTestDraft)

                Spacer()

                if let message = source.lastTestMessage {
                    Text("\(source.lastTestOK == true ? "成功" : "失败")：\(message)")
                        .font(.caption)
                        .foregroundStyle(source.lastTestOK == true ? .green : .red)
                } else {
                    Text("未测试")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if draft.type == .meetingMinutes {
                HStack(spacing: 12) {
                    Label("最大并发", systemImage: "arrow.triangle.2.circlepath")
                    Toggle("不限制", isOn: unlimitedMeetingMinutesConcurrencyBinding)
                        .toggleStyle(.switch)
                    if let limit = draft.meetingMinutesMaximumConcurrency {
                        Stepper("最多 \(limit) 路", value: meetingMinutesConcurrencyBinding, in: 1...64)
                            .fixedSize()
                    }
                    Spacer()
                }
                .font(.callout)
                Text("只控制会议纪要生成请求；由你根据当前模型服务选择限制或不限。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !isBundledVoiceprint {
                Divider()

                HStack {
                    Text(source.isDefault ? "删除默认服务后，会自动选择同类型剩余启用服务作为默认。" : "删除后不会影响已有会议记录。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(role: .destructive) {
                        showingDeleteConfirmation = true
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
            }
        }
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .onChange(of: source) { _, newValue in
            draft = newValue
        }
        .confirmationDialog(
            "删除\(source.type.displayName)模型服务？",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("删除“\(source.name)”", role: .destructive) {
                appState.deleteModelSource(source.id)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这只会删除模型配置，不会删除会议录音或转写记录。")
        }
    }

    private var modelOptions: [String] {
        let combined = draft.availableModels + [draft.selectedModel].compactMap { $0 }
        return Array(Set(combined)).sorted()
    }

    private var apiKeyPlaceholder: String {
        isBundledVoiceprint ? "Hugging Face token（可选）" : "API key"
    }

    private var supportsTextAPIProtocol: Bool {
        draft.type == .postprocess || draft.type == .meetingMinutes || draft.type == .agent
    }

    private var usesInsecureRemoteHTTP: Bool {
        guard let components = URLComponents(string: draft.baseURL),
              components.scheme?.lowercased() == "http",
              let host = components.host?.lowercased()
        else {
            return false
        }
        return host != "localhost" && host != "::1" && !host.hasPrefix("127.")
    }

    private var apiProtocolDescription: String {
        switch draft.apiProtocol {
        case .chatCompletions:
            return "请求会发送到 Base URL 下的 /chat/completions。"
        case .responses:
            return "请求会发送到 Base URL 下的 /responses，适用于 GPT Responses API。"
        }
    }

    private var testButtonTitle: String {
        isBundledVoiceprint ? "加载并测试模型" : "拉取模型并测试"
    }

    private var canTestDraft: Bool {
        isBundledVoiceprint || draft.baseURL.hasPrefix("http://") || draft.baseURL.hasPrefix("https://")
    }

    private var isBundledVoiceprint: Bool {
        draft.type == .voiceprint && draft.baseURL == "sidecar://diarization"
    }

    private var selectedModelBinding: Binding<String> {
        Binding(
            get: { draft.selectedModel ?? "" },
            set: { draft.selectedModel = $0.isEmpty ? nil : $0 }
        )
    }

    private var unlimitedMeetingMinutesConcurrencyBinding: Binding<Bool> {
        Binding(
            get: { draft.meetingMinutesMaximumConcurrency == nil },
            set: { isUnlimited in
                draft.meetingMinutesMaximumConcurrency = isUnlimited
                    ? nil
                    : max(1, draft.meetingMinutesMaximumConcurrency ?? 1)
            }
        )
    }

    private var meetingMinutesConcurrencyBinding: Binding<Int> {
        Binding(
            get: { draft.meetingMinutesMaximumConcurrency ?? 1 },
            set: { draft.meetingMinutesMaximumConcurrency = max(1, $0) }
        )
    }

    private var defaultBinding: Binding<Bool> {
        Binding(
            get: { draft.isDefault },
            set: { isDefault in
                draft.isDefault = isDefault
                if isDefault {
                    draft.enabled = true
                    appState.updateModelSource(draft)
                    appState.setDefaultModelSource(draft.id)
                }
            }
        )
    }
}
