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

    @Test("forwards model and permission mode to the process configuration")
    func forwardsAdvancedOptions() async throws {
        let capture = Capture()
        let client = ClaudeCodeClient(processRunner: { configuration in
            await capture.set(configuration: configuration)
            return "{\"result\":\"ok\"}"
        })
        _ = try await client.run(prompt: "test", workingDirectory: URL(fileURLWithPath: "/tmp"), maxTurns: 3, model: "sonnet", permissionMode: "acceptEdits")
        let value = try #require(await capture.configuration())
        #expect(value.model == "sonnet")
        #expect(value.permissionMode == "acceptEdits")
        #expect(value.maxTurns == 3)
    }

    @Test("returns a stable timeout for a stalled runner")
    func timesOut() async {
        let client = ClaudeCodeClient(processRunner: { _ in
            try await Task.sleep(for: .seconds(5))
            return "{}"
        })
        await #expect(throws: ClaudeCodeClientError.timedOut) {
            _ = try await client.run(prompt: "test", workingDirectory: URL(fileURLWithPath: "/tmp"), timeout: .milliseconds(20))
        }
    }

    @Test("rejects invalid Claude JSON")
    func rejectsInvalidJSON() {
        #expect(throws: ClaudeCodeClientError.invalidJSON) {
            _ = try ClaudeCodeClient.parseResponse("not-json")
        }
    }

    @Test("redacts credentials in process diagnostics")
    func redactsCredentials() {
        let error = ClaudeCodeClientError.processFailed(1, "Authorization: Bearer secret-token api_key=another-secret")
        #expect(!error.localizedDescription.contains("secret-token"))
        #expect(!error.localizedDescription.contains("another-secret"))
    }
}

private actor Capture {
    struct Value: Sendable {
        var prompt: String
        var workingDirectory: URL
        var config: URL?
        var maxTurns: Int
    }

    private var configurationValue: ClaudeCodeProcessConfiguration?

    private var stored: Value?

    func set(prompt: String, workingDirectory: URL, config: URL?, maxTurns: Int) {
        stored = Value(prompt: prompt, workingDirectory: workingDirectory, config: config, maxTurns: maxTurns)
    }

    func set(configuration: ClaudeCodeProcessConfiguration) { configurationValue = configuration }

    func value() -> Value? { stored }
    func configuration() -> ClaudeCodeProcessConfiguration? { configurationValue }
}
