import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum ClaudeCodeTimeoutKind: String, Codable, Equatable, Sendable {
    case modelCall
    case mcpQuery
    case overallMatch

    public var displayName: String {
        switch self {
        case .modelCall: "模型调用超时"
        case .mcpQuery: "MCP 查询超时"
        case .overallMatch: "整体匹配超时"
        }
    }
}

public enum ClaudeCodeClientError: Error, Equatable, LocalizedError, Sendable {
    case executableNotFound
    case launchFailed(String)
    case launchFailedWithDiagnostics(ClaudeCodeDiagnostic)
    case timedOut
    case timedOutWithDiagnostics(ClaudeCodeDiagnostic)
    case processFailed(Int32, String)
    case processFailedWithDiagnostics(ClaudeCodeDiagnostic)
    case invalidJSON
    case invalidJSONWithDiagnostics(ClaudeCodeDiagnostic)
    case unauthenticated
    case unauthenticatedWithDiagnostics(ClaudeCodeDiagnostic)
    case mcpUnavailable(String)
    case mcpUnavailableWithDiagnostics(ClaudeCodeDiagnostic)

    public var errorDescription: String? {
        switch self {
        case .executableNotFound: "未找到 Claude Code 可执行文件。"
        case .launchFailed(let message): "Claude Code 启动失败：\(Self.redacted(message))"
        case .launchFailedWithDiagnostics(let diagnostic): diagnostic.summary
        case .timedOut: "整体匹配超时：Claude Code 请求未完成。"
        case .timedOutWithDiagnostics(let diagnostic): "Claude Code 请求超时：\(diagnostic.summary)"
        case .processFailed(let code, let message): message.isEmpty ? "Claude Code 进程失败（\(code)）。" : "Claude Code 进程失败（\(code)）：\(Self.redacted(message))"
        case .processFailedWithDiagnostics(let diagnostic): "Claude Code 进程失败：\(diagnostic.summary)"
        case .invalidJSON: "Claude Code 未返回有效 JSON。"
        case .invalidJSONWithDiagnostics(let diagnostic): "Claude Code 输出解析失败：\(diagnostic.summary)"
        case .unauthenticated: "Claude Code 未认证。"
        case .unauthenticatedWithDiagnostics(let diagnostic): "Claude Code 未认证：\(diagnostic.summary)"
        case .mcpUnavailable(let message): "MCP 服务不可用：\(Self.redacted(message))"
        case .mcpUnavailableWithDiagnostics(let diagnostic): "MCP 服务不可用：\(diagnostic.summary)"
        }
    }

    public var diagnostic: ClaudeCodeDiagnostic {
        switch self {
        case .executableNotFound:
            return ClaudeCodeDiagnostic(phase: "executable", summary: "未找到 Claude Code 可执行文件。")
        case .launchFailed(let message):
            return ClaudeCodeDiagnostic(phase: "launch", summary: "Claude Code 启动失败：\(Self.redacted(message))", stderr: Self.redacted(message))
        case .launchFailedWithDiagnostics(let diagnostic):
            return diagnostic
        case .timedOut:
            return ClaudeCodeDiagnostic(phase: "timeout.overall_match", summary: "整体匹配超时。", timeoutKind: .overallMatch, timeoutSeconds: 600)
        case .timedOutWithDiagnostics(let diagnostic):
            return diagnostic
        case .processFailed(let code, let message):
            return ClaudeCodeDiagnostic(phase: "process", summary: "Claude Code 进程退出（\(code)）。", exitCode: code, stderr: Self.redacted(message), possibleMCPConnectionError: Self.isMCPMessage(message))
        case .processFailedWithDiagnostics(let diagnostic):
            return diagnostic
        case .invalidJSON:
            return ClaudeCodeDiagnostic(phase: "parse", summary: "Claude Code 未返回有效 JSON。")
        case .invalidJSONWithDiagnostics(let diagnostic):
            return diagnostic
        case .unauthenticated:
            return ClaudeCodeDiagnostic(phase: "authentication", summary: "Claude Code 未认证。")
        case .unauthenticatedWithDiagnostics(let diagnostic):
            return diagnostic
        case .mcpUnavailable(let message):
            return ClaudeCodeDiagnostic(phase: "mcp", summary: "MCP 服务不可用。", stderr: Self.redacted(message), possibleMCPConnectionError: true)
        case .mcpUnavailableWithDiagnostics(let diagnostic):
            return diagnostic
        }
    }

    private static func isMCPMessage(_ value: String) -> Bool {
        value.localizedCaseInsensitiveContains("mcp") || value.localizedCaseInsensitiveContains("ECONN") || value.localizedCaseInsensitiveContains("401")
    }

    private static func redacted(_ value: String) -> String {
        var result = value
        result = result.replacingOccurrences(of: #"(?i)(bearer\s+)[^\s,]+"#, with: "$1[已隐藏]", options: .regularExpression)
        result = result.replacingOccurrences(of: #"(?i)(token|api[-_]?key|authorization)[=:]\s*[^\s,]+"#, with: "$1=[已隐藏]", options: .regularExpression)
        return result
    }
}

public struct ClaudeCodeDiagnostic: Codable, Equatable, Sendable {
    public var phase: String
    public var summary: String
    public var executablePath: String?
    public var exitCode: Int32?
    public var stderr: String
    public var mcpName: String?
    public var configurationSource: ClaudeCodeMCPConfigurationSource?
    public var timeoutKind: ClaudeCodeTimeoutKind?
    public var timeoutSeconds: Int
    public var possibleMCPConnectionError: Bool

    public init(
        phase: String,
        summary: String,
        executablePath: String? = nil,
        exitCode: Int32? = nil,
        stderr: String = "",
        mcpName: String? = nil,
        configurationSource: ClaudeCodeMCPConfigurationSource? = nil,
        timeoutKind: ClaudeCodeTimeoutKind? = nil,
        timeoutSeconds: Int = 600,
        possibleMCPConnectionError: Bool = false
    ) {
        self.phase = phase
        self.summary = summary
        self.executablePath = executablePath
        self.exitCode = exitCode
        self.stderr = stderr
        self.mcpName = mcpName
        self.configurationSource = configurationSource
        self.timeoutKind = timeoutKind
        self.timeoutSeconds = timeoutSeconds
        self.possibleMCPConnectionError = possibleMCPConnectionError
    }
}

public struct ClaudeCodeProcessConfiguration: Sendable, Equatable {
    public var prompt: String
    public var workingDirectory: URL
    /// 仅用于受控测试或诊断；生产调用留空并按 PATH/标准安装路径解析。
    public var executableURL: URL?
    public var mcpConfigURL: URL?
    public var maxTurns: Int
    public var model: String?
    public var permissionMode: String?
    public var timeout: Duration

    public init(prompt: String, workingDirectory: URL, executableURL: URL? = nil, mcpConfigURL: URL?, maxTurns: Int, model: String?, permissionMode: String?, timeout: Duration = .seconds(600)) {
        self.prompt = prompt; self.workingDirectory = workingDirectory; self.executableURL = executableURL; self.mcpConfigURL = mcpConfigURL
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

    public func run(prompt: String, workingDirectory: URL, mcpConfigURL: URL? = nil, maxTurns: Int = 8, model: String? = nil, permissionMode: String? = nil, timeout: Duration = .seconds(600)) async throws -> String {
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
        guard let executable = configuration.executableURL ?? executableURL() else { throw ClaudeCodeClientError.executableNotFound }
        var args = ["-p", configuration.prompt, "--output-format", "json", "--max-turns", String(max(1, configuration.maxTurns))]
        if let model = configuration.model, !model.isEmpty { args += ["--model", model] }
        if let permissionMode = configuration.permissionMode, !permissionMode.isEmpty { args += ["--permission-mode", permissionMode] }
        if let mcp = configuration.mcpConfigURL { args += ["--mcp-config", mcp.path] }

        do {
            try FileManager.default.createDirectory(
                at: configuration.workingDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw ClaudeCodeClientError.launchFailedWithDiagnostics(
                ClaudeCodeDiagnostic(
                    phase: "working_directory",
                    summary: "Claude Code 工作目录不可用：\(error.localizedDescription)",
                    executablePath: executable.path,
                    mcpName: "zentao"
                )
            )
        }

        let process = Process(); process.executableURL = executable; process.arguments = args; process.currentDirectoryURL = configuration.workingDirectory
        let stdout = Pipe(); let stderr = Pipe(); process.standardOutput = stdout; process.standardError = stderr
        do {
            try process.run()
        } catch {
            throw ClaudeCodeClientError.launchFailedWithDiagnostics(
                ClaudeCodeDiagnostic(
                    phase: "launch",
                    summary: "Claude Code 启动失败：\(error.localizedDescription)",
                    executablePath: executable.path,
                    mcpName: "zentao"
                )
            )
        }
        // 开始执行后立即并行读取两个管道，避免 Claude Code 的日志或结构化结果填满
        // Pipe 缓冲区，导致 waitUntilExit() 永远等不到进程结束。
        let stdoutReader = Task.detached(priority: .utility) {
            stdout.fileHandleForReading.readDataToEndOfFile()
        }
        let stderrReader = Task.detached(priority: .utility) {
            stderr.fileHandleForReading.readDataToEndOfFile()
        }
        let waitResult = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask {
                while process.isRunning && !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(25))
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: configuration.timeout)
                return true
            }
            defer { group.cancelAll() }
            return await group.next() ?? true
        }
        if Task.isCancelled {
            if process.isRunning {
                process.terminate()
                #if canImport(Darwin)
                if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
                #endif
            }
            throw CancellationError()
        }
        if waitResult {
            if process.isRunning {
                process.terminate()
                #if canImport(Darwin)
                // Claude Code 可能是 shell/Node 包装器，SIGTERM 只结束外层等待进程。
                // 随后用 SIGKILL 确保硬超时不会被子进程拖住；读取端会在下方关闭。
                if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
                #endif
            }
            if process.isRunning {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async { process.waitUntilExit(); continuation.resume() }
                }
            }
            throw ClaudeCodeClientError.timedOutWithDiagnostics(
                ClaudeCodeDiagnostic(
                    phase: "timeout.mcp_query",
                    summary: "MCP 查询超时：Claude Code 在 \(configuration.timeout.components.seconds) 秒内未完成。",
                    executablePath: executable.path,
                    mcpName: "zentao",
                    timeoutKind: .mcpQuery,
                    timeoutSeconds: max(1, Int(configuration.timeout.components.seconds))
                )
            )
        }
        let output = String(data: await stdoutReader.value, encoding: .utf8) ?? ""
        let error = String(data: await stderrReader.value, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            let stderrMessage = error.trimmingCharacters(in: .whitespacesAndNewlines)
            let stdoutMessage = output.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = [stderrMessage, stdoutMessage].filter { !$0.isEmpty }.joined(separator: "\n")
            if message.localizedCaseInsensitiveContains("mcp") || message.localizedCaseInsensitiveContains("ECONN") || message.localizedCaseInsensitiveContains("401") {
                throw ClaudeCodeClientError.mcpUnavailableWithDiagnostics(
                    ClaudeCodeDiagnostic(phase: "mcp", summary: "禅道 MCP 连接或认证失败。", executablePath: executable.path, exitCode: process.terminationStatus, stderr: ClaudeCodeClient.redact(message), mcpName: "zentao", possibleMCPConnectionError: true)
                )
            }
            if message.localizedCaseInsensitiveContains("auth") || message.localizedCaseInsensitiveContains("login") {
                throw ClaudeCodeClientError.unauthenticatedWithDiagnostics(
                    ClaudeCodeDiagnostic(phase: "authentication", summary: "Claude Code 未认证。", executablePath: executable.path, exitCode: process.terminationStatus, stderr: ClaudeCodeClient.redact(message))
                )
            }
            throw ClaudeCodeClientError.processFailedWithDiagnostics(
                ClaudeCodeDiagnostic(
                    phase: "process",
                    summary: "Claude Code 进程退出（\(process.terminationStatus)）。",
                    executablePath: executable.path,
                    exitCode: process.terminationStatus,
                    stderr: ClaudeCodeClient.redact(message),
                    mcpName: "zentao",
                    possibleMCPConnectionError: ClaudeCodeClient.looksLikeMCPMessage(message)
                )
            )
        }
        do {
            return try parseResponse(output)
        } catch ClaudeCodeClientError.invalidJSON {
            throw ClaudeCodeClientError.invalidJSONWithDiagnostics(
                ClaudeCodeDiagnostic(
                    phase: "parse",
                    summary: "Claude Code 未返回有效 JSON。",
                    executablePath: executable.path,
                    stderr: ClaudeCodeClient.redact(error),
                    mcpName: "zentao"
                )
            )
        }
    }

    public static func executableURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let pathCandidates = (environment["PATH"] ?? "").split(separator: ":").map(String.init).map { URL(fileURLWithPath: $0).appendingPathComponent("claude") }
        let urls = pathCandidates + [URL(fileURLWithPath: "/opt/homebrew/bin/claude"), URL(fileURLWithPath: "/usr/local/bin/claude"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude")]
        return urls.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
    }

    private static func redact(_ value: String) -> String {
        var result = value
        result = result.replacingOccurrences(of: #"(?i)(bearer\s+)[^\s,]+"#, with: "$1[已隐藏]", options: .regularExpression)
        result = result.replacingOccurrences(of: #"(?i)(token|api[-_]?key|authorization)[=:]\s*[^\s,]+"#, with: "$1=[已隐藏]", options: .regularExpression)
        return result
    }

    private static func looksLikeMCPMessage(_ value: String) -> Bool {
        value.localizedCaseInsensitiveContains("mcp")
            || value.localizedCaseInsensitiveContains("ECONN")
            || value.localizedCaseInsensitiveContains("401")
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
