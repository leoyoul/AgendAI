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
        let fileURL = directory.appendingPathComponent("ai-tingji-claude-mcp-\(UUID().uuidString).json")
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        return fileURL
    }
}
