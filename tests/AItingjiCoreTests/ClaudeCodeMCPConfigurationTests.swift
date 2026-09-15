import Foundation
import Testing
@testable import AItingjiCore

@Suite("Claude Code MCP configuration")
struct ClaudeCodeMCPConfigurationTests {
    @Test("writes a session config with an environment token reference")
    func writesRedactedConfig() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try ClaudeCodeMCPConfigurationWriter().write(
            configuration: ClaudeCodeMCPConfiguration(endpoint: "http://example.test/mcp") ,
            directory: directory
        )
        let text = try String(contentsOf: url)
        #expect(text.contains("example.test"))
        #expect(text.contains("${ZENTAO_MCP_TOKEN}"))
        #expect(!text.contains("secret"))
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("rejects an invalid endpoint")
    func rejectsInvalidEndpoint() {
        #expect(throws: ClaudeCodeMCPConfigurationError.invalidEndpoint) {
            _ = try ClaudeCodeMCPConfigurationWriter().write(configuration: ClaudeCodeMCPConfiguration(endpoint: "not a url"))
        }
    }

    @Test("uses the Claude Code user profile when no token is available")
    func resolverFallsBackToUserProfileWithoutToken() throws {
        let selection = try ClaudeCodeMCPConfigurationResolver(
            environment: ["PATH": "/usr/bin"]
        ).resolve(endpoint: "https://zentao.example.test/mcp", transport: "http")

        #expect(selection.source == .userProfile)
        #expect(selection.configURL == nil)
        #expect(selection.reason.contains("用户级配置"))
    }

    @Test("uses a temporary config only when the token environment variable exists")
    func resolverUsesTemporaryConfigWithTokenEnvironment() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let selection = try ClaudeCodeMCPConfigurationResolver(
            environment: ["ZENTAO_MCP_TOKEN": "secret-token"]
        ).resolve(endpoint: "https://zentao.example.test/mcp", transport: "http", directory: directory)

        #expect(selection.source == .temporary)
        #expect(selection.configURL != nil)
        let configURL = try #require(selection.configURL)
        let text = try String(contentsOf: configURL, encoding: .utf8)
        #expect(text.contains("${ZENTAO_MCP_TOKEN}"))
        #expect(!text.contains("secret-token"))
    }
}
