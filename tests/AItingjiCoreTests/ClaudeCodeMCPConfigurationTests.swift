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
}
