import AItingjiCore
import CryptoKit
import Darwin
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
        let port = try unusedLoopbackPort()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", entrypoint.path]
        process.currentDirectoryURL = repositoryRoot
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        environment["TINGLAN_AGENT_DATA_ROOT"] = agentRoot.path
        environment["TINGLAN_AGENT_HOST"] = "127.0.0.1"
        environment["TINGLAN_AGENT_PORT"] = String(port)
        environment["TINGLAN_AGENT_INPUT_ROOTS"] = attachmentRoot.path
        environment["TINGLAN_AGENT_PROVIDER"] = "mock"
        environment["TINGLAN_DB_PATH"] = root.appendingPathComponent("must-not-exist.sqlite").path
        process.environment = environment
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }

        let baseURL = try #require(URL(string: "http://127.0.0.1:\(port)"))
        let tokenURL = agentRoot.appendingPathComponent("api-token")
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = 2
        sessionConfiguration.timeoutIntervalForResource = 5
        let session = URLSession(configuration: sessionConfiguration)
        let token = try await waitUntilReady(baseURL: baseURL, tokenURL: tokenURL, session: session)
        let gateway = MeetingAgentGatewayClient(
            baseURL: baseURL,
            session: session,
            tokenProvider: { token }
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

    private func waitUntilReady(baseURL: URL, tokenURL: URL, session: URLSession) async throws -> String {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let token = try? String(contentsOf: tokenURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !token.isEmpty,
               let healthURL = URL(string: "/healthz", relativeTo: baseURL),
               let (_, response) = try? await session.data(from: healthURL),
               (response as? HTTPURLResponse)?.statusCode == 200
            {
                return token
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw MeetingAgentMockE2EError.timeout("tinglan-agentd 未在 10 秒内就绪")
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

    private func unusedLoopbackPort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw MeetingAgentMockE2EError.socket }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw MeetingAgentMockE2EError.socket }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard nameResult == 0 else { throw MeetingAgentMockE2EError.socket }
        return UInt16(bigEndian: address.sin_port)
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private enum MeetingAgentMockE2EError: Error {
    case socket
    case timeout(String)
    case remoteFailed(String)
}
