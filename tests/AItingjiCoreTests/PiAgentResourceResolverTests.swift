import Foundation
import Testing
@testable import AItingjiCore

@Suite("Pi Agent resources")
struct PiAgentResourceResolverTests {
    @Test("loads user extensions and configured package extensions and skills")
    func resolvesConfiguredResources() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-resources-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let agentRoot = root.appendingPathComponent(".pi/agent", isDirectory: true)
        let userExtensions = agentRoot.appendingPathComponent("extensions", isDirectory: true)
        let packageRoot = root.appendingPathComponent("node_modules", isDirectory: true)
        let package = packageRoot.appendingPathComponent("web-tools", isDirectory: true)
        let packageSkills = package.appendingPathComponent("skills", isDirectory: true)
        try FileManager.default.createDirectory(at: userExtensions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: packageSkills, withIntermediateDirectories: true)
        try Data().write(to: userExtensions.appendingPathComponent("custom.ts"))
        try Data().write(to: package.appendingPathComponent("index.ts"))
        try Data("# Research".utf8).write(to: packageSkills.appendingPathComponent("SKILL.md"))
        try JSONSerialization.data(withJSONObject: ["packages": ["npm:web-tools"]])
            .write(to: agentRoot.appendingPathComponent("settings.json"))
        try JSONSerialization.data(withJSONObject: [
            "pi": ["extensions": ["./index.ts"], "skills": ["./skills"]],
        ]).write(to: package.appendingPathComponent("package.json"))

        let resources = PiAgentResourceResolver(
            homeDirectoryURL: root,
            packageRoots: [packageRoot]
        ).resolve()

        #expect(resources.extensions.map(\.lastPathComponent).sorted() == ["custom.ts", "index.ts"])
        #expect(resources.skills == [packageSkills.standardizedFileURL])
    }

    @Test("loads shared and explicit resources and honors package filters")
    func resolvesSharedExplicitAndFilteredResources() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-resources-filtered-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let agentRoot = root.appendingPathComponent(".pi/agent", isDirectory: true)
        let sharedSkill = root.appendingPathComponent(".agents/skills/shared/SKILL.md")
        let explicitSkill = agentRoot.appendingPathComponent("extra/skill/SKILL.md")
        let explicitExtension = agentRoot.appendingPathComponent("extra/tool.ts")
        let packageRoot = root.appendingPathComponent("node_modules", isDirectory: true)
        let package = packageRoot.appendingPathComponent("filtered-tools", isDirectory: true)
        let keepSkill = package.appendingPathComponent("skills/keep/SKILL.md")
        let skipSkill = package.appendingPathComponent("skills/skip/SKILL.md")
        try FileManager.default.createDirectory(at: sharedSkill.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: explicitSkill.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: keepSkill.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: skipSkill.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: sharedSkill)
        try Data().write(to: explicitSkill)
        try Data().write(to: explicitExtension)
        try Data().write(to: keepSkill)
        try Data().write(to: skipSkill)
        try JSONSerialization.data(withJSONObject: [
            "packages": [[
                "source": "npm:filtered-tools",
                "skills": ["keep"],
                "extensions": [],
            ]],
            "skills": ["extra/skill"],
            "extensions": ["extra/tool.ts"],
        ]).write(to: agentRoot.appendingPathComponent("settings.json"))
        try JSONSerialization.data(withJSONObject: [
            "pi": ["extensions": ["extensions"], "skills": ["skills"]],
        ]).write(to: package.appendingPathComponent("package.json"))

        let resources = PiAgentResourceResolver(
            homeDirectoryURL: root,
            packageRoots: [packageRoot]
        ).resolve()

        #expect(resources.extensions == [explicitExtension.standardizedFileURL])
        #expect(resources.skills.map(\.lastPathComponent).sorted() == ["keep", "shared", "skill"])
    }
}
