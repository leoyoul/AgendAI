import Foundation

public enum PiAgentResourceOrigin: Equatable, Sendable {
    case user
    case shared
    case package(String)
}

public struct PiAgentSkill: Identifiable, Equatable, Sendable {
    public var id: String { fileURL.path }
    public var name: String
    public var description: String
    public var content: String
    public var fileURL: URL
    public var origin: PiAgentResourceOrigin
    public var isEditable: Bool

    public init(
        name: String,
        description: String,
        content: String,
        fileURL: URL,
        origin: PiAgentResourceOrigin,
        isEditable: Bool
    ) {
        self.name = name
        self.description = description
        self.content = content
        self.fileURL = fileURL
        self.origin = origin
        self.isEditable = isEditable
    }
}

public struct PiMCPServer: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public var name: String
    public var configurationJSON: String

    public init(name: String, configurationJSON: String) {
        self.name = name
        self.configurationJSON = configurationJSON
    }
}

public enum PiPluginKind: Equatable, Sendable {
    case package
    case localExtension
}

public struct PiPlugin: Identifiable, Equatable, Sendable {
    public var id: String
    public var kind: PiPluginKind
    public var name: String
    public var source: String
    public var version: String?
    public var fileURL: URL?
    public var content: String?
    public var skillCount: Int
    public var extensionCount: Int

    public init(
        id: String,
        kind: PiPluginKind,
        name: String,
        source: String,
        version: String? = nil,
        fileURL: URL? = nil,
        content: String? = nil,
        skillCount: Int = 0,
        extensionCount: Int = 0
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.source = source
        self.version = version
        self.fileURL = fileURL
        self.content = content
        self.skillCount = skillCount
        self.extensionCount = extensionCount
    }
}

public struct PiAgentConfigurationSnapshot: Equatable, Sendable {
    public var skills: [PiAgentSkill]
    public var mcpServers: [PiMCPServer]
    public var plugins: [PiPlugin]

    public init(
        skills: [PiAgentSkill] = [],
        mcpServers: [PiMCPServer] = [],
        plugins: [PiPlugin] = []
    ) {
        self.skills = skills
        self.mcpServers = mcpServers
        self.plugins = plugins
    }
}

public enum PiAgentConfigurationError: LocalizedError, Equatable, Sendable {
    case invalidSkillName
    case invalidSkillContent
    case skillNotEditable
    case invalidMCPName
    case invalidMCPConfiguration
    case invalidPluginName
    case invalidPluginSource
    case pluginNotEditable
    case settingsInvalid
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidSkillName:
            return "技能名称只能包含小写字母、数字和连字符，长度为 1-64。"
        case .invalidSkillContent:
            return "技能内容必须包含有效的 name 和 description frontmatter。"
        case .skillNotEditable:
            return "插件或共享目录中的技能只能查看，请通过对应插件管理。"
        case .invalidMCPName:
            return "MCP 名称不能为空，且不能包含控制字符。"
        case .invalidMCPConfiguration:
            return "MCP 配置必须是有效的 JSON 对象。"
        case .invalidPluginName:
            return "本地插件名称只能包含字母、数字、连字符和下划线。"
        case .invalidPluginSource:
            return "请输入有效的 npm、Git 或本地 Pi Package 来源。"
        case .pluginNotEditable:
            return "该插件不能直接编辑。"
        case .settingsInvalid:
            return "Pi settings.json 不是有效的 JSON 对象。"
        case .commandFailed(let message):
            return message
        }
    }
}

public struct PiCommandResult: Equatable, Sendable {
    public var exitCode: Int32
    public var standardOutput: String
    public var standardError: String

    public init(exitCode: Int32, standardOutput: String = "", standardError: String = "") {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public protocol PiCommandRunning: Sendable {
    func run(executableURL: URL, arguments: [String], currentDirectoryURL: URL) async throws -> PiCommandResult
}

public struct FoundationPiCommandRunner: PiCommandRunning {
    public init() {}

    public func run(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL
    ) async throws -> PiCommandResult {
        try await Task.detached {
            let outputDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("tinglan-pi-command-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: outputDirectory) }
            let outputURL = outputDirectory.appendingPathComponent("stdout.log")
            let errorURL = outputDirectory.appendingPathComponent("stderr.log")
            _ = FileManager.default.createFile(atPath: outputURL.path, contents: nil)
            _ = FileManager.default.createFile(atPath: errorURL.path, contents: nil)
            let outputHandle = try FileHandle(forWritingTo: outputURL)
            let errorHandle = try FileHandle(forWritingTo: errorURL)
            defer {
                try? outputHandle.close()
                try? errorHandle.close()
            }
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments
            process.currentDirectoryURL = currentDirectoryURL
            process.standardOutput = outputHandle
            process.standardError = errorHandle
            try process.run()
            process.waitUntilExit()
            try outputHandle.synchronize()
            try errorHandle.synchronize()
            return PiCommandResult(
                exitCode: process.terminationStatus,
                standardOutput: String(decoding: try Data(contentsOf: outputURL), as: UTF8.self),
                standardError: String(decoding: try Data(contentsOf: errorURL), as: UTF8.self)
            )
        }.value
    }
}

public struct PiAgentConfigurationStore: Sendable {
    private let homeDirectoryURL: URL
    private let packageRoots: [URL]
    private let executableResolver: any PiExecutableResolving
    private let commandRunner: any PiCommandRunning

    public init(
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        packageRoots: [URL]? = nil,
        executableResolver: any PiExecutableResolving = PiExecutableResolver(),
        commandRunner: any PiCommandRunning = FoundationPiCommandRunner()
    ) {
        self.homeDirectoryURL = homeDirectoryURL.standardizedFileURL
        self.packageRoots = packageRoots ?? [
            homeDirectoryURL.appendingPathComponent(".pi/agent/npm/node_modules", isDirectory: true),
            URL(fileURLWithPath: "/opt/homebrew/lib/node_modules", isDirectory: true),
            URL(fileURLWithPath: "/usr/local/lib/node_modules", isDirectory: true),
        ]
        self.executableResolver = executableResolver
        self.commandRunner = commandRunner
    }

    public func loadSnapshot() throws -> PiAgentConfigurationSnapshot {
        let settings = try readSettings()
        let packageSources = Self.packageSources(from: settings)
        let packageItems = packageSources.map { packageMetadata(source: $0) }
        return PiAgentConfigurationSnapshot(
            skills: loadSkills(packageMetadata: packageItems),
            mcpServers: try loadMCPServers(settings: settings),
            plugins: loadLocalExtensions() + packageItems.map(\.plugin)
        )
    }

    @discardableResult
    public func createSkill(name: String, description: String, instructions: String) throws -> PiAgentSkill {
        guard Self.isValidSkillName(name) else { throw PiAgentConfigurationError.invalidSkillName }
        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDescription.isEmpty else { throw PiAgentConfigurationError.invalidSkillContent }
        let directory = skillsRootURL.appendingPathComponent(name, isDirectory: true).standardizedFileURL
        guard Self.isDescendant(directory, of: skillsRootURL) else {
            throw PiAgentConfigurationError.invalidSkillName
        }
        let fileURL = directory.appendingPathComponent("SKILL.md")
        guard !FileManager.default.fileExists(atPath: fileURL.path) else {
            throw PiAgentConfigurationError.commandFailed("技能“\(name)”已存在。")
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let content = Self.renderSkill(
            name: name,
            description: trimmedDescription,
            instructions: instructions
        )
        try writeData(Data(content.utf8), to: fileURL, backsUpExistingFile: false)
        return try skill(at: fileURL, origin: .user, isEditable: true)
    }

    @discardableResult
    public func updateSkill(_ skill: PiAgentSkill, content: String) throws -> PiAgentSkill {
        guard skill.isEditable,
              Self.isDescendant(skill.fileURL, of: skillsRootURL),
              skill.fileURL.lastPathComponent == "SKILL.md"
        else { throw PiAgentConfigurationError.skillNotEditable }
        guard let metadata = Self.skillMetadata(from: content), Self.isValidSkillName(metadata.name) else {
            throw PiAgentConfigurationError.invalidSkillContent
        }
        try writeData(Data(content.utf8), to: skill.fileURL, backsUpExistingFile: true)
        return try self.skill(at: skill.fileURL, origin: .user, isEditable: true)
    }

    public func deleteSkill(_ skill: PiAgentSkill) throws {
        let directory = skill.fileURL.deletingLastPathComponent().standardizedFileURL
        guard skill.isEditable,
              Self.isDescendant(directory, of: skillsRootURL),
              directory.resolvingSymlinksInPath() != skillsRootURL.resolvingSymlinksInPath()
        else { throw PiAgentConfigurationError.skillNotEditable }
        try backupItem(at: directory)
        try FileManager.default.removeItem(at: directory)
    }

    @discardableResult
    public func upsertMCPServer(name: String, configurationJSON: String) throws -> PiMCPServer {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty,
              !trimmedName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw PiAgentConfigurationError.invalidMCPName }
        guard let data = configurationJSON.data(using: .utf8),
              let configuration = try? JSONSerialization.jsonObject(with: data),
              configuration is [String: Any]
        else { throw PiAgentConfigurationError.invalidMCPConfiguration }
        var settings = try readSettings()
        var servers = settings["mcpServers"] as? [String: Any] ?? [:]
        servers[trimmedName] = configuration
        settings["mcpServers"] = servers
        try writeSettings(settings)
        return PiMCPServer(
            name: trimmedName,
            configurationJSON: try Self.prettyJSON(configuration)
        )
    }

    public func deleteMCPServer(name: String) throws {
        var settings = try readSettings()
        var servers = settings["mcpServers"] as? [String: Any] ?? [:]
        servers.removeValue(forKey: name)
        settings["mcpServers"] = servers
        try writeSettings(settings)
    }

    @discardableResult
    public func createLocalExtension(name: String, content: String) throws -> PiPlugin {
        guard Self.isValidPluginName(name) else { throw PiAgentConfigurationError.invalidPluginName }
        let fileURL = extensionsRootURL.appendingPathComponent("\(name).ts").standardizedFileURL
        guard Self.isDescendant(fileURL, of: extensionsRootURL) else {
            throw PiAgentConfigurationError.invalidPluginName
        }
        guard !FileManager.default.fileExists(atPath: fileURL.path) else {
            throw PiAgentConfigurationError.commandFailed("本地插件“\(name)”已存在。")
        }
        try FileManager.default.createDirectory(
            at: extensionsRootURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try writeData(Data(content.utf8), to: fileURL, backsUpExistingFile: false)
        return localExtension(at: fileURL)
    }

    @discardableResult
    public func updateLocalExtension(_ plugin: PiPlugin, content: String) throws -> PiPlugin {
        guard plugin.kind == .localExtension,
              let fileURL = plugin.fileURL,
              Self.isDescendant(fileURL, of: extensionsRootURL)
        else { throw PiAgentConfigurationError.pluginNotEditable }
        try writeData(Data(content.utf8), to: fileURL, backsUpExistingFile: true)
        return localExtension(at: fileURL)
    }

    public func deleteLocalExtension(_ plugin: PiPlugin) throws {
        guard plugin.kind == .localExtension,
              let fileURL = plugin.fileURL,
              Self.isDescendant(fileURL, of: extensionsRootURL)
        else { throw PiAgentConfigurationError.pluginNotEditable }
        try backupItem(at: fileURL)
        try FileManager.default.removeItem(at: fileURL)
    }

    public func installPlugin(source: String) async throws {
        try await runPackageCommand("install", source: source)
    }

    public func updatePlugin(source: String) async throws {
        try await runPackageCommand("update", source: source)
    }

    public func removePlugin(source: String) async throws {
        try await runPackageCommand("remove", source: source)
    }

    private var agentRootURL: URL {
        homeDirectoryURL.appendingPathComponent(".pi/agent", isDirectory: true)
    }

    private var settingsURL: URL { agentRootURL.appendingPathComponent("settings.json") }
    private var skillsRootURL: URL { agentRootURL.appendingPathComponent("skills", isDirectory: true) }
    private var sharedSkillsRootURL: URL {
        homeDirectoryURL.appendingPathComponent(".agents/skills", isDirectory: true)
    }
    private var extensionsRootURL: URL {
        agentRootURL.appendingPathComponent("extensions", isDirectory: true)
    }

    private func readSettings() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return [:] }
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL))
        guard let settings = object as? [String: Any] else {
            throw PiAgentConfigurationError.settingsInvalid
        }
        return settings
    }

    private func writeSettings(_ settings: [String: Any]) throws {
        guard JSONSerialization.isValidJSONObject(settings) else {
            throw PiAgentConfigurationError.settingsInvalid
        }
        let data = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) + Data("\n".utf8)
        try FileManager.default.createDirectory(
            at: agentRootURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try writeData(data, to: settingsURL, backsUpExistingFile: true)
    }

    private func loadMCPServers(settings: [String: Any]) throws -> [PiMCPServer] {
        guard let raw = settings["mcpServers"] else { return [] }
        guard let servers = raw as? [String: Any] else {
            throw PiAgentConfigurationError.settingsInvalid
        }
        return try servers.map { name, configuration in
            guard configuration is [String: Any] else {
                throw PiAgentConfigurationError.invalidMCPConfiguration
            }
            return PiMCPServer(
                name: name,
                configurationJSON: try Self.prettyJSON(configuration)
            )
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private struct PackageMetadata {
        var plugin: PiPlugin
        var skillRoots: [URL]
    }

    private func packageMetadata(source: String) -> PackageMetadata {
        let packageName = Self.packageName(from: source)
        let packageURL = packageName.flatMap(installedPackageURL(named:))
        let manifest = packageURL.flatMap(Self.packageManifest(at:))
        let skillRoots = zip(manifest?.skills ?? [], repeatElement(packageURL, count: manifest?.skills.count ?? 0))
            .compactMap { path, root in root.map { $0.appendingPathComponent(path, isDirectory: true) } }
        return PackageMetadata(
            plugin: PiPlugin(
                id: "package:\(source)",
                kind: .package,
                name: manifest?.name ?? packageName ?? source,
                source: source,
                version: manifest?.version,
                fileURL: packageURL,
                skillCount: skillRoots.reduce(0) { $0 + skillFiles(in: $1).count },
                extensionCount: manifest?.extensions.count ?? 0
            ),
            skillRoots: skillRoots
        )
    }

    private func loadSkills(packageMetadata: [PackageMetadata]) -> [PiAgentSkill] {
        var result: [PiAgentSkill] = []
        for fileURL in skillFiles(in: skillsRootURL) {
            if let skill = try? skill(at: fileURL, origin: .user, isEditable: true) {
                result.append(skill)
            }
        }
        for fileURL in skillFiles(in: sharedSkillsRootURL) {
            if let skill = try? skill(at: fileURL, origin: .shared, isEditable: false) {
                result.append(skill)
            }
        }
        for metadata in packageMetadata {
            for root in metadata.skillRoots {
                for fileURL in skillFiles(in: root) {
                    if let skill = try? skill(
                        at: fileURL,
                        origin: .package(metadata.plugin.name),
                        isEditable: false
                    ) {
                        result.append(skill)
                    }
                }
            }
        }
        var seen: Set<String> = []
        return result
            .filter { seen.insert($0.fileURL.standardizedFileURL.path).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func skill(at fileURL: URL, origin: PiAgentResourceOrigin, isEditable: Bool) throws -> PiAgentSkill {
        let content = try String(contentsOf: fileURL, encoding: .utf8)
        guard let metadata = Self.skillMetadata(from: content) else {
            throw PiAgentConfigurationError.invalidSkillContent
        }
        return PiAgentSkill(
            name: metadata.name,
            description: metadata.description,
            content: content,
            fileURL: fileURL.standardizedFileURL,
            origin: origin,
            isEditable: isEditable
        )
    }

    private func loadLocalExtensions() -> [PiPlugin] {
        let fileExtensions = Set(["ts", "js", "mjs"])
        let files = (try? FileManager.default.contentsOfDirectory(
            at: extensionsRootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return files
            .filter { fileExtensions.contains($0.pathExtension.lowercased()) }
            .map(localExtension(at:))
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func localExtension(at fileURL: URL) -> PiPlugin {
        PiPlugin(
            id: "extension:\(fileURL.standardizedFileURL.path)",
            kind: .localExtension,
            name: fileURL.deletingPathExtension().lastPathComponent,
            source: fileURL.path,
            fileURL: fileURL.standardizedFileURL,
            content: try? String(contentsOf: fileURL, encoding: .utf8),
            extensionCount: 1
        )
    }

    private func skillFiles(in root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var result: [URL] = []
        for case let url as URL in enumerator where url.lastPathComponent == "SKILL.md" {
            result.append(url.standardizedFileURL)
        }
        return result
    }

    private func installedPackageURL(named name: String) -> URL? {
        for root in packageRoots {
            let candidate = root.appendingPathComponent(name, isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("package.json").path) {
                return candidate.standardizedFileURL
            }
        }
        return nil
    }

    private static func packageSources(from settings: [String: Any]) -> [String] {
        guard let packages = settings["packages"] as? [Any] else { return [] }
        return packages.compactMap { value in
            if let source = value as? String { return source }
            return (value as? [String: Any])?["source"] as? String
        }
    }

    private static func packageName(from source: String) -> String? {
        guard source.hasPrefix("npm:") else { return nil }
        let spec = String(source.dropFirst(4))
        if spec.hasPrefix("@") {
            guard let separator = spec.dropFirst().lastIndex(of: "@") else { return spec }
            return String(spec[..<separator])
        }
        return String(spec.split(separator: "@", maxSplits: 1).first ?? "")
    }

    private static func packageManifest(at packageURL: URL) -> (
        name: String?, version: String?, skills: [String], extensions: [String]
    )? {
        let url = packageURL.appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let pi = object["pi"] as? [String: Any]
        return (
            name: object["name"] as? String,
            version: object["version"] as? String,
            skills: pi?["skills"] as? [String] ?? [],
            extensions: pi?["extensions"] as? [String] ?? []
        )
    }

    private func runPackageCommand(_ command: String, source: String) async throws {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidPluginSource(trimmed) else {
            throw PiAgentConfigurationError.invalidPluginSource
        }
        let executableURL = try executableResolver.resolve()
        let result = try await commandRunner.run(
            executableURL: executableURL,
            arguments: [command, trimmed],
            currentDirectoryURL: homeDirectoryURL
        )
        guard result.exitCode == 0 else {
            let detail = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            throw PiAgentConfigurationError.commandFailed(
                detail.isEmpty ? "Pi 插件操作失败（退出码 \(result.exitCode)）。" : detail
            )
        }
    }

    private func writeData(_ data: Data, to url: URL, backsUpExistingFile: Bool) throws {
        if backsUpExistingFile, FileManager.default.fileExists(atPath: url.path) {
            try backupItem(at: url)
        }
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func backupItem(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let formatter = ISO8601DateFormatter()
        let timestamp = formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backupRootURL = agentRootURL.appendingPathComponent("backups", isDirectory: true)
        try FileManager.default.createDirectory(
            at: backupRootURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let backupURL = backupRootURL
            .appendingPathComponent("\(url.lastPathComponent).\(timestamp).\(UUID().uuidString).bak")
        try FileManager.default.copyItem(at: url, to: backupURL)
    }

    private static func prettyJSON(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: value,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        return String(decoding: data, as: UTF8.self)
    }

    private static func renderSkill(name: String, description: String, instructions: String) -> String {
        let body = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        ---
        name: \(name)
        description: \(yamlQuoted(description.replacingOccurrences(of: "\n", with: " ")))
        ---

        \(body.isEmpty ? "# \(name)" : body)
        """ + "\n"
    }

    private static func skillMetadata(from content: String) -> (name: String, description: String)? {
        let normalized = content.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first == "---",
              let end = lines.dropFirst().firstIndex(of: "---")
        else { return nil }
        var name = ""
        var description = ""
        var index = 1
        while index < end {
            let line = lines[index]
            if line.hasPrefix("name:") {
                name = yamlScalar(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
            } else if line.hasPrefix("description:") {
                let scalar = String(line.dropFirst(12)).trimmingCharacters(in: .whitespaces)
                if scalar == "|" || scalar == ">" {
                    var blockLines: [String] = []
                    index += 1
                    while index < end {
                        let blockLine = lines[index]
                        guard blockLine.first?.isWhitespace == true || blockLine.isEmpty else {
                            index -= 1
                            break
                        }
                        blockLines.append(blockLine.trimmingCharacters(in: .whitespaces))
                        index += 1
                    }
                    description = scalar == ">"
                        ? blockLines.joined(separator: " ")
                        : blockLines.joined(separator: "\n")
                } else {
                    description = yamlScalar(scalar)
                }
            }
            index += 1
        }
        guard !name.isEmpty, !description.isEmpty else { return nil }
        return (name, description)
    }

    private static func yamlQuoted(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) else {
            return "\"\""
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func yamlScalar(_ value: String) -> String {
        guard value.hasPrefix("\""), value.hasSuffix("\""),
              let data = value.data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? String
        else { return value }
        return decoded
    }

    private static func isValidSkillName(_ value: String) -> Bool {
        guard (1...64).contains(value.count) else { return false }
        let pattern = #"^[a-z0-9]+(?:-[a-z0-9]+)*$"#
        return value.range(of: pattern, options: .regularExpression) != nil
    }

    private static func isValidPluginName(_ value: String) -> Bool {
        guard (1...80).contains(value.count) else { return false }
        return value.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil
    }

    private static func isValidPluginSource(_ value: String) -> Bool {
        guard !value.isEmpty, !value.contains("\n"), !value.contains("\r") else { return false }
        return value.hasPrefix("npm:")
            || value.hasPrefix("git:")
            || value.hasPrefix("https://")
            || value.hasPrefix("http://")
            || value.hasPrefix("ssh://")
            || value.hasPrefix("/")
            || value.hasPrefix("./")
            || value.hasPrefix("../")
    }

    private static func isDescendant(_ url: URL, of root: URL) -> Bool {
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath().path
        let rootPath = resolvedRoot.hasSuffix("/") ? resolvedRoot : resolvedRoot + "/"
        return url.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(rootPath)
    }
}
