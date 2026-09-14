import Foundation
import Testing
@testable import AItingjiCore

@Suite("Claude Code client")
struct ClaudeCodeClientTests {
    @Test("passes prompt, working directory and MCP config to the injected runner")
    func forwardsRequestToRunner() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let config = directory.appendingPathComponent("mcp.json")
        let capture = Capture()
        let client = ClaudeCodeClient(responseGenerator: { prompt, workingDirectory, mcpConfigURL, maxTurns in
            await capture.set(prompt: prompt, workingDirectory: workingDirectory, config: mcpConfigURL, maxTurns: maxTurns)
            return "{\"meetingID\":\"m\",\"todos\":[]}" 
        })

        let result = try await client.run(prompt: "匹配禅道", workingDirectory: directory, mcpConfigURL: config, maxTurns: 4)
        #expect(result.contains("meetingID"))
        let value = try #require(await capture.value())
        #expect(value.prompt == "匹配禅道")
        #expect(value.workingDirectory == directory)
        #expect(value.config == config)
        #expect(value.maxTurns == 4)
    }

    @Test("propagates injected process errors")
    func propagatesErrors() async {
        let client = ClaudeCodeClient(responseGenerator: { _, _, _, _ in
            throw ClaudeCodeClientError.timedOut
        })
        await #expect(throws: ClaudeCodeClientError.timedOut) {
            _ = try await client.run(prompt: "test", workingDirectory: FileManager.default.temporaryDirectory)
        }
    }
}

private actor Capture {
    struct Value: Sendable {
        var prompt: String
        var workingDirectory: URL
        var config: URL?
        var maxTurns: Int
    }

    private var stored: Value?

    func set(prompt: String, workingDirectory: URL, config: URL?, maxTurns: Int) {
        stored = Value(prompt: prompt, workingDirectory: workingDirectory, config: config, maxTurns: maxTurns)
    }

    func value() -> Value? { stored }
}
