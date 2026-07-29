import Foundation

public struct ModelSourceTestResult: Equatable, Sendable {
    public var ok: Bool
    public var message: String
    public var models: [String]

    public init(ok: Bool, message: String, models: [String] = []) {
        self.ok = ok
        self.message = message
        self.models = models
    }
}

public protocol HTTPDataLoading: Sendable {
    func data(from url: URL, headers: [String: String]) async throws -> Data
    func response(from url: URL, headers: [String: String]) async throws -> HTTPDataLoadResponse
}

public struct HTTPDataLoadResponse: Equatable, Sendable {
    public var data: Data
    public var statusCode: Int

    public init(data: Data, statusCode: Int) {
        self.data = data
        self.statusCode = statusCode
    }
}

public extension HTTPDataLoading {
    func response(from url: URL, headers: [String: String]) async throws -> HTTPDataLoadResponse {
        HTTPDataLoadResponse(
            data: try await data(from: url, headers: headers),
            statusCode: 200
        )
    }
}

public struct URLSessionDataLoader: HTTPDataLoading {
    public init() {}

    public func data(from url: URL, headers: [String: String]) async throws -> Data {
        var request = URLRequest(url: url)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (data, _) = try await HTTPSessionFactory.shared().data(for: request)
        return data
    }

    public func response(from url: URL, headers: [String: String]) async throws -> HTTPDataLoadResponse {
        var request = URLRequest(url: url)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (data, response) = try await HTTPSessionFactory.shared().data(for: request)
        return HTTPDataLoadResponse(
            data: data,
            statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0
        )
    }
}

public struct ModelSourceTester<Loader: HTTPDataLoading>: Sendable {
    public var loader: Loader

    public init(loader: Loader) {
        self.loader = loader
    }

    public func test(source: ModelSource) async -> ModelSourceTestResult {
        if source.baseURL == "builtin://voiceprint" {
            return ModelSourceTestResult(ok: true, message: "内置声纹模型可用", models: ["builtin-voiceprint-v2"])
        }

        if source.baseURL == "sidecar://diarization" {
            return ModelSourceTestResult(
                ok: true,
                message: "本机说话人分离配置格式正确；App 内测试会执行真实预热。",
                models: [VoiceprintModelMigration.sidecarModel]
            )
        }

        if source.baseURL.hasPrefix("mock://") {
            return ModelSourceTestResult(ok: true, message: "连接成功", models: [source.selectedModel ?? "mock-model"])
        }

        guard let url = URL(string: source.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/models") else {
            return ModelSourceTestResult(ok: false, message: "Base URL 无效")
        }

        do {
            let headers = source.apiKey.isEmpty ? [:] : ["Authorization": "Bearer \(source.apiKey)"]
            let response = try await loader.response(from: url, headers: headers)
            guard (200..<300).contains(response.statusCode) else {
                return ModelSourceTestResult(
                    ok: false,
                    message: Self.errorMessage(statusCode: response.statusCode, data: response.data),
                    models: []
                )
            }
            let modelList = try JSONDecoder().decode(ModelListResponse.self, from: response.data)
            return ModelSourceTestResult(ok: true, message: "连接成功", models: modelList.data.map(\.id))
        } catch {
            return ModelSourceTestResult(ok: false, message: error.localizedDescription)
        }
    }

    private static func errorMessage(statusCode: Int, data: Data) -> String {
        let payload = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let error = try? JSONDecoder().decode(APIErrorResponse.self, from: data),
           let message = error.error?.message?.trimmingCharacters(in: .whitespacesAndNewlines),
           !message.isEmpty {
            return "服务返回 \(statusCode)：\(message)"
        }
        return payload.isEmpty ? "服务返回 HTTP \(statusCode)" : "服务返回 \(statusCode)：\(payload)"
    }
}

private struct ModelListResponse: Decodable {
    var data: [ModelItem]
}

private struct ModelItem: Decodable {
    var id: String
}

private struct APIErrorResponse: Decodable {
    var error: APIError?
}

private struct APIError: Decodable {
    var message: String?
}
