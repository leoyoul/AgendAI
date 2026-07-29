import Foundation

/// 统一的 URLSession 工厂：所有模型侧 HTTP 调用（ASR、后处理、模型列表探测、声纹上传）
/// 都必须通过这里拿到 URLSession，避免 URLSession.shared 的默认"无超时"行为
/// 导致远端挂起时录音管线永远等待。
public enum HTTPSessionFactory {
    /// 单个请求的最长等待时间（发起到首字节返回）。
    public static let defaultRequestTimeout: TimeInterval = 15
    /// 整个请求的最长时间（含大文件上传）。
    public static let defaultResourceTimeout: TimeInterval = 120
    public static let asrRequestTimeout: TimeInterval = 900
    public static let asrResourceTimeout: TimeInterval = 900
    public static let generationRequestTimeout: TimeInterval = 900
    public static let generationResourceTimeout: TimeInterval = 900

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedSession: URLSession?

    public static func shared() -> URLSession {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cachedSession { return cached }
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = defaultRequestTimeout
        cfg.timeoutIntervalForResource = defaultResourceTimeout
        cfg.httpMaximumConnectionsPerHost = 4
        cfg.waitsForConnectivity = false
        let session = URLSession(configuration: cfg)
        cachedSession = session
        return session
    }

    /// 单元测试专用：给自定义 configuration，用于验证超时行为。
    public static func make(configuration: URLSessionConfiguration) -> URLSession {
        URLSession(configuration: configuration)
    }

    /// 本地 ASR 首次加载和推理可能需要数分钟，短超时会让仍在服务端运行的请求被重复提交。
    public static func asr() -> URLSession {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = asrRequestTimeout
        cfg.timeoutIntervalForResource = asrResourceTimeout
        cfg.httpMaximumConnectionsPerHost = 1
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }

    /// 会议纪要属于长文本生成，不能复用实时链路的 15 秒首字节超时。
    public static func generation() -> URLSession {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = generationRequestTimeout
        cfg.timeoutIntervalForResource = generationResourceTimeout
        cfg.httpMaximumConnectionsPerHost = 2
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }
}
