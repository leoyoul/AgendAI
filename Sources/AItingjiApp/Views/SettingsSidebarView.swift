import AItingjiCore
import SwiftUI

struct SettingsSidebarView: View {
    @Binding var selection: WorkspaceDestination
    let onReturn: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onReturn) {
                Label("返回应用", systemImage: "arrow.left")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .frame(height: 38)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.top, 14)
            .padding(.bottom, 10)

            List(selection: $selection) {
                Section("配置") {
                    ForEach(WorkspaceDestination.settingsDestinations.filter { $0 != .archive && $0 != .debugLog }) { destination in
                        Label(destination.title, systemImage: destination.systemImage)
                            .tag(destination)
                    }
                }
                Section("管理") {
                    ForEach([WorkspaceDestination.archive, .debugLog]) { destination in
                        Label(destination.title, systemImage: destination.systemImage)
                            .tag(destination)
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .background(.regularMaterial)
    }
}
