import Foundation

public struct HTTPUploadRequest: Equatable, Sendable {
    public var url: URL
    public var headers: [String: String]
    public var body: Data

    public init(url: URL, headers: [String: String], body: Data) {
        self.url = url
        self.headers = headers
        self.body = body
    }
}

public struct HTTPUploadResponse: Equatable, Sendable {
    public var data: Data
    public var statusCode: Int

    public init(data: Data, statusCode: Int) {
        self.data = data
        self.statusCode = statusCode
    }
}

public protocol HTTPDataUploading: Sendable {
    func upload(request: HTTPUploadRequest) async throws -> HTTPUploadResponse
}

public struct URLSessionDataUploader: HTTPDataUploading {
    private let session: URLSession
    private let coordinator: HTTPOriginRequestCoordinator
    private let maximumConcurrencyPerOrigin: Int?

    public init(
        session: URLSession = HTTPSessionFactory.shared(),
        coordinator: HTTPOriginRequestCoordinator = .shared,
        maximumConcurrencyPerOrigin: Int? = 1
    ) {
        self.session = session
        self.coordinator = coordinator
        self.maximumConcurrencyPerOrigin = maximumConcurrencyPerOrigin
    }

    public func upload(request: HTTPUploadRequest) async throws -> HTTPUploadResponse {
        try await coordinator.perform(
            for: request.url,
            maximumConcurrency: maximumConcurrencyPerOrigin
        ) {
            var urlRequest = URLRequest(url: request.url)
            urlRequest.httpMethod = "POST"
            urlRequest.httpBody = request.body
            for (key, value) in request.headers {
                urlRequest.setValue(value, forHTTPHeaderField: key)
            }
            let (data, response) = try await session.data(for: urlRequest)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            return HTTPUploadResponse(data: data, statusCode: statusCode)
        }
    }
}
