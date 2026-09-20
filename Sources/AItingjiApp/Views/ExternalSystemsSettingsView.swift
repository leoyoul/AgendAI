import AItingjiCore
import SwiftUI

struct ExternalSystemsSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var draft = ZentaoConfiguration()
    @State private var message = ""
    @State private var showingDiagnostic = false

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
                Text("MCP 权限测试使用已保存的配置；修改地址或传输类型后请先点击“保存配置”。")
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
                    Button {
                        appState.testZentaoMCP()
                    } label: {
                        if appState.zentaoMCPTestRunning {
                            Label("测试中", systemImage: "hourglass")
                        } else {
                            Label("测试 MCP 权限", systemImage: "checkmark.shield")
                        }
                    }
                    .disabled(!draft.enabled || appState.zentaoMCPTestRunning)
                    Spacer()
                    if !message.isEmpty { Text(message).foregroundStyle(.secondary) }
                    if !appState.zentaoMCPTestMessage.isEmpty {
                        if appState.zentaoMCPTestDiagnostic == nil {
                            Text(appState.zentaoMCPTestMessage)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        } else {
                            Text(appState.zentaoMCPTestMessage)
                                .foregroundStyle(Color.orange)
                                .lineLimit(2)
                        }
                        if appState.zentaoMCPTestDiagnostic != nil {
                            Button("查看诊断") { showingDiagnostic = true }
                                .buttonStyle(.bordered)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(24)
        .navigationTitle("外部系统")
        .onAppear { draft = appState.zentaoConfiguration }
        .sheet(isPresented: $showingDiagnostic) {
            VStack(alignment: .leading, spacing: 14) {
                Label("禅道 MCP 测试诊断", systemImage: "stethoscope")
                    .font(.title2.bold())
                if let diagnostic = appState.zentaoMCPTestDiagnostic {
                    LabeledContent("原因", value: diagnostic.summary)
                    LabeledContent("执行阶段", value: diagnostic.phase)
                    LabeledContent("CLI 路径", value: diagnostic.executablePath ?? "未解析")
                    LabeledContent("配置来源", value: diagnostic.configurationSource?.displayName ?? "未知")
                    if !diagnostic.deniedTools.isEmpty {
                        LabeledContent("未授权工具", value: diagnostic.deniedTools.joined(separator: ", "))
                    }
                    if let path = diagnostic.responsePath {
                        LabeledContent("响应路径", value: path)
                    }
                }
                Text("测试只调用禅道只读工具，不会创建、修改或删除任务；诊断信息不会包含 Token 或 Authorization Header。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack { Spacer(); Button("关闭") { showingDiagnostic = false } }
            }
            .padding(24)
            .frame(minWidth: 520)
        }
    }
}
