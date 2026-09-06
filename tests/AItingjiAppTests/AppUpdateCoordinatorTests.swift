import Foundation
import Sparkle
import Testing
@testable import AItingjiApp

@Suite("App update coordinator")
@MainActor
struct AppUpdateCoordinatorTests {
    @Test("production app outside Applications requires installation")
    func productionInstallationPolicy() {
        #expect(AppInstallationLocationPolicy.requiresInstallationPrompt(bundleIdentifier: "com.local.aitingji", bundleURL: URL(fileURLWithPath: "/Users/tester/Downloads/AgendAI 会小纪.app"), environment: [:]))
        #expect(AppInstallationLocationPolicy.requiresInstallationPrompt(bundleIdentifier: "com.local.aitingji", bundleURL: URL(fileURLWithPath: "/private/var/folders/test/AppTranslocation/AgendAI 会小纪.app"), environment: [:]))
        #expect(!AppInstallationLocationPolicy.requiresInstallationPrompt(bundleIdentifier: "com.local.aitingji", bundleURL: URL(fileURLWithPath: "/Applications/AgendAI 会小纪.app"), environment: [:]))
    }

    @Test("development, XCTest, and test app copies skip the installation reminder")
    func nonProductionInstallationPolicy() {
        let downloadsBundle = URL(fileURLWithPath: "/Users/tester/Downloads/AgendAI 会小纪.app")
        #expect(!AppInstallationLocationPolicy.requiresInstallationPrompt(bundleIdentifier: "com.local.aitingji.test", bundleURL: downloadsBundle, environment: [:]))
        #expect(!AppInstallationLocationPolicy.requiresInstallationPrompt(bundleIdentifier: "com.local.aitingji", bundleURL: downloadsBundle, environment: ["XCTestConfigurationFilePath": "/tmp/test.xctest"]))
        #expect(!AppInstallationLocationPolicy.requiresInstallationPrompt(bundleIdentifier: nil, bundleURL: downloadsBundle, environment: [:]))
    }

    @Test("only the test bundle accepts a local feed override")
    func testFeedOverrideIsIsolated() {
        let environment = ["TINGLAN_SPARKLE_FEED_URL": "http://127.0.0.1:4567/appcast.xml"]
        #expect(AppInstallationLocationPolicy.testFeedURL(bundleIdentifier: "com.local.aitingji.test", environment: environment)?.absoluteString == "http://127.0.0.1:4567/appcast.xml")
        #expect(AppInstallationLocationPolicy.testFeedURL(bundleIdentifier: "com.local.aitingji", environment: environment) == nil)
    }

    @Test("startup is gated by an installation reminder and does not initialize Sparkle")
    func installationReminderGatesAutomaticCheck() {
        let driver = TestUpdateDriver()
        let coordinator = makeCoordinator(driver: driver, bundleURL: "/Users/tester/Downloads/AgendAI 会小纪.app")
        coordinator.start(log: { _ in })
        #expect(coordinator.showInstallationPrompt)
        #expect(driver.startCalls == 0)
        #expect(driver.backgroundCheckCalls == 0)
    }

    @Test("startup starts Sparkle and makes one background check")
    func startupCheckRunsOnce() {
        let driver = TestUpdateDriver()
        let coordinator = makeCoordinator(driver: driver, bundleURL: "/Applications/AgendAI 会小纪.app")
        coordinator.start(log: { _ in })
        coordinator.start(log: { _ in })
        #expect(driver.startCalls == 1)
        #expect(driver.backgroundCheckCalls == 1)
        #expect(coordinator.isChecking)
    }

    @Test("brand state shows the current version or a stable update indicator")
    func brandStateTracksUpdateEvents() {
        let driver = TestUpdateDriver()
        let coordinator = makeCoordinator(driver: driver, bundleURL: "/Applications/AgendAI 会小纪.app")
        #expect(coordinator.brandState == .current(version: "0.1.3"))
        driver.emit(.updateAvailable(version: "0.1.4"))
        #expect(coordinator.brandState == .updateAvailable(currentVersion: "0.1.3", latestVersion: "0.1.4"))
        #expect(coordinator.brandState.versionLabel == "v0.1.4 可更新")
        #expect(coordinator.brandState.hasUpdate)
    }

    @Test("test build keeps automatic checks disabled without an injected feed")
    func testBuildRequiresFeedInjection() {
        let driver = TestUpdateDriver()
        let coordinator = AppUpdateCoordinator(
            bundleIdentifier: "com.local.aitingji.test",
            bundleURL: URL(fileURLWithPath: "/Users/tester/Downloads/AgendAI 会小纪 测试版.app"),
            currentVersion: "0.1.3",
            environment: [:],
            driver: driver
        )
        coordinator.start(log: { _ in })
        #expect(!coordinator.updatesAreEnabled)
        #expect(driver.startCalls == 0)
        #expect(driver.backgroundCheckCalls == 0)
    }

    @Test("test build starts a background check when its local feed is injected")
    func testBuildAcceptsInjectedFeed() {
        let driver = TestUpdateDriver()
        let coordinator = AppUpdateCoordinator(
            bundleIdentifier: "com.local.aitingji.test",
            bundleURL: URL(fileURLWithPath: "/Users/tester/Downloads/AgendAI 会小纪 测试版.app"),
            currentVersion: "0.1.3",
            environment: ["TINGLAN_SPARKLE_FEED_URL": "http://127.0.0.1:4567/appcast.xml"],
            driver: driver
        )

        coordinator.start(log: { _ in })

        #expect(coordinator.updatesAreEnabled)
        #expect(driver.startCalls == 1)
        #expect(driver.backgroundCheckCalls == 1)
    }

    @Test("manual update checks use the standard updater driver")
    func manualCheckUsesDriver() {
        let driver = TestUpdateDriver()
        let coordinator = makeCoordinator(driver: driver, bundleURL: "/Applications/AgendAI 会小纪.app")
        coordinator.checkForUpdatesManually(log: { _ in })
        #expect(driver.manualCheckCalls == 1)
        #expect(coordinator.isChecking)
    }

    @Test("normal Sparkle abort codes are not reported as update failures")
    func expectedSparkleAbortCodesAreIgnored() {
        let expectedCodes = [
            Int(SUError.noUpdateError.rawValue),
            Int(SUError.installationCanceledError.rawValue),
            Int(SUError.installationAuthorizeLaterError.rawValue)
        ]

        for code in expectedCodes {
            let error = NSError(domain: SUSparkleErrorDomain, code: code)
            #expect(SparkleUpdateDriver.abortEvent(for: error) == nil)
        }

        let realFailure = NSError(
            domain: SUSparkleErrorDomain,
            code: Int(SUError.appcastError.rawValue),
            userInfo: [NSLocalizedDescriptionKey: "更新源不可用"]
        )
        #expect(SparkleUpdateDriver.abortEvent(for: realFailure) == .failed(message: "更新源不可用"))
    }

    @Test("no-update callback followed by its abort keeps the status successful")
    func noUpdateThenAbortDoesNotLogFailure() {
        let driver = TestUpdateDriver()
        let coordinator = makeCoordinator(driver: driver, bundleURL: "/Applications/AgendAI 会小纪.app")
        var logs: [String] = []
        coordinator.start(log: { logs.append($0) })

        driver.emit(.upToDate)
        let noUpdateError = NSError(
            domain: SUSparkleErrorDomain,
            code: Int(SUError.noUpdateError.rawValue)
        )
        if let abortEvent = SparkleUpdateDriver.abortEvent(for: noUpdateError) {
            driver.emit(abortEvent)
        }

        #expect(coordinator.brandState == .current(version: "0.1.3"))
        #expect(logs.count == 1)
        #expect(logs[0].contains("已是最新版"))
        #expect(!logs[0].contains("失败"))
    }

    private func makeCoordinator(driver: TestUpdateDriver, bundleURL: String) -> AppUpdateCoordinator {
        AppUpdateCoordinator(bundleIdentifier: "com.local.aitingji", bundleURL: URL(fileURLWithPath: bundleURL), currentVersion: "0.1.3", environment: [:], driver: driver)
    }
}

@MainActor
private final class TestUpdateDriver: AppUpdateDriving {
    var canCheckForUpdates = true
    var eventHandler: ((AppUpdateDriverEvent) -> Void)?
    private(set) var startCalls = 0
    private(set) var manualCheckCalls = 0
    private(set) var backgroundCheckCalls = 0

    func start() throws { startCalls += 1 }
    func checkForUpdates() { manualCheckCalls += 1 }
    func checkForUpdatesInBackground() { backgroundCheckCalls += 1 }
    func emit(_ event: AppUpdateDriverEvent) { eventHandler?(event) }
}
