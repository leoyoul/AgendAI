import Foundation
import Testing
@testable import AItingjiCore

/// 常驻 JSONL sidecar 传输的基础契约：
/// - 单进程处理多次调用
/// - FIFO 严格保序
/// - 优雅关闭时排空未完成请求
@Suite("PersistentJSONLSidecarTransport 集成", .serialized)
struct PersistentJSONLSidecarTransportTests {
    @Test("多次连续请求由同一常驻进程处理并按序返回")
    func handlesConsecutiveRequestsWithOneProcess() async throws {
        let transport = makeTransport()
        defer { Task { await transport.shutdown() } }

        let first = try await transport.send(makeRequest(id: "req-1", method: "hello", value: "A"))
        let second = try await transport.send(makeRequest(id: "req-2", method: "hello", value: "B"))

        let firstEnvelope = try decodeEnvelope(from: first)
        let secondEnvelope = try decodeEnvelope(from: second)
        #expect(firstEnvelope.id == "req-1")
        #expect(secondEnvelope.id == "req-2")
        #expect(firstEnvelope.ok)
        #expect(secondEnvelope.ok)
    }

    @Test("忽略 sidecar stdout 的回车进度日志并读取 JSON 响应")
    func ignoresCarriageReturnProgressNoise() async throws {
        let transport = makeTransport(script: noisySidecarScriptURL())
        defer { Task { await transport.shutdown() } }

        let response = try await transport.send(makeRequest(id: "noisy-req", method: "hello"))
        let envelope = try decodeEnvelope(from: response)
        #expect(envelope.id == "noisy-req")
        #expect(envelope.ok)
    }

    @Test("shutdown 后禁止再发请求")
    func rejectsRequestsAfterShutdown() async throws {
        let transport = makeTransport()
        _ = try await transport.send(makeRequest(id: "req-1", method: "hello", value: "A"))
        await transport.shutdown()

        do {
            _ = try await transport.send(makeRequest(id: "req-2", method: "hello", value: "B"))
            Issue.record("shutdown 之后仍然接受请求")
        } catch let error as DiarizationClientError {
            switch error {
            case .transport:
                break
            default:
                Issue.record("expected transport error, got \(error)")
            }
        }
    }

    @Test("子进程崩溃后下一次 send 自动重启")
    func recoversFromChildProcessCrash() async throws {
        let transport = makeTransport()
        defer { Task { await transport.shutdown() } }

        // 让子进程主动退出，模拟崩溃
        do {
            _ = try await transport.send(makeRequest(id: "req-crash", method: "exit"))
        } catch {
            // exit 会导致 EOF，send 抛错是预期行为
        }

        // 下一次调用应该自动重启进程并成功
        let response = try await transport.send(makeRequest(id: "req-after-restart", method: "hello", value: "restarted"))
        let envelope = try decodeEnvelope(from: response)
        #expect(envelope.ok)
        #expect(envelope.id == "req-after-restart")
    }

    // MARK: - Helpers

    private func makeTransport(script: URL? = nil) -> PersistentJSONLSidecarTransport {
        let python = pythonExecutable()
        let script = script ?? echoSidecarScriptURL()
        let configuration = DiarizationSidecarLaunchConfiguration(
            executableURL: python,
            arguments: [script.path],
            workingDirectoryURL: nil,
            environment: [:],
            missingPythonMessage: nil,
            sidecarErrorMessageTransform: { $0 }
        )
        return PersistentJSONLSidecarTransport(configuration: configuration)
    }

    private func makeRequest(id: String, method: String, value: String? = nil) -> DiarizationSidecarRequest {
        var params: [String: DiarizationValue] = [:]
        if let value {
            params["value"] = .string(value)
        }
        return DiarizationSidecarRequest(id: id, method: method, params: params)
    }

    private func decodeEnvelope(from line: String) throws -> ResponseEnvelope {
        let data = line.data(using: .utf8) ?? Data()
        return try JSONDecoder().decode(ResponseEnvelope.self, from: data)
    }

    private func pythonExecutable() -> URL {
        // 首选 python3；若系统未安装，退化到 /usr/bin/env（测试会在少数机器上被跳过）
        for candidate in ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"] {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return URL(fileURLWithPath: "/usr/bin/python3")
    }

    private func echoSidecarScriptURL() -> URL {
        // 从当前文件位置向上找到 tests/Support/echo_sidecar.py，兼容 spm test 的工作目录
        let thisFile = URL(fileURLWithPath: #filePath)
        let testsDir = thisFile.deletingLastPathComponent().deletingLastPathComponent()
        return testsDir.appendingPathComponent("Support").appendingPathComponent("echo_sidecar.py")
    }

    private func noisySidecarScriptURL() -> URL {
        let thisFile = URL(fileURLWithPath: #filePath)
        let testsDir = thisFile.deletingLastPathComponent().deletingLastPathComponent()
        return testsDir.appendingPathComponent("Support").appendingPathComponent("noisy_sidecar.py")
    }
}

// PersistentJSONLSidecarTransport 用现成的 configuration.init(executableURL:arguments:...) —
// 我们需要一个能直接指定可执行路径的构造器，走 DiarizationSidecarLaunchConfiguration 现有的字段。
extension DiarizationSidecarLaunchConfiguration {
    fileprivate init(
        executableURL: URL,
        arguments: [String],
        workingDirectoryURL: URL?,
        environment: [String: String],
        missingPythonMessage: String?,
        sidecarErrorMessageTransform: @escaping @Sendable (String) -> String
    ) {
        self.init(
            scriptURL: URL(fileURLWithPath: arguments.first ?? ""),
            backend: .production,
            huggingFaceToken: nil,
            pythonExecutableURL: executableURL,
            workingDirectoryURL: workingDirectoryURL,
            missingPythonMessage: missingPythonMessage,
            sidecarErrorMessageTransform: sidecarErrorMessageTransform
        )
        // scriptURL init 会附加 --mode jsonl --backend funasr；测试脚本不需要这些，重写 arguments
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
    }
}

private struct ResponseEnvelope: Decodable {
    let id: String
    let ok: Bool
}
