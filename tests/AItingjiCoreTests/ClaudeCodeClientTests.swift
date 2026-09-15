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

    @Test("runs Claude Code with the non-interactive JSON arguments")
    func defaultProcessPassesExpectedArguments() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("mock-claude.sh")
        let argumentsFile = root.appendingPathComponent("arguments.txt")
        let scriptText = "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"" + argumentsFile.path + "\"\nprintf '%s' '{\"result\":\"ok\"}'\n"
        try Data(scriptText.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)

        let mcpURL = root.appendingPathComponent("mcp.json")
        let configuration = ClaudeCodeProcessConfiguration(
            prompt: "匹配禅道",
            workingDirectory: root,
            executableURL: script,
            mcpConfigURL: mcpURL,
            maxTurns: 4,
            model: "sonnet",
            permissionMode: "acceptEdits",
            timeout: .seconds(2)
        )
        let result = try await ClaudeCodeClient.defaultResponse(configuration)
        #expect(result == "ok")
        let arguments = try String(contentsOf: argumentsFile, encoding: .utf8)
        #expect(arguments.contains("-p\n匹配禅道"))
        #expect(arguments.contains("--output-format\njson"))
        #expect(arguments.contains("--max-turns\n4"))
        #expect(arguments.contains("--model\nsonnet"))
        #expect(arguments.contains("--permission-mode\nacceptEdits"))
        #expect(arguments.contains("--mcp-config\n\(mcpURL.path)"))
    }

    @Test("terminates a stalled Claude Code process and returns timeout diagnostics")
    func terminatesStalledProcess() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("mock-claude-sleep.sh")
        try Data("#!/bin/sh\nsleep 5\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)

        let configuration = ClaudeCodeProcessConfiguration(
            prompt: "匹配禅道",
            workingDirectory: root,
            executableURL: script,
            mcpConfigURL: nil,
            maxTurns: 1,
            model: nil,
            permissionMode: nil,
            timeout: .milliseconds(40)
        )
        do {
            _ = try await ClaudeCodeClient.defaultResponse(configuration)
            Issue.record("预期 Claude Code 超时")
        } catch let error as ClaudeCodeClientError {
            guard case .timedOutWithDiagnostics(let diagnostic) = error else {
                Issue.record("收到非预期错误：\(error.localizedDescription)")
                return
            }
            #expect(diagnostic.executablePath == script.path)
            #expect(diagnostic.timeoutKind == .mcpQuery)
            #expect(diagnostic.timeoutSeconds == 1)
            #expect(diagnostic.phase == "timeout.mcp_query")
        }
    }

    @Test("maps a non-zero MCP process with 401 diagnostics and redacts credentials")
    func mapsMCPProcessFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("mock-claude-failure.sh")
        try Data("#!/bin/sh\necho 'MCP HTTP 401 Authorization: Bearer secret-token' >&2\nexit 7\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let configuration = ClaudeCodeProcessConfiguration(
            prompt: "匹配禅道", workingDirectory: root, executableURL: script,
            mcpConfigURL: nil, maxTurns: 1, model: nil, permissionMode: nil,
            timeout: .seconds(2)
        )

        do {
            _ = try await ClaudeCodeClient.defaultResponse(configuration)
            Issue.record("预期 MCP 连接失败")
        } catch let error as ClaudeCodeClientError {
            guard case .mcpUnavailableWithDiagnostics(let diagnostic) = error else {
                Issue.record("收到非预期错误：\(error.localizedDescription)")
                return
            }
            #expect(diagnostic.exitCode == 7)
            #expect(diagnostic.mcpName == "zentao")
            #expect(diagnostic.possibleMCPConnectionError)
            #expect(!diagnostic.stderr.contains("secret-token"))
        }
    }

    @Test("keeps CLI and stderr details when JSON output is invalid")
    func mapsInvalidJSONWithDiagnostics() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("mock-claude-invalid.sh")
        try Data("#!/bin/sh\necho 'not-json'\necho 'parser detail' >&2\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let configuration = ClaudeCodeProcessConfiguration(
            prompt: "匹配禅道", workingDirectory: root, executableURL: script,
            mcpConfigURL: nil, maxTurns: 1, model: nil, permissionMode: nil,
            timeout: .seconds(2)
        )

        do {
            _ = try await ClaudeCodeClient.defaultResponse(configuration)
            Issue.record("预期非法 JSON 错误")
        } catch let error as ClaudeCodeClientError {
            guard case .invalidJSONWithDiagnostics(let diagnostic) = error else {
                Issue.record("收到非预期错误：\(error.localizedDescription)")
                return
            }
            #expect(diagnostic.executablePath == script.path)
            #expect(diagnostic.stderr.contains("parser detail"))
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

    private var configurationValue: ClaudeCodeProcessConfiguration?

    private var stored: Value?

    func set(prompt: String, workingDirectory: URL, config: URL?, maxTurns: Int) {
        stored = Value(prompt: prompt, workingDirectory: workingDirectory, config: config, maxTurns: maxTurns)
    }

    func set(configuration: ClaudeCodeProcessConfiguration) { configurationValue = configuration }

    func value() -> Value? { stored }
    func configuration() -> ClaudeCodeProcessConfiguration? { configurationValue }
}
