import Foundation

public actor HTTPOriginRequestCoordinator {
    public static let shared = HTTPOriginRequestCoordinator()

    private struct Waiter {
        let maximumConcurrency: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var activeCountsByOrigin: [String: Int] = [:]
    private var waitersByOrigin: [String: [Waiter]] = [:]

    public init() {}

    public func perform<Result: Sendable>(
        for url: URL,
        maximumConcurrency: Int? = 1,
        operation: @Sendable () async throws -> Result
    ) async rethrows -> Result {
        let origin = Self.originKey(for: url)
        await acquire(origin: origin, maximumConcurrency: maximumConcurrency)
        do {
            let result = try await operation()
            release(origin: origin)
            return result
        } catch {
            release(origin: origin)
            throw error
        }
    }

    private func acquire(origin: String, maximumConcurrency: Int?) async {
        let limit = maximumConcurrency.map { max(1, $0) }
        let activeCount = activeCountsByOrigin[origin, default: 0]
        if limit == nil || (waitersByOrigin[origin, default: []].isEmpty && activeCount < limit!) {
            activeCountsByOrigin[origin] = activeCount + 1
            return
        }
        await withCheckedContinuation { continuation in
            waitersByOrigin[origin, default: []].append(
                Waiter(maximumConcurrency: limit!, continuation: continuation)
            )
        }
    }

    private func release(origin: String) {
        let activeCount = max(0, activeCountsByOrigin[origin, default: 0] - 1)
        activeCountsByOrigin[origin] = activeCount
        guard var waiters = waitersByOrigin[origin], !waiters.isEmpty else {
            activeCountsByOrigin.removeValue(forKey: origin)
            waitersByOrigin.removeValue(forKey: origin)
            return
        }

        while let first = waiters.first,
              activeCountsByOrigin[origin, default: 0] < first.maximumConcurrency {
            waiters.removeFirst()
            activeCountsByOrigin[origin, default: 0] += 1
            first.continuation.resume()
        }
        if waiters.isEmpty {
            waitersByOrigin.removeValue(forKey: origin)
        } else {
            waitersByOrigin[origin] = waiters
        }
    }

    private static func originKey(for url: URL) -> String {
        let scheme = url.scheme?.lowercased() ?? ""
        let host = url.host?.lowercased() ?? ""
        let defaultPort = scheme == "https" ? 443 : 80
        return "\(scheme)://\(host):\(url.port ?? defaultPort)"
    }
}
