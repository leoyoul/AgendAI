import AItingjiCore
import CryptoKit
import Foundation
import Testing

@Suite("Meeting Agent Mock end-to-end", .serialized)
struct MeetingAgentMockE2ETests {
    @Test("Swift submits to agentd, imports the package, and persists ready state")
    func swiftToAgentdToSQLite() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("tinglan-agent-e2e-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let agentRoot = root.appendingPathComponent("agent", isDirectory: true)
        let attachmentRoot = root.appendingPathComponent("attachments", isDirectory: true)
        let tinglanRoot = root.appendingPathComponent("tinglan", isDirectory: true)
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: attachmentRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let attachmentURL = attachmentRoot.appendingPathComponent("需求说明.txt")
        let attachmentData = Data("项目范围以本次会议确认为准。".utf8)
        try attachmentData.write(to: attachmentURL)

        let jobID = "job-\(UUID().uuidString.lowercased())"
        let meetingID = "meeting-\(UUID().uuidString.lowercased())"
        let request = MeetingAgentJobRequest(
            requestID: jobID,
            meeting: MeetingAgentMeetingInput(
                id: meetingID,
                title: "Agent Mock 闭环会议",
                startedAt: "2026-07-18T01:00:00Z",
                endedAt: "2026-07-18T02:00:00Z",
                timezone: "Asia/Shanghai",
                captureSource: "mixed",
                participants: []
            ),
            transcript: MeetingAgentTranscriptInput(
                language: "zh-CN",
                plainText: "本次会议确认先完成输入输出协议，再接入真实 Provider。",
                segments: [
                    MeetingAgentTranscriptSegmentInput(
                        id: "segment-1",
                        startMs: 0,
                        endMs: 4_000,
                        speaker: "待确认",
                        text: "先完成输入输出协议，再接入真实 Provider。"
                    )
                ]
            ),
            attachments: [
                MeetingAgentAttachmentInput(
                    id: "attachment-1",
                    fileName: attachmentURL.lastPathComponent,
                    mediaType: "text/plain",
                    sizeBytes: Int64(attachmentData.count),
                    sha256: sha256(attachmentData),
                    sourcePath: attachmentURL.path
                )
            ],
            analysis: MeetingAgentAnalysisInput(goal: "核对实施顺序和风险", language: "zh-CN")
        )
        let requestHash = try MeetingAgentRequestHasher.hash(request)

        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let entrypoint = repositoryRoot.appendingPathComponent("Tools/tinglan_agentd/src/index.mjs")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", entrypoint.path]
        process.currentDirectoryURL = repositoryRoot
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        environment["TINGLAN_AGENT_DATA_ROOT"] = agentRoot.path
        environment["TINGLAN_AGENT_HOST"] = "127.0.0.1"
        environment["TINGLAN_AGENT_PORT"] = "0"
        environment["TINGLAN_AGENT_INPUT_ROOTS"] = attachmentRoot.path
        environment["TINGLAN_AGENT_PROVIDER"] = "mock"
        environment["TINGLAN_DB_PATH"] = root.appendingPathComponent("must-not-exist.sqlite").path
        process.environment = environment
        let stdoutURL = root.appendingPathComponent("agentd.stdout.log")
        let stderrURL = root.appendingPathComponent("agentd.stderr.log")
        fileManager.createFile(atPath: stdoutURL.path, contents: nil)
        fileManager.createFile(atPath: stderrURL.path, contents: nil)
        let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdoutHandle.close()
            try? stderrHandle.close()
        }
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }

        let tokenURL = agentRoot.appendingPathComponent("api-token")
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = 2
        sessionConfiguration.timeoutIntervalForResource = 5
        let session = URLSession(configuration: sessionConfiguration)
        let readiness = try await waitUntilReady(
            process: process,
            stdoutURL: stdoutURL,
            stderrURL: stderrURL,
            tokenURL: tokenURL,
            session: session
        )
        let gateway = MeetingAgentGatewayClient(
            baseURL: readiness.baseURL,
            session: session,
            tokenProvider: { readiness.token }
        )

        let databaseURL = tinglanRoot.appendingPathComponent("ai-tingji.sqlite")
        let store = try AppPersistenceStore(path: databaseURL.path)
        defer { store.close() }
        try store.upsertMeeting(Meeting(
            id: meetingID,
            title: request.meeting.title,
            status: .done,
            captureSource: .mixed,
            createdAt: Date(timeIntervalSince1970: 1),
            startedAt: Date(timeIntervalSince1970: 1),
            endedAt: Date(timeIntervalSince1970: 2)
        ))
        let localJobCreatedAt = Date()
        try store.createMeetingAgentJob(MeetingAgentJob(
            id: jobID,
            meetingID: meetingID,
            requestHash: requestHash,
            provider: "mock",
            analysisGoal: request.analysis.goal,
            createdAt: localJobCreatedAt
        ))

        let submitted = try await gateway.submit(request)
        #expect(submitted.jobID == jobID)
        let queuedAt = Date()
        #expect(try store.transitionMeetingAgentJob(
            id: jobID,
            from: .submitting,
            to: .queued,
            expectedUpdatedAt: localJobCreatedAt,
            updatedAt: queuedAt
        ))

        let remoteStatus = try await waitForCompletion(gateway: gateway, jobID: jobID)
        #expect(remoteStatus.status == .succeeded)
        let resultResponse = try await gateway.fetchResult(jobID: jobID)
        #expect(resultResponse.requestHash == requestHash)

        #expect(try store.transitionMeetingAgentJob(
            id: jobID,
            from: .queued,
            to: .importing,
            expectedUpdatedAt: queuedAt,
            updatedAt: Date()
        ))
        let importer = MeetingAgentResultImporter(
            agentJobsRoot: agentRoot.appendingPathComponent("jobs", isDirectory: true),
            meetingDirectoryLayout: MeetingDirectoryLayout(applicationSupportDirectory: tinglanRoot)
        )
        let published = try importer.importResult(
            response: resultResponse,
            expected: MeetingAgentImportExpectation(
                jobID: jobID,
                requestID: jobID,
                meetingID: meetingID,
                requestHash: requestHash
            )
        )
        let importedAt = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let savedResult = try store.importMeetingAgentResult(
            jobID: jobID,
            result: published.makeResult(importedAt: importedAt),
            todos: published.makeTodos(importedAt: importedAt)
        )

        #expect(try store.loadMeetingAgentJob(id: jobID)?.status == .ready)
        #expect(try store.loadMeetingAgentResult(jobID: jobID) == savedResult)
        #expect(try store.loadMeetingTodos(meetingID: meetingID).isEmpty)
        #expect(published.todos.items.isEmpty)
        #expect(fileManager.fileExists(atPath: published.reportURL.path))
        let report = try String(contentsOf: published.reportURL, encoding: .utf8)
        #expect(report.contains("正式纪要"))
        #expect(report.contains("智能分析"))
        #expect(fileManager.fileExists(atPath: agentRoot.appendingPathComponent("agent.sqlite").path))
        #expect(fileManager.fileExists(atPath: databaseURL.path))
        #expect(agentRoot.appendingPathComponent("agent.sqlite").standardizedFileURL != databaseURL.standardizedFileURL)
        #expect(!fileManager.fileExists(atPath: environment["TINGLAN_DB_PATH"]!))

        let sanitizedRequestURL = agentRoot
            .appendingPathComponent("jobs/\(jobID)/input/request.json")
        let sanitizedRequest = try String(contentsOf: sanitizedRequestURL, encoding: .utf8)
        #expect(!sanitizedRequest.contains(attachmentURL.path))
        #expect(sanitizedRequest.contains("attachments/需求说明.txt"))
    }

    private func waitUntilReady(
        process: Process,
        stdoutURL: URL,
        stderrURL: URL,
        tokenURL: URL,
        session: URLSession
    ) async throws -> (baseURL: URL, token: String) {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let stdout = (try? String(contentsOf: stdoutURL, encoding: .utf8)) ?? ""
            if let baseURL = agentBaseURL(from: stdout),
               let token = try? String(contentsOf: tokenURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !token.isEmpty,
               let healthURL = URL(string: "/healthz", relativeTo: baseURL),
               let (_, response) = try? await session.data(from: healthURL),
               (response as? HTTPURLResponse)?.statusCode == 200
            {
                return (baseURL, token)
            }
            if !process.isRunning {
                throw MeetingAgentMockE2EError.startupFailed(
                    diagnostics(process: process, stdoutURL: stdoutURL, stderrURL: stderrURL)
                )
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw MeetingAgentMockE2EError.timeout(
            "tinglan-agentd 未在 10 秒内就绪。\n" + diagnostics(
                process: process,
                stdoutURL: stdoutURL,
                stderrURL: stderrURL
            )
        )
    }

    private func agentBaseURL(from stdout: String) -> URL? {
        guard let line = stdout.split(separator: "\n").last(where: { $0.contains("tinglan-agentd listening on ") }),
              let marker = line.range(of: "http://") else {
            return nil
        }
        return URL(string: String(line[marker.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func diagnostics(process: Process, stdoutURL: URL, stderrURL: URL) -> String {
        let stdout = (try? String(contentsOf: stdoutURL, encoding: .utf8)) ?? ""
        let stderr = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
        let exit = process.isRunning ? "仍在运行" : "退出码 \(process.terminationStatus)"
        return "进程状态：\(exit)\nstdout:\n\(stdout)\nstderr:\n\(stderr)"
    }

    private func waitForCompletion(
        gateway: MeetingAgentGatewayClient,
        jobID: String
    ) async throws -> MeetingAgentJobStatusResponse {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let status = try await gateway.fetchStatus(jobID: jobID)
            switch status.status {
            case .succeeded:
                return status
            case .failed, .cancelled:
                throw MeetingAgentMockE2EError.remoteFailed(status.error?.message ?? status.status.rawValue)
            case .queued, .running:
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        throw MeetingAgentMockE2EError.timeout("Agent 作业未在 10 秒内完成")
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private enum MeetingAgentMockE2EError: Error, LocalizedError {
    case timeout(String)
    case startupFailed(String)
    case remoteFailed(String)

    var errorDescription: String? {
        switch self {
        case let .timeout(message), let .startupFailed(message), let .remoteFailed(message):
            message
        }
    }
}
