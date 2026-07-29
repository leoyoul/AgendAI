import CryptoKit
import Darwin
import Foundation

public struct MeetingAgentImportExpectation: Equatable, Sendable {
    public var jobID: String
    public var requestID: String
    public var meetingID: String
    public var requestHash: String

    public init(jobID: String, requestID: String, meetingID: String, requestHash: String) {
        self.jobID = jobID
        self.requestID = requestID
        self.meetingID = meetingID
        self.requestHash = requestHash
    }
}

public struct MeetingAgentResultFileDescriptor: Codable, Equatable, Sendable {
    public var path: String
    public var sizeBytes: Int64
    public var sha256: String

    public init(path: String, sizeBytes: Int64, sha256: String) {
        self.path = path
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
    }

    enum CodingKeys: String, CodingKey {
        case path
        case sizeBytes = "size_bytes"
        case sha256
    }
}

public struct MeetingAgentResultAssetDescriptor: Codable, Equatable, Sendable {
    public var path: String
    public var sizeBytes: Int64
    public var sha256: String
    public var mediaType: String

    public init(path: String, sizeBytes: Int64, sha256: String, mediaType: String) {
        self.path = path
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
        self.mediaType = mediaType
    }

    enum CodingKeys: String, CodingKey {
        case path
        case sizeBytes = "size_bytes"
        case sha256
        case mediaType = "media_type"
    }

    var fileDescriptor: MeetingAgentResultFileDescriptor {
        MeetingAgentResultFileDescriptor(path: path, sizeBytes: sizeBytes, sha256: sha256)
    }
}

public struct MeetingAgentTodosFileDescriptor: Codable, Equatable, Sendable {
    public var path: String
    public var sizeBytes: Int64
    public var sha256: String
    public var count: Int

    public init(path: String, sizeBytes: Int64, sha256: String, count: Int) {
        self.path = path
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
        self.count = count
    }

    enum CodingKeys: String, CodingKey {
        case path
        case sizeBytes = "size_bytes"
        case sha256
        case count
    }

    var fileDescriptor: MeetingAgentResultFileDescriptor {
        MeetingAgentResultFileDescriptor(path: path, sizeBytes: sizeBytes, sha256: sha256)
    }
}

public struct MeetingAgentResultManifest: Codable, Equatable, Sendable {
    public var schemaVersion: String
    public var jobID: String
    public var requestID: String
    public var requestHash: String
    public var meetingID: String
    public var provider: MeetingAgentProviderDescriptor
    public var generatedAt: String
    public var report: MeetingAgentResultFileDescriptor
    public var todos: MeetingAgentTodosFileDescriptor
    public var assets: [MeetingAgentResultAssetDescriptor]
    public var skillsUsed: [String]
    public var warnings: [String]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case jobID = "job_id"
        case requestID = "request_id"
        case requestHash = "request_hash"
        case meetingID = "meeting_id"
        case provider
        case generatedAt = "generated_at"
        case report
        case todos
        case assets
        case skillsUsed = "skills_used"
        case warnings
    }
}

public struct MeetingAgentTodoDocument: Codable, Equatable, Sendable {
    public var schemaVersion: String
    public var jobID: String
    public var meetingID: String
    public var items: [MeetingAgentTodoItem]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case jobID = "job_id"
        case meetingID = "meeting_id"
        case items
    }
}

public struct MeetingAgentTodoItem: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var description: String
    public var owner: String?
    public var deadline: String?
    public var deliverable: String?
    public var acceptanceCriteria: String?
    public var evidence: [MeetingTodoEvidence]
    public var confirmationStatus: MeetingTodoConfirmationStatus
    public var proposedWorkflow: MeetingTodoWorkflow

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case description
        case owner
        case deadline
        case deliverable
        case acceptanceCriteria = "acceptance_criteria"
        case evidence
        case confirmationStatus = "confirmation_status"
        case proposedWorkflow = "proposed_workflow"
    }
}

public struct ValidatedMeetingAgentImport: Sendable {
    public let response: MeetingAgentResultResponse
    public let expectation: MeetingAgentImportExpectation
    public let sourceDirectory: URL
    public let manifestRelativePath: String
    public let manifest: MeetingAgentResultManifest
    public let todos: MeetingAgentTodoDocument
    let files: [MeetingAgentResultFileDescriptor]
    let fileContents: [String: Data]
}

public struct PublishedMeetingAgentImport: Sendable {
    public let jobDirectory: URL
    public let reportURL: URL
    public let manifestURL: URL
    public let todosURL: URL
    public let relativeJobDirectory: String
    public let manifestRelativePath: String
    public let manifestSHA256: String
    public let manifest: MeetingAgentResultManifest
    public let todos: MeetingAgentTodoDocument

    public func makeResult(importedAt: Date) -> MeetingAgentResult {
        MeetingAgentResult(
            id: manifest.jobID,
            jobID: manifest.jobID,
            meetingID: manifest.meetingID,
            manifestRelativePath: "\(relativeJobDirectory)/\(manifestRelativePath)",
            reportRelativePath: "\(relativeJobDirectory)/\(manifest.report.path)",
            manifestSHA256: manifestSHA256,
            importedAt: importedAt
        )
    }

    public func makeTodos(importedAt: Date) -> [MeetingTodo] {
        todos.items.map { item in
            MeetingTodo(
                id: item.id,
                jobID: todos.jobID,
                meetingID: todos.meetingID,
                title: item.title,
                detail: item.description,
                owner: item.owner,
                deadline: item.deadline,
                deliverable: item.deliverable,
                acceptanceCriteria: item.acceptanceCriteria,
                evidence: item.evidence,
                confirmationStatus: item.confirmationStatus,
                proposedWorkflow: item.proposedWorkflow,
                createdAt: importedAt
            )
        }
    }

}

public enum MeetingAgentResultImportError: Error, Equatable, LocalizedError, Sendable {
    case identityMismatch(String)
    case unsafeResultPath(String)
    case resultOutsideAgentRoot
    case symbolicLink(String)
    case invalidManifest(String)
    case invalidTodos(String)
    case missingFile(String)
    case fileSizeMismatch(String)
    case fileHashMismatch(String)
    case invalidHTML(String)
    case unsafeResourceReference(String)
    case undeclaredResource(String)
    case resultConflict
    case fileSystem(String)

    public var errorDescription: String? {
        switch self {
        case let .identityMismatch(reason): "结果身份不匹配：\(reason)"
        case let .unsafeResultPath(path): "结果路径不安全：\(path)"
        case .resultOutsideAgentRoot: "结果目录不在 Agent jobs 根目录内"
        case let .symbolicLink(path): "结果包包含符号链接：\(path)"
        case let .invalidManifest(reason): "manifest 无效：\(reason)"
        case let .invalidTodos(reason): "todos 无效：\(reason)"
        case let .missingFile(path): "结果文件不存在：\(path)"
        case let .fileSizeMismatch(path): "结果文件大小不匹配：\(path)"
        case let .fileHashMismatch(path): "结果文件哈希不匹配：\(path)"
        case let .invalidHTML(reason): "报告 HTML 无效：\(reason)"
        case let .unsafeResourceReference(path): "HTML 资源引用不安全：\(path)"
        case let .undeclaredResource(path): "HTML 引用了 manifest 未声明资源：\(path)"
        case .resultConflict: "已发布结果目录与本次结果不一致"
        case let .fileSystem(reason): "结果文件操作失败：\(reason)"
        }
    }
}

public struct MeetingAgentResultImporter: Sendable {
    private static let maximumManifestBytes: Int64 = 1 * 1_024 * 1_024
    private static let maximumReportBytes: Int64 = 20 * 1_024 * 1_024
    private static let maximumTodosBytes: Int64 = 5 * 1_024 * 1_024
    private static let maximumAssetBytes: Int64 = 50 * 1_024 * 1_024
    private static let maximumResultBytes: Int64 = 200 * 1_024 * 1_024
    private static let maximumAssetCount = 100

    private let agentJobsRoot: URL
    private let meetingDirectoryLayout: MeetingDirectoryLayout
    private let scanner = HTMLResourceReferenceScanner()
    private let publicationTestHook: (@Sendable () throws -> Void)?
    private var fileManager: FileManager { .default }

    public init(
        agentJobsRoot: URL,
        meetingDirectoryLayout: MeetingDirectoryLayout = .default()
    ) {
        self.agentJobsRoot = agentJobsRoot.standardizedFileURL
        self.meetingDirectoryLayout = meetingDirectoryLayout
        publicationTestHook = nil
    }

    init(
        agentJobsRoot: URL,
        meetingDirectoryLayout: MeetingDirectoryLayout,
        publicationTestHook: @escaping @Sendable () throws -> Void
    ) {
        self.agentJobsRoot = agentJobsRoot.standardizedFileURL
        self.meetingDirectoryLayout = meetingDirectoryLayout
        self.publicationTestHook = publicationTestHook
    }

    public func importResult(
        response: MeetingAgentResultResponse,
        expected: MeetingAgentImportExpectation
    ) throws -> PublishedMeetingAgentImport {
        try publish(validate(response: response, expected: expected))
    }

    public func validate(
        response: MeetingAgentResultResponse,
        expected: MeetingAgentImportExpectation
    ) throws -> ValidatedMeetingAgentImport {
        try validateIdentity(response: response, expected: expected)
        guard MeetingDirectoryLayout.isSafeRelativePath(response.manifestPath) else {
            throw MeetingAgentResultImportError.unsafeResultPath(response.manifestPath)
        }

        let sourceDirectory = try validatedSourceDirectory(response.resultPath)
        let manifestURL = sourceDirectory.appendingPathComponent(response.manifestPath)
        let manifestData = try readVerifiedFile(
            at: manifestURL,
            relativePath: response.manifestPath,
            expectedSize: nil,
            maximumSize: Self.maximumManifestBytes,
            expectedHash: response.manifestSHA256
        )
        let manifest = try decodeManifest(manifestData)
        try validateManifestIdentity(manifest, response: response, expected: expected)

        var files = [manifest.report, manifest.todos.fileDescriptor]
        files.append(contentsOf: manifest.assets.map(\.fileDescriptor))
        guard response.manifestPath == "manifest.json",
              manifest.report.path == "report.html",
              manifest.todos.path == "todos.json",
              files.allSatisfy({ $0.sizeBytes >= 0 }),
              manifest.assets.count <= Self.maximumAssetCount,
              manifest.report.sizeBytes <= Self.maximumReportBytes,
              manifest.todos.sizeBytes <= Self.maximumTodosBytes,
              manifest.assets.allSatisfy({ $0.sizeBytes <= Self.maximumAssetBytes }),
              files.reduce(Int64(manifestData.count), { partial, file in
                  partial > Self.maximumResultBytes - file.sizeBytes
                      ? Self.maximumResultBytes + 1
                      : partial + file.sizeBytes
              }) <= Self.maximumResultBytes
        else {
            throw MeetingAgentResultImportError.invalidManifest("结果包超过 v1 资源上限")
        }
        let allPaths = [response.manifestPath] + files.map(\.path)
        guard Set(allPaths).count == allPaths.count else {
            throw MeetingAgentResultImportError.invalidManifest("文件路径重复")
        }
        var fileContents = [response.manifestPath: manifestData]
        for file in files {
            guard MeetingDirectoryLayout.isSafeRelativePath(file.path), file.sizeBytes >= 0, Self.isSHA256(file.sha256) else {
                throw MeetingAgentResultImportError.invalidManifest("文件描述不合法")
            }
            fileContents[file.path] = try readVerifiedFile(
                at: sourceDirectory.appendingPathComponent(file.path),
                relativePath: file.path,
                expectedSize: file.sizeBytes,
                maximumSize: file.sizeBytes,
                expectedHash: file.sha256
            )
        }
        try rejectUndeclaredFiles(in: sourceDirectory, declaredPaths: Set(allPaths), conflict: false)

        guard let reportData = fileContents[manifest.report.path] else {
            throw MeetingAgentResultImportError.missingFile(manifest.report.path)
        }
        try validateHTML(reportData, manifest: manifest)

        guard let todosData = fileContents[manifest.todos.path] else {
            throw MeetingAgentResultImportError.missingFile(manifest.todos.path)
        }
        let todos = try decodeTodos(todosData)
        try validateTodos(todos, manifest: manifest)

        return ValidatedMeetingAgentImport(
            response: response,
            expectation: expected,
            sourceDirectory: sourceDirectory,
            manifestRelativePath: response.manifestPath,
            manifest: manifest,
            todos: todos,
            files: files,
            fileContents: fileContents
        )
    }

    public func publish(_ validated: ValidatedMeetingAgentImport) throws -> PublishedMeetingAgentImport {
        let target = try meetingDirectoryLayout.jobDirectory(
            meetingID: validated.expectation.meetingID,
            jobID: validated.expectation.jobID
        )
        let relativeJobDirectory = try meetingDirectoryLayout.relativeJobDirectory(jobID: validated.expectation.jobID)
        let declaredFiles = [
            MeetingAgentResultFileDescriptor(
                path: validated.manifestRelativePath,
                sizeBytes: Int64(validated.fileContents[validated.manifestRelativePath]?.count ?? -1),
                sha256: validated.response.manifestSHA256
            )
        ] + validated.files
        let jobsDescriptor = try openOrCreateJobsDirectory(for: target)
        defer { close(jobsDescriptor) }
        if try verifyNamedPublishedDirectory(
            jobsDescriptor: jobsDescriptor,
            name: target.lastPathComponent,
            expectedURL: target,
            files: declaredFiles,
            allowMissing: true
        ) {
            return makePublished(validated, at: target, relativeJobDirectory: relativeJobDirectory)
        }

        let stagingName = ".\(target.lastPathComponent).import-staging-\(UUID().uuidString)"
        guard mkdirat(jobsDescriptor, stagingName, 0o700) == 0 else {
            throw MeetingAgentResultImportError.fileSystem(String(cString: strerror(errno)))
        }
        let stagingDescriptor = openat(jobsDescriptor, stagingName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard stagingDescriptor >= 0 else {
            throw MeetingAgentResultImportError.fileSystem(String(cString: strerror(errno)))
        }
        defer {
            cleanupStaging(
                jobsDescriptor: jobsDescriptor,
                name: stagingName,
                stagingDescriptor: stagingDescriptor,
                files: declaredFiles
            )
            close(stagingDescriptor)
        }
        do {
            try publicationTestHook?()
            for file in declaredFiles {
                guard let contents = validated.fileContents[file.path] else {
                    throw MeetingAgentResultImportError.resultConflict
                }
                try writeSnapshot(contents, relativePath: file.path, directoryDescriptor: stagingDescriptor)
            }
            guard fsync(stagingDescriptor) == 0 else {
                throw MeetingAgentResultImportError.fileSystem(String(cString: strerror(errno)))
            }
            try verifyPublishedDirectory(descriptor: stagingDescriptor, files: declaredFiles)

            let renameResult = renameatx_np(
                jobsDescriptor,
                stagingName,
                jobsDescriptor,
                target.lastPathComponent,
                UInt32(RENAME_EXCL)
            )
            if renameResult != 0, errno != EEXIST {
                throw MeetingAgentResultImportError.fileSystem(String(cString: strerror(errno)))
            }
            guard fsync(jobsDescriptor) == 0 else {
                throw MeetingAgentResultImportError.fileSystem(String(cString: strerror(errno)))
            }
            guard try verifyNamedPublishedDirectory(
                jobsDescriptor: jobsDescriptor,
                name: target.lastPathComponent,
                expectedURL: target,
                files: declaredFiles,
                allowMissing: false
            ) else {
                throw MeetingAgentResultImportError.resultConflict
            }
        } catch let error as MeetingAgentResultImportError {
            throw error
        } catch {
            throw MeetingAgentResultImportError.fileSystem(error.localizedDescription)
        }
        return makePublished(validated, at: target, relativeJobDirectory: relativeJobDirectory)
    }

    private func validateIdentity(
        response: MeetingAgentResultResponse,
        expected: MeetingAgentImportExpectation
    ) throws {
        guard response.schemaVersion == "1.0" else {
            throw MeetingAgentResultImportError.identityMismatch("schema_version 不是 1.0")
        }
        guard response.jobID == response.requestID else {
            throw MeetingAgentResultImportError.identityMismatch("job_id 与 request_id 不一致")
        }
        guard expected.jobID == expected.requestID,
              response.jobID == expected.jobID,
              response.requestID == expected.requestID
        else {
            throw MeetingAgentResultImportError.identityMismatch("作业 ID 与本地作业不一致")
        }
        guard response.meetingID == expected.meetingID else {
            throw MeetingAgentResultImportError.identityMismatch("meeting_id 与本地作业不一致")
        }
        guard response.requestHash.caseInsensitiveCompare(expected.requestHash) == .orderedSame else {
            throw MeetingAgentResultImportError.identityMismatch("request_hash 与本地作业不一致")
        }
    }

    private func validateManifestIdentity(
        _ manifest: MeetingAgentResultManifest,
        response: MeetingAgentResultResponse,
        expected: MeetingAgentImportExpectation
    ) throws {
        guard manifest.schemaVersion == "1.0",
              manifest.jobID == expected.jobID,
              manifest.requestID == expected.requestID,
              manifest.jobID == manifest.requestID,
              manifest.meetingID == expected.meetingID,
              manifest.requestHash.caseInsensitiveCompare(expected.requestHash) == .orderedSame,
              manifest.provider == response.provider
        else {
            throw MeetingAgentResultImportError.identityMismatch("manifest 身份与本地作业不一致")
        }
    }

    private func validatedSourceDirectory(_ path: String) throws -> URL {
        guard path.hasPrefix("/") else {
            throw MeetingAgentResultImportError.unsafeResultPath(path)
        }
        let rawRoot = agentJobsRoot.standardizedFileURL
        let rawSource = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        guard Self.isContained(rawSource, in: rawRoot) else {
            throw MeetingAgentResultImportError.resultOutsideAgentRoot
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: rawSource.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw MeetingAgentResultImportError.missingFile(path)
        }
        try rejectSymlinkComponents(from: rawSource, through: rawRoot, label: "结果目录")
        let resolvedRoot = rawRoot.resolvingSymlinksInPath().standardizedFileURL
        let resolvedSource = rawSource.resolvingSymlinksInPath().standardizedFileURL
        guard Self.isContained(resolvedSource, in: resolvedRoot) else {
            throw MeetingAgentResultImportError.resultOutsideAgentRoot
        }
        return rawSource
    }

    private func rejectSymlinkComponents(
        from source: URL,
        through root: URL,
        label: String,
        allowMissing: Bool = false
    ) throws {
        var current = source
        while current.path.count >= root.path.count {
            let attributes: [FileAttributeKey: Any]?
            do {
                attributes = try fileManager.attributesOfItem(atPath: current.path)
            } catch {
                if allowMissing {
                    attributes = nil
                } else {
                    throw MeetingAgentResultImportError.missingFile(label)
                }
            }
            if attributes?[.type] as? FileAttributeType == .typeSymbolicLink {
                throw MeetingAgentResultImportError.symbolicLink(label)
            }
            if current.path == root.path { break }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
    }

    private func decodeManifest(_ data: Data) throws -> MeetingAgentResultManifest {
        do {
            let object = try requiredObject(data, keys: [
                "schema_version", "job_id", "request_id", "request_hash", "meeting_id", "provider",
                "generated_at", "report", "todos", "assets", "skills_used", "warnings"
            ])
            try requireExactKeys(object["provider"], keys: ["name", "run_id"])
            try requireExactKeys(object["report"], keys: ["path", "size_bytes", "sha256"])
            try requireExactKeys(object["todos"], keys: ["path", "size_bytes", "sha256", "count"])
            for asset in object["assets"] as? [Any] ?? [] {
                try requireExactKeys(asset, keys: ["path", "size_bytes", "sha256", "media_type"])
            }
            let manifest = try JSONDecoder().decode(MeetingAgentResultManifest.self, from: data)
            guard Self.isSafeJobID(manifest.jobID),
                  Self.isSafeJobID(manifest.requestID),
                  Self.isNonEmptyID(manifest.meetingID),
                  Self.isSHA256(manifest.requestHash),
                  !manifest.provider.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !manifest.provider.runID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  Self.isISO8601(manifest.generatedAt),
                  manifest.todos.count >= 0,
                  manifest.assets.allSatisfy({ !$0.mediaType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            else {
                throw MeetingAgentResultImportError.invalidManifest("字段值不符合 v1 协议")
            }
            return manifest
        } catch let error as MeetingAgentResultImportError {
            throw error
        } catch {
            throw MeetingAgentResultImportError.invalidManifest("字段不符合 v1 协议")
        }
    }

    private func decodeTodos(_ data: Data) throws -> MeetingAgentTodoDocument {
        do {
            let object = try requiredObject(
                data,
                keys: ["schema_version", "job_id", "meeting_id", "items"],
                todos: true
            )
            guard let items = object["items"] as? [Any] else {
                throw MeetingAgentResultImportError.invalidTodos("待办字段不符合 v1 协议")
            }
            for value in items {
                try requireExactKeys(value, keys: [
                    "id", "title", "description", "owner", "deadline", "deliverable",
                    "acceptance_criteria", "evidence", "confirmation_status", "proposed_workflow"
                ], todos: true)
                guard let item = value as? [String: Any], let evidence = item["evidence"] as? [Any] else {
                    throw MeetingAgentResultImportError.invalidTodos("待办字段不符合 v1 协议")
                }
                for evidenceItem in evidence {
                    try requireExactKeys(evidenceItem, keys: ["segment_id", "quote", "time_range"], todos: true)
                }
            }
            return try JSONDecoder().decode(MeetingAgentTodoDocument.self, from: data)
        } catch let error as MeetingAgentResultImportError {
            throw error
        } catch {
            throw MeetingAgentResultImportError.invalidTodos("待办字段不符合 v1 协议")
        }
    }

    private func validateTodos(
        _ todos: MeetingAgentTodoDocument,
        manifest: MeetingAgentResultManifest
    ) throws {
        guard todos.schemaVersion == "1.0",
              todos.jobID == manifest.jobID,
              todos.meetingID == manifest.meetingID,
              todos.items.count == manifest.todos.count
        else {
            throw MeetingAgentResultImportError.invalidTodos("待办身份或数量不匹配")
        }
        for item in todos.items {
            guard !item.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  item.id.count <= 200,
                  !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  item.confirmationStatus == .pendingConfirmation
            else {
                throw MeetingAgentResultImportError.invalidTodos("待办字段不符合 v1 协议")
            }
            if (item.owner != nil || item.deadline != nil), item.evidence.isEmpty {
                throw MeetingAgentResultImportError.invalidTodos("负责人或期限缺少会议证据")
            }
            if item.owner?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true ||
                item.deadline?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true
            {
                throw MeetingAgentResultImportError.invalidTodos("负责人或期限不能为空字符串")
            }
            if item.evidence.contains(where: {
                $0.segmentID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    $0.segmentID.count > 200 ||
                    $0.quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    $0.timeRange.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }) {
                throw MeetingAgentResultImportError.invalidTodos("会议证据为空")
            }
        }
    }

    private func validateHTML(_ data: Data, manifest: MeetingAgentResultManifest) throws {
        guard let html = String(data: data, encoding: .utf8) else {
            throw MeetingAgentResultImportError.invalidHTML("不是 UTF-8")
        }
        let lowercased = html.lowercased()
        guard lowercased.contains("<html"), lowercased.contains("<head"), lowercased.contains("<body") else {
            throw MeetingAgentResultImportError.invalidHTML("缺少完整文档结构")
        }
        let declaredAssets = Set(manifest.assets.map(\.path))
        let references: [HTMLResourceReference]
        do {
            references = try scanner.scan(html)
        } catch {
            throw MeetingAgentResultImportError.invalidHTML("资源属性无法解析")
        }
        for reference in references {
            let normalized = try normalizedLocalResource(reference.value)
            guard declaredAssets.contains(normalized) else {
                throw MeetingAgentResultImportError.undeclaredResource(normalized)
            }
        }
    }

    private func normalizedLocalResource(_ rawValue: String) throws -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("//"),
              !trimmed.contains("&"),
              !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else {
            throw MeetingAgentResultImportError.unsafeResourceReference(rawValue)
        }
        let pathWithEscapes = String(trimmed.prefix { $0 != "?" && $0 != "#" })
        guard let decoded = pathWithEscapes.removingPercentEncoding,
              !decoded.isEmpty,
              MeetingDirectoryLayout.isSafeRelativePath(decoded)
        else {
            throw MeetingAgentResultImportError.unsafeResourceReference(rawValue)
        }
        let firstComponent = decoded.split(separator: "/", maxSplits: 1).first.map(String.init) ?? decoded
        if firstComponent.contains(":") {
            throw MeetingAgentResultImportError.unsafeResourceReference(rawValue)
        }
        return decoded
    }

    private func readVerifiedFile(
        at url: URL,
        relativePath: String,
        expectedSize: Int64?,
        maximumSize: Int64,
        expectedHash: String
    ) throws -> Data {
        guard MeetingDirectoryLayout.isSafeRelativePath(relativePath) else {
            throw MeetingAgentResultImportError.unsafeResultPath(relativePath)
        }
        let rawURL = url.standardizedFileURL
        let rawRoot = agentJobsRoot.standardizedFileURL
        guard Self.isContained(rawURL, in: rawRoot) else {
            throw MeetingAgentResultImportError.unsafeResultPath(relativePath)
        }
        let suffix = String(rawURL.path.dropFirst(rawRoot.path.count + 1))
        let components = suffix.split(separator: "/").map(String.init)
        guard !components.isEmpty else {
            throw MeetingAgentResultImportError.missingFile(relativePath)
        }
        var descriptor = open(rawRoot.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw MeetingAgentResultImportError.symbolicLink(relativePath)
        }
        defer { if descriptor >= 0 { close(descriptor) } }
        for component in components.dropLast() {
            let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard next >= 0 else {
                throw MeetingAgentResultImportError.symbolicLink(relativePath)
            }
            close(descriptor)
            descriptor = next
        }
        let fileDescriptor = openat(descriptor, components.last!, O_RDONLY | O_NOFOLLOW)
        guard fileDescriptor >= 0 else {
            if errno == ELOOP { throw MeetingAgentResultImportError.symbolicLink(relativePath) }
            throw MeetingAgentResultImportError.missingFile(relativePath)
        }
        var status = stat()
        guard fstat(fileDescriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
            close(fileDescriptor)
            throw MeetingAgentResultImportError.missingFile(relativePath)
        }
        let actualSize = Int64(status.st_size)
        guard actualSize <= maximumSize else {
            close(fileDescriptor)
            throw MeetingAgentResultImportError.invalidManifest("文件超过 v1 资源上限：\(relativePath)")
        }
        if let expectedSize, actualSize != expectedSize {
            close(fileDescriptor)
            throw MeetingAgentResultImportError.fileSizeMismatch(relativePath)
        }
        let handle = FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: true)
        var data = Data()
        do {
            let chunkSize = 1_024 * 1_024
            while data.count <= maximumSize {
                let remaining = min(chunkSize, Int(maximumSize) + 1 - data.count)
                guard remaining > 0, let chunk = try handle.read(upToCount: remaining), !chunk.isEmpty else { break }
                data.append(chunk)
            }
        } catch {
            throw MeetingAgentResultImportError.fileSystem(error.localizedDescription)
        }
        guard data.count <= maximumSize else {
            throw MeetingAgentResultImportError.invalidManifest("文件超过 v1 资源上限：\(relativePath)")
        }
        guard data.count == actualSize else {
            throw MeetingAgentResultImportError.fileSizeMismatch(relativePath)
        }
        guard Self.sha256(data).caseInsensitiveCompare(expectedHash) == .orderedSame else {
            throw MeetingAgentResultImportError.fileHashMismatch(relativePath)
        }
        return data
    }

    private func openOrCreateJobsDirectory(for target: URL) throws -> Int32 {
        let root = meetingDirectoryLayout.applicationSupportDirectory.standardizedFileURL
        guard Self.isContained(target, in: root) else {
            throw MeetingAgentResultImportError.fileSystem("发布目录越出会小纪根目录")
        }
        let relative = String(target.standardizedFileURL.path.dropFirst(root.path.count + 1))
        let components = relative.split(separator: "/").map(String.init)
        guard components.count >= 2 else {
            throw MeetingAgentResultImportError.fileSystem("发布目录层级无效")
        }
        let canonicalParent = try canonicalExistingDirectory(root.deletingLastPathComponent())
        let parentDescriptor = try openOrCreateAbsoluteDirectory(canonicalParent)
        defer { close(parentDescriptor) }
        if mkdirat(parentDescriptor, root.lastPathComponent, 0o700) != 0, errno != EEXIST {
            throw MeetingAgentResultImportError.fileSystem(String(cString: strerror(errno)))
        }
        var descriptor = openat(
            parentDescriptor,
            root.lastPathComponent,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw MeetingAgentResultImportError.symbolicLink("发布目录")
        }
        do {
            for component in components.dropLast() {
                if mkdirat(descriptor, component, 0o700) != 0, errno != EEXIST {
                    throw MeetingAgentResultImportError.fileSystem(String(cString: strerror(errno)))
                }
                let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                guard next >= 0 else {
                    if errno == ELOOP || errno == ENOTDIR {
                        throw MeetingAgentResultImportError.symbolicLink("发布目录")
                    }
                    throw MeetingAgentResultImportError.fileSystem(String(cString: strerror(errno)))
                }
                close(descriptor)
                descriptor = next
            }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    private func canonicalExistingDirectory(_ directory: URL) throws -> URL {
        guard let pointer = realpath(directory.path, nil) else {
            throw MeetingAgentResultImportError.fileSystem(String(cString: strerror(errno)))
        }
        defer { free(pointer) }
        return URL(fileURLWithPath: String(cString: pointer), isDirectory: true)
    }

    private func openOrCreateAbsoluteDirectory(_ directory: URL) throws -> Int32 {
        guard directory.path.hasPrefix("/") else {
            throw MeetingAgentResultImportError.fileSystem("会小纪根目录不是绝对路径")
        }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw MeetingAgentResultImportError.fileSystem(String(cString: strerror(errno)))
        }
        do {
            for component in directory.path.split(separator: "/").map(String.init) {
                if mkdirat(descriptor, component, 0o700) != 0, errno != EEXIST {
                    throw MeetingAgentResultImportError.fileSystem(String(cString: strerror(errno)))
                }
                let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                guard next >= 0 else {
                    throw MeetingAgentResultImportError.fileSystem("无法打开目录组件 \(component)：\(String(cString: strerror(errno)))")
                }
                close(descriptor)
                descriptor = next
            }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    private func verifyNamedPublishedDirectory(
        jobsDescriptor: Int32,
        name: String,
        expectedURL: URL,
        files: [MeetingAgentResultFileDescriptor],
        allowMissing: Bool
    ) throws -> Bool {
        let descriptor = openat(jobsDescriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            if allowMissing, errno == ENOENT { return false }
            throw MeetingAgentResultImportError.resultConflict
        }
        defer { close(descriptor) }
        var boundStatus = stat()
        var namedStatus = stat()
        guard fstat(descriptor, &boundStatus) == 0,
              lstat(expectedURL.path, &namedStatus) == 0,
              namedStatus.st_mode & S_IFMT == S_IFDIR,
              boundStatus.st_dev == namedStatus.st_dev,
              boundStatus.st_ino == namedStatus.st_ino
        else {
            throw MeetingAgentResultImportError.resultConflict
        }
        try verifyPublishedDirectory(descriptor: descriptor, files: files)
        return true
    }

    private func verifyPublishedDirectory(
        descriptor: Int32,
        files: [MeetingAgentResultFileDescriptor]
    ) throws {
        do {
            let directory = URL(fileURLWithPath: "/dev/fd/\(descriptor)", isDirectory: true)
            try rejectUndeclaredBoundFiles(in: directory, declaredPaths: Set(files.map(\.path)))
            for file in files {
                _ = try readPublishedFile(directoryDescriptor: descriptor, descriptor: file)
            }
        } catch {
            throw MeetingAgentResultImportError.resultConflict
        }
    }

    private func rejectUndeclaredBoundFiles(in directory: URL, declaredPaths: Set<String>) throws {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey],
            options: []
        ) else {
            throw MeetingAgentResultImportError.resultConflict
        }
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey])
            let relative = String(url.path.dropFirst(directory.path.count + 1))
            if values.isSymbolicLink == true {
                throw MeetingAgentResultImportError.resultConflict
            }
            if values.isRegularFile == true, !declaredPaths.contains(relative) {
                throw MeetingAgentResultImportError.resultConflict
            }
            if values.isRegularFile != true, values.isDirectory != true, values.isSymbolicLink != true {
                throw MeetingAgentResultImportError.resultConflict
            }
        }
    }

    private func writeSnapshot(
        _ contents: Data,
        relativePath: String,
        directoryDescriptor: Int32
    ) throws {
        guard MeetingDirectoryLayout.isSafeRelativePath(relativePath) else {
            throw MeetingAgentResultImportError.resultConflict
        }
        let components = relativePath.split(separator: "/").map(String.init)
        var parent = dup(directoryDescriptor)
        guard parent >= 0 else {
            throw MeetingAgentResultImportError.fileSystem(String(cString: strerror(errno)))
        }
        defer { close(parent) }
        for component in components.dropLast() {
            if mkdirat(parent, component, 0o700) != 0, errno != EEXIST {
                throw MeetingAgentResultImportError.fileSystem(String(cString: strerror(errno)))
            }
            let next = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard next >= 0 else {
                throw MeetingAgentResultImportError.symbolicLink(relativePath)
            }
            close(parent)
            parent = next
        }
        let fileDescriptor = openat(parent, components.last!, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fileDescriptor >= 0 else {
            throw MeetingAgentResultImportError.fileSystem(String(cString: strerror(errno)))
        }
        defer { close(fileDescriptor) }
        var offset = 0
        try contents.withUnsafeBytes { bytes in
            while offset < bytes.count {
                let written = Darwin.write(
                    fileDescriptor,
                    bytes.baseAddress!.advanced(by: offset),
                    bytes.count - offset
                )
                if written < 0, errno == EINTR { continue }
                guard written > 0 else {
                    throw MeetingAgentResultImportError.fileSystem(String(cString: strerror(errno)))
                }
                offset += written
            }
        }
        guard fsync(fileDescriptor) == 0, fsync(parent) == 0 else {
            throw MeetingAgentResultImportError.fileSystem(String(cString: strerror(errno)))
        }
    }

    private func cleanupStaging(
        jobsDescriptor: Int32,
        name: String,
        stagingDescriptor: Int32,
        files: [MeetingAgentResultFileDescriptor]
    ) {
        var openedStatus = stat()
        var namedStatus = stat()
        guard fstat(stagingDescriptor, &openedStatus) == 0,
              fstatat(jobsDescriptor, name, &namedStatus, AT_SYMLINK_NOFOLLOW) == 0,
              namedStatus.st_mode & S_IFMT == S_IFDIR,
              openedStatus.st_dev == namedStatus.st_dev,
              openedStatus.st_ino == namedStatus.st_ino
        else { return }

        for file in files {
            unlinkKnownItem(relativePath: file.path, directoryDescriptor: stagingDescriptor, isDirectory: false)
        }
        let directories = Set(files.flatMap { file -> [String] in
            let parts = file.path.split(separator: "/").dropLast().map(String.init)
            guard !parts.isEmpty else { return [] }
            return parts.indices.map { parts[...$0].joined(separator: "/") }
        }).sorted { lhs, rhs in
            lhs.split(separator: "/").count > rhs.split(separator: "/").count
        }
        for directory in directories {
            unlinkKnownItem(relativePath: directory, directoryDescriptor: stagingDescriptor, isDirectory: true)
        }
        _ = unlinkat(jobsDescriptor, name, AT_REMOVEDIR)
    }

    private func unlinkKnownItem(relativePath: String, directoryDescriptor: Int32, isDirectory: Bool) {
        let components = relativePath.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return }
        var parent = dup(directoryDescriptor)
        guard parent >= 0 else { return }
        defer { close(parent) }
        for component in components.dropLast() {
            let next = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard next >= 0 else { return }
            close(parent)
            parent = next
        }
        _ = unlinkat(parent, components.last!, isDirectory ? AT_REMOVEDIR : 0)
    }

    private func readPublishedFile(
        directoryDescriptor: Int32,
        descriptor: MeetingAgentResultFileDescriptor
    ) throws -> Data {
        let components = descriptor.path.split(separator: "/").map(String.init)
        var parent = dup(directoryDescriptor)
        guard parent >= 0 else { throw MeetingAgentResultImportError.resultConflict }
        defer { close(parent) }
        for component in components.dropLast() {
            let next = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard next >= 0 else { throw MeetingAgentResultImportError.resultConflict }
            close(parent)
            parent = next
        }
        let fileDescriptor = openat(parent, components.last!, O_RDONLY | O_NOFOLLOW)
        guard fileDescriptor >= 0 else { throw MeetingAgentResultImportError.resultConflict }
        var status = stat()
        guard fstat(fileDescriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              Int64(status.st_size) == descriptor.sizeBytes
        else {
            close(fileDescriptor)
            throw MeetingAgentResultImportError.resultConflict
        }
        let handle = FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: true)
        var data = Data()
        while data.count <= descriptor.sizeBytes {
            let remaining = min(1_024 * 1_024, Int(descriptor.sizeBytes) + 1 - data.count)
            guard remaining > 0, let chunk = try handle.read(upToCount: remaining), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        guard data.count == descriptor.sizeBytes else {
            throw MeetingAgentResultImportError.resultConflict
        }
        guard Self.sha256(data).caseInsensitiveCompare(descriptor.sha256) == .orderedSame else {
            throw MeetingAgentResultImportError.resultConflict
        }
        return data
    }

    private func rejectUndeclaredFiles(
        in directory: URL,
        declaredPaths: Set<String>,
        conflict: Bool
    ) throws {
        let resolvedDirectory = directory.resolvingSymlinksInPath().standardizedFileURL
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey],
            options: []
        ) else {
            if conflict {
                throw MeetingAgentResultImportError.resultConflict
            }
            throw MeetingAgentResultImportError.fileSystem("无法枚举结果目录")
        }
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey])
            let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
            guard Self.isContained(resolvedURL, in: resolvedDirectory) else {
                if conflict {
                    throw MeetingAgentResultImportError.resultConflict
                }
                throw MeetingAgentResultImportError.symbolicLink(url.lastPathComponent)
            }
            let relative = String(resolvedURL.path.dropFirst(resolvedDirectory.path.count + 1))
            if values.isSymbolicLink == true {
                if conflict {
                    throw MeetingAgentResultImportError.resultConflict
                }
                throw MeetingAgentResultImportError.symbolicLink(relative)
            }
            if values.isRegularFile == true, !declaredPaths.contains(relative) {
                if conflict {
                    throw MeetingAgentResultImportError.resultConflict
                }
                throw MeetingAgentResultImportError.invalidManifest("存在未声明文件：\(relative)")
            }
            if values.isRegularFile != true, values.isDirectory != true, values.isSymbolicLink != true {
                if conflict {
                    throw MeetingAgentResultImportError.resultConflict
                }
                throw MeetingAgentResultImportError.invalidManifest("存在特殊文件：\(relative)")
            }
        }
    }

    private func makePublished(
        _ validated: ValidatedMeetingAgentImport,
        at target: URL,
        relativeJobDirectory: String
    ) -> PublishedMeetingAgentImport {
        PublishedMeetingAgentImport(
            jobDirectory: target,
            reportURL: target.appendingPathComponent(validated.manifest.report.path),
            manifestURL: target.appendingPathComponent(validated.manifestRelativePath),
            todosURL: target.appendingPathComponent(validated.manifest.todos.path),
            relativeJobDirectory: relativeJobDirectory,
            manifestRelativePath: validated.manifestRelativePath,
            manifestSHA256: validated.response.manifestSHA256,
            manifest: validated.manifest,
            todos: validated.todos
        )
    }

    private func requiredObject(
        _ data: Data,
        keys: Set<String>,
        todos: Bool = false
    ) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == keys
        else {
            if todos {
                throw MeetingAgentResultImportError.invalidTodos("待办字段不符合 v1 协议")
            }
            throw MeetingAgentResultImportError.invalidManifest("字段不符合 v1 协议")
        }
        return object
    }

    private func requireExactKeys(_ value: Any?, keys: Set<String>, todos: Bool = false) throws {
        guard let object = value as? [String: Any], Set(object.keys) == keys else {
            if todos {
                throw MeetingAgentResultImportError.invalidTodos("待办字段不符合 v1 协议")
            }
            throw MeetingAgentResultImportError.invalidManifest("字段不符合 v1 协议")
        }
    }

    private func synchronizeFile(at url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    private func synchronizeDirectories(under root: URL) throws {
        var directories = [root]
        if let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) {
            for case let url as URL in enumerator {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    directories.append(url)
                }
            }
        }
        for directory in directories.reversed() {
            try synchronizeDirectory(at: directory)
        }
    }

    private func synchronizeDirectory(at url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw MeetingAgentResultImportError.fileSystem(String(cString: strerror(errno)))
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw MeetingAgentResultImportError.fileSystem(String(cString: strerror(errno)))
        }
    }

    private static func isContained(_ candidate: URL, in root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let candidatePath = candidate.standardizedFileURL.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    private static func isSHA256(_ value: String) -> Bool {
        let hexadecimal = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        return value.count == 64 && value.unicodeScalars.allSatisfy(hexadecimal.contains)
    }

    private static func isSafeJobID(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 200, value.first?.isASCII == true else { return false }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        guard value.unicodeScalars.allSatisfy(allowed.contains) else { return false }
        return value.first?.isLetter == true || value.first?.isNumber == true
    }

    private static func isNonEmptyID(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= 200
    }

    private static func isISO8601(_ value: String) -> Bool {
        let formatter = ISO8601DateFormatter()
        if formatter.date(from: value) != nil { return true }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: value) != nil
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
