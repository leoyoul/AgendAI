import Foundation

public enum MeetingAgentGatewayError: Error, Equatable, LocalizedError, Sendable {
    case invalidJobID
    case emptyToken
    case timeout
    case transport(String)
    case invalidResponse(statusCode: Int, reason: String)
    case api(statusCode: Int, code: String, message: String, details: [MeetingAgentJSONValue])

    public var errorDescription: String? {
        switch self {
        case .invalidJobID:
            "Agent 作业 ID 无效"
        case .emptyToken:
            "Agent API token 为空"
        case .timeout:
            "Agent API 请求超时"
        case let .transport(message):
            "Agent API 连接失败：\(message)"
        case let .invalidResponse(statusCode, reason):
            "Agent API 响应无效（HTTP \(statusCode)）：\(reason)"
        case let .api(_, code, message, _):
            "Agent API 错误 \(code)：\(message)"
        }
    }
}

public struct MeetingAgentGatewayClient: Sendable {
    public typealias TokenProvider = @Sendable () throws -> String

    private let baseURL: URL
    private let session: URLSession
    private let tokenProvider: TokenProvider
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        baseURL: URL = URL(string: "http://127.0.0.1:18765")!,
        session: URLSession = HTTPSessionFactory.shared(),
        tokenProvider: @escaping TokenProvider
    ) {
        self.baseURL = baseURL
        self.session = session
        self.tokenProvider = tokenProvider
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        decoder = JSONDecoder()
    }

    public func submit(_ job: MeetingAgentJobRequest) async throws -> MeetingAgentSubmitResponse {
        try validate(jobID: job.requestID)
        var request = try authorizedRequest(pathComponents: ["v1", "jobs"])
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(job.requestID, forHTTPHeaderField: "Idempotency-Key")
        do {
            request.httpBody = try encoder.encode(job)
        } catch {
            throw MeetingAgentGatewayError.invalidResponse(statusCode: 0, reason: "请求编码失败：\(error.localizedDescription)")
        }
        let response = try await perform(
            request,
            expectedStatusCode: 202,
            exactKeys: ["schema_version", "job_id", "request_id", "status"],
            as: MeetingAgentSubmitResponse.self
        )
        guard response.schemaVersion == "1.0",
              response.jobID == job.requestID,
              response.requestID == job.requestID
        else {
            throw MeetingAgentGatewayError.invalidResponse(statusCode: 202, reason: "响应版本或作业身份不匹配")
        }
        return response
    }

    public func fetchStatus(jobID: String) async throws -> MeetingAgentJobStatusResponse {
        try validate(jobID: jobID)
        var request = try authorizedRequest(pathComponents: ["v1", "jobs", jobID])
        request.httpMethod = "GET"
        let response = try await perform(
            request,
            expectedStatusCode: 200,
            exactKeys: [
                "schema_version", "job_id", "request_id", "meeting_id", "provider", "status",
                "created_at", "updated_at", "started_at", "completed_at", "error"
            ],
            nestedExactKeys: ["error": ["code", "message"]],
            as: MeetingAgentJobStatusResponse.self
        )
        if let reason = Self.invalidStatusReason(response, expectedJobID: jobID) {
            throw MeetingAgentGatewayError.invalidResponse(statusCode: 200, reason: reason)
        }
        return response
    }

    public func fetchResult(jobID: String) async throws -> MeetingAgentResultResponse {
        try validate(jobID: jobID)
        var request = try authorizedRequest(pathComponents: ["v1", "jobs", jobID, "result"])
        request.httpMethod = "GET"
        let response = try await perform(
            request,
            expectedStatusCode: 200,
            exactKeys: [
                "schema_version", "job_id", "request_id", "meeting_id", "request_hash", "provider",
                "result_path", "manifest_path", "manifest_sha256"
            ],
            nestedExactKeys: ["provider": ["name", "run_id"]],
            as: MeetingAgentResultResponse.self
        )
        if let reason = Self.invalidResultReason(response, expectedJobID: jobID) {
            throw MeetingAgentGatewayError.invalidResponse(statusCode: 200, reason: reason)
        }
        return response
    }

    private func validate(jobID: String) throws {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        guard !jobID.isEmpty,
              jobID.count <= 200,
              jobID.first?.isASCII == true,
              jobID.first?.isLetter == true || jobID.first?.isNumber == true,
              jobID.unicodeScalars.allSatisfy(allowed.contains)
        else {
            throw MeetingAgentGatewayError.invalidJobID
        }
    }

    private func authorizedRequest(pathComponents: [String]) throws -> URLRequest {
        let token = try tokenProvider().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw MeetingAgentGatewayError.emptyToken
        }
        var url = baseURL
        for component in pathComponents {
            url.appendPathComponent(component)
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func perform<Response: Decodable>(
        _ request: URLRequest,
        expectedStatusCode: Int,
        exactKeys: Set<String>,
        nestedExactKeys: [String: Set<String>] = [:],
        as type: Response.Type
    ) async throws -> Response {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            if error.code == .timedOut { throw MeetingAgentGatewayError.timeout }
            throw MeetingAgentGatewayError.transport(error.localizedDescription)
        } catch {
            throw MeetingAgentGatewayError.transport(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw MeetingAgentGatewayError.invalidResponse(statusCode: 0, reason: "不是 HTTP 响应")
        }
        guard httpResponse.statusCode == expectedStatusCode else {
            if let apiError = try? Self.decodeStrictAPIError(data, decoder: decoder) {
                throw MeetingAgentGatewayError.api(
                    statusCode: httpResponse.statusCode,
                    code: apiError.error.code,
                    message: apiError.error.message,
                    details: apiError.error.details
                )
            }
            throw MeetingAgentGatewayError.invalidResponse(
                statusCode: httpResponse.statusCode,
                reason: "缺少统一错误响应"
            )
        }
        do {
            try Self.validateExactJSON(data, keys: exactKeys, nestedKeys: nestedExactKeys)
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw MeetingAgentGatewayError.invalidResponse(
                statusCode: httpResponse.statusCode,
                reason: error.localizedDescription
            )
        }
    }

    private static func validateExactJSON(
        _ data: Data,
        keys: Set<String>,
        nestedKeys: [String: Set<String>]
    ) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == keys
        else {
            throw MeetingAgentGatewayError.invalidResponse(statusCode: 0, reason: "响应字段不符合 v1 协议")
        }
        for (key, expected) in nestedKeys {
            if object[key] is NSNull { continue }
            guard let nested = object[key] as? [String: Any], Set(nested.keys) == expected else {
                throw MeetingAgentGatewayError.invalidResponse(statusCode: 0, reason: "响应字段不符合 v1 协议")
            }
        }
    }

    private static func decodeStrictAPIError(
        _ data: Data,
        decoder: JSONDecoder
    ) throws -> MeetingAgentAPIErrorResponse {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["error"],
              let error = object["error"] as? [String: Any],
              Set(error.keys) == ["code", "message", "details"],
              let code = error["code"] as? String,
              !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              error["message"] is String,
              error["details"] is [Any]
        else {
            throw MeetingAgentGatewayError.invalidResponse(statusCode: 0, reason: "错误响应字段不符合 v1 协议")
        }
        return try decoder.decode(MeetingAgentAPIErrorResponse.self, from: data)
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func isISO8601(_ value: String) -> Bool {
        if ISO8601DateFormatter().date(from: value) != nil { return true }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) != nil
    }

    private static func invalidStatusReason(
        _ response: MeetingAgentJobStatusResponse,
        expectedJobID: String
    ) -> String? {
        guard response.schemaVersion == "1.0" else { return "schema_version 不是 1.0" }
        guard response.jobID == expectedJobID, response.requestID == expectedJobID else { return "作业身份不匹配" }
        guard !response.meetingID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "meeting_id 为空" }
        guard !response.provider.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "provider 为空" }
        guard isISO8601(response.createdAt), isISO8601(response.updatedAt),
              response.startedAt.map(isISO8601) ?? true,
              response.completedAt.map(isISO8601) ?? true
        else { return "时间字段不是 ISO 8601" }
        guard response.error.map({ !$0.code.isEmpty && !$0.message.isEmpty }) ?? true else { return "error 字段为空" }
        return nil
    }

    private static func invalidResultReason(
        _ response: MeetingAgentResultResponse,
        expectedJobID: String
    ) -> String? {
        guard response.schemaVersion == "1.0" else { return "schema_version 不是 1.0" }
        guard response.jobID == expectedJobID, response.requestID == expectedJobID else { return "作业身份不匹配" }
        guard !response.meetingID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "meeting_id 为空" }
        guard isSHA256(response.requestHash), isSHA256(response.manifestSHA256) else { return "SHA-256 字段无效" }
        guard !response.provider.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !response.provider.runID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return "provider 字段为空" }
        guard response.resultPath.hasPrefix("/") else { return "result_path 不是绝对路径" }
        guard MeetingDirectoryLayout.isSafeRelativePath(response.manifestPath) else { return "manifest_path 不安全" }
        return nil
    }
}
