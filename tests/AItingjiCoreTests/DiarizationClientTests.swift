import AItingjiCore
import Foundation
import Testing

@Test
func diarizationSidecarClientParsesHealthAndTurns() async throws {
    let transport = MockDiarizationTransport(responses: [
        #"{"id":"1","ok":true,"result":{"status":"ready","models":["mock-diarization"]}}"#,
        #"{"id":"2","ok":true,"result":{"turns":[{"startMs":0,"endMs":1200,"speakerKey":"SPEAKER_A","confidence":0.91},{"startMs":1200,"endMs":2500,"speakerKey":"SPEAKER_B","confidence":0.88}]}}"#
    ])
    let client = DiarizationSidecarClient(transport: transport)

    let health = try await client.health()
    let turns = try await client.diarizeFile(path: "/tmp/meeting.wav")

    #expect(health.status == "ready")
    #expect(health.models == ["mock-diarization"])
    #expect(turns == [
        DiarizationTurn(startMs: 0, endMs: 1200, speakerKey: "SPEAKER_A", confidence: 0.91),
        DiarizationTurn(startMs: 1200, endMs: 2500, speakerKey: "SPEAKER_B", confidence: 0.88)
    ])
    let requests = await transport.requests
    #expect(requests.map(\.method) == ["health", "diarize_file"])
    #expect(requests[1].params["path"] == .string("/tmp/meeting.wav"))
}

@Test
func diarizationSidecarClientSendsSpeakerConstraints() async throws {
    let transport = MockDiarizationTransport(responses: [
        #"{"id":"1","ok":true,"result":{"turns":[]}}"#,
        #"{"id":"2","ok":true,"result":{"turns":[]}}"#
    ])
    let client = DiarizationSidecarClient(transport: transport)

    _ = try await client.diarizeWindow(
        path: "/tmp/meeting.wav",
        startMs: 1_000,
        endMs: 61_000,
        speakerConstraint: DiarizationSpeakerConstraint(minSpeakers: 2, maxSpeakers: 4)
    )
    _ = try await client.diarizeFile(
        path: "/tmp/meeting.wav",
        speakerConstraint: DiarizationSpeakerConstraint(numSpeakers: 3)
    )

    let requests = await transport.requests
    #expect(requests[0].params["minSpeakers"] == .int(2))
    #expect(requests[0].params["maxSpeakers"] == .int(4))
    #expect(requests[0].params["numSpeakers"] == nil)
    #expect(requests[1].params["numSpeakers"] == .int(3))
}

@Test
func diarizationSidecarClientParsesFinalBatchResult() async throws {
    let response = #"""
    {"id":"1","ok":true,"result":{
      "fullTurns":[{"startMs":0,"endMs":1000,"speakerKey":"SPEAKER_00","confidence":0.9}],
      "windowedTurns":[
        {"windowIndex":0,"windowStartMs":0,"windowEndMs":90000,"turn":{"startMs":0,"endMs":1000,"speakerKey":"SPEAKER_00","confidence":0.9}}
      ],
      "embeddingsByLocalSpeakerKey":{"0:SPEAKER_00":{"embedding":[1,0],"confidence":0.95}}
    }}
    """#
    let transport = MockDiarizationTransport(responses: [response])
    let client = DiarizationSidecarClient(transport: transport)

    let result = try await client.diarizeFinalBatch(
        path: "/tmp/meeting.wav",
        windows: [
            FinalDiarizationWindowBatchRequest(
                index: 0,
                startMs: 0,
                endMs: 90_000,
                acceptedStartMs: 0,
                acceptedEndMs: 82_500
            )
        ],
        speakerConstraint: DiarizationSpeakerConstraint(numSpeakers: 3)
    )

    #expect(result.fullTurns == [
        DiarizationTurn(startMs: 0, endMs: 1_000, speakerKey: "SPEAKER_00", confidence: 0.9)
    ])
    #expect(result.windowedTurns == [
        WindowedDiarizationTurn(
            window: FinalDiarizationWindow(index: 0, startMs: 0, endMs: 90_000),
            turn: DiarizationTurn(startMs: 0, endMs: 1_000, speakerKey: "SPEAKER_00", confidence: 0.9)
        )
    ])
    #expect(result.embeddingsByLocalSpeakerKey["0:SPEAKER_00"] == VoiceprintResult(embedding: [1, 0], confidence: 0.95))
    let requests = await transport.requests
    #expect(requests[0].method == "diarize_final_batch")
    #expect(requests[0].params["path"] == .string("/tmp/meeting.wav"))
    #expect(requests[0].params["numSpeakers"] == .int(3))
    guard case .string(let windowsJSON) = requests[0].params["windows"] else {
        Issue.record("batch windows should be JSON encoded")
        return
    }
    #expect(windowsJSON.contains(#""acceptedEndMs":82500"#))
}

@Test
func diarizationSidecarClientSurfacesReadableErrors() async {
    let transport = MockDiarizationTransport(responses: [
        #"{"id":"1","ok":false,"error":{"code":"missing_token","message":"缺少 Hugging Face token"}}"#
    ])
    let client = DiarizationSidecarClient(transport: transport)

    await #expect(throws: DiarizationClientError.sidecar("缺少 Hugging Face token")) {
        _ = try await client.preload(huggingFaceToken: nil)
    }
}

@Test
func processDiarizationTransportEncodesRequestsAndReadsOneLineResponse() async throws {
    let executable = "/bin/sh"
    let script = #"read line; echo '{"id":"process-1","ok":true,"result":{"status":"ready","models":["process-mock"]}}'"#
    let transport = ProcessDiarizationSidecarTransport(
        executableURL: URL(fileURLWithPath: executable),
        arguments: ["-c", script]
    )

    let response = try await transport.send(
        DiarizationSidecarRequest(id: "process-1", method: "health")
    )

    #expect(response.contains(#""status":"ready""#))
    #expect(response.contains("process-mock"))
}

@Test
func processDiarizationTransportUsesMissingPythonMessageWhenExecutableCannotLaunch() async {
    let transport = ProcessDiarizationSidecarTransport(
        executableURL: URL(fileURLWithPath: "/tmp/tinglan-missing-python"),
        arguments: [],
        missingPythonMessage: "请先安装本机说话人分离依赖"
    )

    await #expect(throws: DiarizationClientError.transport("请先安装本机说话人分离依赖")) {
        _ = try await transport.send(DiarizationSidecarRequest(id: "process-2", method: "health"))
    }
}

@Test
func processDiarizationTransportCreatesWorkingDirectoryBeforeLaunch() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("tinglan-sidecar-workdir-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let script = "read line; echo '{\"id\":\"process-workdir\",\"ok\":true}'"
    let transport = ProcessDiarizationSidecarTransport(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", script],
        workingDirectoryURL: root,
        missingPythonMessage: "未找到本机说话人分离 Python 环境"
    )

    let response = try await transport.send(
        DiarizationSidecarRequest(id: "process-workdir", method: "health")
    )

    #expect(FileManager.default.fileExists(atPath: root.path))
    #expect(response.contains(#""id":"process-workdir""#))
}

@Test
func processDiarizationTransportTransformsSidecarStderr() async {
    let executable = "/bin/sh"
    let script = #"echo "ModuleNotFoundError: No module named 'funasr'" >&2; exit 1"#
    let transport = ProcessDiarizationSidecarTransport(
        executableURL: URL(fileURLWithPath: executable),
        arguments: ["-c", script],
        sidecarErrorMessageTransform: { message in
            "请安装依赖：\(message)"
        }
    )

    await #expect(throws: DiarizationClientError.transport("请安装依赖：ModuleNotFoundError: No module named 'funasr'")) {
        _ = try await transport.send(DiarizationSidecarRequest(id: "process-3", method: "health"))
    }
}

@Test
func processDiarizationTransportDoesNotDeadlockWhenSidecarWritesLargeStderr() async throws {
    let executable = "/bin/sh"
    let script = """
    read line
    i=0
    while [ $i -lt 20000 ]; do
      echo "model loading progress line $i" >&2
      i=$((i + 1))
    done
    echo '{"id":"process-large-stderr","ok":true,"result":{"status":"ready","models":["process-mock"]}}'
    """
    let transport = ProcessDiarizationSidecarTransport(
        executableURL: URL(fileURLWithPath: executable),
        arguments: ["-c", script]
    )

    let response = try await withThrowingTaskGroup(of: String.self) { group in
        group.addTask {
            try await transport.send(
                DiarizationSidecarRequest(id: "process-large-stderr", method: "health")
            )
        }
        group.addTask {
            try await Task.sleep(for: .seconds(5))
            throw DiarizationClientError.transport("sidecar stderr pipe deadlocked")
        }
        let first = try await group.next() ?? ""
        group.cancelAll()
        return first
    }

    #expect(response.contains(#""status":"ready""#))
}

@Test
func processDiarizationTransportPropagatesCancellationAndTerminatesChild() async throws {
    // sidecar 挂起 5 秒等 stdin，父任务 200ms 后取消应立即返回 CancellationError。
    let script = "read line; sleep 5; echo done"
    let transport = ProcessDiarizationSidecarTransport(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", script]
    )
    let start = Date()
    let task = Task { () throws -> String in
        try await transport.send(
            DiarizationSidecarRequest(id: "process-cancel", method: "diarize_file")
        )
    }
    try await Task.sleep(nanoseconds: 200_000_000)
    task.cancel()
    do {
        _ = try await task.value
        Issue.record("Expected cancellation but transport returned normally.")
    } catch is CancellationError {
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 2.0, "Cancellation should return quickly, took \(elapsed)s")
    } catch {
        Issue.record("Expected CancellationError, got: \(error)")
    }
}

private actor MockDiarizationTransport: DiarizationSidecarTransport {
    private var responses: [String]
    private(set) var requests: [DiarizationSidecarRequest] = []

    init(responses: [String]) {
        self.responses = responses
    }

    func send(_ request: DiarizationSidecarRequest) async throws -> String {
        requests.append(request)
        guard !responses.isEmpty else {
            throw DiarizationClientError.transport("没有 mock 响应")
        }
        return responses.removeFirst()
    }
}
