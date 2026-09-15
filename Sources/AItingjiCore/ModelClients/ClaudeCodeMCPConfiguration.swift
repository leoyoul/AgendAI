import Foundation

public struct ClaudeCodeMCPConfiguration: Codable, Equatable, Sendable {
    public var name: String
    public var endpoint: String
    public var transport: String
    public var tokenEnvironmentVariable: String?

    public init(name: String = "zentao", endpoint: String, transport: String = "http", tokenEnvironmentVariable: String? = "ZENTAO_MCP_TOKEN") {
        self.name = name
        self.endpoint = endpoint
        self.transport = transport
        self.tokenEnvironmentVariable = tokenEnvironmentVariable
    }
}

public enum ClaudeCodeMCPConfigurationSource: String, Codable, Equatable, Sendable {
    case userProfile
    case temporary

    public var displayName: String {
        switch self {
        case .userProfile: "Claude Code 用户级配置（回退）"
        case .temporary: "会话级临时配置"
        }
    }
}

public struct ClaudeCodeMCPConfigurationSelection: Equatable, Sendable {
    public var source: ClaudeCodeMCPConfigurationSource
    public var configURL: URL?
    public var reason: String

    public init(source: ClaudeCodeMCPConfigurationSource, configURL: URL? = nil, reason: String) {
        self.source = source
        self.configURL = configURL
        self.reason = reason
    }
}

public enum ClaudeCodeMCPConfigurationError: Error, Equatable, LocalizedError, Sendable {
    case invalidEndpoint
    case unsupportedTransport(String)

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "禅道 MCP 地址无效。"
        case .unsupportedTransport(let value): "暂不支持的禅道 MCP 传输类型：\(value)"
        }
    }
}

/// 生成一次调用专用的 Claude Code MCP 配置。文件只包含 endpoint 和环境变量引用。
public struct ClaudeCodeMCPConfigurationWriter: Sendable {
    public init() {}

    public func write(configuration: ClaudeCodeMCPConfiguration, directory: URL = FileManager.default.temporaryDirectory) throws -> URL {
        guard let url = URL(string: configuration.endpoint),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil else { throw ClaudeCodeMCPConfigurationError.invalidEndpoint }
        guard ["http", "https", "sse", "stdio"].contains(configuration.transport.lowercased()) else {
            throw ClaudeCodeMCPConfigurationError.unsupportedTransport(configuration.transport)
        }
        var server: [String: Any] = ["type": configuration.transport, "url": configuration.endpoint]
        if let variable = configuration.tokenEnvironmentVariable?.trimmingCharacters(in: .whitespacesAndNewlines), !variable.isEmpty {
            server["headers"] = ["Authorization": "Bearer ${\(variable)}"]
        }
        let root: [String: Any] = ["mcpServers": [configuration.name: server]]
        let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let fileURL = directory.appendingPathComponent("ai-tingji-claude-mcp-\(UUID().uuidString).json")
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        return fileURL
    }
}

/// 只在调用进程明确提供 Token 时生成临时配置；否则让 Claude Code 使用其用户级配置。
public struct ClaudeCodeMCPConfigurationResolver: Sendable {
    private let environment: [String: String]
    private let tokenEnvironmentVariable: String

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        tokenEnvironmentVariable: String = "ZENTAO_MCP_TOKEN"
    ) {
        self.environment = environment
        self.tokenEnvironmentVariable = tokenEnvironmentVariable
    }

    public func resolve(
        endpoint: String,
        transport: String,
        directory: URL = FileManager.default.temporaryDirectory
    ) throws -> ClaudeCodeMCPConfigurationSelection {
        let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEndpoint.isEmpty else {
            return ClaudeCodeMCPConfigurationSelection(
                source: .userProfile,
                reason: "未提供应用级 MCP 地址，使用 Claude Code 用户级配置。"
            )
        }

        let token = environment[tokenEnvironmentVariable]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !token.isEmpty else {
            return ClaudeCodeMCPConfigurationSelection(
                source: .userProfile,
                reason: "未检测到 \(tokenEnvironmentVariable)，使用 Claude Code 用户级配置。"
            )
        }

        let configURL = try ClaudeCodeMCPConfigurationWriter().write(
            configuration: ClaudeCodeMCPConfiguration(
                endpoint: trimmedEndpoint,
                transport: transport,
                tokenEnvironmentVariable: tokenEnvironmentVariable
            ),
            directory: directory
        )
        return ClaudeCodeMCPConfigurationSelection(
            source: .temporary,
            configURL: configURL,
            reason: "检测到环境变量，使用会话级临时 MCP 配置。"
        )
    }
}
