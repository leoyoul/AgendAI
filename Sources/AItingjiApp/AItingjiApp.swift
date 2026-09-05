import AItingjiCore
import SwiftUI

@main
struct AItingjiApp: App {
    @State private var appState = AppState()
    @State private var updateCoordinator = AppUpdateCoordinator()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "AgendAI 会小纪") {
            RootView(updateCoordinator: updateCoordinator)
                .environment(appState)
                .frame(minWidth: 980, minHeight: 680)
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        appState.refreshPermissionStatus()
                    }
                }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button(updateCoordinator.isChecking ? "正在检查更新…" : "检查更新…") {
                    Task {
                        await updateCoordinator.checkManually(log: appState.recordUpdateLog)
                    }
                }
                .disabled(updateCoordinator.isChecking)
            }
        }
    }
}
