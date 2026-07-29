import Foundation

public protocol PiExecutableResolving: Sendable {
    func resolve() throws -> URL
}

public struct PiExecutableResolver: PiExecutableResolving {
    private let environment: [String: String]

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    public func resolve() throws -> URL {
        for candidate in candidates() where FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate.standardizedFileURL
        }
        throw PiAgentRPCClientError.executableNotFound
    }

    private func candidates() -> [URL] {
        var candidates: [URL] = []
        if let pathValue = environment["PATH"] {
            candidates.append(contentsOf: pathValue
                .split(separator: ":", omittingEmptySubsequences: true)
                .map { URL(fileURLWithPath: String($0), isDirectory: true).appendingPathComponent("pi") })
        }
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/pi"))
        candidates.append(URL(fileURLWithPath: "/usr/local/bin/pi"))
        if let home = environment["HOME"], !home.isEmpty {
            candidates.append(
                URL(fileURLWithPath: home, isDirectory: true)
                    .appendingPathComponent(".pi/agent/npm/node_modules/.bin/pi")
            )
        }

        var seen = Set<String>()
        return candidates.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
}
