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
                TextField("登录账号（可选）", text: $draft.username)
                SecureField("API Token（可选）", text: $draft.token)
                Text("支持内网 IP、局域网域名和公网 HTTPS 域名。公网部署时请优先使用 HTTPS，并建议使用禅道个人 API Token；会小纪不会代替你登录，也不会自动创建任务。交接时会生成可审计草稿，确认后再在禅道中提交。")
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
