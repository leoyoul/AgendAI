import AItingjiCore
import Foundation
import Testing
@testable import AItingjiApp

@MainActor
@Suite("App update coordinator")
struct AppUpdateCoordinatorTests {
    @Test("automatic check reports an update and only runs once per launch")
    func automaticCheckRunsOnce() async throws {
        let calls = UpdateCheckCallCounter()
        let release = try testRelease()
        let coordinator = AppUpdateCoordinator(
            currentVersion: "0.1.1",
            checkOperation: { version in
                await calls.record(version)
                return .updateAvailable(release)
            }
        )
        var logs: [String] = []

        await coordinator.checkAutomatically { logs.append($0) }
        coordinator.notice = nil
        await coordinator.checkAutomatically { logs.append($0) }

        #expect(await calls.values == ["0.1.1"])
        #expect(coordinator.notice == nil)
        #expect(logs.count == 1)
    }

    @Test("automatic failure is logged without presenting an alert")
    func automaticFailureIsSilent() async {
        let coordinator = AppUpdateCoordinator(
            currentVersion: "0.1.2",
            checkOperation: { _ in throw UpdateCheckError.httpStatus(403) }
        )
        var logs: [String] = []

        await coordinator.checkAutomatically { logs.append($0) }

        #expect(coordinator.notice == nil)
        #expect(logs.first?.contains("HTTP 403") == true)
    }

    @Test("manual checks present current status and failures")
    func manualCheckPresentsResult() async {
        let current = AppUpdateCoordinator(
            currentVersion: "0.1.2",
            checkOperation: { _ in .upToDate }
        )
        await current.checkManually { _ in }
        #expect(current.notice == .upToDate(currentVersion: "0.1.2"))

        let failed = AppUpdateCoordinator(
            currentVersion: "0.1.2",
            checkOperation: { _ in throw UpdateCheckError.decodingFailed }
        )
        await failed.checkManually { _ in }
        #expect(failed.notice == .failure(message: UpdateCheckError.decodingFailed.localizedDescription))
    }

    @Test("release button opens only the checked official URL")
    func releaseButtonOpensOfficialURL() throws {
        var openedURL: URL?
        let coordinator = AppUpdateCoordinator(
            currentVersion: "0.1.1",
            checkOperation: { _ in .upToDate },
            openURL: {
                openedURL = $0
                return true
            }
        )
        let release = try testRelease()

        coordinator.openRelease(release) { _ in }

        #expect(openedURL == release.htmlURL)
    }

    private func testRelease() throws -> GitHubRelease {
        GitHubRelease(
            version: try AppVersion("0.1.2"),
            name: "AgendAI 会小纪 v0.1.2",
            htmlURL: try #require(URL(string: "https://github.com/leoyoul/AgendAI/releases/tag/v0.1.2"))
        )
    }
}

private actor UpdateCheckCallCounter {
    private(set) var values: [String] = []

    func record(_ value: String) {
        values.append(value)
    }
}
