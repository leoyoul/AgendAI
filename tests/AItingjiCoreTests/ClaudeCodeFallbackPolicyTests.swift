import Foundation
import Testing
@testable import AItingjiCore

@Suite("Claude Code fallback and timeout policy")
struct ClaudeCodeFallbackPolicyTests {
    @Test("default follow-up process timeout is 600 seconds")
    func defaultTimeoutIsTenMinutes() {
        let configuration = ClaudeCodeProcessConfiguration(
            prompt: "match",
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            mcpConfigURL: nil,
            maxTurns: 8,
            model: nil,
            permissionMode: nil
        )

        #expect(configuration.timeout == .seconds(600))
    }

    @Test("a caller can retain a short timeout for deterministic tests")
    func customTimeoutIsPreserved() {
        let configuration = ClaudeCodeProcessConfiguration(
            prompt: "match",
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            mcpConfigURL: nil,
            maxTurns: 1,
            model: nil,
            permissionMode: nil,
            timeout: .milliseconds(25)
        )

        #expect(configuration.timeout == .milliseconds(25))
    }

    @Test("temporary MCP configuration uses an environment reference and never a token value")
    func temporaryConfigurationIsRedacted() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = try ClaudeCodeMCPConfigurationWriter().write(
            configuration: ClaudeCodeMCPConfiguration(
                endpoint: "https://zentao.example.test/mcp",
                tokenEnvironmentVariable: "ZENTAO_MCP_TOKEN"
            ),
            directory: directory
        )
        let text = try String(contentsOf: url, encoding: .utf8)

        #expect(text.contains("zentao.example.test"))
        #expect(text.contains("${ZENTAO_MCP_TOKEN}"))
        #expect(text.contains("Bearer ${ZENTAO_MCP_TOKEN}"))
        #expect(!text.contains("secret-token"))
    }

    @Test("nil MCP config preserves user-level Claude Code configuration mode")
    func nilMCPConfigMeansNoTemporaryOverride() {
        let configuration = ClaudeCodeProcessConfiguration(
            prompt: "match",
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            mcpConfigURL: nil,
            maxTurns: 8,
            model: nil,
            permissionMode: nil
        )

        #expect(configuration.mcpConfigURL == nil)
    }

    @Test("process diagnostics do not expose credentials")
    func processDiagnosticsAreRedacted() {
        let error = ClaudeCodeClientError.processFailed(
            1,
            "MCP request failed: Authorization: Bearer top-secret-token api_key=private-key"
        )

        let description = error.localizedDescription
        #expect(!description.contains("top-secret-token"))
        #expect(!description.contains("private-key"))
        #expect(description.contains("[已隐藏]"))
    }
}
