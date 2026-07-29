import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum PiAgentRPCClientError: Error, Equatable, Sendable {
    case invalidModelSource
    case missingModel
    case missingAPIKey
    case invalidBaseURL
    case emptyPrompt
    case executableNotFound
    case temporaryDirectoryFailed(String)
    case launchFailed(String)
    case processFailed(exitCode: Int32, stderr: String)
    case invalidRPC(String)
    case rpcRejected(String)
    case processEndedBeforeAgentEnd
}

extension PiAgentRPCClientError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidModelSource:
            "Pi Agent 只接受 Agent 类型的模型配置。"
        case .missingModel:
            "Pi Agent 模型未选择。"
        case .missingAPIKey:
            "Pi Agent API Key 为空。"
        case .invalidBaseURL:
            "Pi Agent 模型服务地址无效。"
        case .emptyPrompt:
            "Pi Agent 消息不能为空。"
        case .executableNotFound:
            "未找到 Pi 可执行文件。"
        case .temporaryDirectoryFailed(let message):
            "Pi Agent 临时目录创建失败：\(message)"
        case .launchFailed(let message):
            "Pi Agent 启动失败：\(message)"
        case .processFailed(let exitCode, let stderr):
            stderr.isEmpty
                ? "Pi Agent 进程失败（\(exitCode)）。"
                : "Pi Agent 进程失败（\(exitCode)）：\(stderr)"
        case .invalidRPC(let message):
            "Pi Agent RPC 响应无效：\(message)"
        case .rpcRejected(let message):
            "Pi Agent RPC 请求失败：\(message)"
        case .processEndedBeforeAgentEnd:
            "Pi Agent 未返回 agent_end 就结束。"
        }
    }
}

public enum PiAgentRPCEvent: Equatable, Sendable {
    case promptAccepted
    case textDelta(String)
    case thinkingDelta(String)
    case toolExecutionStarted(name: String)
    case toolExecutionEnded(name: String, isError: Bool)
    case compactionStarted(reason: String)
    case compactionEnded(reason: String, tokensBefore: Int?, estimatedTokensAfter: Int?)
    case extensionInteractionCancelled(title: String)
    case sessionStats(PiAgentSessionStats)
    case completed(String)
}

public struct PiAgentSessionStats: Equatable, Sendable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var cacheWriteTokens: Int
    public var totalTokens: Int
    public var contextTokens: Int?
    public var contextWindow: Int?
    public var contextPercent: Double?
    public var userMessages: Int
    public var assistantMessages: Int
    public var toolCalls: Int

    public init(
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        cacheWriteTokens: Int,
        totalTokens: Int,
        contextTokens: Int?,
        contextWindow: Int?,
        contextPercent: Double?,
        userMessages: Int,
        assistantMessages: Int,
        toolCalls: Int
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.totalTokens = totalTokens
        self.contextTokens = contextTokens
        self.contextWindow = contextWindow
        self.contextPercent = contextPercent
        self.userMessages = userMessages
        self.assistantMessages = assistantMessages
        self.toolCalls = toolCalls
    }
}

public struct PiAgentRuntimeConfiguration: Equatable, Sendable {
    public static let defaultTools = [
        "read", "bash", "edit", "write", "grep", "find", "ls",
        "web_search", "code_search", "fetch_content", "get_search_content", "tavily_search",
        "ctx_execute", "ctx_execute_file", "ctx_index", "ctx_search", "ctx_fetch_and_index",
        "ctx_batch_execute", "ctx_stats", "ctx_doctor", "ctx_upgrade", "ctx_purge", "ctx_insight",
    ]

    public var workingDirectoryURL: URL
    public var sessionDirectoryURL: URL
    public var extensionURLs: [URL]
    public var skillURLs: [URL]
    public var enabledTools: [String]
    public var sessionName: String?

    public init(
        workingDirectoryURL: URL,
        sessionDirectoryURL: URL,
        extensionURLs: [URL] = [],
        skillURLs: [URL] = [],
        enabledTools: [String] = Self.defaultTools,
        sessionName: String? = nil
    ) {
        self.workingDirectoryURL = workingDirectoryURL
        self.sessionDirectoryURL = sessionDirectoryURL
        self.extensionURLs = extensionURLs
        self.skillURLs = skillURLs
        self.enabledTools = enabledTools
        self.sessionName = sessionName
    }

    public var hasPersistedSession: Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: sessionDirectoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return false }
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "jsonl" {
            return true
        }
        return false
    }
}

public struct PiAgentProcessRequest: Equatable, Sendable {
    public var executableURL: URL
    public var arguments: [String]
    public var environment: [String: String]
    public var currentDirectoryURL: URL
    public var standardInput: Data

    public init(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectoryURL: URL,
        standardInput: Data
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.currentDirectoryURL = currentDirectoryURL
        self.standardInput = standardInput
    }
}

public protocol PiAgentProcessSession: Sendable {
    func output() -> AsyncThrowingStream<Data, Error>
    func send(_ data: Data) throws
    func terminate()
}

public protocol PiAgentProcessRunning: Sendable {
    func start(_ request: PiAgentProcessRequest) throws -> any PiAgentProcessSession
}

public struct PiAgentRPCClient: Sendable {
    private static let providerName = "tinglan"
    private static let apiKeyEnvironmentName = "TINGLAN_PI_API_KEY"

    private let executableResolver: any PiExecutableResolving
    private let processRunner: any PiAgentProcessRunning
    private let temporaryDirectoryRoot: URL
    private let environment: [String: String]

    public init(
        executableResolver: any PiExecutableResolving = PiExecutableResolver(),
        processRunner: any PiAgentProcessRunning = FoundationPiAgentProcessRunner(),
        temporaryDirectoryRoot: URL = FileManager.default.temporaryDirectory,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.executableResolver = executableResolver
        self.processRunner = processRunner
        self.temporaryDirectoryRoot = temporaryDirectoryRoot
        self.environment = environment
    }

    public func stream(
        source: ModelSource,
        prompt: String,
        runtime: PiAgentRuntimeConfiguration? = nil
    ) -> AsyncThrowingStream<PiAgentRPCEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(
                        source: source,
                        prompt: prompt,
                        runtime: runtime,
                        continuation: continuation
                    )
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(
        source: ModelSource,
        prompt: String,
        runtime: PiAgentRuntimeConfiguration?,
        continuation: AsyncThrowingStream<PiAgentRPCEvent, Error>.Continuation
    ) async throws {
        let validated = try validate(source: source, prompt: prompt)
        let executableURL = try executableResolver.resolve()
        let workingDirectory = try createTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workingDirectory) }

        try writeModelsConfiguration(
            source: source,
            model: validated.model,
            to: workingDirectory.appendingPathComponent("models.json")
        )
        var processEnvironment = environment
        processEnvironment["PI_CODING_AGENT_DIR"] = workingDirectory.path
        processEnvironment[Self.apiKeyEnvironmentName] = source.apiKey
        let request = PiAgentProcessRequest(
            executableURL: executableURL,
            arguments: Self.arguments(model: validated.model, runtime: runtime),
            environment: processEnvironment,
            currentDirectoryURL: runtime?.workingDirectoryURL ?? workingDirectory,
            standardInput: try Self.initialCommands(
                validated.prompt,
                sessionName: runtime?.sessionName
            )
        )
        if let runtime {
            try prepareRuntimeDirectories(runtime)
        }
        let session: any PiAgentProcessSession
        do {
            session = try processRunner.start(request)
        } catch let error as PiAgentRPCClientError {
            throw error
        } catch {
            throw PiAgentRPCClientError.launchFailed(error.localizedDescription)
        }
        var phaseTimeoutTask: Task<Void, Never>?
        func scheduleProcessTermination(after duration: Duration) {
            phaseTimeoutTask?.cancel()
            phaseTimeoutTask = Task {
                do {
                    try await Task.sleep(for: duration)
                    guard !Task.isCancelled else { return }
                    session.terminate()
                } catch {}
            }
        }
        defer {
            phaseTimeoutTask?.cancel()
            session.terminate()
        }

        var parser = PiAgentRPCEventParser()
        var accumulatedText = ""
        var promptAccepted = false
        var didRequestSessionStats = false
        var didCompleteAgentTurn = false
        var isCompacting = false
        var didRequestProactiveCompaction = false
        for try await chunk in session.output() {
            try Task.checkCancellation()
            for event in try parser.append(chunk) {
                switch event {
                case .promptAccepted:
                    promptAccepted = true
                    continuation.yield(.promptAccepted)
                case .textDelta(let delta):
                    accumulatedText += delta
                    continuation.yield(.textDelta(delta))
                case .thinkingDelta(let delta):
                    continuation.yield(.thinkingDelta(delta))
                case .toolExecutionStarted(let name):
                    continuation.yield(.toolExecutionStarted(name: name))
                case .toolExecutionEnded(let name, let isError):
                    continuation.yield(.toolExecutionEnded(name: name, isError: isError))
                case .compactionStarted(let reason):
                    isCompacting = true
                    scheduleProcessTermination(after: .seconds(120))
                    continuation.yield(.compactionStarted(reason: reason))
                case .compactionEnded(let reason, let tokensBefore, let estimatedTokensAfter):
                    isCompacting = false
                    continuation.yield(.compactionEnded(
                        reason: reason,
                        tokensBefore: tokensBefore,
                        estimatedTokensAfter: estimatedTokensAfter
                    ))
                    if didCompleteAgentTurn, didRequestSessionStats {
                        try session.send(Self.sessionStatsCommand())
                        scheduleProcessTermination(after: .seconds(5))
                    }
                case .extensionUIRequest(let id, let title):
                    try session.send(Self.cancelExtensionUIRequest(id: id))
                    continuation.yield(.extensionInteractionCancelled(title: title))
                case .agentEnd(let finalText):
                    guard promptAccepted else {
                        throw PiAgentRPCClientError.invalidRPC("agent_end 早于 prompt 成功响应")
                    }
                    let completedText = finalText.flatMap { $0.isEmpty ? nil : $0 } ?? accumulatedText
                    continuation.yield(.completed(completedText))
                    didCompleteAgentTurn = true
                    // Pi checks auto-compaction immediately after agent_end. Let the
                    // compaction event reach stdout before a fast stats response can
                    // make this client terminate the process.
                    try await Task.sleep(for: .milliseconds(120))
                    try session.send(Self.sessionStatsCommand())
                    didRequestSessionStats = true
                    scheduleProcessTermination(after: .seconds(5))
                case .sessionStats(let stats):
                    continuation.yield(.sessionStats(stats))
                    if isCompacting { continue }
                    if !didRequestProactiveCompaction,
                       Self.shouldCompactProactively(stats) {
                        didRequestProactiveCompaction = true
                        try session.send(Self.compactCommand())
                        scheduleProcessTermination(after: .seconds(120))
                        continue
                    }
                    phaseTimeoutTask?.cancel()
                    return
                }
            }
        }
        try parser.finish()
        if didRequestSessionStats { return }
        throw PiAgentRPCClientError.processEndedBeforeAgentEnd
    }

    private func validate(source: ModelSource, prompt: String) throws -> (model: String, prompt: String) {
        guard source.type == .agent, source.enabled else {
            throw PiAgentRPCClientError.invalidModelSource
        }
        let model = source.selectedModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !model.isEmpty else { throw PiAgentRPCClientError.missingModel }
        guard !source.apiKey.isEmpty else { throw PiAgentRPCClientError.missingAPIKey }
        guard let url = URL(string: source.baseURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else {
            throw PiAgentRPCClientError.invalidBaseURL
        }
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { throw PiAgentRPCClientError.emptyPrompt }
        return (model, prompt)
    }

    private func createTemporaryDirectory() throws -> URL {
        let url = temporaryDirectoryRoot
            .appendingPathComponent("tinglan-pi-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            return url
        } catch {
            throw PiAgentRPCClientError.temporaryDirectoryFailed(error.localizedDescription)
        }
    }

    private func writeModelsConfiguration(source: ModelSource, model: String, to url: URL) throws {
        let api: String = source.apiProtocol == .responses ? "openai-responses" : "openai-completions"
        let document = ModelsDocument(providers: [
            Self.providerName: ProviderConfiguration(
                baseUrl: source.baseURL,
                api: api,
                apiKey: Self.apiKeyEnvironmentName,
                authHeader: true,
                models: [ModelConfiguration(id: model, name: model)]
            ),
        ])
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(document).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw PiAgentRPCClientError.temporaryDirectoryFailed(error.localizedDescription)
        }
    }

    private func prepareRuntimeDirectories(_ runtime: PiAgentRuntimeConfiguration) throws {
        do {
            try FileManager.default.createDirectory(
                at: runtime.sessionDirectoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw PiAgentRPCClientError.temporaryDirectoryFailed(error.localizedDescription)
        }
    }

    private static func arguments(
        model: String,
        runtime: PiAgentRuntimeConfiguration?
    ) -> [String] {
        var arguments = [
            "--mode", "rpc",
            "--no-extensions",
            "--no-skills",
            "--no-prompt-templates",
            "--provider", providerName,
            "--model", model,
        ]
        guard let runtime else {
            arguments.insert(contentsOf: ["--no-session", "--no-tools", "--no-context-files"], at: 2)
            return arguments
        }
        arguments.insert(contentsOf: [
            "--session-dir", runtime.sessionDirectoryURL.path,
            "--tools", runtime.enabledTools.joined(separator: ","),
        ], at: 2)
        if runtime.hasPersistedSession {
            arguments.insert("--continue", at: 2)
        }
        for url in runtime.extensionURLs {
            arguments.append(contentsOf: ["--extension", url.path])
        }
        for url in runtime.skillURLs {
            arguments.append(contentsOf: ["--skill", url.path])
        }
        return arguments
    }

    private static func initialCommands(_ prompt: String, sessionName: String?) throws -> Data {
        var data = try commandData([
            "id": "auto-compaction-1",
            "type": "set_auto_compaction",
            "enabled": true,
        ])
        if let sessionName = sessionName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !sessionName.isEmpty {
            data.append(try commandData([
                "id": "session-name-1",
                "type": "set_session_name",
                "name": sessionName,
            ]))
        }
        data.append(try commandData([
            "id": "prompt-1",
            "type": "prompt",
            "message": prompt,
        ]))
        return data
    }

    private static func sessionStatsCommand() throws -> Data {
        try commandData(["id": "session-stats-1", "type": "get_session_stats"])
    }

    private static func compactCommand() throws -> Data {
        try commandData(["id": "proactive-compaction-1", "type": "compact"])
    }

    private static func cancelExtensionUIRequest(id: String) throws -> Data {
        try commandData([
            "id": id,
            "type": "extension_ui_response",
            "cancelled": true,
        ])
    }

    static func shouldCompactProactively(_ stats: PiAgentSessionStats) -> Bool {
        if let tokens = stats.contextTokens,
           let window = stats.contextWindow,
           window > 0 {
            return Double(tokens) / Double(window) >= 0.8
        }
        return (stats.contextPercent ?? 0) >= 80
    }

    private static func commandData(_ object: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(0x0A)
        return data
    }
}

private struct ModelsDocument: Encodable {
    var providers: [String: ProviderConfiguration]
}

private struct ProviderConfiguration: Encodable {
    var baseUrl: String
    var api: String
    var apiKey: String
    var authHeader: Bool
    var models: [ModelConfiguration]
}

private struct ModelConfiguration: Encodable {
    var id: String
    var name: String
}

public struct FoundationPiAgentProcessRunner: PiAgentProcessRunning {
    public init() {}

    public func start(_ request: PiAgentProcessRequest) throws -> any PiAgentProcessSession {
        try FoundationPiAgentProcessSession(request: request)
    }
}

private final class FoundationPiAgentProcessSession: PiAgentProcessSession, @unchecked Sendable {
    private static let maximumStderrBytes = 64 * 1_024

    private let process: Process
    private let input: FileHandle
    private let outputHandle: FileHandle
    private let errorHandle: FileHandle
    private let stateLock = NSLock()
    private var didTerminate = false

    init(request: PiAgentProcessRequest) throws {
        process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        input = inputPipe.fileHandleForWriting
#if canImport(Darwin)
        _ = fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1)
#endif
        outputHandle = outputPipe.fileHandleForReading
        errorHandle = errorPipe.fileHandleForReading
        process.executableURL = request.executableURL
        process.arguments = request.arguments
        process.environment = request.environment
        process.currentDirectoryURL = request.currentDirectoryURL
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        do {
            try process.run()
            try input.write(contentsOf: request.standardInput)
        } catch {
            if process.isRunning { process.terminate() }
            throw PiAgentRPCClientError.launchFailed(error.localizedDescription)
        }
    }

    func output() -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached { [self] in
                let stderrTask = Task.detached { [self] in readStderr() }
                do {
                    while !Task.isCancelled {
                        try Task.checkCancellation()
                        let data = outputHandle.availableData
                        guard !data.isEmpty else { break }
                        continuation.yield(data)
                    }
                    process.waitUntilExit()
                    let stderr = await stderrTask.value
                    if process.terminationStatus != 0 && !wasTerminated() {
                        throw PiAgentRPCClientError.processFailed(
                            exitCode: process.terminationStatus,
                            stderr: stderr
                        )
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { [weak self] _ in
                task.cancel()
                self?.terminate()
            }
        }
    }

    func send(_ data: Data) throws {
        try input.write(contentsOf: data)
    }

    func terminate() {
        let shouldTerminate = stateLock.withLock { () -> Bool in
            guard !didTerminate else { return false }
            didTerminate = true
            return true
        }
        guard shouldTerminate else { return }
        try? input.write(contentsOf: Data("{\"type\":\"abort\"}\n".utf8))
        try? input.close()
        if process.isRunning { process.terminate() }
    }

    private func wasTerminated() -> Bool {
        stateLock.withLock { didTerminate }
    }

    private func readStderr() -> String {
        var retained = Data()
        do {
            while let data = try errorHandle.read(upToCount: 16 * 1_024), !data.isEmpty {
                let remaining = Self.maximumStderrBytes - retained.count
                if remaining > 0 { retained.append(data.prefix(remaining)) }
            }
        } catch {
            return String(decoding: retained, as: UTF8.self)
        }
        return String(decoding: retained, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
