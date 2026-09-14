import AItingjiCore
import Testing
@testable import AItingjiApp

@Suite("Settings navigation presentation")
struct SettingsNavigationPresentationTests {
    @Test("main sidebar keeps only calendar and settings categories are separate")
    func sidebarDestinations() {
        #expect(WorkspaceDestination.sidebarDestinations == [.calendar])
        #expect(WorkspaceDestination.settingsDestinations == [
            .agentSettings, .models, .knowledgeBase, .vocabulary,
            .people, .externalSystems, .archive, .debugLog
        ])
        #expect(Set(WorkspaceDestination.settingsDestinations).count == 8)
    }
}
