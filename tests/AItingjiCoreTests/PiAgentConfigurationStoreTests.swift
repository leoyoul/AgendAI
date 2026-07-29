import AItingjiCore
import Foundation
import Testing

@Suite("Pi Agent global configuration")
struct PiAgentConfigurationStoreTests {
    @Test("loads global skills, MCP servers, packages, and local extensions")
    func loadsSnapshot() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeSkill(name: "local-skill", description: "本机技能")
        try fixture.writeLocalExtension(name: "local-tool")
        try fixture.writePackage(
            name: "demo-package",
            version: "1.2.3",
            skills: ["skills"],
            extensions: ["index.ts"]
        )
        try fixture.writeSettings([
            "theme": "dark",
            "packages": ["npm:demo-package"],
            "mcpServers": [
                "demo": ["command": "/usr/bin/demo", "args": ["serve"]],
            ],
        ])

        let snapshot = try fixture.store.loadSnapshot()

        #expect(snapshot.skills.map(\.name) == ["local-skill", "package-skill"])
        #expect(snapshot.skills.first(where: { $0.name == "local-skill" })?.isEditable == true)
        #expect(snapshot.skills.first(where: { $0.name == "package-skill" })?.isEditable == false)
        #expect(snapshot.mcpServers.map(\.name) == ["demo"])
        let hasPackage = snapshot.plugins.contains(where: {
            $0.kind == .package && $0.name == "demo-package" && $0.version == "1.2.3"
        })
        let hasLocalExtension = snapshot.plugins.contains(where: {
            $0.kind == .localExtension && $0.name == "local-tool"
        })
        #expect(hasPackage)
        #expect(hasLocalExtension)
    }

    @Test("skill CRUD is restricted to the global Pi user skill root")
    func skillCRUD() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        let created = try fixture.store.createSkill(
            name: "meeting-review",
            description: "检查会议结果",
            instructions: "# 工作流\n\n检查事实。"
        )
        #expect(created.isEditable)
        #expect(created.description == "检查会议结果")
        #expect(FileManager.default.fileExists(atPath: created.fileURL.path))

        let updatedContent = created.content.replacingOccurrences(of: "检查事实。", with: "核对事实。")
        let updated = try fixture.store.updateSkill(created, content: updatedContent)
        #expect(updated.content.contains("核对事实。"))
        #expect(try fixture.backups().count == 1)

        try fixture.store.deleteSkill(updated)
        #expect(!FileManager.default.fileExists(atPath: updated.fileURL.path))
        #expect(try fixture.store.loadSnapshot().skills.isEmpty)

        let outside = PiAgentSkill(
            name: "outside",
            description: "outside",
            content: "---\nname: outside\ndescription: outside\n---\n",
            fileURL: fixture.root.appendingPathComponent("outside/SKILL.md"),
            origin: .user,
            isEditable: true
        )
        #expect(throws: PiAgentConfigurationError.skillNotEditable) {
            try fixture.store.deleteSkill(outside)
        }
        #expect(throws: PiAgentConfigurationError.invalidSkillName) {
            try fixture.store.createSkill(name: "../escape", description: "bad", instructions: "bad")
        }
    }

    @Test("MCP CRUD preserves unrelated Pi settings and arbitrary server fields")
    func mcpCRUDPreservesSettings() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeSettings([
            "defaultModel": "model-a",
            "custom": ["keep": true],
            "mcpServers": ["old": ["url": "https://old.example.test"]],
        ])

        let saved = try fixture.store.upsertMCPServer(
            name: "remote",
            configurationJSON: #"{"url":"https://mcp.example.test","headers":{"X-Test":"yes"}}"#
        )
        #expect(saved.configurationJSON.contains("headers"))
        var settings = try fixture.readSettings()
        #expect(settings["defaultModel"] as? String == "model-a")
        #expect((settings["custom"] as? [String: Any])?["keep"] as? Bool == true)
        #expect((settings["mcpServers"] as? [String: Any])?["remote"] != nil)

        try fixture.store.deleteMCPServer(name: "old")
        settings = try fixture.readSettings()
        #expect((settings["mcpServers"] as? [String: Any])?["old"] == nil)
        #expect((settings["mcpServers"] as? [String: Any])?["remote"] != nil)
        #expect(try fixture.backups().count == 2)

        #expect(throws: PiAgentConfigurationError.invalidMCPConfiguration) {
            try fixture.store.upsertMCPServer(name: "bad", configurationJSON: "[]")
        }
    }

    @Test("local extension CRUD writes only inside the global extension root")
    func localExtensionCRUD() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        let plugin = try fixture.store.createLocalExtension(
            name: "meeting-tools",
            content: "export default function () {}\n"
        )
        #expect(plugin.kind == .localExtension)
        #expect(plugin.content?.contains("export default") == true)

        let updated = try fixture.store.updateLocalExtension(plugin, content: "export default 42\n")
        #expect(updated.content == "export default 42\n")
        try fixture.store.deleteLocalExtension(updated)
        #expect(updated.fileURL.map { !FileManager.default.fileExists(atPath: $0.path) } == true)

        #expect(throws: PiAgentConfigurationError.invalidPluginName) {
            try fixture.store.createLocalExtension(name: "../bad", content: "bad")
        }
    }

    @Test("package operations call the resolved Pi executable with global commands")
    func packageCommands() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        try await fixture.store.installPlugin(source: "npm:demo-package")
        try await fixture.store.updatePlugin(source: "npm:demo-package")
        try await fixture.store.removePlugin(source: "npm:demo-package")

        let calls = await fixture.runner.calls
        #expect(calls.map(\.arguments) == [
            ["install", "npm:demo-package"],
            ["update", "npm:demo-package"],
            ["remove", "npm:demo-package"],
        ])
        #expect(calls.allSatisfy { $0.executableURL == fixture.piURL })
    }
}

private struct Fixture {
    let root: URL
    let home: URL
    let packageRoot: URL
    let piURL: URL
    let runner: RecordingPiCommandRunner
    let store: PiAgentConfigurationStore

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PiAgentConfigurationStoreTests-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        packageRoot = root.appendingPathComponent("packages", isDirectory: true)
        piURL = root.appendingPathComponent("bin/pi")
        runner = RecordingPiCommandRunner()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: packageRoot, withIntermediateDirectories: true)
        store = PiAgentConfigurationStore(
            homeDirectoryURL: home,
            packageRoots: [packageRoot],
            executableResolver: FixedPiExecutableResolver(url: piURL),
            commandRunner: runner
        )
    }

    var settingsURL: URL {
        home.appendingPathComponent(".pi/agent/settings.json")
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    func writeSettings(_ settings: [String: Any]) throws {
        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: settingsURL)
    }

    func readSettings() throws -> [String: Any] {
        try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any]
        )
    }

    func writeSkill(name: String, description: String) throws {
        let url = home.appendingPathComponent(".pi/agent/skills/\(name)/SKILL.md")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "---\nname: \(name)\ndescription: \(description)\n---\n\n# Test\n".write(
            to: url,
            atomically: true,
            encoding: .utf8
        )
    }

    func writeLocalExtension(name: String) throws {
        let url = home.appendingPathComponent(".pi/agent/extensions/\(name).ts")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "export default function () {}\n".write(to: url, atomically: true, encoding: .utf8)
    }

    func writePackage(name: String, version: String, skills: [String], extensions: [String]) throws {
        let packageURL = packageRoot.appendingPathComponent(name, isDirectory: true)
        let skillsURL = packageURL.appendingPathComponent("skills/package-skill/SKILL.md")
        try FileManager.default.createDirectory(at: skillsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "---\nname: \"package-skill\"\ndescription: |\n  包技能第一行\n  包技能第二行\n---\n".write(
            to: skillsURL,
            atomically: true,
            encoding: .utf8
        )
        let package: [String: Any] = [
            "name": name,
            "version": version,
            "pi": ["skills": skills, "extensions": extensions],
        ]
        let data = try JSONSerialization.data(withJSONObject: package, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: packageURL.appendingPathComponent("package.json"))
    }

    func backups() throws -> [URL] {
        let root = home.appendingPathComponent(".pi/agent/backups", isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "bak" }
    }
}

private struct FixedPiExecutableResolver: PiExecutableResolving {
    let url: URL
    func resolve() throws -> URL { url }
}

private actor RecordingPiCommandRunner: PiCommandRunning {
    struct Call: Sendable {
        let executableURL: URL
        let arguments: [String]
        let currentDirectoryURL: URL
    }

    private(set) var calls: [Call] = []

    func run(executableURL: URL, arguments: [String], currentDirectoryURL: URL) async throws -> PiCommandResult {
        calls.append(Call(
            executableURL: executableURL,
            arguments: arguments,
            currentDirectoryURL: currentDirectoryURL
        ))
        return PiCommandResult(exitCode: 0)
    }
}
