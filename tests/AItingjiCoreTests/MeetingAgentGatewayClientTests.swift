import AItingjiCore
import Foundation
import Testing

@Test
func meetingAgentGatewaySubmitsVersionedRequestWithAuthenticationAndIdempotency() async throws {
    let recorder = GatewayRequestRecorder { request in
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/v1/jobs")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer local-secret")
        #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == "job-1")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let body = try requestBodyData(request)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["schema_version"] as? String == "1.0")
        #expect(object["request_id"] as? String == "job-1")
        let transcript = try #require(object["transcript"] as? [String: Any])
        #expect(transcript["plain_text"] as? String == "完整转写")

        return GatewayStubResponse(
            statusCode: 202,
            body: #"{"schema_version":"1.0","job_id":"job-1","request_id":"job-1","status":"queued"}"#
        )
    }
    let client = makeGatewayClient(recorder: recorder)

    let response = try await client.submit(makeGatewayJobRequest())

    #expect(response == MeetingAgentSubmitResponse(
        schemaVersion: "1.0",
        jobID: "job-1",
        requestID: "job-1",
        status: .queued
    ))
}

@Test
func meetingAgentGatewayFetchesStatusAndResult() async throws {
    let recorder = GatewayRequestRecorder { request in
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer local-secret")
        if request.url?.path == "/v1/jobs/job.with-space_1" {
            return GatewayStubResponse(
                statusCode: 200,
                body: #"{"schema_version":"1.0","job_id":"job.with-space_1","request_id":"job.with-space_1","meeting_id":"meeting-1","provider":"mock","status":"running","created_at":"2026-07-18T01:00:00Z","updated_at":"2026-07-18T01:00:01Z","started_at":"2026-07-18T01:00:01Z","completed_at":null,"error":null}"#
            )
        }
        #expect(request.url?.path == "/v1/jobs/job.with-space_1/result")
        return GatewayStubResponse(
            statusCode: 200,
            body: #"{"schema_version":"1.0","job_id":"job.with-space_1","request_id":"job.with-space_1","meeting_id":"meeting-1","request_hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","provider":{"name":"mock","run_id":"mock-run"},"result_path":"/tmp/agent/jobs/job.with-space_1/output","manifest_path":"manifest.json","manifest_sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}"#
        )
    }
    let client = makeGatewayClient(recorder: recorder)

    let status = try await client.fetchStatus(jobID: "job.with-space_1")
    let result = try await client.fetchResult(jobID: "job.with-space_1")

    #expect(status.status == .running)
    #expect(status.startedAt == "2026-07-18T01:00:01Z")
    #expect(status.completedAt == nil)
    #expect(result.provider == MeetingAgentProviderDescriptor(name: "mock", runID: "mock-run"))
    #expect(result.manifestPath == "manifest.json")
}

@Test(arguments: [
    (401, "AUTH_REQUIRED"),
    (409, "IDEMPOTENCY_CONFLICT"),
    (500, "PROVIDER_FAILED")
])
func meetingAgentGatewayDecodesUnifiedAPIErrors(statusCode: Int, code: String) async {
    let recorder = GatewayRequestRecorder { _ in
        GatewayStubResponse(
            statusCode: statusCode,
            body: "{\"error\":{\"code\":\"\(code)\",\"message\":\"请求失败\",\"details\":[\"detail\"]}}"
        )
    }
    let client = makeGatewayClient(recorder: recorder)

    do {
        _ = try await client.fetchStatus(jobID: "job-1")
        Issue.record("应抛出 API 错误")
    } catch let error as MeetingAgentGatewayError {
        #expect(error == .api(statusCode: statusCode, code: code, message: "请求失败", details: ["detail"]))
    } catch {
        Issue.record("错误类型不正确：\(error)")
    }
}

@Test(arguments: [
    #"{"error":{"code":"INVALID_REQUEST","message":"失败","details":[],"extra":true}}"#,
    #"{"error":{"code":"INVALID_REQUEST","message":"失败"}}"#
])
func meetingAgentGatewayRejectsMalformedAPIErrorShape(body: String) async {
    let recorder = GatewayRequestRecorder { _ in GatewayStubResponse(statusCode: 400, body: body) }
    let client = makeGatewayClient(recorder: recorder)

    do {
        _ = try await client.fetchStatus(jobID: "job-1")
        Issue.record("漂移的错误响应应被拒绝")
    } catch let error as MeetingAgentGatewayError {
        guard case .invalidResponse = error else {
            Issue.record("应为 invalidResponse，实际为 \(error)")
            return
        }
    } catch {
        Issue.record("错误类型不正确：\(error)")
    }
}

@Test
func meetingAgentGatewayRejectsInvalidHTTPAndJSONResponses() async {
    let invalidHTTPClient = MeetingAgentGatewayClient(
        baseURL: URL(string: "http://127.0.0.1:18765")!,
        session: URLSession(configuration: .ephemeral),
        tokenProvider: { "token" }
    )
    // 不能构造非 HTTP URLResponse 的 URLProtocol 响应，因此用非 HTTP URL 触发 transport 错误。
    do {
        _ = try await invalidHTTPClient.fetchStatus(jobID: "")
        Issue.record("空 job ID 应被拒绝")
    } catch let error as MeetingAgentGatewayError {
        #expect(error == .invalidJobID)
    } catch {
        Issue.record("错误类型不正确：\(error)")
    }

    let recorder = GatewayRequestRecorder { _ in
        GatewayStubResponse(statusCode: 200, body: "not-json")
    }
    let client = makeGatewayClient(recorder: recorder)
    do {
        _ = try await client.fetchStatus(jobID: "job-1")
        Issue.record("无效 JSON 应被拒绝")
    } catch let error as MeetingAgentGatewayError {
        guard case .invalidResponse = error else {
            Issue.record("应为 invalidResponse，实际为 \(error)")
            return
        }
    } catch {
        Issue.record("错误类型不正确：\(error)")
    }
}

@Test(arguments: ["../healthz", "job/child", "job with space", "_job"])
func meetingAgentGatewayRejectsUnsafeJobIDs(jobID: String) async {
    let recorder = GatewayRequestRecorder { _ in
        Issue.record("非法 job ID 不应发起 HTTP 请求")
        return GatewayStubResponse(statusCode: 500, body: "{}")
    }
    let client = makeGatewayClient(recorder: recorder)

    await #expect(throws: MeetingAgentGatewayError.invalidJobID) {
        _ = try await client.fetchStatus(jobID: jobID)
    }
}

@Test
func meetingAgentGatewayRejectsMismatchedVersionedResponseIdentity() async {
    let recorder = GatewayRequestRecorder { _ in
        GatewayStubResponse(
            statusCode: 202,
            body: #"{"schema_version":"2.0","job_id":"other","request_id":"other","status":"queued"}"#
        )
    }
    let client = makeGatewayClient(recorder: recorder)

    do {
        _ = try await client.submit(makeGatewayJobRequest())
        Issue.record("版本或身份不匹配的响应应被拒绝")
    } catch let error as MeetingAgentGatewayError {
        guard case .invalidResponse = error else {
            Issue.record("应为 invalidResponse，实际为 \(error)")
            return
        }
    } catch {
        Issue.record("错误类型不正确：\(error)")
    }
}

@Test
func meetingAgentGatewaySurfacesTimeout() async {
    let recorder = GatewayRequestRecorder { _ in
        throw URLError(.timedOut)
    }
    let client = makeGatewayClient(recorder: recorder)

    do {
        _ = try await client.fetchStatus(jobID: "job-1")
        Issue.record("超时应抛错")
    } catch let error as MeetingAgentGatewayError {
        #expect(error == .timeout)
    } catch {
        Issue.record("错误类型不正确：\(error)")
    }
}

@Test
func meetingAgentGatewayPreservesCancellation() async {
    let recorder = GatewayRequestRecorder { _ in throw URLError(.cancelled) }
    let client = makeGatewayClient(recorder: recorder)

    await #expect(throws: CancellationError.self) {
        _ = try await client.fetchStatus(jobID: "job-1")
    }
}

@Test(arguments: [
    #"{"schema_version":"1.0","job_id":"job-1","request_id":"job-1","status":"queued","extra":true}"#,
    #"{"schema_version":"1.0","job_id":"job-1","request_id":"job-1"}"#
])
func meetingAgentGatewayRejectsProtocolShapeDrift(body: String) async {
    let recorder = GatewayRequestRecorder { _ in GatewayStubResponse(statusCode: 202, body: body) }
    let client = makeGatewayClient(recorder: recorder)

    await #expect(throws: MeetingAgentGatewayError.self) {
        _ = try await client.submit(makeGatewayJobRequest())
    }
}

@Test
func meetingAgentGatewayRejectsInvalidNestedResultFields() async {
    let recorder = GatewayRequestRecorder { _ in
        GatewayStubResponse(
            statusCode: 200,
            body: #"{"schema_version":"1.0","job_id":"job-1","request_id":"job-1","meeting_id":"meeting-1","request_hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","provider":{"name":"","run_id":"run","extra":true},"result_path":"relative","manifest_path":"manifest.json","manifest_sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}"#
        )
    }
    let client = makeGatewayClient(recorder: recorder)

    await #expect(throws: MeetingAgentGatewayError.self) {
        _ = try await client.fetchResult(jobID: "job-1")
    }
}

private func makeGatewayJobRequest() -> MeetingAgentJobRequest {
    MeetingAgentJobRequest(
        requestID: "job-1",
        meeting: MeetingAgentMeetingInput(
            id: "meeting-1",
            title: "项目周例会",
            startedAt: "2026-07-18T01:00:00Z",
            endedAt: "2026-07-18T02:00:00Z",
            timezone: "Asia/Shanghai",
            captureSource: "mixed",
            participants: []
        ),
        transcript: MeetingAgentTranscriptInput(
            language: "zh-CN",
            plainText: "完整转写",
            segments: [
                MeetingAgentTranscriptSegmentInput(
                    id: "segment-1",
                    startMs: 0,
                    endMs: 3_200,
                    speaker: "待确认",
                    text: "会议内容"
                )
            ]
        ),
        attachments: [],
        analysis: MeetingAgentAnalysisInput(goal: "核对风险", language: "zh-CN")
    )
}

private func makeGatewayClient(recorder: GatewayRequestRecorder) -> MeetingAgentGatewayClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [GatewayURLProtocol.self]
    configuration.httpAdditionalHeaders = ["X-Tinglan-Test-Recorder": recorder.id]
    GatewayURLProtocol.register(recorder)
    return MeetingAgentGatewayClient(
        baseURL: URL(string: "http://127.0.0.1:18765")!,
        session: URLSession(configuration: configuration),
        tokenProvider: { "local-secret" }
    )
}

private func requestBodyData(_ request: URLRequest) throws -> Data {
    if let body = request.httpBody {
        return body
    }
    let stream = try #require(request.httpBodyStream)
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while true {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count < 0 {
            throw stream.streamError ?? URLError(.cannotDecodeContentData)
        }
        if count == 0 { break }
        data.append(buffer, count: count)
    }
    return data
}

private struct GatewayStubResponse: Sendable {
    var statusCode: Int
    var body: String
}

private final class GatewayRequestRecorder: @unchecked Sendable {
    let id = UUID().uuidString
    let handler: @Sendable (URLRequest) throws -> GatewayStubResponse

    init(handler: @escaping @Sendable (URLRequest) throws -> GatewayStubResponse) {
        self.handler = handler
    }
}

private final class GatewayURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var recorders: [String: GatewayRequestRecorder] = [:]

    static func register(_ recorder: GatewayRequestRecorder) {
        lock.lock()
        recorders[recorder.id] = recorder
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let recorderID = try #require(request.value(forHTTPHeaderField: "X-Tinglan-Test-Recorder"))
            Self.lock.lock()
            let registeredRecorder = Self.recorders[recorderID]
            Self.lock.unlock()
            let recorder = try #require(registeredRecorder)
            let stub = try recorder.handler(request)
            let response = HTTPURLResponse(
                url: try #require(request.url),
                statusCode: stub.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(stub.body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
