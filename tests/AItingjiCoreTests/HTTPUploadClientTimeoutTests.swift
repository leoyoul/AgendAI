import AItingjiCore
import Foundation
import Network
import Testing

/// 验证 HTTPUploadClient 的默认 URLSession 会遵守超时。
/// 用一个 accept 后不再响应的 tcp listener 模拟"挂起的服务器"，
/// 客户端应在 configured request timeout 内报错。
@Test
func httpUploadClientTimesOutWhenServerHangs() async throws {
    let listener = try makeHangingListener()
    let port = listener.port!.rawValue
    listener.newConnectionHandler = { conn in
        // 收到连接后不做任何事，让请求挂死。
        conn.start(queue: .global())
    }
    listener.start(queue: .global())
    defer { listener.cancel() }

    // 走短超时的 session，避免测试跑 15 秒。
    let cfg = URLSessionConfiguration.ephemeral
    cfg.timeoutIntervalForRequest = 1.5
    cfg.timeoutIntervalForResource = 3
    cfg.waitsForConnectivity = false
    let session = HTTPSessionFactory.make(configuration: cfg)

    let url = URL(string: "http://127.0.0.1:\(port)/upload")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = Data("hello".utf8)

    let start = Date()
    do {
        _ = try await session.data(for: request)
        Issue.record("Expected timeout error but request completed successfully.")
    } catch {
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 6, "Request should time out within a few seconds, took \(elapsed)s")
        let nsError = error as NSError
        // NSURLErrorTimedOut = -1001
        #expect(
            nsError.code == NSURLErrorTimedOut || nsError.domain == NSURLErrorDomain,
            "Expected URL timeout, got: \(nsError)"
        )
    }
}

private func makeHangingListener() throws -> NWListener {
    let params = NWParameters.tcp
    return try NWListener(using: params, on: .any)
}
