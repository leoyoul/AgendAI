import Foundation

public enum DiarizationValue: Codable, Equatable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

public struct DiarizationSidecarRequest: Codable, Equatable, Sendable {
    public var id: String
    public var method: String
    public var params: [String: DiarizationValue]

    public init(id: String, method: String, params: [String: DiarizationValue] = [:]) {
        self.id = id
        self.method = method
        self.params = params
    }
}

public struct DiarizationHealth: Equatable, Sendable {
    public var status: String
    public var models: [String]

    public init(status: String, models: [String]) {
        self.status = status
        self.models = models
    }
}

public enum DiarizationClientError: Error, Equatable, LocalizedError, Sendable {
    case transport(String)
    case invalidResponse
    case sidecar(String)

    public var errorDescription: String? {
        switch self {
        case .transport(let message):
            return "说话人分离 sidecar 通信失败：\(message)"
        case .invalidResponse:
            return "说话人分离 sidecar 返回格式无效。"
        case .sidecar(let message):
            return message
        }
    }
}

public protocol DiarizationClient: Sendable {
    func health() async throws -> DiarizationHealth
    func preload(huggingFaceToken: String?) async throws -> DiarizationHealth
    func diarizeFile(path: String, speakerConstraint: DiarizationSpeakerConstraint) async throws -> [DiarizationTurn]
    func diarizeWindow(path: String, startMs: Int, endMs: Int, speakerConstraint: DiarizationSpeakerConstraint) async throws -> [DiarizationTurn]
    func embedSpeaker(path: String, startMs: Int, endMs: Int) async throws -> VoiceprintResult
}

public struct FinalDiarizationWindowBatchRequest: Equatable, Codable, Sendable {
    public var index: Int
    public var startMs: Int
    public var endMs: Int
    public var acceptedStartMs: Int
    public var acceptedEndMs: Int

    public init(index: Int, startMs: Int, endMs: Int, acceptedStartMs: Int, acceptedEndMs: Int) {
        self.index = index
        self.startMs = startMs
        self.endMs = endMs
        self.acceptedStartMs = acceptedStartMs
        self.acceptedEndMs = acceptedEndMs
    }
}

public struct FinalDiarizationBatchResult: Equatable, Sendable {
    public var fullTurns: [DiarizationTurn]
    public var windowedTurns: [WindowedDiarizationTurn]
    public var embeddingsByLocalSpeakerKey: [String: VoiceprintResult]

    public init(
        fullTurns: [DiarizationTurn],
        windowedTurns: [WindowedDiarizationTurn],
        embeddingsByLocalSpeakerKey: [String: VoiceprintResult]
    ) {
        self.fullTurns = fullTurns
        self.windowedTurns = windowedTurns
        self.embeddingsByLocalSpeakerKey = embeddingsByLocalSpeakerKey
    }
}

public extension DiarizationClient {
    func diarizeFile(path: String) async throws -> [DiarizationTurn] {
        try await diarizeFile(path: path, speakerConstraint: .automatic)
    }

    func diarizeWindow(path: String, startMs: Int, endMs: Int) async throws -> [DiarizationTurn] {
        try await diarizeWindow(path: path, startMs: startMs, endMs: endMs, speakerConstraint: .automatic)
    }
}

public protocol DiarizationSidecarTransport: Sendable {
    func send(_ request: DiarizationSidecarRequest) async throws -> String
}

public struct ProcessDiarizationSidecarTransport: DiarizationSidecarTransport {
    public var executableURL: URL
    public var arguments: [String]
    public var workingDirectoryURL: URL?
    public var environment: [String: String]
    public var missingPythonMessage: String?
    public var sidecarErrorMessageTransform: @Sendable (String) -> String

    public init(
        executableURL: URL,
        arguments: [String],
        workingDirectoryURL: URL? = nil,
        environment: [String: String] = [:],
        missingPythonMessage: String? = nil,
        sidecarErrorMessageTransform: @escaping @Sendable (String) -> String = { $0 }
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.workingDirectoryURL = workingDirectoryURL
        self.environment = environment
        self.missingPythonMessage = missingPythonMessage
        self.sidecarErrorMessageTransform = sidecarErrorMessageTransform
    }

    public init(configuration: DiarizationSidecarLaunchConfiguration) {
        self.executableURL = configuration.executableURL
        self.arguments = configuration.arguments
        self.workingDirectoryURL = configuration.workingDirectoryURL
        self.environment = configuration.environment
        self.missingPythonMessage = configuration.missingPythonMessage
        self.sidecarErrorMessageTransform = configuration.sidecarErrorMessageTransform
    }

    public func send(_ request: DiarizationSidecarRequest) async throws -> String {
        let executableURL = self.executableURL
        let arguments = self.arguments
        let workingDirectoryURL = self.workingDirectoryURL
        let environment = self.environment
        let missingPythonMessage = self.missingPythonMessage
        let sidecarErrorMessageTransform = self.sidecarErrorMessageTransform

        let task = Task.detached(priority: .utility) { () throws -> String in
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments
            if let workingDirectoryURL {
                do {
                    try FileManager.default.createDirectory(
                        at: workingDirectoryURL,
                        withIntermediateDirectories: true
                    )
                } catch {
                    throw DiarizationClientError.transport("无法创建说话人分离工作目录：\(error.localizedDescription)")
                }
                process.currentDirectoryURL = workingDirectoryURL
            }
            if !environment.isEmpty {
                process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
            }

            let input = Pipe()
            let output = Pipe()
            let error = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = error

            do {
                try process.run()
            } catch {
                throw DiarizationClientError.transport(missingPythonMessage ?? error.localizedDescription)
            }

            // 用 Swift 5.10+ 支持的 throwing write，捕获 pipe 断连异常避免 NSException 直接干掉进程。
            do {
                let payload = try JSONEncoder().encode(request)
                if #available(macOS 13.0, *) {
                    try input.fileHandleForWriting.write(contentsOf: payload)
                    try input.fileHandleForWriting.write(contentsOf: Data([0x0A]))
                } else {
                    input.fileHandleForWriting.write(payload)
                    input.fileHandleForWriting.write(Data([0x0A]))
                }
                try? input.fileHandleForWriting.close()
            } catch {
                if process.isRunning { process.terminate() }
                throw DiarizationClientError.transport(
                    sidecarErrorMessageTransform("sidecar 输入管道写入失败：\(error.localizedDescription)")
                )
            }

            let outputReader = PipeDataReader(fileHandle: output.fileHandleForReading)
            let errorReader = PipeDataReader(fileHandle: error.fileHandleForReading)
            outputReader.start()
            errorReader.start()
            // 循环等进程结束，同时响应上层取消。
            while process.isRunning {
                if Task.isCancelled {
                    process.terminate()
                    // 给子进程 500ms 优雅退出机会，超时后 kill。
                    for _ in 0..<50 {
                        if !process.isRunning { break }
                        try? await Task.sleep(nanoseconds: 10_000_000)
                    }
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    _ = outputReader.finish()
                    _ = errorReader.finish()
                    throw CancellationError()
                }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            let outputData = outputReader.finish()
            let errorData = errorReader.finish()
            guard process.terminationStatus == 0 else {
                let message = String(decoding: errorData, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let fallback = "sidecar 进程退出：\(process.terminationStatus)"
                throw DiarizationClientError.transport(sidecarErrorMessageTransform(message.isEmpty ? fallback : message))
            }
            guard let line = String(decoding: outputData, as: UTF8.self)
                .split(separator: "\n", maxSplits: 1)
                .first
                .map(String.init) else {
                throw DiarizationClientError.invalidResponse
            }
            return line
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

private final class PipeDataReader: @unchecked Sendable {
    private let fileHandle: FileHandle
    private var data = Data()
    private let lock = NSLock()
    private let group = DispatchGroup()

    init(fileHandle: FileHandle) {
        self.fileHandle = fileHandle
    }

    func start() {
        group.enter()
        DispatchQueue.global(qos: .utility).async { [fileHandle] in
            let readData = fileHandle.readDataToEndOfFile()
            self.lock.lock()
            self.data = readData
            self.lock.unlock()
            self.group.leave()
        }
    }

    func finish() -> Data {
        group.wait()
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

public struct DiarizationSidecarClient<Transport: DiarizationSidecarTransport>: DiarizationClient {
    public var transport: Transport
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(transport: Transport) {
        self.transport = transport
    }

    public func health() async throws -> DiarizationHealth {
        let result = try await call("health", decode: HealthResult.self)
        return DiarizationHealth(status: result.status, models: result.models)
    }

    public func preload(huggingFaceToken: String?) async throws -> DiarizationHealth {
        var params: [String: DiarizationValue] = [:]
        if let huggingFaceToken, !huggingFaceToken.isEmpty {
            params["hfToken"] = .string(huggingFaceToken)
        }
        let result = try await call("preload", params: params, decode: HealthResult.self)
        return DiarizationHealth(status: result.status, models: result.models)
    }

    public func diarizeFile(
        path: String,
        speakerConstraint: DiarizationSpeakerConstraint = .automatic
    ) async throws -> [DiarizationTurn] {
        let result = try await call(
            "diarize_file",
            params: params(path: path, speakerConstraint: speakerConstraint),
            decode: TurnsResult.self
        )
        return result.turns
    }

    public func diarizeWindow(
        path: String,
        startMs: Int,
        endMs: Int,
        speakerConstraint: DiarizationSpeakerConstraint = .automatic
    ) async throws -> [DiarizationTurn] {
        let result = try await call(
            "diarize_window",
            params: params(
                path: path,
                startMs: startMs,
                endMs: endMs,
                speakerConstraint: speakerConstraint
            ),
            decode: TurnsResult.self
        )
        return result.turns
    }

    public func embedSpeaker(path: String, startMs: Int, endMs: Int) async throws -> VoiceprintResult {
        let result = try await call(
            "embed_speaker",
            params: ["path": .string(path), "startMs": .int(startMs), "endMs": .int(endMs)],
            decode: EmbeddingResult.self
        )
        return VoiceprintResult(embedding: result.embedding, confidence: result.confidence)
    }

    public func diarizeFinalBatch(
        path: String,
        windows: [FinalDiarizationWindowBatchRequest],
        speakerConstraint: DiarizationSpeakerConstraint = .automatic
    ) async throws -> FinalDiarizationBatchResult {
        var params = params(path: path, speakerConstraint: speakerConstraint)
        params["windows"] = .string(try jsonString(from: windows))
        let result = try await call(
            "diarize_final_batch",
            params: params,
            decode: FinalBatchResult.self
        )
        return FinalDiarizationBatchResult(
            fullTurns: result.fullTurns,
            windowedTurns: result.windowedTurns.map {
                WindowedDiarizationTurn(
                    window: FinalDiarizationWindow(
                        index: $0.windowIndex,
                        startMs: $0.windowStartMs,
                        endMs: $0.windowEndMs
                    ),
                    turn: $0.turn
                )
            },
            embeddingsByLocalSpeakerKey: result.embeddingsByLocalSpeakerKey.mapValues {
                VoiceprintResult(embedding: $0.embedding, confidence: $0.confidence)
            }
        )
    }

    private func call<T: Decodable>(
        _ method: String,
        params: [String: DiarizationValue] = [:],
        decode: T.Type
    ) async throws -> T {
        let request = DiarizationSidecarRequest(id: UUID().uuidString, method: method, params: params)
        let responseLine: String
        do {
            responseLine = try await transport.send(request)
        } catch let error as DiarizationClientError {
            throw error
        } catch {
            throw DiarizationClientError.transport(error.localizedDescription)
        }

        guard let data = responseLine.data(using: .utf8) else {
            throw DiarizationClientError.invalidResponse
        }
        let envelope = try decoder.decode(SidecarResponse<T>.self, from: data)
        if envelope.ok, let result = envelope.result {
            return result
        }
        throw DiarizationClientError.sidecar(envelope.error?.message ?? "说话人分离 sidecar 调用失败。")
    }

    private func params(
        path: String,
        startMs: Int? = nil,
        endMs: Int? = nil,
        speakerConstraint: DiarizationSpeakerConstraint
    ) -> [String: DiarizationValue] {
        var params: [String: DiarizationValue] = ["path": .string(path)]
        if let startMs {
            params["startMs"] = .int(startMs)
        }
        if let endMs {
            params["endMs"] = .int(endMs)
        }
        if let minSpeakers = speakerConstraint.minSpeakers {
            params["minSpeakers"] = .int(minSpeakers)
        }
        if let maxSpeakers = speakerConstraint.maxSpeakers {
            params["maxSpeakers"] = .int(maxSpeakers)
        }
        if let numSpeakers = speakerConstraint.numSpeakers {
            params["numSpeakers"] = .int(numSpeakers)
        }
        return params
    }

    private func jsonString<T: Encodable>(from value: T) throws -> String {
        String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}

private struct SidecarResponse<Result: Decodable>: Decodable {
    var id: String
    var ok: Bool
    var result: Result?
    var error: SidecarError?
}

private struct SidecarError: Decodable {
    var code: String?
    var message: String
}

private struct HealthResult: Decodable {
    var status: String
    var models: [String]
}

private struct TurnsResult: Decodable {
    var turns: [DiarizationTurn]
}

private struct EmbeddingResult: Decodable {
    var embedding: [Double]
    var confidence: Double
}

private struct FinalBatchResult: Decodable {
    var fullTurns: [DiarizationTurn]
    var windowedTurns: [WindowedTurnResult]
    var embeddingsByLocalSpeakerKey: [String: EmbeddingResult]
}

private struct WindowedTurnResult: Decodable {
    var windowIndex: Int
    var windowStartMs: Int
    var windowEndMs: Int
    var turn: DiarizationTurn
}
