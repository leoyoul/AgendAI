@testable import AItingjiCore
import CryptoKit
import Foundation
import Testing

@Test
func meetingDirectoryLayoutBuildsStableContainedJobPaths() throws {
    let root = URL(fileURLWithPath: "/tmp/会小纪测试", isDirectory: true)
    let layout = MeetingDirectoryLayout(applicationSupportDirectory: root)

    #expect(try layout.jobDirectory(meetingID: "meeting-1", jobID: "job-1").path ==
        "/tmp/会小纪测试/Meetings/meeting-1/agent/jobs/job-1")
    #expect(try layout.relativeJobDirectory(jobID: "job-1") == "agent/jobs/job-1")
    #expect(throws: MeetingDirectoryLayoutError.invalidPathComponent("..")) {
        try layout.jobDirectory(meetingID: "..", jobID: "job-1")
    }
    #expect(throws: MeetingDirectoryLayoutError.invalidPathComponent("job/1")) {
        try layout.jobDirectory(meetingID: "meeting-1", jobID: "job/1")
    }
}

@Test
func htmlResourceScannerFindsMediaAttributesButIgnoresOrdinaryLinks() throws {
    let html = #"""
    <!doctype html><html><head></head><body>
      <a href="https://example.com/source">来源</a>
      <img src="assets/chart.png">
      <source src='assets/audio.m4a' srcset="assets/chart.png 1x, assets/chart@2x.png 2x">
    </body></html>
    """#

    let references = try HTMLResourceReferenceScanner().scan(html)

    #expect(references.map(\.value) == [
        "assets/chart.png",
        "assets/audio.m4a",
        "assets/chart.png",
        "assets/chart@2x.png"
    ])
    #expect(!references.contains { $0.value.contains("example.com") })
}

@Test(arguments: [
    #"<html><head><base href="https://evil.example/"></head><body><img src="assets/chart.png"></body></html>"#,
    #"<html><head><style>body{background:url(https://evil.example/a.png)}</style></head><body></body></html>"#,
    #"<html><head><style>body{background:u/**/rl(https://evil.example/a.png)}</style></head><body></body></html>"#,
    #"<html><head><style>body{background:u\72l(https://evil.example/a.png)}</style></head><body></body></html>"#,
    #"<html><head></head><body><svg><image href="https://evil.example/a.png"></image></svg></body></html>"#,
    #"<html><head></head><body><img onerror="alert(1)" src="assets/chart.png"></body></html>"#,
    #"<html><head></head><body background="https://evil.example/a.png"></body></html>"#,
    #"<html><head></head><body><area href="javascript:alert(1)"></body></html>"#,
    #"<html><head></head><body><a href="https://example.com" ping="https://evil.example/log">来源</a></body></html>"#
])
func htmlResourceScannerRejectsActiveOrExternalResourceChannels(html: String) {
    #expect(throws: HTMLResourceReferenceScannerError.self) {
        try HTMLResourceReferenceScanner().scan(html)
    }
}

@Test
func htmlResourceScannerHandlesSlashSeparatedAttributes() throws {
    let references = try HTMLResourceReferenceScanner().scan(
        #"<html><head></head><body><img/src="https&colon;//evil.example/a.png"></body></html>"#
    )
    #expect(references.map(\.value) == ["https://evil.example/a.png"])
}

@Test
func meetingAgentImporterValidatesAndPublishesCompletePackage() throws {
    let fixture = try AgentResultFixture.make()
    defer { fixture.remove() }
    let importer = MeetingAgentResultImporter(
        agentJobsRoot: fixture.agentJobsRoot,
        meetingDirectoryLayout: MeetingDirectoryLayout(applicationSupportDirectory: fixture.tinglanRoot)
    )

    let validated = try importer.validate(response: fixture.response, expected: fixture.expectation)
    let published = try importer.publish(validated)

    #expect(published.reportURL.path.hasSuffix("/Meetings/meeting-1/agent/jobs/job-1/report.html"))
    #expect(FileManager.default.fileExists(atPath: published.reportURL.path))
    #expect(published.todos.items.count == 1)
    #expect(published.todos.items[0].confirmationStatus == .pendingConfirmation)
    #expect(published.manifest.provider.name == "mock")
    #expect(published.relativeJobDirectory == "agent/jobs/job-1")

    let reused = try importer.publish(validated)
    #expect(reused.jobDirectory == published.jobDirectory)
}

@Test
func meetingAgentImporterRejectsIdentityMismatchAndOutsideRoot() throws {
    let fixture = try AgentResultFixture.make()
    defer { fixture.remove() }
    let importer = fixture.importer

    var mismatchedRequest = fixture.response
    mismatchedRequest.requestID = "other-job"
    #expect(throws: MeetingAgentResultImportError.identityMismatch("job_id 与 request_id 不一致")) {
        try importer.validate(response: mismatchedRequest, expected: fixture.expectation)
    }

    var wrongMeeting = fixture.response
    wrongMeeting.meetingID = "other-meeting"
    #expect(throws: MeetingAgentResultImportError.identityMismatch("meeting_id 与本地作业不一致")) {
        try importer.validate(response: wrongMeeting, expected: fixture.expectation)
    }

    let outside = fixture.root.appendingPathComponent("outside", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    var outsideResponse = fixture.response
    outsideResponse.resultPath = outside.path
    #expect(throws: MeetingAgentResultImportError.resultOutsideAgentRoot) {
        try importer.validate(response: outsideResponse, expected: fixture.expectation)
    }
}

@Test
func meetingAgentImporterRejectsSymlinksAndTamperedFiles() throws {
    let fixture = try AgentResultFixture.make()
    defer { fixture.remove() }

    let asset = fixture.outputDirectory.appendingPathComponent("assets/chart.png")
    try FileManager.default.removeItem(at: asset)
    try FileManager.default.createSymbolicLink(
        at: asset,
        withDestinationURL: fixture.outputDirectory.appendingPathComponent("report.html")
    )
    #expect(throws: MeetingAgentResultImportError.symbolicLink("assets/chart.png")) {
        try fixture.importer.validate(response: fixture.response, expected: fixture.expectation)
    }

    try FileManager.default.removeItem(at: asset)
    try Data("tampered".utf8).write(to: asset)
    #expect(throws: MeetingAgentResultImportError.fileSizeMismatch("assets/chart.png")) {
        try fixture.importer.validate(response: fixture.response, expected: fixture.expectation)
    }
}

@Test
func meetingAgentImporterRejectsSameSizeHashTampering() throws {
    let fixture = try AgentResultFixture.make()
    defer { fixture.remove() }
    let asset = fixture.outputDirectory.appendingPathComponent("assets/chart.png")
    try Data("PNG-CONTENT".utf8).write(to: asset)

    #expect(throws: MeetingAgentResultImportError.fileHashMismatch("assets/chart.png")) {
        try fixture.importer.validate(response: fixture.response, expected: fixture.expectation)
    }
}

@Test(arguments: [
    "https://example.com/image.png",
    "http://example.com/image.png",
    "file:///tmp/image.png",
    "data:image/png;base64,AAAA",
    "/tmp/image.png",
    "../image.png",
    "assets/not-declared.png"
])
func meetingAgentImporterRejectsUnsafeOrUndeclaredMediaReferences(reference: String) throws {
    let fixture = try AgentResultFixture.make(reportReference: reference)
    defer { fixture.remove() }

    #expect(throws: MeetingAgentResultImportError.self) {
        try fixture.importer.validate(response: fixture.response, expected: fixture.expectation)
    }
}

@Test
func meetingAgentImporterRejectsBaseURLAndCSSResourceBypasses() throws {
    for report in [
        #"<html><head><base href="https://evil.example/"></head><body><img src="assets/chart.png"></body></html>"#,
        #"<html><head><style>.hero{background-image:url(https://evil.example/a.png)}</style></head><body></body></html>"#
    ] {
        let fixture = try AgentResultFixture.make(reportHTML: report)
        defer { fixture.remove() }
        #expect(throws: MeetingAgentResultImportError.invalidHTML("资源属性无法解析")) {
            try fixture.importer.validate(response: fixture.response, expected: fixture.expectation)
        }
    }
}

@Test
func meetingAgentImporterRejectsOversizedDeclaredResult() throws {
    let fixture = try AgentResultFixture.make(manifestMutation: { manifest in
        var report = try #require(manifest["report"] as? [String: Any])
        report["size_bytes"] = 20 * 1_024 * 1_024 + 1
        manifest["report"] = report
    })
    defer { fixture.remove() }

    #expect(throws: MeetingAgentResultImportError.invalidManifest("结果包超过 v1 资源上限")) {
        try fixture.importer.validate(response: fixture.response, expected: fixture.expectation)
    }
}

@Test
func meetingAgentImporterRejectsNonStrictOrConfirmedTodos() throws {
    let fixture = try AgentResultFixture.make(todoMutation: { todo in
        var item = try #require(todo["items"] as? [[String: Any]])[0]
        item["confirmation_status"] = "confirmed"
        item["unexpected"] = true
        todo["items"] = [item]
    })
    defer { fixture.remove() }

    #expect(throws: MeetingAgentResultImportError.invalidTodos("待办字段不符合 v1 协议")) {
        try fixture.importer.validate(response: fixture.response, expected: fixture.expectation)
    }
}

@Test
func meetingAgentImporterRefusesConflictingPublishedDirectoryAndKeepsOlderReports() throws {
    let fixture = try AgentResultFixture.make()
    defer { fixture.remove() }
    let published = try fixture.importer.importResult(response: fixture.response, expected: fixture.expectation)
    try Data("changed".utf8).write(to: published.reportURL)

    #expect(throws: MeetingAgentResultImportError.resultConflict) {
        try fixture.importer.importResult(response: fixture.response, expected: fixture.expectation)
    }

    let oldJob = published.jobDirectory.deletingLastPathComponent().appendingPathComponent("old-job", isDirectory: true)
    try FileManager.default.createDirectory(at: oldJob, withIntermediateDirectories: true)
    let oldReport = oldJob.appendingPathComponent("report.html")
    try Data("old report".utf8).write(to: oldReport)
    #expect(FileManager.default.fileExists(atPath: oldReport.path))
}

@Test
func meetingAgentImporterRejectsSymlinkedPublicationParents() throws {
    let fixture = try AgentResultFixture.make()
    defer { fixture.remove() }
    let agentDirectory = fixture.tinglanRoot
        .appendingPathComponent("Meetings/meeting-1/agent", isDirectory: true)
    let outside = fixture.root.appendingPathComponent("publication-escape", isDirectory: true)
    try FileManager.default.createDirectory(at: agentDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
        at: agentDirectory.appendingPathComponent("jobs", isDirectory: true),
        withDestinationURL: outside
    )
    let validated = try fixture.importer.validate(response: fixture.response, expected: fixture.expectation)

    #expect(throws: MeetingAgentResultImportError.symbolicLink("发布目录")) {
        try fixture.importer.publish(validated)
    }
    #expect((try FileManager.default.contentsOfDirectory(atPath: outside.path)).isEmpty)
}

@Test
func meetingAgentImporterCannotEscapeWhenJobsDirectoryIsSwappedDuringPublish() throws {
    let fixture = try AgentResultFixture.make()
    defer { fixture.remove() }
    let jobs = fixture.tinglanRoot.appendingPathComponent("Meetings/meeting-1/agent/jobs", isDirectory: true)
    let movedJobs = jobs.deletingLastPathComponent().appendingPathComponent("jobs-original", isDirectory: true)
    let outside = fixture.root.appendingPathComponent("publication-race-escape", isDirectory: true)
    try FileManager.default.createDirectory(at: jobs, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let importer = MeetingAgentResultImporter(
        agentJobsRoot: fixture.agentJobsRoot,
        meetingDirectoryLayout: MeetingDirectoryLayout(applicationSupportDirectory: fixture.tinglanRoot),
        publicationTestHook: {
        let fileManager = FileManager.default
            try fileManager.moveItem(at: jobs, to: movedJobs)
            try fileManager.createSymbolicLink(at: jobs, withDestinationURL: outside)
        }
    )
    let validated = try importer.validate(response: fixture.response, expected: fixture.expectation)

    #expect(throws: MeetingAgentResultImportError.self) {
        try importer.publish(validated)
    }
    var isDirectory: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: movedJobs.path, isDirectory: &isDirectory) && isDirectory.boolValue)
    let jobsValues = try jobs.resourceValues(forKeys: [.isSymbolicLinkKey])
    #expect(jobsValues.isSymbolicLink == true)
    #expect((try FileManager.default.contentsOfDirectory(atPath: outside.path)).isEmpty)
}

@Test
func meetingAgentImporterPublishesOnlyValidatedSnapshotWhenSourceChanges() throws {
    let fixture = try AgentResultFixture.make()
    defer { fixture.remove() }
    let validated = try fixture.importer.validate(response: fixture.response, expected: fixture.expectation)
    let report = fixture.outputDirectory.appendingPathComponent("report.html")
    let original = try Data(contentsOf: report)
    try Data(repeating: 0x58, count: original.count).write(to: report)

    let published = try fixture.importer.publish(validated)
    #expect(try Data(contentsOf: published.reportURL) == original)
}

private struct AgentResultFixture {
    let root: URL
    let agentJobsRoot: URL
    let tinglanRoot: URL
    let outputDirectory: URL
    let response: MeetingAgentResultResponse
    let expectation: MeetingAgentImportExpectation

    var importer: MeetingAgentResultImporter {
        MeetingAgentResultImporter(
            agentJobsRoot: agentJobsRoot,
            meetingDirectoryLayout: MeetingDirectoryLayout(applicationSupportDirectory: tinglanRoot)
        )
    }

    static func make(
        reportReference: String = "assets/chart.png",
        reportHTML: String? = nil,
        todoMutation: ((inout [String: Any]) throws -> Void)? = nil,
        manifestMutation: ((inout [String: Any]) throws -> Void)? = nil,
        assetData providedAssetData: Data? = nil
    ) throws -> AgentResultFixture {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("tinglan-importer-\(UUID().uuidString)", isDirectory: true)
        let agentJobsRoot = root.appendingPathComponent("agent/jobs", isDirectory: true)
        let output = agentJobsRoot.appendingPathComponent("job-1/output", isDirectory: true)
        let assets = output.appendingPathComponent("assets", isDirectory: true)
        let tinglanRoot = root.appendingPathComponent("tinglan", isDirectory: true)
        try fileManager.createDirectory(at: assets, withIntermediateDirectories: true)

        let defaultReport = """
        <!doctype html><html><head><meta charset="utf-8"></head><body>
        <a href="https://example.com/source">来源</a>
        <img src="\(reportReference)">
        </body></html>
        """
        let report = reportHTML ?? defaultReport
        let reportData = Data(report.utf8)
        let assetData = providedAssetData ?? Data("png-content".utf8)
        try reportData.write(to: output.appendingPathComponent("report.html"))
        try assetData.write(to: assets.appendingPathComponent("chart.png"))

        var todo: [String: Any] = [
            "schema_version": "1.0",
            "job_id": "job-1",
            "meeting_id": "meeting-1",
            "items": [[
                "id": "todo-1",
                "title": "形成方案",
                "description": "形成方案初稿",
                "owner": NSNull(),
                "deadline": NSNull(),
                "deliverable": "方案初稿",
                "acceptance_criteria": "覆盖会议确认范围",
                "evidence": [[
                    "segment_id": "segment-1",
                    "quote": "形成方案初稿",
                    "time_range": "00:01:00-00:01:10"
                ]],
                "confirmation_status": "pending_confirmation",
                "proposed_workflow": "none"
            ]]
        ]
        try todoMutation?(&todo)
        let todosData = try JSONSerialization.data(withJSONObject: todo, options: [.sortedKeys])
        try todosData.write(to: output.appendingPathComponent("todos.json"))

        var manifest: [String: Any] = [
            "schema_version": "1.0",
            "job_id": "job-1",
            "request_id": "job-1",
            "request_hash": String(repeating: "a", count: 64),
            "meeting_id": "meeting-1",
            "provider": ["name": "mock", "run_id": "mock-job-1"],
            "generated_at": "2026-07-18T02:00:00Z",
            "report": descriptor(path: "report.html", data: reportData),
            "todos": descriptor(path: "todos.json", data: todosData).merging(["count": 1]) { _, new in new },
            "assets": [descriptor(path: "assets/chart.png", data: assetData).merging(["media_type": "image/png"]) { _, new in new }],
            "skills_used": [],
            "warnings": []
        ]
        try manifestMutation?(&manifest)
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        try manifestData.write(to: output.appendingPathComponent("manifest.json"))

        let response = MeetingAgentResultResponse(
            schemaVersion: "1.0",
            jobID: "job-1",
            requestID: "job-1",
            meetingID: "meeting-1",
            requestHash: String(repeating: "a", count: 64),
            provider: MeetingAgentProviderDescriptor(name: "mock", runID: "mock-job-1"),
            resultPath: output.path,
            manifestPath: "manifest.json",
            manifestSHA256: sha256(manifestData)
        )
        return AgentResultFixture(
            root: root,
            agentJobsRoot: agentJobsRoot,
            tinglanRoot: tinglanRoot,
            outputDirectory: output,
            response: response,
            expectation: MeetingAgentImportExpectation(
                jobID: "job-1",
                requestID: "job-1",
                meetingID: "meeting-1",
                requestHash: String(repeating: "a", count: 64)
            )
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    private static func descriptor(path: String, data: Data) -> [String: Any] {
        ["path": path, "size_bytes": data.count, "sha256": sha256(data)]
    }
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
