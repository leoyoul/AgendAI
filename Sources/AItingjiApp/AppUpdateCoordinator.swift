import AppKit
import Foundation
import Observation
import Sparkle

enum AppInstallationLocationPolicy {
    static let productionBundleIdentifier = "com.local.aitingji"
    static let testBundleIdentifier = "com.local.aitingji.test"
    static let applicationsDirectory = URL(fileURLWithPath: "/Applications", isDirectory: true)

    static func requiresInstallationPrompt(
        bundleIdentifier: String?,
        bundleURL: URL,
        environment: [String: String]
    ) -> Bool {
        guard bundleIdentifier == productionBundleIdentifier,
              !isTestProcess(environment: environment) else {
            return false
        }
        return bundleURL.standardizedFileURL.deletingLastPathComponent() != applicationsDirectory
    }

    static func isTestProcess(environment: [String: String]) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
    }

    static func testFeedURL(
        bundleIdentifier: String?,
        environment: [String: String]
    ) -> URL? {
        guard bundleIdentifier == testBundleIdentifier,
              let rawValue = environment["TINGLAN_SPARKLE_FEED_URL"],
              !rawValue.isEmpty,
              let url = URL(string: rawValue) else {
            return nil
        }
        return url
    }
}

@MainActor
protocol AppUpdateDriving: AnyObject {
    var canCheckForUpdates: Bool { get }
    var eventHandler: ((AppUpdateDriverEvent) -> Void)? { get set }

    func start() throws
    func checkForUpdates()
    func checkForUpdatesInBackground()
}

enum AppUpdateDriverEvent: Equatable {
    case updateAvailable(version: String)
    case upToDate
    case failed(message: String)
}

@MainActor
final class SparkleUpdateDriver: NSObject, AppUpdateDriving, SPUUpdaterDelegate {
    var eventHandler: ((AppUpdateDriverEvent) -> Void)?

    private let feedURLOverride: URL?
    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: self,
        userDriverDelegate: nil
    )

    init(feedURLOverride: URL?) {
        self.feedURLOverride = feedURLOverride
    }

    var canCheckForUpdates: Bool {
        controller.updater.canCheckForUpdates
    }

    func start() throws {
        // The standard Sparkle UI remains intact, but Skip is cleared on launch.
        // It can therefore never suppress a future automatic check permanently.
        clearSkippedVersions()
        if feedURLOverride != nil {
            controller.updater.automaticallyChecksForUpdates = true
        }

        try controller.updater.start()
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    func checkForUpdatesInBackground() {
        controller.updater.checkForUpdatesInBackground()
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        feedURLOverride?.absoluteString
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        eventHandler?(.updateAvailable(version: item.displayVersionString))
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        eventHandler?(.upToDate)
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        guard let event = Self.abortEvent(for: error) else { return }
        eventHandler?(event)
    }

    static func abortEvent(for error: Error) -> AppUpdateDriverEvent? {
        let nsError = error as NSError
        guard nsError.domain == SUSparkleErrorDomain else {
            return .failed(message: nsError.localizedDescription)
        }
        guard !expectedAbortErrorCodes.contains(nsError.code) else {
            return nil
        }
        return .failed(message: nsError.localizedDescription)
    }

    private static let expectedAbortErrorCodes: Set<Int> = [
        Int(SUError.noUpdateError.rawValue),
        Int(SUError.installationCanceledError.rawValue),
        Int(SUError.installationAuthorizeLaterError.rawValue)
    ]

    private func clearSkippedVersions() {
        let defaults = UserDefaults.standard
        ["SUSkippedVersion", "SUSkippedMajorVersion", "SUSkippedMajorSubreleaseVersion"]
            .forEach(defaults.removeObject(forKey:))
    }
}

enum AppUpdateBrandState: Equatable {
    case current(version: String)
    case updateAvailable(currentVersion: String, latestVersion: String)

    var versionLabel: String {
        switch self {
        case .current(let version): "v\(version)"
        case .updateAvailable(_, let latestVersion): "v\(latestVersion) 可更新"
        }
    }

    var hasUpdate: Bool {
        if case .updateAvailable = self { return true }
        return false
    }
}

@MainActor
@Observable
final class AppUpdateCoordinator {
    typealias Log = @MainActor (String) -> Void
    typealias InstallationRevealAction = @MainActor (URL, URL) -> Void

    let currentVersion: String
    let installationPromptRequired: Bool
    let updatesAreEnabled: Bool
    @ObservationIgnored private let bundleURL: URL
    @ObservationIgnored private let driver: AppUpdateDriving
    @ObservationIgnored private let revealInstallationLocations: InstallationRevealAction
    @ObservationIgnored private var log: Log?
    private var didStart = false

    private(set) var isChecking = false
    private(set) var brandState: AppUpdateBrandState
    var showInstallationPrompt = false

    convenience init() {
        self.init(
            bundleIdentifier: Bundle.main.bundleIdentifier,
            bundleURL: Bundle.main.bundleURL,
            currentVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0",
            environment: ProcessInfo.processInfo.environment
        )
    }

    init(
        bundleIdentifier: String?,
        bundleURL: URL,
        currentVersion: String,
        environment: [String: String],
        driver: AppUpdateDriving? = nil,
        revealInstallationLocations: InstallationRevealAction? = nil
    ) {
        self.currentVersion = currentVersion
        self.bundleURL = bundleURL
        let feedURLOverride = AppInstallationLocationPolicy.testFeedURL(
            bundleIdentifier: bundleIdentifier,
            environment: environment
        )
        updatesAreEnabled = bundleIdentifier != AppInstallationLocationPolicy.testBundleIdentifier
            || feedURLOverride != nil
        installationPromptRequired = AppInstallationLocationPolicy.requiresInstallationPrompt(
            bundleIdentifier: bundleIdentifier,
            bundleURL: bundleURL,
            environment: environment
        )
        brandState = .current(version: currentVersion)
        self.driver = driver ?? SparkleUpdateDriver(
            feedURLOverride: feedURLOverride
        )
        self.revealInstallationLocations = revealInstallationLocations ?? { bundleURL, applicationsURL in
            NSWorkspace.shared.open(applicationsURL)
            NSWorkspace.shared.activateFileViewerSelecting([bundleURL])
        }
        self.driver.eventHandler = { [weak self] event in
            self?.handle(event)
        }
    }

    func start(log: @escaping Log) {
        guard !didStart else { return }
        didStart = true
        self.log = log

        guard !installationPromptRequired else {
            showInstallationPrompt = true
            log("当前会小纪未安装在“应用程序”目录，已暂停自动更新检查。")
            return
        }
        guard updatesAreEnabled else { return }

        do {
            try driver.start()
            isChecking = true
            driver.checkForUpdatesInBackground()
        } catch {
            isChecking = false
            log("自动更新服务启动失败：\(error.localizedDescription)")
        }
    }

    func checkForUpdatesManually(log: @escaping Log) {
        self.log = log
        guard !installationPromptRequired else {
            showInstallationPrompt = true
            return
        }
        guard updatesAreEnabled else { return }
        guard driver.canCheckForUpdates else { return }

        isChecking = true
        driver.checkForUpdates()
    }

    func revealCurrentAppAndApplications() {
        revealInstallationLocations(bundleURL, AppInstallationLocationPolicy.applicationsDirectory)
    }

    private func handle(_ event: AppUpdateDriverEvent) {
        isChecking = false
        switch event {
        case .updateAvailable(let latestVersion):
            brandState = .updateAvailable(currentVersion: currentVersion, latestVersion: latestVersion)
            log?("发现新版本 \(latestVersion)，当前版本 \(currentVersion)。")
        case .upToDate:
            brandState = .current(version: currentVersion)
            log?("更新检查完成，当前版本 \(currentVersion) 已是最新版。")
        case .failed(let message):
            log?("更新检查失败：\(message)")
        }
    }
}
