import AItingjiCore
import SwiftUI

struct KnowledgeBaseSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var draft = DifyKnowledgeBaseConfiguration(
        baseURL: "http://127.0.0.1:15080/v1"
    )

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                serviceConfiguration
                knowledgeBaseSelection
            }
            .padding(28)
        }
        .navigationTitle("知识库")
        .onAppear { draft = appState.knowledgeBaseConfiguration }
        .onChange(of: appState.knowledgeBaseConfiguration) { _, configuration in
            draft = configuration
        }
        .disabled(!appState.isPersistenceAvailable)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 7) {
                Text("知识库")
                    .font(.largeTitle.bold())
                Text("配置 Dify 服务，并选择会议 Agent 可以联动检索的知识库。")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Label(draft.enabled ? "已启用" : "未启用", systemImage: draft.enabled ? "checkmark.circle.fill" : "circle")
                .font(.callout.bold())
                .foregroundStyle(draft.enabled ? .green : .secondary)
        }
    }

    private var serviceConfiguration: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Dify 服务 API", systemImage: "network")
                    .font(.title2.bold())
                Spacer()
                Toggle("启用", isOn: $draft.enabled)
                    .toggleStyle(.switch)
            }

            TextField("例如 http://127.0.0.1:15080/v1", text: $draft.baseURL)
                .font(.system(.body, design: .monospaced))
                .textFieldStyle(.roundedBorder)

            SecureField("Dataset API Key", text: $draft.apiKey)
                .textFieldStyle(.roundedBorder)

            if usesInsecureRemoteHTTP {
                Label("此 HTTP 地址会明文传输 API Key 和检索问题，请优先改用 HTTPS。", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.bold())
                    .foregroundStyle(.orange)
            }

            Text("API Key 仅明文保存在本机会小纪数据库；请求使用 Bearer 鉴权。")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button {
                    appState.updateKnowledgeBaseConfiguration(draft)
                } label: {
                    Label("保存", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    appState.updateKnowledgeBaseConfiguration(draft)
                    appState.testAndLoadKnowledgeBases(draft)
                } label: {
                    Label("测试并加载", systemImage: "arrow.clockwise")
                }
                .disabled(!canConnect)

                Spacer()
                if !appState.libraryStatusMessage.isEmpty {
                    Text(appState.libraryStatusMessage)
                        .font(.caption)
                        .foregroundStyle(appState.libraryStatusMessage.contains("失败") ? .red : .secondary)
                        .lineLimit(2)
                }
            }
        }
        .panelStyle()
    }

    private var knowledgeBaseSelection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Agent 可用知识库", systemImage: "books.vertical")
                    .font(.title2.bold())
                Spacer()
                Text("已选 \(draft.selectedKnowledgeBaseIDs.count) / \(draft.knowledgeBases.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if draft.knowledgeBases.isEmpty {
                ContentUnavailableView(
                    "尚未加载知识库",
                    systemImage: "books.vertical",
                    description: Text("保存服务地址和 API Key 后，点击“测试并加载”。")
                )
                .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                VStack(spacing: 0) {
                    ForEach(draft.knowledgeBases) { knowledgeBase in
                        HStack(alignment: .top, spacing: 12) {
                            Toggle("", isOn: selectionBinding(for: knowledgeBase.id))
                                .labelsHidden()
                                .toggleStyle(.checkbox)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(knowledgeBase.name)
                                    .font(.headline)
                                if let description = knowledgeBase.description, !description.isEmpty {
                                    Text(description)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                Text(knowledgeBase.id)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 12)
                        if knowledgeBase.id != draft.knowledgeBases.last?.id {
                            Divider()
                        }
                    }
                }

                HStack {
                    Spacer()
                    Button {
                        appState.updateKnowledgeBaseConfiguration(draft)
                    } label: {
                        Label("保存选择", systemImage: "checkmark")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .panelStyle()
    }

    private var canConnect: Bool {
        let baseURL = draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return (baseURL.hasPrefix("http://") || baseURL.hasPrefix("https://"))
            && !draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var usesInsecureRemoteHTTP: Bool {
        guard let components = URLComponents(string: draft.baseURL),
              components.scheme?.lowercased() == "http",
              let host = components.host?.lowercased()
        else { return false }
        return host != "localhost" && host != "::1" && !host.hasPrefix("127.")
    }

    private func selectionBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { draft.selectedKnowledgeBaseIDs.contains(id) },
            set: { selected in
                if selected {
                    if !draft.selectedKnowledgeBaseIDs.contains(id) {
                        draft.selectedKnowledgeBaseIDs.append(id)
                    }
                } else {
                    draft.selectedKnowledgeBaseIDs.removeAll { $0 == id }
                }
            }
        )
    }
}
