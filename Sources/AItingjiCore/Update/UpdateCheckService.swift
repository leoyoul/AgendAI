import Foundation

/// A release published for the official AgendAI repository.
public struct GitHubRelease: Sendable, Equatable {
    public let version: AppVersion
    public let name: String
    public let htmlURL: URL

    public init(version: AppVersion, name: String, htmlURL: URL) {
        self.version = version
        self.name = name
        self.htmlURL = htmlURL
    }
}

/// Numeric application version. An optional leading `v` is ignored.
public struct AppVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let components: [Int]

    public init(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = trimmed.first == "v" || trimmed.first == "V" ? String(trimmed.dropFirst()) : trimmed
        guard !raw.isEmpty else { throw UpdateCheckError.invalidVersion(value) }

        let pieces = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard !pieces.isEmpty,
              pieces.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\Character.isNumber) }) else {
            throw UpdateCheckError.invalidVersion(value)
        }
        let parsed = pieces.compactMap { Int($0) }
        guard parsed.count == pieces.count, parsed.allSatisfy({ $0 >= 0 }) else {
            throw UpdateCheckError.invalidVersion(value)
        }
        components = parsed
    }

    public var description: String { components.map(String.init).joined(separator: ".") }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}

public enum UpdateCheckResult: Sendable, Equatable {
    case updateAvailable(GitHubRelease)
    case upToDate
}

public enum UpdateCheckError: Error, LocalizedError, Sendable, Equatable {
    case invalidVersion(String)
    case invalidResponse
    case network(String)
    case httpStatus(Int)
    case decodingFailed
    case untrustedReleaseURL

    public var errorDescription: String? {
        switch self {
        case .invalidVersion(let value): return "版本号无效：\(value)"
        case .invalidResponse: return "更新服务返回了无效响应"
        case .network(let detail): return "无法连接更新服务：\(detail)"
        case .httpStatus(let status): return "更新服务请求失败（HTTP \(status)）"
        case .decodingFailed: return "无法读取更新信息"
        case .untrustedReleaseURL: return "更新下载地址不受信任"
        }
    }
}

public struct UpdateCheckService: Sendable {
    public typealias HTTPLoader = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    public static let repositoryOwner = "leoyoul"
    public static let repositoryName = "AgendAI"
    public static let latestReleaseURL = URL(string: "https://api.github.com/repos/leoyoul/AgendAI/releases/latest")!

    private let loader: HTTPLoader

    public init() {
        self.loader = Self.defaultLoader
    }

    public init(loader: @escaping HTTPLoader) {
        self.loader = loader
    }

    public func check(currentVersion: String) async throws -> UpdateCheckResult {
        try await check(currentVersion: AppVersion(currentVersion))
    }

    public func check(currentVersion: AppVersion) async throws -> UpdateCheckResult {
        var request = URLRequest(url: Self.latestReleaseURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("AgendAI-UpdateChecker", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await loader(request)
        } catch let error as UpdateCheckError {
            throw error
        } catch {
            throw UpdateCheckError.network(error.localizedDescription)
        }
        guard (200..<300).contains(response.statusCode) else {
            throw UpdateCheckError.httpStatus(response.statusCode)
        }

        let payload: ReleasePayload
        do {
            payload = try JSONDecoder().decode(ReleasePayload.self, from: data)
        } catch {
            throw UpdateCheckError.decodingFailed
        }
        guard payload.draft == false, payload.prerelease == false,
              let tag = payload.tagName,
              let htmlURL = payload.htmlURL else {
            throw UpdateCheckError.decodingFailed
        }
        let releaseVersion: AppVersion
        do {
            releaseVersion = try AppVersion(tag)
        } catch let error as UpdateCheckError {
            throw error
        } catch {
            throw UpdateCheckError.decodingFailed
        }
        guard Self.isTrustedReleaseURL(htmlURL) else {
            throw UpdateCheckError.untrustedReleaseURL
        }

        guard currentVersion < releaseVersion else { return .upToDate }
        let name = payload.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = if let name, !name.isEmpty { name } else { tag }
        return .updateAvailable(GitHubRelease(
            version: releaseVersion,
            name: displayName,
            htmlURL: htmlURL
        ))
    }

    public static func isTrustedReleaseURL(_ url: URL?) -> Bool {
        guard let url,
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "github.com" else { return false }
        let components = url.pathComponents
        let prefix = ["/", repositoryOwner, repositoryName, "releases"]
        let suffix = components.dropFirst(prefix.count)
        return !suffix.isEmpty
            && Array(components.prefix(prefix.count)) == prefix
            && suffix.allSatisfy { $0 != "." && $0 != ".." }
    }

    private static let defaultLoader: HTTPLoader = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw UpdateCheckError.invalidResponse
        }
        return (data, httpResponse)
    }
}

private struct ReleasePayload: Decodable {
    let tagName: String?
    let name: String?
    let htmlURL: URL?
    let draft: Bool
    let prerelease: Bool

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case htmlURL = "html_url"
        case draft
        case prerelease
    }
}
