import AItingjiCore
import SwiftUI

@main
struct AItingjiApp: App {
    @State private var appState = AppState()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "AgendAI 会小纪") {
            RootView()
                .environment(appState)
                .frame(minWidth: 980, minHeight: 680)
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        appState.refreshPermissionStatus()
                    }
                }
        }
        .windowResizability(.contentSize)
    }
}
