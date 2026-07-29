import Foundation

public struct PiAgentResources: Equatable, Sendable {
    public var extensions: [URL]
    public var skills: [URL]

    public init(extensions: [URL] = [], skills: [URL] = []) {
        self.extensions = extensions
        self.skills = skills
    }
}

public struct PiAgentResourceResolver: Sendable {
    private let homeDirectoryURL: URL
    private let packageRoots: [URL]

    public init(
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        packageRoots: [URL]? = nil
    ) {
        self.homeDirectoryURL = homeDirectoryURL
        self.packageRoots = packageRoots ?? [
            homeDirectoryURL.appendingPathComponent(".pi/agent/npm/node_modules", isDirectory: true),
            URL(fileURLWithPath: "/opt/homebrew/lib/node_modules", isDirectory: true),
            URL(fileURLWithPath: "/usr/local/lib/node_modules", isDirectory: true),
        ]
    }

    public func resolve() -> PiAgentResources {
        let agentRoot = homeDirectoryURL.appendingPathComponent(".pi/agent", isDirectory: true)
        var extensionURLs = resourceFiles(
            in: agentRoot.appendingPathComponent("extensions", isDirectory: true),
            extensions: ["ts", "js", "mjs"]
        )
        var skillURLs = skillDirectories(
            in: agentRoot.appendingPathComponent("skills", isDirectory: true)
        )
        skillURLs.append(contentsOf: skillDirectories(
            in: homeDirectoryURL.appendingPathComponent(".agents/skills", isDirectory: true)
        ))

        let settings = configuredResources(settingsURL: agentRoot.appendingPathComponent("settings.json"))
        extensionURLs.append(contentsOf: settings.extensions.compactMap {
            existingURL(resolvedPath($0, relativeTo: agentRoot))
        })
        skillURLs.append(contentsOf: settings.skills.compactMap {
            existingURL(resolvedPath($0, relativeTo: agentRoot))
        })

        for package in settings.packages {
            guard let packageURL = installedPackageURL(source: package.source, relativeTo: agentRoot),
                  let manifest = packageManifest(at: packageURL) else {
                continue
            }
            extensionURLs.append(contentsOf: filteredPackageExtensions(
                manifest.extensions,
                filter: package.extensions,
                packageURL: packageURL
            ))
            skillURLs.append(contentsOf: filteredPackageSkills(
                manifest.skills,
                filter: package.skills,
                packageURL: packageURL
            ))
        }

        return PiAgentResources(
            extensions: deduplicated(extensionURLs),
            skills: deduplicated(skillURLs)
        )
    }

    private struct ConfiguredPackage {
        var source: String
        var extensions: [String]?
        var skills: [String]?
    }

    private func configuredResources(settingsURL: URL) -> (
        packages: [ConfiguredPackage], extensions: [String], skills: [String]
    ) {
        guard let data = try? Data(contentsOf: settingsURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ([], [], [])
        }
        let packages = (object["packages"] as? [Any] ?? []).compactMap { value -> ConfiguredPackage? in
            if let source = value as? String {
                return ConfiguredPackage(source: source, extensions: nil, skills: nil)
            }
            guard let configuration = value as? [String: Any],
                  let source = configuration["source"] as? String else { return nil }
            return ConfiguredPackage(
                source: source,
                extensions: configuration["extensions"] as? [String],
                skills: configuration["skills"] as? [String]
            )
        }
        return (
            packages,
            object["extensions"] as? [String] ?? [],
            object["skills"] as? [String] ?? []
        )
    }

    private func installedPackageURL(source: String, relativeTo agentRoot: URL) -> URL? {
        if source.hasPrefix("npm:"), let name = npmPackageName(from: source) {
            return installedNPMPackageURL(named: name)
        }
        let candidate = resolvedPath(source, relativeTo: agentRoot)
        guard FileManager.default.fileExists(atPath: candidate.appendingPathComponent("package.json").path) else {
            return nil
        }
        return candidate.standardizedFileURL
    }

    private func installedNPMPackageURL(named name: String) -> URL? {
        for root in packageRoots {
            let candidate = root.appendingPathComponent(name, isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("package.json").path) {
                return candidate
            }
        }
        return nil
    }

    private func npmPackageName(from source: String) -> String? {
        let spec = String(source.dropFirst(4))
        guard !spec.isEmpty else { return nil }
        if spec.hasPrefix("@"),
           let versionSeparator = spec.dropFirst().lastIndex(of: "@") {
            return String(spec[..<versionSeparator])
        }
        return String(spec.split(separator: "@", maxSplits: 1).first ?? "")
    }

    private func packageManifest(at packageURL: URL) -> (extensions: [String], skills: [String])? {
        let url = packageURL.appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard let pi = object["pi"] as? [String: Any] else {
            return (
                extensions: FileManager.default.fileExists(
                    atPath: packageURL.appendingPathComponent("extensions", isDirectory: true).path
                ) ? ["extensions"] : [],
                skills: FileManager.default.fileExists(
                    atPath: packageURL.appendingPathComponent("skills", isDirectory: true).path
                ) ? ["skills"] : []
            )
        }
        return (
            extensions: pi["extensions"] as? [String] ?? [],
            skills: pi["skills"] as? [String] ?? []
        )
    }

    private func filteredPackageExtensions(
        _ paths: [String],
        filter: [String]?,
        packageURL: URL
    ) -> [URL] {
        guard filter?.isEmpty != true else { return [] }
        let urls = paths.compactMap { existingURL(packageURL.appendingPathComponent($0)) }
        guard let filter else { return urls }
        let allowed = Set(filter)
        return urls.flatMap { url -> [URL] in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                return allowed.contains(url.deletingPathExtension().lastPathComponent) ? [url] : []
            }
            return resourceFiles(in: url, extensions: ["ts", "js", "mjs"]).filter {
                allowed.contains($0.deletingPathExtension().lastPathComponent)
            }
        }
    }

    private func filteredPackageSkills(
        _ paths: [String],
        filter: [String]?,
        packageURL: URL
    ) -> [URL] {
        guard filter?.isEmpty != true else { return [] }
        let urls = paths.compactMap {
            existingURL(packageURL.appendingPathComponent($0, isDirectory: true))
        }
        guard let filter else { return urls }
        return urls.flatMap { url -> [URL] in
            var matches: [URL] = []
            for name in filter {
                let candidate = url.appendingPathComponent(name, isDirectory: true)
                if FileManager.default.fileExists(
                    atPath: candidate.appendingPathComponent("SKILL.md").path
                ) {
                    matches.append(candidate.standardizedFileURL)
                } else if url.lastPathComponent == name,
                          FileManager.default.fileExists(
                            atPath: url.appendingPathComponent("SKILL.md").path
                          ) {
                    matches.append(url.standardizedFileURL)
                }
            }
            return matches
        }
    }

    private func resolvedPath(_ value: String, relativeTo root: URL) -> URL {
        if value == "~" {
            return homeDirectoryURL
        }
        if value.hasPrefix("~/") {
            return homeDirectoryURL.appendingPathComponent(String(value.dropFirst(2)))
        }
        if value.hasPrefix("/") {
            return URL(fileURLWithPath: value)
        }
        return root.appendingPathComponent(value)
    }

    private func resourceFiles(in directory: URL, extensions: Set<String>) -> [URL] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return files.filter { extensions.contains($0.pathExtension.lowercased()) }
    }

    private func skillDirectories(in directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var directories: [URL] = []
        for case let url as URL in enumerator where url.lastPathComponent == "SKILL.md" {
            directories.append(url.deletingLastPathComponent())
        }
        return directories
    }

    private func existingURL(_ url: URL) -> URL? {
        FileManager.default.fileExists(atPath: url.path) ? url.standardizedFileURL : nil
    }

    private func deduplicated(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        return urls
            .map(\.standardizedFileURL)
            .filter { seen.insert($0.path).inserted }
            .sorted { $0.path < $1.path }
    }
}
