import AItingjiCore
import SwiftUI

struct ExternalSystemsSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var draft = ZentaoConfiguration()
    @State private var message = ""

    var body: some View {
        Form {
            Section {
                Toggle("启用禅道", isOn: $draft.enabled)
                TextField("禅道地址", text: $draft.baseURL)
                TextField("Claude Code MCP 地址（可选）", text: $draft.mcpEndpoint)
                TextField("MCP 传输类型", text: $draft.mcpTransport)
                Text("优先复用 Claude Code 用户级 zentao 配置。只有应用进程明确存在 ZENTAO_MCP_TOKEN 时，才生成会话级临时 MCP 配置；Token 不写入应用数据库或项目文件。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("登录账号（可选）", text: $draft.username)
                Text("支持内网 IP、局域网域名和公网 HTTPS 域名。公网部署时请优先使用 HTTPS。会后待办通过 Claude Code 调用禅道 MCP，并按禅道 ID 或规范化名称去重。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("禅道", systemImage: "link")
            }

            Section {
                HStack {
                    Button("保存配置") {
                        message = appState.updateZentaoConfiguration(draft) ? "已保存" : "保存失败，请检查地址"
                    }
                    Button("打开禅道") {
                        if let url = URL(string: draft.baseURL) { NSWorkspace.shared.open(url) }
                    }
                    .disabled(URL(string: draft.baseURL) == nil)
                    Spacer()
                    Text(message).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding(24)
        .navigationTitle("外部系统")
        .onAppear { draft = appState.zentaoConfiguration }
    }
}
