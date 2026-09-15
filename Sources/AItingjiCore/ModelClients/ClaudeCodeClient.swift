import Foundation

public enum ClaudeCodeClientError: Error, Equatable, LocalizedError, Sendable {
    case executableNotFound
    case launchFailed(String)
    case timedOut
    case processFailed(Int32, String)
    case invalidJSON
    case unauthenticated
    case mcpUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .executableNotFound: "未找到 Claude Code 可执行文件。"
        case .launchFailed(let message): "Claude Code 启动失败：\(Self.redacted(message))"
        case .timedOut: "Claude Code 请求超时。"
        case .processFailed(let code, let message): message.isEmpty ? "Claude Code 进程失败（\(code)）。" : "Claude Code 进程失败（\(code)）：\(Self.redacted(message))"
        case .invalidJSON: "Claude Code 未返回有效 JSON。"
        case .unauthenticated: "Claude Code 未认证。"
        case .mcpUnavailable(let message): "MCP 服务不可用：\(Self.redacted(message))"
        }
    }

    private static func redacted(_ value: String) -> String {
        var result = value
        result = result.replacingOccurrences(of: #"(?i)(bearer\s+)[^\s,]+"#, with: "$1[已隐藏]", options: .regularExpression)
        result = result.replacingOccurrences(of: #"(?i)(token|api[-_]?key|authorization)[=:]\s*[^\s,]+"#, with: "$1=[已隐藏]", options: .regularExpression)
        return result
    }
}

public struct ClaudeCodeProcessConfiguration: Sendable, Equatable {
    public var prompt: String
    public var workingDirectory: URL
    public var mcpConfigURL: URL?
    public var maxTurns: Int
    public var model: String?
    public var permissionMode: String?
    public var timeout: Duration

    public init(prompt: String, workingDirectory: URL, mcpConfigURL: URL?, maxTurns: Int, model: String?, permissionMode: String?, timeout: Duration = .seconds(120)) {
        self.prompt = prompt; self.workingDirectory = workingDirectory; self.mcpConfigURL = mcpConfigURL
        self.maxTurns = maxTurns; self.model = model; self.permissionMode = permissionMode; self.timeout = timeout
    }
}

public struct ClaudeCodeClient: Sendable {
    public typealias ResponseGenerator = @Sendable (String, URL, URL?, Int) async throws -> String
    public typealias ProcessRunner = @Sendable (ClaudeCodeProcessConfiguration) async throws -> String
    private let runner: ProcessRunner

    public init(responseGenerator: @escaping ResponseGenerator) {
        self.runner = { configuration in
            try await responseGenerator(configuration.prompt, configuration.workingDirectory, configuration.mcpConfigURL, configuration.maxTurns)
        }
    }

    public init(processRunner: @escaping ProcessRunner = ClaudeCodeClient.defaultResponse) {
        self.runner = processRunner
    }

    public func run(prompt: String, workingDirectory: URL, mcpConfigURL: URL? = nil, maxTurns: Int = 8, model: String? = nil, permissionMode: String? = nil, timeout: Duration = .seconds(120)) async throws -> String {
        let configuration = ClaudeCodeProcessConfiguration(prompt: prompt, workingDirectory: workingDirectory, mcpConfigURL: mcpConfigURL, maxTurns: maxTurns, model: model, permissionMode: permissionMode, timeout: timeout)
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await self.runner(configuration) }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ClaudeCodeClientError.timedOut
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    public static func defaultResponse(_ configuration: ClaudeCodeProcessConfiguration) async throws -> String {
        let pathCandidates = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init).map { URL(fileURLWithPath: $0).appendingPathComponent("claude") }
        let urls = pathCandidates + [URL(fileURLWithPath: "/opt/homebrew/bin/claude"), URL(fileURLWithPath: "/usr/local/bin/claude"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude")]
        guard let executable = urls.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else { throw ClaudeCodeClientError.executableNotFound }
        var args = ["-p", configuration.prompt, "--output-format", "json", "--max-turns", String(max(1, configuration.maxTurns))]
        if let model = configuration.model, !model.isEmpty { args += ["--model", model] }
        if let permissionMode = configuration.permissionMode, !permissionMode.isEmpty { args += ["--permission-mode", permissionMode] }
        if let mcp = configuration.mcpConfigURL { args += ["--mcp-config", mcp.path] }

        let process = Process(); process.executableURL = executable; process.arguments = args; process.currentDirectoryURL = configuration.workingDirectory
        let stdout = Pipe(); let stderr = Pipe(); process.standardOutput = stdout; process.standardError = stderr
        do { try process.run() } catch { throw ClaudeCodeClientError.launchFailed(error.localizedDescription) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async { process.waitUntilExit(); continuation.resume() }
                }
            }
            group.addTask {
                try await Task.sleep(for: configuration.timeout)
                if process.isRunning { process.terminate() }
                throw ClaudeCodeClientError.timedOut
            }
            defer { group.cancelAll() }
            _ = try await group.next()!
        }
        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let error = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            let stderrMessage = error.trimmingCharacters(in: .whitespacesAndNewlines)
            let stdoutMessage = output.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = [stderrMessage, stdoutMessage].filter { !$0.isEmpty }.joined(separator: "\n")
            if message.localizedCaseInsensitiveContains("auth") || message.localizedCaseInsensitiveContains("login") { throw ClaudeCodeClientError.unauthenticated }
            if message.localizedCaseInsensitiveContains("mcp") || message.localizedCaseInsensitiveContains("ECONN") { throw ClaudeCodeClientError.mcpUnavailable(message) }
            throw ClaudeCodeClientError.processFailed(process.terminationStatus, message)
        }
        return try parseResponse(output)
    }

    /// Validates Claude Code's JSON envelope while preserving raw structured payloads.
    static func parseResponse(_ output: String) throws -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let jsonText: String
        if let first = trimmed.firstIndex(of: "{"), let last = trimmed.lastIndex(of: "}") {
            jsonText = String(trimmed[first...last])
        } else {
            jsonText = trimmed
        }
        guard let data = jsonText.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) else { throw ClaudeCodeClientError.invalidJSON }
        if let dictionary = object as? [String: Any], let result = dictionary["result"] as? String { return result }
        if let dictionary = object as? [String: Any], let content = dictionary["content"] as? String { return content }
        return output
    }
}
