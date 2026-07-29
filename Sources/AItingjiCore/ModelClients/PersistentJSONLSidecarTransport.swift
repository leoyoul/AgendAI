import Foundation

/// 常驻的 sidecar JSONL 传输。一次启动、长连接读写，避免每次调用都 fork Python。
///
/// - 线程安全：actor 隔离，`send` 串行处理（Python 侧是单线程 JSONL，天然顺序对齐）。
/// - 故障恢复：进程退出或写入失败自动重启，下一次 `send` 生效。
public actor PersistentJSONLSidecarTransport: DiarizationSidecarTransport {
    public let configuration: DiarizationSidecarLaunchConfiguration
    private var runtime: Runtime?
    private var isTerminated = false

    public init(configuration: DiarizationSidecarLaunchConfiguration) {
        self.configuration = configuration
    }

    public func send(_ request: DiarizationSidecarRequest) async throws -> String {
        if isTerminated {
            throw DiarizationClientError.transport("常驻 sidecar 已终止。")
        }
        let runtime = try ensureRunning()
        do {
            return try await runtime.send(request: request)
        } catch let error as DiarizationClientError {
            // 传输层错误可能意味着进程死了，先清掉再抛。下一次 send() 会重启。
            await runtime.shutdown()
            self.runtime = nil
            throw error
        } catch {
            await runtime.shutdown()
            self.runtime = nil
            throw DiarizationClientError.transport(error.localizedDescription)
        }
    }

    /// 结束会话时调用，优雅关闭常驻子进程。
    public func shutdown() async {
        isTerminated = true
        if let runtime {
            await runtime.shutdown()
            self.runtime = nil
        }
    }

    /// 主动预启动。返回时可以保证进程已 fork（不保证模型已加载完）。
    public func preflight() throws {
        _ = try ensureRunning()
    }

    private func ensureRunning() throws -> Runtime {
        if let runtime {
            return runtime
        }
        let runtime = try Runtime.launch(configuration: configuration)
        self.runtime = runtime
        return runtime
    }
}

extension PersistentJSONLSidecarTransport {
    /// 一个正在运行的 sidecar 子进程 + 串行请求队列。
    fileprivate actor Runtime {
        private let process: Process
        private let stdinHandle: FileHandle
        private let reader: LineReader
        private var pending: [(id: String, continuation: CheckedContinuation<String, Error>)] = []
        private var readerTask: Task<Void, Never>?
        private var didFinish = false
        private let sidecarErrorMessageTransform: @Sendable (String) -> String

        static func launch(configuration: DiarizationSidecarLaunchConfiguration) throws -> Runtime {
            let process = Process()
            process.executableURL = configuration.executableURL
            process.arguments = configuration.arguments
            if let workingDirectoryURL = configuration.workingDirectoryURL {
                try? FileManager.default.createDirectory(at: workingDirectoryURL, withIntermediateDirectories: true)
                process.currentDirectoryURL = workingDirectoryURL
            }
            if !configuration.environment.isEmpty {
                process.environment = ProcessInfo.processInfo.environment.merging(configuration.environment) { _, new in new }
            }
            let input = Pipe()
            let output = Pipe()
            let errorPipe = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = errorPipe
            do {
                try process.run()
            } catch {
                let message = configuration.missingPythonMessage ?? error.localizedDescription
                throw DiarizationClientError.transport(message)
            }
            // stderr 直接排走以免子进程被阻塞；出错时子进程会写完 stderr 后退出，
            // send() 里检测到进程死亡时再从 pipe 读兜底信息。
            let errorHandle = errorPipe.fileHandleForReading
            errorHandle.readabilityHandler = { _ = $0.availableData }
            return Runtime(
                process: process,
                stdinHandle: input.fileHandleForWriting,
                reader: LineReader(fileHandle: output.fileHandleForReading),
                sidecarErrorMessageTransform: configuration.sidecarErrorMessageTransform
            )
        }

        private init(
            process: Process,
            stdinHandle: FileHandle,
            reader: LineReader,
            sidecarErrorMessageTransform: @escaping @Sendable (String) -> String
        ) {
            self.process = process
            self.stdinHandle = stdinHandle
            self.reader = reader
            self.sidecarErrorMessageTransform = sidecarErrorMessageTransform
        }

        func send(request: DiarizationSidecarRequest) async throws -> String {
            if didFinish || !process.isRunning {
                throw DiarizationClientError.transport("sidecar 已退出。")
            }
            if readerTask == nil {
                startReaderIfNeeded()
            }
            let payload = try JSONEncoder().encode(request)
            do {
                if #available(macOS 13.0, *) {
                    try stdinHandle.write(contentsOf: payload)
                    try stdinHandle.write(contentsOf: Data([0x0A]))
                } else {
                    stdinHandle.write(payload)
                    stdinHandle.write(Data([0x0A]))
                }
            } catch {
                throw DiarizationClientError.transport(
                    sidecarErrorMessageTransform("sidecar 输入管道写入失败：\(error.localizedDescription)")
                )
            }
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                pending.append((request.id, continuation))
            }
        }

        func shutdown() {
            guard !didFinish else { return }
            didFinish = true
            readerTask?.cancel()
            try? stdinHandle.close()
            if process.isRunning {
                process.terminate()
            }
            // 排空所有未回收的请求
            for entry in pending {
                entry.continuation.resume(throwing: DiarizationClientError.transport("sidecar 已终止。"))
            }
            pending.removeAll()
        }

        private func startReaderIfNeeded() {
            readerTask = Task { [reader] in
                await self.readerLoop(reader: reader)
            }
        }

        private func readerLoop(reader: LineReader) async {
            while !Task.isCancelled {
                let line: String?
                do {
                    line = try await reader.readLine()
                } catch {
                    await fail(error: DiarizationClientError.transport(
                        sidecarErrorMessageTransform("sidecar 输出读取失败：\(error.localizedDescription)")
                    ))
                    return
                }
                guard let line else {
                    await handleEOF()
                    return
                }
                deliver(line: line)
            }
        }

        private func deliver(line: String) {
            // sidecar 的 stdout 可能混入带回车的第三方进度日志；只接收带有效请求 ID 的 JSON 响应。
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let response = object as? [String: Any],
                  let responseID = response["id"] as? String,
                  let index = pending.firstIndex(where: { $0.id == responseID })
            else {
                return
            }
            let entry = pending.remove(at: index)
            entry.continuation.resume(returning: line)
        }

        private func handleEOF() async {
            didFinish = true
            // 读到 EOF 时子进程仍可能处于"即将退出"状态，直接访问 terminationStatus 会抛 NSException。
            // 用后台任务等它结束再读，主线程只等短时间。
            let status: Int32 = await Task.detached(priority: .utility) { [process] in
                if process.isRunning {
                    process.waitUntilExit()
                }
                return process.terminationStatus
            }.value
            let message = status == 0
                ? "sidecar 意外结束（正常退出）。"
                : "sidecar 进程退出：\(status)"
            let transformed = sidecarErrorMessageTransform(message)
            for entry in pending {
                entry.continuation.resume(throwing: DiarizationClientError.transport(transformed))
            }
            pending.removeAll()
        }

        private func fail(error: DiarizationClientError) async {
            didFinish = true
            for entry in pending {
                entry.continuation.resume(throwing: error)
            }
            pending.removeAll()
            if process.isRunning {
                process.terminate()
            }
        }
    }

    /// 逐行读取管道内容的辅助器。actor 隔离，多次 readLine 可安全串行调用。
    fileprivate actor LineReader {
        private let fileHandle: FileHandle
        private var buffer = Data()
        private var isClosed = false

        init(fileHandle: FileHandle) {
            self.fileHandle = fileHandle
        }

        func readLine() async throws -> String? {
            while true {
                if let delimiter = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                    let lineData = buffer[..<delimiter]
                    buffer.removeSubrange(...delimiter)
                    while let next = buffer.first, next == 0x0A || next == 0x0D {
                        buffer.removeFirst()
                    }
                    return String(decoding: lineData, as: UTF8.self)
                }
                if isClosed {
                    if buffer.isEmpty {
                        return nil
                    }
                    let remaining = buffer
                    buffer.removeAll()
                    return String(decoding: remaining, as: UTF8.self)
                }
                try await readMoreData()
            }
        }

        private func readMoreData() async throws {
            let handle = fileHandle
            // Task.detached + FileHandle.availableData 阻塞读，避免占用主线程。
            let chunk: Data = await Task.detached(priority: .utility) {
                handle.availableData
            }.value
            if chunk.isEmpty {
                isClosed = true
            } else {
                buffer.append(chunk)
            }
        }
    }
}
