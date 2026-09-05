import AItingjiCore
import AppKit
import Foundation
import Observation

enum AppUpdateCheckTrigger: Sendable {
    case automatic
    case manual
}

enum AppUpdateNotice: Identifiable, Equatable {
    case updateAvailable(currentVersion: String, release: GitHubRelease)
    case upToDate(currentVersion: String)
    case failure(message: String)

    var id: String {
        switch self {
        case .updateAvailable: "update-available"
        case .upToDate: "up-to-date"
        case .failure: "failure"
        }
    }
}

@MainActor
@Observable
final class AppUpdateCoordinator {
    typealias CheckOperation = @Sendable (String) async throws -> UpdateCheckResult
    typealias URLOpener = @MainActor (URL) -> Bool

    private let currentVersion: String
    @ObservationIgnored private let checkOperation: CheckOperation
    @ObservationIgnored private let openURL: URLOpener
    private var didStartAutomaticCheck = false

    private(set) var isChecking = false
    var notice: AppUpdateNotice?

    init(
        currentVersion: String = AppUpdateCoordinator.bundleVersion(),
        checkOperation: CheckOperation? = nil,
        openURL: URLOpener? = nil
    ) {
        self.currentVersion = currentVersion
        if let checkOperation {
            self.checkOperation = checkOperation
        } else {
            let service = UpdateCheckService()
            self.checkOperation = { version in
                try await service.check(currentVersion: version)
            }
        }
        self.openURL = openURL ?? { NSWorkspace.shared.open($0) }
    }

    func checkAutomatically(log: (String) -> Void) async {
        guard !didStartAutomaticCheck else { return }
        didStartAutomaticCheck = true
        await check(trigger: .automatic, log: log)
    }

    func checkManually(log: (String) -> Void) async {
        await check(trigger: .manual, log: log)
    }

    func openRelease(_ release: GitHubRelease, log: (String) -> Void) {
        guard UpdateCheckService.isTrustedReleaseURL(release.htmlURL) else {
            let message = UpdateCheckError.untrustedReleaseURL.localizedDescription
            notice = .failure(message: message)
            log("打开更新页面失败：\(message)")
            return
        }
        guard openURL(release.htmlURL) else {
            let message = "无法打开浏览器，请稍后重试。"
            notice = .failure(message: message)
            log("打开更新页面失败：\(message)")
            return
        }
        log("已打开 AgendAI \(release.version) 下载页面。")
    }

    private func check(trigger: AppUpdateCheckTrigger, log: (String) -> Void) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        do {
            switch try await checkOperation(currentVersion) {
            case .updateAvailable(let release):
                notice = .updateAvailable(currentVersion: currentVersion, release: release)
                log("发现新版本 \(release.version)，当前版本 \(currentVersion)。")
            case .upToDate:
                log("更新检查完成，当前版本 \(currentVersion) 已是最新版。")
                if trigger == .manual {
                    notice = .upToDate(currentVersion: currentVersion)
                }
            }
        } catch {
            let message = error.localizedDescription
            log("更新检查失败：\(message)")
            if trigger == .manual {
                notice = .failure(message: message)
            }
        }
    }

    private static func bundleVersion() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }
}
