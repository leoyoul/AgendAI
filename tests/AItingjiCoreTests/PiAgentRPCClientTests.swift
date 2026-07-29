import Foundation
import Testing
@testable import AItingjiCore

@Suite("Pi Agent RPC Client")
struct PiAgentRPCClientTests {
    @Test("resolver prefers PATH and falls back to the user Pi install")
    func resolverOrder() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pathBin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: pathBin, withIntermediateDirectories: true)
        let pathPi = pathBin.appendingPathComponent("pi")
        FileManager.default.createFile(atPath: pathPi.path, contents: Data("#!/bin/sh\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: pathPi.path)
        let fallbackPi = root.appendingPathComponent(".pi/agent/npm/node_modules/.bin/pi")
        try FileManager.default.createDirectory(
            at: fallbackPi.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: fallbackPi.path, contents: Data("#!/bin/sh\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fallbackPi.path)

        let pathResolver = PiExecutableResolver(
            environment: ["PATH": pathBin.path, "HOME": root.path]
        )
        #expect(try pathResolver.resolve() == pathPi.standardizedFileURL)

        try FileManager.default.removeItem(at: pathPi)
        let fallbackResolver = PiExecutableResolver(
            environment: ["PATH": pathBin.path, "HOME": root.path]
        )
        #expect(try fallbackResolver.resolve() == fallbackPi.standardizedFileURL)
    }

    @Test("event parser uses strict LF framing and keeps Unicode separators")
    func strictJSONLParsing() throws {
        var parser = PiAgentRPCEventParser()
        let frames = [
            #"{"id":"prompt-1","type":"response","command":"prompt","success":true}"#,
            #"{"type":"message_update","assistantMessageEvent":{"type":"thinking_delta","delta":"核对人员库"}}"#,
            "{\"type\":\"message_update\",\"assistantMessageEvent\":{\"type\":\"text_delta\",\"delta\":\"A\u{2028}B\"}}",
            #"{"type":"tool_execution_start","toolCallId":"call-1","toolName":"meeting_context","args":{}}"#,
            #"{"type":"tool_execution_end","toolCallId":"call-1","toolName":"meeting_context","result":{},"isError":false}"#,
            #"{"type":"extension_ui_request","id":"ui-1","method":"confirm","title":"是否继续","message":"确认"}"#,
            #"{"type":"agent_end","messages":[]}"#,
        ].joined(separator: "\n") + "\n"
        let bytes = Data(frames.utf8)
        let split = try #require(bytes.firstRange(of: Data("A".utf8))?.upperBound)

        let first = try parser.append(bytes[..<split])
        let second = try parser.append(bytes[split...])
        try parser.finish()

        #expect(first == [.promptAccepted, .thinkingDelta("核对人员库")])
        #expect(second == [
            .textDelta("A\u{2028}B"),
            .toolExecutionStarted(name: "meeting_context"),
            .toolExecutionEnded(name: "meeting_context", isError: false),
            .extensionUIRequest(id: "ui-1", title: "是否继续"),
            .agentEnd(finalText: nil)
        ])
    }

    @Test("event parser rejects bad JSON and prompt rejection")
    func parserErrors() throws {
        var malformed = PiAgentRPCEventParser()
        #expect(throws: PiAgentRPCClientError.self) {
            _ = try malformed.append(Data("{bad json}\n".utf8))
        }

        var rejected = PiAgentRPCEventParser()
        #expect(throws: PiAgentRPCClientError.rpcRejected("model unavailable")) {
            _ = try rejected.append(Data(
                #"{"id":"prompt-1","type":"response","command":"prompt","success":false,"error":"model unavailable"}"#.utf8
                    + Data([0x0A])
            ))
        }

        var generationError = PiAgentRPCEventParser()
        #expect(throws: PiAgentRPCClientError.rpcRejected("模型服务断开连接")) {
            _ = try generationError.append(Data(
                #"{"type":"message_update","assistantMessageEvent":{"type":"error","reason":"error","error":{"role":"assistant","stopReason":"error","errorMessage":"模型服务断开连接"}}}"#.utf8
                    + Data([0x0A])
            ))
        }

        var messageEndError = PiAgentRPCEventParser()
        #expect(throws: PiAgentRPCClientError.rpcRejected("推理已中止")) {
            _ = try messageEndError.append(Data(
                #"{"type":"message_end","message":{"role":"assistant","stopReason":"aborted","errorMessage":"推理已中止"}}"#.utf8
                    + Data([0x0A])
            ))
        }
    }

    @Test("client isolates API key, streams deltas, and cleans temporary config")
    func clientLaunchContract() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("fake-pi")
        FileManager.default.createFile(atPath: executable.path, contents: Data())
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let runner = CapturingPiProcessRunner(outputChunks: successfulOutputChunks())
        let client = PiAgentRPCClient(
            executableResolver: FixedPiResolver(url: executable),
            processRunner: runner,
            temporaryDirectoryRoot: root
        )
        let source = ModelSource(
            id: "agent-1",
            type: .agent,
            name: "Agent",
            baseURL: "https://llm.example.test/v1",
            apiKey: "super-secret-key",
            apiProtocol: .responses,
            selectedModel: "gpt-agent",
            availableModels: ["gpt-agent"],
            isDefault: true,
            enabled: true
        )

        var events: [PiAgentRPCEvent] = []
        for try await event in client.stream(source: source, prompt: "结合会议回答") {
            events.append(event)
        }

        #expect(events == [
            .promptAccepted,
            .thinkingDelta("核对人员库"),
            .textDelta("你"),
            .textDelta("好"),
            .completed("你好"),
            .sessionStats(Self.sampleSessionStats)
        ])
        let request = try #require(await runner.capturedRequest())
        #expect(request.executableURL == executable)
        #expect(request.arguments == [
            "--mode", "rpc",
            "--no-session",
            "--no-tools",
            "--no-context-files",
            "--no-extensions",
            "--no-skills",
            "--no-prompt-templates",
            "--provider", "tinglan",
            "--model", "gpt-agent",
        ])
        #expect(request.environment["PI_CODING_AGENT_DIR"] == request.currentDirectoryURL.path)
        #expect(request.environment["TINGLAN_PI_API_KEY"] == "super-secret-key")
        let commandLines = String(decoding: request.standardInput, as: UTF8.self)
            .split(separator: "\n")
        #expect(commandLines.count == 2)
        let autoCompactionObject = try #require(
            JSONSerialization.jsonObject(with: Data(commandLines[0].utf8)) as? [String: Any]
        )
        #expect(autoCompactionObject["type"] as? String == "set_auto_compaction")
        #expect(autoCompactionObject["enabled"] as? Bool == true)
        let promptObject = try #require(
            JSONSerialization.jsonObject(with: Data(commandLines[1].utf8)) as? [String: Any]
        )
        #expect(promptObject["id"] as? String == "prompt-1")
        #expect(promptObject["type"] as? String == "prompt")
        #expect(promptObject["message"] as? String == "结合会议回答")

        let modelsData = try #require(await runner.capturedModelsJSON())
        let modelsText = String(decoding: modelsData, as: UTF8.self)
        #expect(modelsText.contains("TINGLAN_PI_API_KEY"))
        #expect(!modelsText.contains("super-secret-key"))
        let modelsObject = try #require(
            JSONSerialization.jsonObject(with: modelsData) as? [String: Any]
        )
        let providers = try #require(modelsObject["providers"] as? [String: Any])
        let provider = try #require(providers["tinglan"] as? [String: Any])
        #expect(provider["baseUrl"] as? String == "https://llm.example.test/v1")
        #expect(provider["api"] as? String == "openai-responses")
        #expect(provider["apiKey"] as? String == "TINGLAN_PI_API_KEY")
        #expect(provider["authHeader"] as? Bool == true)
        #expect(await runner.capturedDirectoryPermissions() == 0o700)
        #expect(await runner.capturedModelsPermissions() == 0o600)
        #expect(!FileManager.default.fileExists(atPath: request.currentDirectoryURL.path))
    }

    @Test("runtime creates the first session, then continues it with tools, extensions, skills, and workspace")
    func fullAgentRuntimeArguments() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("fake-pi")
        FileManager.default.createFile(atPath: executable.path, contents: Data())
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let runner = CapturingPiProcessRunner(outputChunks: successfulOutputChunks())
        let client = PiAgentRPCClient(
            executableResolver: FixedPiResolver(url: executable),
            processRunner: runner,
            temporaryDirectoryRoot: root
        )
        let source = ModelSource(
            id: "agent-runtime",
            type: .agent,
            name: "Agent",
            baseURL: "https://llm.example.test/v1",
            apiKey: "key",
            apiProtocol: .responses,
            selectedModel: "gpt-agent",
            enabled: true
        )
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let runtime = PiAgentRuntimeConfiguration(
            workingDirectoryURL: workspace,
            sessionDirectoryURL: sessions,
            extensionURLs: [root.appendingPathComponent("web.ts")],
            skillURLs: [root.appendingPathComponent("skills", isDirectory: true)],
            enabledTools: ["read", "edit", "web_search"],
            sessionName: "会议 Agent"
        )

        for try await _ in client.stream(source: source, prompt: "继续分析", runtime: runtime) {}

        let request = try #require(await runner.capturedRequest())
        #expect(request.currentDirectoryURL == workspace)
        #expect(!request.arguments.contains("--continue"))
        #expect(request.arguments.contains(sessions.path))
        #expect(request.arguments.contains("read,edit,web_search"))
        #expect(request.arguments.contains(root.appendingPathComponent("web.ts").path))
        #expect(request.arguments.contains(root.appendingPathComponent("skills").path))
        #expect(!request.arguments.contains("--name"))
        let initialCommands = String(decoding: request.standardInput, as: UTF8.self)
        #expect(initialCommands.contains("\"type\":\"set_session_name\""))
        #expect(initialCommands.contains("会议 Agent"))
        #expect(FileManager.default.fileExists(atPath: sessions.path))

        try Data("session\n".utf8).write(to: sessions.appendingPathComponent("session.jsonl"))
        for try await _ in client.stream(source: source, prompt: "继续分析", runtime: runtime) {}
        let continuedRequest = try #require(await runner.capturedRequest())
        #expect(continuedRequest.arguments.contains("--continue"))
    }

    @Test("parser exposes compaction and real session context statistics")
    func parsesCompactionAndSessionStats() throws {
        var parser = PiAgentRPCEventParser()
        let frames = [
            #"{"type":"compaction_start","reason":"threshold"}"#,
            #"{"type":"compaction_end","reason":"threshold","result":{"tokensBefore":120000,"estimatedTokensAfter":28000}}"#,
            #"{"type":"response","command":"get_session_stats","success":true,"data":{"userMessages":5,"assistantMessages":4,"toolCalls":7,"tokens":{"input":50000,"output":8000,"cacheRead":3000,"cacheWrite":1000,"total":62000},"contextUsage":{"tokens":28000,"contextWindow":131072,"percent":21.4}}}"#,
        ].joined(separator: "\n") + "\n"

        let events = try parser.append(Data(frames.utf8))
        try parser.finish()

        #expect(events == [
            .compactionStarted(reason: "threshold"),
            .compactionEnded(reason: "threshold", tokensBefore: 120_000, estimatedTokensAfter: 28_000),
            .sessionStats(PiAgentSessionStats(
                inputTokens: 50_000,
                outputTokens: 8_000,
                cacheReadTokens: 3_000,
                cacheWriteTokens: 1_000,
                totalTokens: 62_000,
                contextTokens: 28_000,
                contextWindow: 131_072,
                contextPercent: 21.4,
                userMessages: 5,
                assistantMessages: 4,
                toolCalls: 7
            )),
        ])
    }

    @Test("client proactively compacts at eighty percent and waits for refreshed stats")
    func proactivelyCompactsHighContextUsage() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("fake-pi")
        FileManager.default.createFile(atPath: executable.path, contents: Data())
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let highStats = #"{"type":"response","command":"get_session_stats","success":true,"data":{"userMessages":8,"assistantMessages":8,"toolCalls":3,"tokens":{"input":80000,"output":2000,"cacheRead":0,"cacheWrite":0,"total":82000},"contextUsage":{"tokens":104000,"contextWindow":128000,"percent":81.25}}}"#
        let lowStats = #"{"type":"response","command":"get_session_stats","success":true,"data":{"userMessages":9,"assistantMessages":9,"toolCalls":3,"tokens":{"input":83000,"output":2500,"cacheRead":0,"cacheWrite":0,"total":85500},"contextUsage":{"tokens":28000,"contextWindow":128000,"percent":21.875}}}"#
        let output = [
            #"{"id":"prompt-1","type":"response","command":"prompt","success":true}"#,
            #"{"type":"agent_end","messages":[]}"#,
            highStats,
            #"{"type":"compaction_start","reason":"manual"}"#,
            #"{"type":"compaction_end","reason":"manual","result":{"tokensBefore":104000,"estimatedTokensAfter":28000}}"#,
            lowStats,
        ].joined(separator: "\n") + "\n"
        let client = PiAgentRPCClient(
            executableResolver: FixedPiResolver(url: executable),
            processRunner: CapturingPiProcessRunner(outputChunks: [Data(output.utf8)]),
            temporaryDirectoryRoot: root
        )
        let source = ModelSource(
            id: "agent-compaction",
            type: .agent,
            name: "Agent",
            baseURL: "https://llm.example.test/v1",
            apiKey: "key",
            selectedModel: "gpt-agent",
            enabled: true
        )

        var events: [PiAgentRPCEvent] = []
        for try await event in client.stream(source: source, prompt: "继续") {
            events.append(event)
        }

        #expect(events.contains(.compactionStarted(reason: "manual")))
        #expect(events.contains(.compactionEnded(
            reason: "manual",
            tokensBefore: 104_000,
            estimatedTokensAfter: 28_000
        )))
        #expect(events.last == .sessionStats(PiAgentSessionStats(
            inputTokens: 83_000,
            outputTokens: 2_500,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            totalTokens: 85_500,
            contextTokens: 28_000,
            contextWindow: 128_000,
            contextPercent: 21.875,
            userMessages: 9,
            assistantMessages: 9,
            toolCalls: 3
        )))
    }

    @Test("foundation runner delivers a short line before a long-lived process exits")
    func foundationRunnerStreamsWithoutWaitingForBufferOrEOF() async throws {
        let request = PiAgentProcessRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf 'ready\\n'; sleep 2"],
            environment: ProcessInfo.processInfo.environment,
            currentDirectoryURL: FileManager.default.temporaryDirectory,
            standardInput: Data()
        )
        let session = try FoundationPiAgentProcessRunner().start(request)
        defer { session.terminate() }
        let clock = ContinuousClock()
        let start = clock.now
        var iterator = session.output().makeAsyncIterator()
        let first = try #require(await iterator.next())

        #expect(String(decoding: first, as: UTF8.self) == "ready\n")
        #expect(start.duration(to: clock.now) < .seconds(1))
    }

    @Test("client validates source and cleans temporary directory after protocol failure")
    func validationAndFailureCleanup() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("fake-pi")
        let runner = CapturingPiProcessRunner(outputChunks: [Data("{bad}\n".utf8)])
        let client = PiAgentRPCClient(
            executableResolver: FixedPiResolver(url: executable),
            processRunner: runner,
            temporaryDirectoryRoot: root
        )
        var source = ModelSource(
            id: "agent-1",
            type: .agent,
            name: "Agent",
            baseURL: "https://llm.example.test/v1",
            apiKey: "key",
            apiProtocol: .chatCompletions,
            selectedModel: "model"
        )

        do {
            for try await _ in client.stream(source: source, prompt: "hello") {}
            Issue.record("Expected malformed RPC output to fail")
        } catch {
            #expect(error is PiAgentRPCClientError)
        }
        let failedRequest = try #require(await runner.capturedRequest())
        #expect(!FileManager.default.fileExists(atPath: failedRequest.currentDirectoryURL.path))

        source.type = .meetingMinutes
        let invalidClient = PiAgentRPCClient(
            executableResolver: FixedPiResolver(url: executable),
            processRunner: CapturingPiProcessRunner(outputChunks: [])
        )
        do {
            for try await _ in invalidClient.stream(source: source, prompt: "hello") {}
            Issue.record("Expected non-agent source to fail")
        } catch {
            #expect(error as? PiAgentRPCClientError == .invalidModelSource)
        }
    }

    private func successfulOutputChunks() -> [Data] {
        let prefix = Data(
            (#"{"id":"prompt-1","type":"response","command":"prompt","success":true}"# + "\n"
                + #"{"type":"message_update","assistantMessageEvent":{"type":"thinking_delta","delta":"核对人员库"}}"# + "\n"
                + #"{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":""#).utf8
        )
        let suffix = Data(
            (#""}}"# + "\n"
                + #"{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"好"}}"# + "\n"
                + #"{"type":"agent_end","messages":[]}"# + "\n"
                + #"{"type":"response","command":"get_session_stats","success":true,"data":{"userMessages":2,"assistantMessages":2,"toolCalls":1,"tokens":{"input":1000,"output":200,"cacheRead":100,"cacheWrite":0,"total":1300},"contextUsage":{"tokens":900,"contextWindow":32000,"percent":2.8}}}"# + "\n").utf8
        )
        let firstCharacter = Array(Data("你".utf8))
        return [
            prefix + Data(firstCharacter.prefix(1)),
            Data(firstCharacter.dropFirst()) + suffix,
        ]
    }

    private static let sampleSessionStats = PiAgentSessionStats(
        inputTokens: 1_000,
        outputTokens: 200,
        cacheReadTokens: 100,
        cacheWriteTokens: 0,
        totalTokens: 1_300,
        contextTokens: 900,
        contextWindow: 32_000,
        contextPercent: 2.8,
        userMessages: 2,
        assistantMessages: 2,
        toolCalls: 1
    )

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-agent-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private struct FixedPiResolver: PiExecutableResolving {
    let url: URL

    func resolve() throws -> URL { url }
}

private actor CapturingPiProcessRunner: PiAgentProcessRunning {
    private let outputChunks: [Data]
    private var request: PiAgentProcessRequest?
    private var modelsJSON: Data?
    private var directoryPermissions: Int?
    private var modelsPermissions: Int?

    init(outputChunks: [Data]) {
        self.outputChunks = outputChunks
    }

    nonisolated func start(_ request: PiAgentProcessRequest) throws -> any PiAgentProcessSession {
        FakePiProcessSession(chunks: outputChunks) { [weak self] in
            guard let self else { return }
            await self.capture(request)
        }
    }

    private func capture(_ request: PiAgentProcessRequest) {
        self.request = request
        let modelsURL = request.currentDirectoryURL.appendingPathComponent("models.json")
        modelsJSON = try? Data(contentsOf: modelsURL)
        directoryPermissions = Self.permissions(at: request.currentDirectoryURL)
        modelsPermissions = Self.permissions(at: modelsURL)
    }

    func capturedRequest() -> PiAgentProcessRequest? { request }
    func capturedModelsJSON() -> Data? { modelsJSON }
    func capturedDirectoryPermissions() -> Int? { directoryPermissions }
    func capturedModelsPermissions() -> Int? { modelsPermissions }

    private static func permissions(at url: URL) -> Int? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let value = attributes[.posixPermissions] as? NSNumber else {
            return nil
        }
        return value.intValue
    }
}

private final class FakePiProcessSession: PiAgentProcessSession, @unchecked Sendable {
    private let chunks: [Data]
    private let onStart: @Sendable () async -> Void

    init(chunks: [Data], onStart: @escaping @Sendable () async -> Void) {
        self.chunks = chunks
        self.onStart = onStart
    }

    func output() -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await onStart()
                for chunk in chunks { continuation.yield(chunk) }
                continuation.finish()
            }
        }
    }

    func send(_: Data) throws {}

    func terminate() {}
}
