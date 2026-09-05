import Foundation

public struct DiarizationPythonEnvironment: Equatable, Sendable {
    public var rootURL: URL
    public var executableURL: URL

    public init(rootURL: URL, executableURL: URL) {
        self.rootURL = rootURL
        self.executableURL = executableURL
    }
}

public enum DiarizationSidecarRuntimeResolver {
    public static let supportDirectoryName = "会小纪"
    public static let sidecarEnvironmentDirectoryName = "VoiceprintSidecar"

    public static func resolveProjectRoot(
        currentDirectoryURL: URL,
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> URL {
        candidateDevelopmentProjectRoots(currentDirectoryURL: currentDirectoryURL, homeDirectoryURL: homeDirectoryURL)
            .first { root in
                fileExists(developmentSidecarScriptURL(projectRootURL: root).path)
            } ?? currentDirectoryURL
    }

    public static func resolveSidecarScriptURL(
        currentDirectoryURL: URL,
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        bundleResourcesURL: URL? = Bundle.main.resourceURL,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> URL? {
        if let bundleResourcesURL {
            let bundledScriptURL = bundledSidecarScriptURL(bundleResourcesURL: bundleResourcesURL)
            if fileExists(bundledScriptURL.path) {
                return bundledScriptURL
            }
        }

        let projectRootURL = resolveProjectRoot(
            currentDirectoryURL: currentDirectoryURL,
            homeDirectoryURL: homeDirectoryURL,
            fileExists: fileExists
        )
        let developmentScriptURL = developmentSidecarScriptURL(projectRootURL: projectRootURL)
        return fileExists(developmentScriptURL.path) ? developmentScriptURL : nil
    }

    public static func resolveSetupScriptURL(
        currentDirectoryURL: URL,
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        bundleResourcesURL: URL? = Bundle.main.resourceURL,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> URL? {
        if let bundleResourcesURL {
            let bundledSetupURL = bundledSetupScriptURL(bundleResourcesURL: bundleResourcesURL)
            if fileExists(bundledSetupURL.path) {
                return bundledSetupURL
            }
        }

        return candidateDevelopmentProjectRoots(
            currentDirectoryURL: currentDirectoryURL,
            homeDirectoryURL: homeDirectoryURL
        )
        .lazy
        .map { developmentSetupScriptURL(projectRootURL: $0) }
        .first { fileExists($0.path) }
    }

    public static func resolvePythonExecutable(
        projectRootURL: URL,
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        applicationSupportURL: URL? = nil,
        allowProjectFallback: Bool = true,
        isExecutableFile: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> URL? {
        resolvePythonEnvironment(
            projectRootURL: projectRootURL,
            homeDirectoryURL: homeDirectoryURL,
            applicationSupportURL: applicationSupportURL,
            allowProjectFallback: allowProjectFallback,
            isExecutableFile: isExecutableFile
        )?.executableURL
    }

    public static func resolvePythonEnvironment(
        projectRootURL: URL,
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        applicationSupportURL: URL? = nil,
        allowProjectFallback: Bool = true,
        isExecutableFile: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> DiarizationPythonEnvironment? {
        candidatePythonEnvironmentRoots(
            projectRootURL: projectRootURL,
            homeDirectoryURL: homeDirectoryURL,
            applicationSupportURL: applicationSupportURL,
            allowProjectFallback: allowProjectFallback
        )
        .lazy
        .map { rootURL in
            DiarizationPythonEnvironment(
                rootURL: rootURL,
                executableURL: py312PythonURL(environmentRootURL: rootURL)
            )
        }
        .first { isExecutableFile($0.executableURL.path) }
    }

    public static func developmentSidecarScriptURL(projectRootURL: URL) -> URL {
        projectRootURL
            .appendingPathComponent("Tools")
            .appendingPathComponent("voiceprint_sidecar")
            .appendingPathComponent("server.py")
    }

    public static func bundledSidecarScriptURL(bundleResourcesURL: URL) -> URL {
        bundleResourcesURL
            .appendingPathComponent("voiceprint_sidecar")
            .appendingPathComponent("server.py")
    }

    public static func sidecarScriptURL(projectRootURL: URL) -> URL {
        developmentSidecarScriptURL(projectRootURL: projectRootURL)
    }

    public static func developmentSetupScriptURL(projectRootURL: URL) -> URL {
        projectRootURL
            .appendingPathComponent("scripts")
            .appendingPathComponent("setup_voiceprint_sidecar.sh")
    }

    public static func bundledSetupScriptURL(bundleResourcesURL: URL) -> URL {
        bundleResourcesURL
            .appendingPathComponent("scripts")
            .appendingPathComponent("setup_voiceprint_sidecar.sh")
    }

    public static func setupScriptURL(projectRootURL: URL) -> URL {
        developmentSetupScriptURL(projectRootURL: projectRootURL)
    }

    public static func missingPythonEnvironmentMessage(
        environmentRootURL: URL,
        setupScriptURL: URL
    ) -> String {
        "未找到本机说话人分离 Python 环境：\(py312PythonURL(environmentRootURL: environmentRootURL).path)。请先运行：sh \(setupScriptURL.path)"
    }

    public static func missingPythonEnvironmentMessage(projectRootURL: URL, setupScriptURL: URL? = nil) -> String {
        let scriptURL = setupScriptURL ?? self.setupScriptURL(projectRootURL: projectRootURL)
        return missingPythonEnvironmentMessage(environmentRootURL: projectRootURL, setupScriptURL: scriptURL)
    }

    public static func missingDependencyMessage(
        _ originalMessage: String,
        environmentRootURL: URL,
        setupScriptURL: URL
    ) -> String? {
        guard originalMessage.contains("No module named") else { return nil }
        return "本机说话人分离依赖缺失：\(originalMessage)。请运行：sh \(setupScriptURL.path)"
    }

    public static func missingDependencyMessage(_ originalMessage: String, projectRootURL: URL, setupScriptURL: URL? = nil) -> String? {
        let scriptURL = setupScriptURL ?? self.setupScriptURL(projectRootURL: projectRootURL)
        return missingDependencyMessage(originalMessage, environmentRootURL: projectRootURL, setupScriptURL: scriptURL)
    }

    public static func sidecarEnvironmentRootURL(applicationSupportURL: URL? = nil) -> URL {
        if let applicationSupportURL {
            return applicationSupportURL
                .appendingPathComponent(supportDirectoryName, isDirectory: true)
                .appendingPathComponent(sidecarEnvironmentDirectoryName, isDirectory: true)
        }
        return ApplicationDataDirectory.child(sidecarEnvironmentDirectoryName)
    }

    private static func candidateDevelopmentProjectRoots(currentDirectoryURL: URL, homeDirectoryURL: URL) -> [URL] {
        // 开发版仅从当前工作目录和 ~/Documents/AgendAI 解析；安装版由 bundleResourcesURL 显式解析。
        uniqueURLs([
            currentDirectoryURL,
            homeDirectoryURL
                .appendingPathComponent("Documents")
                .appendingPathComponent("AgendAI")
        ])
    }

    private static func candidatePythonEnvironmentRoots(
        projectRootURL: URL,
        homeDirectoryURL: URL,
        applicationSupportURL: URL?,
        allowProjectFallback: Bool
    ) -> [URL] {
        var roots = [sidecarEnvironmentRootURL(applicationSupportURL: applicationSupportURL)]
        if allowProjectFallback {
            roots.append(contentsOf: [
                projectRootURL,
                homeDirectoryURL
                    .appendingPathComponent("Documents")
                    .appendingPathComponent("AgendAI")
            ])
        }
        return uniqueURLs(roots)
    }

    private static func py312PythonURL(environmentRootURL: URL) -> URL {
        environmentRootURL
            .appendingPathComponent(".voiceprint-py312")
            .appendingPathComponent("bin")
            .appendingPathComponent("python")
    }

    private static func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        return urls.filter { url in
            let key = url.standardizedFileURL.path
            return seen.insert(key).inserted
        }
    }
}
