import Foundation

public enum ClaudeCodeClientError: Error, Equatable, LocalizedError, Sendable {
    case executableNotFound
    case launchFailed(String)
    case timedOut
    case processFailed(Int32, String)
    case invalidJSON

    public var errorDescription: String? {
        switch self {
        case .executableNotFound: "未找到 Claude Code 可执行文件。"
        case .launchFailed(let message): "Claude Code 启动失败：\(message)"
        case .timedOut: "Claude Code 请求超时。"
        case .processFailed(let code, let message): message.isEmpty ? "Claude Code 进程失败（\(code)）。" : "Claude Code 进程失败（\(code)）：\(message)"
        case .invalidJSON: "Claude Code 未返回有效 JSON。"
        }
    }
}

public struct ClaudeCodeClient: Sendable {
    public typealias ResponseGenerator = @Sendable (String, URL, URL?, Int) async throws -> String
    private let responseGenerator: ResponseGenerator

    public init(responseGenerator: @escaping ResponseGenerator = ClaudeCodeClient.defaultResponse) {
        self.responseGenerator = responseGenerator
    }

    public func run(prompt: String, workingDirectory: URL, mcpConfigURL: URL? = nil, maxTurns: Int = 8) async throws -> String {
        try await responseGenerator(prompt, workingDirectory, mcpConfigURL, maxTurns)
    }

    public static func defaultResponse(prompt: String, workingDirectory: URL, mcpConfigURL: URL?, maxTurns: Int) async throws -> String {
        let candidates = ProcessInfo.processInfo.environment["PATH"].map { $0.split(separator: ":").map(String.init).map { URL(fileURLWithPath: $0).appendingPathComponent("claude") } } ?? []
        let urls = candidates + [URL(fileURLWithPath: "/opt/homebrew/bin/claude"), URL(fileURLWithPath: "/usr/local/bin/claude"), URL(fileURLWithPath: FileManager.default.homeDirectoryForCurrentUser.path).appendingPathComponent(".local/bin/claude")]
        guard let executable = urls.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else { throw ClaudeCodeClientError.executableNotFound }
        var args = ["-p", prompt, "--output-format", "json", "--max-turns", String(max(1, maxTurns))]
        if let mcpConfigURL { args += ["--mcp-config", mcpConfigURL.path] }
        let process = Process()
        process.executableURL = executable
        process.arguments = args
        process.currentDirectoryURL = workingDirectory
        let stdout = Pipe(); let stderr = Pipe()
        process.standardOutput = stdout; process.standardError = stderr
        do { try process.run() } catch { throw ClaudeCodeClientError.launchFailed(error.localizedDescription) }
        process.waitUntilExit()
        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let error = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else { throw ClaudeCodeClientError.processFailed(process.terminationStatus, error.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard let data = output.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) else { throw ClaudeCodeClientError.invalidJSON }
        if let dictionary = object as? [String: Any], let result = dictionary["result"] as? String { return result }
        if let dictionary = object as? [String: Any], let content = dictionary["content"] as? String { return content }
        return output
    }
}
