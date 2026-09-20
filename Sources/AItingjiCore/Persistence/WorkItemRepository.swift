import Foundation

public enum WorkItemRepositoryError: Error, Equatable, LocalizedError, Sendable {
    case invalidTitle
    case invalidDateRange
    case invalidStatusTransition
    case missingWorkItem
    case invalidRecord

    public var errorDescription: String? {
        switch self {
        case .invalidTitle: "任务标题不能为空。"
        case .invalidDateRange: "计划结束日期不能早于计划开始日期。"
        case .invalidStatusTransition: "任务状态不能这样变更。"
        case .missingWorkItem: "找不到工作项。"
        case .invalidRecord: "工作项数据无效。"
        }
    }
}

public struct WorkItemRepository: Sendable {
    private let database: Database
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(database: Database) {
        self.database = database
    }

    public func create(_ item: WorkItem, origins: [WorkItemOrigin] = []) throws {
        try validate(item)
        try database.transaction {
            try insert(item)
            for origin in origins {
                try insert(origin)
            }
        }
    }

    public func update(_ item: WorkItem) throws {
        try validate(item)
        let changes = try database.executeReturningChanges(
            """
            UPDATE work_items SET
                title = ?, detail = ?, deliverable = ?, acceptance_criteria = ?,
                owner_person_ids = ?, owner_name_hints = ?, source_deadline_text = ?,
                planned_start_date = ?, planned_end_date = ?, status = ?, priority = ?,
                tags_json = ?, completion_note = ?, completed_at = ?, source_meeting_id = ?,
                source_meeting_title = ?, source = ?, updated_at = ?
            WHERE id = ?
            """,
            bindings: bindings(for: item, includeCreatedAt: false) + [.text(item.id)]
        )
        guard changes == 1 else { throw WorkItemRepositoryError.missingWorkItem }
    }

    public func delete(id: WorkItem.ID) throws {
        let changes = try database.executeReturningChanges(
            "DELETE FROM work_items WHERE id = ?",
            bindings: [.text(id)]
        )
        guard changes == 1 else { throw WorkItemRepositoryError.missingWorkItem }
    }

    public func delete(ids: [WorkItem.ID]) throws {
        var uniqueIDs: [WorkItem.ID] = []
        for id in ids where !id.isEmpty {
            if !uniqueIDs.contains(id) {
                uniqueIDs.append(id)
            }
        }
        guard !uniqueIDs.isEmpty else { return }

        let placeholders = Array(repeating: "?", count: uniqueIDs.count).joined(separator: ", ")
        try database.transaction {
            let changes = try database.executeReturningChanges(
                "DELETE FROM work_items WHERE id IN (\(placeholders))",
                bindings: uniqueIDs.map(SQLiteValue.text)
            )
            guard changes == uniqueIDs.count else {
                throw WorkItemRepositoryError.missingWorkItem
            }
        }
    }

    public func detachMeetingSource(meetingID: Meeting.ID) throws {
        try database.transaction {
            try database.execute(
                "UPDATE work_items SET source_meeting_id = NULL, updated_at = ? WHERE source_meeting_id = ?",
                bindings: [.real(Date().timeIntervalSince1970), .text(meetingID)]
            )
            try database.execute(
                "UPDATE work_item_origins SET meeting_id = NULL WHERE meeting_id = ?",
                bindings: [.text(meetingID)]
            )
        }
    }

    public func get(id: WorkItem.ID) throws -> WorkItem? {
        try database.query(
            "SELECT * FROM work_items WHERE id = ?",
            bindings: [.text(id)]
        ).first.map(decode)
    }

    public func list() throws -> [WorkItem] {
        try database.query(
            "SELECT * FROM work_items ORDER BY COALESCE(planned_start_date, '9999-12-31'), updated_at DESC, id"
        ).map(decode)
    }

    public func listOrigins(workItemID: WorkItem.ID) throws -> [WorkItemOrigin] {
        try database.query(
            """
            SELECT * FROM work_item_origins
            WHERE work_item_id = ?
            ORDER BY created_at, id
            """,
            bindings: [.text(workItemID)]
        ).map(decodeOrigin)
    }

    public func loadWorkItemOrigins(workItemID: WorkItem.ID) throws -> [WorkItemOrigin] {
        try listOrigins(workItemID: workItemID)
    }

    public func addOrigin(_ origin: WorkItemOrigin) throws {
        try insert(origin)
    }

    /// 幂等合并会议生成的工作项，绝不覆盖已有工作项的用户编辑字段。
    @discardableResult
    public func mergeGeneratedWorkItems(_ candidates: [WorkItemImportCandidate]) throws -> [WorkItem] {
        guard !candidates.isEmpty else { return [] }
        return try database.transaction {
            var existing = try list()
            var merged: [WorkItem] = []
            for candidate in candidates {
                if let origin = try findOrigin(sourceKey: candidate.origin.sourceKey),
                   let item = existing.first(where: { $0.id == origin.workItemID }) {
                    merged.append(item)
                    continue
                }

                let match = existing.filter { item in
                    guard item.sourceMeetingID != nil,
                          item.sourceMeetingID == candidate.item.sourceMeetingID,
                          item.plannedEndDate == candidate.item.plannedEndDate
                    else { return false }
                    let titleMatches = comparable(item.title) == comparable(candidate.item.title)
                        || ((try? listOrigins(workItemID: item.id)) ?? []).contains {
                            comparable($0.rawTitle) == comparable(candidate.origin.rawTitle)
                        }
                    guard titleMatches else { return false }
                    let existingOwners = Set(item.ownerPersonIDs)
                    let candidateOwners = Set(candidate.item.ownerPersonIDs)
                    return existingOwners == candidateOwners
                }

                let item: WorkItem
                if let matched = match.count == 1 ? match.first : nil {
                    item = matched
                } else {
                    item = candidate.item
                    try insert(item)
                    existing.append(item)
                }
                try insert(
                    WorkItemOrigin(
                        id: candidate.origin.id,
                        workItemID: item.id,
                        source: candidate.origin.source,
                        sourceKey: candidate.origin.sourceKey,
                        meetingID: candidate.origin.meetingID,
                        meetingTitle: candidate.origin.meetingTitle,
                        jobID: candidate.origin.jobID,
                        todoID: candidate.origin.todoID,
                        rawTitle: candidate.origin.rawTitle,
                        rawOwnerNames: candidate.origin.rawOwnerNames,
                        rawDeadline: candidate.origin.rawDeadline,
                        evidence: candidate.origin.evidence,
                        createdAt: candidate.origin.createdAt
                    )
                )
                merged.append(item)
            }
            return merged
        }
    }

    private func insert(_ item: WorkItem) throws {
        try database.execute(
            """
            INSERT INTO work_items (
                id, title, detail, deliverable, acceptance_criteria,
                owner_person_ids, owner_name_hints, source_deadline_text,
                planned_start_date, planned_end_date, status, priority, tags_json,
                completion_note, completed_at, source_meeting_id, source_meeting_title,
                source, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            bindings: bindings(for: item, includeID: true)
        )
    }

    private func insert(_ origin: WorkItemOrigin) throws {
        let evidence = try encoder.encode(origin.evidence)
        let ownerNames = try encoder.encode(origin.rawOwnerNames)
        try database.execute(
            """
            INSERT OR IGNORE INTO work_item_origins (
                id, work_item_id, source, source_key, meeting_id, meeting_title,
                job_id, todo_id, raw_title, raw_owner_names, raw_deadline,
                evidence_json, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            bindings: [
                .text(origin.id),
                .text(origin.workItemID),
                .text(origin.source.rawValue),
                .text(origin.sourceKey),
                origin.meetingID.map(SQLiteValue.text) ?? .null,
                origin.meetingTitle.map(SQLiteValue.text) ?? .null,
                origin.jobID.map(SQLiteValue.text) ?? .null,
                origin.todoID.map(SQLiteValue.text) ?? .null,
                .text(origin.rawTitle),
                .text(String(decoding: ownerNames, as: UTF8.self)),
                origin.rawDeadline.map(SQLiteValue.text) ?? .null,
                .text(String(decoding: evidence, as: UTF8.self)),
                .real(origin.createdAt.timeIntervalSince1970)
            ]
        )
    }

    private func findOrigin(sourceKey: String) throws -> WorkItemOrigin? {
        try database.query(
            "SELECT * FROM work_item_origins WHERE source_key = ?",
            bindings: [.text(sourceKey)]
        ).first.map(decodeOrigin)
    }

    private func validate(_ item: WorkItem) throws {
        guard !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WorkItemRepositoryError.invalidTitle
        }
        if let start = item.plannedStartDate, let end = item.plannedEndDate,
           WorkItemDate.normalized(end) < WorkItemDate.normalized(start) {
            throw WorkItemRepositoryError.invalidDateRange
        }
    }

    private func bindings(
        for item: WorkItem,
        includeID: Bool = false,
        includeCreatedAt: Bool = true
    ) -> [SQLiteValue] {
        let owners = (try? encoder.encode(item.ownerPersonIDs)) ?? Data("[]".utf8)
        let hints = (try? encoder.encode(item.ownerNameHints)) ?? Data("[]".utf8)
        let tags = (try? encoder.encode(item.tags)) ?? Data("[]".utf8)
        var values: [SQLiteValue] = []
        if includeID { values.append(.text(item.id)) }
        values.append(contentsOf: [
            .text(item.title),
            .text(item.detail),
            .text(item.deliverable),
            .text(item.acceptanceCriteria),
            .text(String(decoding: owners, as: UTF8.self)),
            .text(String(decoding: hints, as: UTF8.self)),
            item.sourceDeadlineText.map(SQLiteValue.text) ?? .null,
            item.plannedStartDate.map { .text(WorkItemDate.key($0)) } ?? .null,
            item.plannedEndDate.map { .text(WorkItemDate.key($0)) } ?? .null,
            .text(item.status.rawValue),
            .text(item.priority.rawValue),
            .text(String(decoding: tags, as: UTF8.self)),
            .text(item.completionNote),
            item.completedAt.map { .real($0.timeIntervalSince1970) } ?? .null,
            item.sourceMeetingID.map(SQLiteValue.text) ?? .null,
            item.sourceMeetingTitle.map(SQLiteValue.text) ?? .null,
            .text(item.source.rawValue)
        ])
        if includeCreatedAt {
            values.append(.real(item.createdAt.timeIntervalSince1970))
        }
        values.append(.real(item.updatedAt.timeIntervalSince1970))
        return values
    }

    private func decode(_ row: [String: SQLiteValue]) throws -> WorkItem {
        guard let statusValue = row["status"]?.stringValue,
              let status = WorkItemStatus(rawValue: statusValue),
              let priorityValue = row["priority"]?.stringValue,
              let priority = WorkItemPriority(rawValue: priorityValue),
              let sourceValue = row["source"]?.stringValue,
              let source = WorkItemSource(rawValue: sourceValue),
              let createdAt = row["created_at"]?.doubleValue,
              let updatedAt = row["updated_at"]?.doubleValue else {
            throw WorkItemRepositoryError.invalidRecord
        }
        return WorkItem(
            id: row["id"]?.stringValue ?? "",
            title: row["title"]?.stringValue ?? "",
            detail: row["detail"]?.stringValue ?? "",
            deliverable: row["deliverable"]?.stringValue ?? "",
            acceptanceCriteria: row["acceptance_criteria"]?.stringValue ?? "",
            ownerPersonIDs: decodeArray(row["owner_person_ids"]?.stringValue),
            ownerNameHints: decodeArray(row["owner_name_hints"]?.stringValue),
            sourceDeadlineText: row["source_deadline_text"]?.stringValue,
            plannedStartDate: row["planned_start_date"]?.stringValue.flatMap { WorkItemDate.date(from: $0) },
            plannedEndDate: row["planned_end_date"]?.stringValue.flatMap { WorkItemDate.date(from: $0) },
            status: status,
            priority: priority,
            tags: decodeArray(row["tags_json"]?.stringValue),
            completionNote: row["completion_note"]?.stringValue ?? "",
            completedAt: row["completed_at"]?.doubleValue.map(Date.init(timeIntervalSince1970:)),
            sourceMeetingID: row["source_meeting_id"]?.stringValue,
            sourceMeetingTitle: row["source_meeting_title"]?.stringValue,
            source: source,
            createdAt: Date(timeIntervalSince1970: createdAt),
            updatedAt: Date(timeIntervalSince1970: updatedAt)
        )
    }

    private func decodeOrigin(_ row: [String: SQLiteValue]) throws -> WorkItemOrigin {
        guard let sourceValue = row["source"]?.stringValue,
              let source = WorkItemSource(rawValue: sourceValue),
              let createdAt = row["created_at"]?.doubleValue else {
            throw WorkItemRepositoryError.invalidRecord
        }
        let evidenceJSON = row["evidence_json"]?.stringValue ?? "[]"
        let evidence = try decoder.decode([MeetingTodoEvidence].self, from: Data(evidenceJSON.utf8))
        return WorkItemOrigin(
            id: row["id"]?.stringValue ?? "",
            workItemID: row["work_item_id"]?.stringValue ?? "",
            source: source,
            sourceKey: row["source_key"]?.stringValue ?? "",
            meetingID: row["meeting_id"]?.stringValue,
            meetingTitle: row["meeting_title"]?.stringValue,
            jobID: row["job_id"]?.stringValue,
            todoID: row["todo_id"]?.stringValue,
            rawTitle: row["raw_title"]?.stringValue ?? "",
            rawOwnerNames: decodeArray(row["raw_owner_names"]?.stringValue),
            rawDeadline: row["raw_deadline"]?.stringValue,
            evidence: evidence,
            createdAt: Date(timeIntervalSince1970: createdAt)
        )
    }

    private func decodeArray<T: Decodable>(_ value: String?) -> [T] {
        guard let value, let data = value.data(using: .utf8),
              let decoded = try? decoder.decode([T].self, from: data) else { return [] }
        return decoded
    }

    private func comparable(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
            .lowercased()
    }
}
