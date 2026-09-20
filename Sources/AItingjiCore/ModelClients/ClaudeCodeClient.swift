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
    case structuredOutputFailedWithDiagnostics(ClaudeCodeDiagnostic)
    case unauthenticated
    case unauthenticatedWithDiagnostics(ClaudeCodeDiagnostic)
    case mcpPermissionDenied([String])
    case mcpPermissionDeniedWithDiagnostics(ClaudeCodeDiagnostic)
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
        case .structuredOutputFailedWithDiagnostics(let diagnostic): diagnostic.summary
        case .unauthenticated: "Claude Code 未认证。"
        case .unauthenticatedWithDiagnostics(let diagnostic): "Claude Code 未认证：\(diagnostic.summary)"
        case .mcpPermissionDenied(let tools): "禅道 MCP 工具未授权：\(tools.joined(separator: ", "))"
        case .mcpPermissionDeniedWithDiagnostics(let diagnostic): diagnostic.summary
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
        case .structuredOutputFailedWithDiagnostics(let diagnostic):
            return diagnostic
        case .unauthenticated:
            return ClaudeCodeDiagnostic(phase: "authentication", summary: "Claude Code 未认证。")
        case .unauthenticatedWithDiagnostics(let diagnostic):
            return diagnostic
        case .mcpPermissionDenied(let tools):
            return ClaudeCodeDiagnostic(
                phase: "permission",
                summary: "禅道 MCP 工具未授权：\(tools.joined(separator: ", "))",
                mcpName: "zentao",
                deniedTools: tools
            )
        case .mcpPermissionDeniedWithDiagnostics(let diagnostic):
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
    public var responsePath: String?
    public var expectedType: String?
    public var actualType: String?
    public var normalizationWarnings: [String]
    public var deniedTools: [String]
    public var structuredOutputRetryPerformed: Bool

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
        possibleMCPConnectionError: Bool = false,
        responsePath: String? = nil,
        expectedType: String? = nil,
        actualType: String? = nil,
        normalizationWarnings: [String] = [],
        deniedTools: [String] = [],
        structuredOutputRetryPerformed: Bool = false
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
        self.responsePath = responsePath
        self.expectedType = expectedType
        self.actualType = actualType
        self.normalizationWarnings = normalizationWarnings
        self.deniedTools = deniedTools
        self.structuredOutputRetryPerformed = structuredOutputRetryPerformed
    }

    private enum CodingKeys: String, CodingKey {
        case phase, summary, executablePath, exitCode, stderr, mcpName
        case configurationSource, timeoutKind, timeoutSeconds, possibleMCPConnectionError
        case responsePath, expectedType, actualType, normalizationWarnings, deniedTools
        case structuredOutputRetryPerformed
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            phase: try values.decode(String.self, forKey: .phase),
            summary: try values.decode(String.self, forKey: .summary),
            executablePath: try values.decodeIfPresent(String.self, forKey: .executablePath),
            exitCode: try values.decodeIfPresent(Int32.self, forKey: .exitCode),
            stderr: try values.decodeIfPresent(String.self, forKey: .stderr) ?? "",
            mcpName: try values.decodeIfPresent(String.self, forKey: .mcpName),
            configurationSource: try values.decodeIfPresent(ClaudeCodeMCPConfigurationSource.self, forKey: .configurationSource),
            timeoutKind: try values.decodeIfPresent(ClaudeCodeTimeoutKind.self, forKey: .timeoutKind),
            timeoutSeconds: try values.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? 600,
            possibleMCPConnectionError: try values.decodeIfPresent(Bool.self, forKey: .possibleMCPConnectionError) ?? false,
            responsePath: try values.decodeIfPresent(String.self, forKey: .responsePath),
            expectedType: try values.decodeIfPresent(String.self, forKey: .expectedType),
            actualType: try values.decodeIfPresent(String.self, forKey: .actualType),
            normalizationWarnings: try values.decodeIfPresent([String].self, forKey: .normalizationWarnings) ?? [],
            deniedTools: try values.decodeIfPresent([String].self, forKey: .deniedTools) ?? [],
            structuredOutputRetryPerformed: try values.decodeIfPresent(Bool.self, forKey: .structuredOutputRetryPerformed) ?? false
        )
    }
}

/// Parameters intentionally scoped to one Claude Code invocation.
public struct ClaudeCodeInvocationOptions: Sendable, Equatable {
    public var allowedTools: [String]
    public var builtInTools: String?
    public var permissionPrompts: String?
    public var jsonSchema: String?

    public init(
        allowedTools: [String] = [],
        builtInTools: String? = nil,
        permissionPrompts: String? = nil,
        jsonSchema: String? = nil
    ) {
        self.allowedTools = allowedTools
        self.builtInTools = builtInTools
        self.permissionPrompts = permissionPrompts
        self.jsonSchema = jsonSchema
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
    public var allowedTools: [String]
    public var builtInTools: String?
    public var permissionPrompts: String?
    public var jsonSchema: String?

    public init(
        prompt: String,
        workingDirectory: URL,
        executableURL: URL? = nil,
        mcpConfigURL: URL?,
        maxTurns: Int,
        model: String?,
        permissionMode: String?,
        timeout: Duration = .seconds(600),
        allowedTools: [String] = [],
        builtInTools: String? = nil,
        permissionPrompts: String? = nil,
        jsonSchema: String? = nil
    ) {
        self.prompt = prompt; self.workingDirectory = workingDirectory; self.executableURL = executableURL; self.mcpConfigURL = mcpConfigURL
        self.maxTurns = maxTurns; self.model = model; self.permissionMode = permissionMode; self.timeout = timeout
        self.allowedTools = allowedTools; self.builtInTools = builtInTools
        self.permissionPrompts = permissionPrompts; self.jsonSchema = jsonSchema
    }
}

public struct ClaudeCodeClient: Sendable {
    public typealias ResponseGenerator = @Sendable (String, URL, URL?, Int) async throws -> String
    public typealias ConfiguredResponseGenerator = @Sendable (String, URL, URL?, Int, ClaudeCodeInvocationOptions) async throws -> String
    public typealias ProcessRunner = @Sendable (ClaudeCodeProcessConfiguration) async throws -> String
    private let runner: ProcessRunner

    public init(responseGenerator: @escaping ResponseGenerator) {
        self.runner = { configuration in
            try await responseGenerator(configuration.prompt, configuration.workingDirectory, configuration.mcpConfigURL, configuration.maxTurns)
        }
    }

    public init(configuredResponseGenerator: @escaping ConfiguredResponseGenerator) {
        self.runner = { configuration in
            try await configuredResponseGenerator(
                configuration.prompt,
                configuration.workingDirectory,
                configuration.mcpConfigURL,
                configuration.maxTurns,
                ClaudeCodeInvocationOptions(
                    allowedTools: configuration.allowedTools,
                    builtInTools: configuration.builtInTools,
                    permissionPrompts: configuration.permissionPrompts,
                    jsonSchema: configuration.jsonSchema
                )
            )
        }
    }

    public init(processRunner: @escaping ProcessRunner = ClaudeCodeClient.defaultResponse) {
        self.runner = processRunner
    }

    public func run(
        prompt: String,
        workingDirectory: URL,
        mcpConfigURL: URL? = nil,
        maxTurns: Int = 8,
        model: String? = nil,
        permissionMode: String? = nil,
        timeout: Duration = .seconds(600),
        options: ClaudeCodeInvocationOptions = ClaudeCodeInvocationOptions()
    ) async throws -> String {
        let configuration = ClaudeCodeProcessConfiguration(
            prompt: prompt,
            workingDirectory: workingDirectory,
            mcpConfigURL: mcpConfigURL,
            maxTurns: maxTurns,
            model: model,
            permissionMode: permissionMode,
            timeout: timeout,
            allowedTools: options.allowedTools,
            builtInTools: options.builtInTools,
            permissionPrompts: options.permissionPrompts,
            jsonSchema: options.jsonSchema
        )
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
        if !configuration.allowedTools.isEmpty {
            args += ["--allowed-tools", configuration.allowedTools.joined(separator: ",")]
        }
        if let builtInTools = configuration.builtInTools {
            args += ["--tools", builtInTools]
        }
        if let permissionPrompts = configuration.permissionPrompts, !permissionPrompts.isEmpty {
            args += ["--permission-prompts", permissionPrompts]
        }
        if let jsonSchema = configuration.jsonSchema, !jsonSchema.isEmpty {
            args += ["--json-schema", jsonSchema]
        }
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
            if let deniedTools = Self.permissionDeniedTools(in: message), !deniedTools.isEmpty {
                throw ClaudeCodeClientError.mcpPermissionDeniedWithDiagnostics(
                    ClaudeCodeDiagnostic(
                        phase: "permission",
                        summary: "禅道 MCP 工具未授权：\(deniedTools.joined(separator: ", "))",
                        executablePath: executable.path,
                        exitCode: process.terminationStatus,
                        stderr: ClaudeCodeClient.redact(message),
                        mcpName: "zentao",
                        deniedTools: deniedTools
                    )
                )
            }
            if Self.looksLikeStructuredOutputFailure(message) {
                throw ClaudeCodeClientError.structuredOutputFailedWithDiagnostics(
                    ClaudeCodeDiagnostic(
                        phase: "parse.schema",
                        summary: "Claude Code 结构化输出未通过 JSON Schema 校验。",
                        executablePath: executable.path,
                        exitCode: process.terminationStatus,
                        stderr: ClaudeCodeClient.redact(message),
                        mcpName: "zentao"
                    )
                )
            }
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
            if let deniedTools = Self.permissionDeniedTools(in: output), !deniedTools.isEmpty {
                throw ClaudeCodeClientError.mcpPermissionDeniedWithDiagnostics(
                    ClaudeCodeDiagnostic(
                        phase: "permission",
                        summary: "禅道 MCP 工具未授权：\(deniedTools.joined(separator: ", "))",
                        executablePath: executable.path,
                        stderr: ClaudeCodeClient.redact(error),
                        mcpName: "zentao",
                        deniedTools: deniedTools
                    )
                )
            }
            let response = try parseResponse(output)
            return response
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

    private static func looksLikeStructuredOutputFailure(_ value: String) -> Bool {
        let lowercased = value.lowercased()
        return lowercased.contains("structured output")
            || lowercased.contains("json schema")
            || lowercased.contains("schema validation")
    }

    private static func permissionDeniedTools(in value: String) -> [String]? {
        let lowercased = value.lowercased()
        let markers = ["requested permissions", "haven't granted", "permission denied", "not authorized", "未授权"]
        guard markers.contains(where: { lowercased.contains($0) }) else { return nil }
        let pattern = #"mcp__zentao__[A-Za-z0-9_]+"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        var names: [String] = []
        expression.enumerateMatches(in: value, range: range) { match, _, _ in
            guard let match, let matchRange = Range(match.range, in: value) else { return }
            let name = String(value[matchRange])
            if !names.contains(name) { names.append(name) }
        }
        return names
    }

    /// Validates Claude Code's JSON envelope while preserving raw structured payloads.
    public static func parseResponse(_ output: String) throws -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let jsonText: String
        if let first = trimmed.firstIndex(of: "{"), let last = trimmed.lastIndex(of: "}") {
            jsonText = String(trimmed[first...last])
        } else {
            jsonText = trimmed
        }
        guard let data = jsonText.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) else { throw ClaudeCodeClientError.invalidJSON }
        if let dictionary = object as? [String: Any], let structuredOutput = dictionary["structured_output"], !(structuredOutput is NSNull), JSONSerialization.isValidJSONObject(structuredOutput) {
            let data = try JSONSerialization.data(withJSONObject: structuredOutput, options: [.sortedKeys])
            return String(data: data, encoding: .utf8) ?? output
        }
        if let dictionary = object as? [String: Any], let result = dictionary["result"] as? String { return result }
        if let dictionary = object as? [String: Any], let content = dictionary["content"] as? String { return content }
        return output
    }
}
