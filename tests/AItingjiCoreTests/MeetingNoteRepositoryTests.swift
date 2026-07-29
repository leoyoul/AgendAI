import Foundation
import Testing
@testable import AItingjiCore

@Test
func meetingNotesAndImagesRoundTripThroughSQLite() throws {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("ai-tingji-notes-\(UUID().uuidString).sqlite")
        .path
    defer { try? FileManager.default.removeItem(atPath: path) }

    let store = try AppPersistenceStore(path: path)
    let meeting = Meeting(
        id: "notes-meeting",
        title: "笔记持久化",
        status: .done,
        createdAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
    try store.upsertMeeting(meeting)

    let note = MeetingNote(
        id: "note-1",
        meetingID: meeting.id,
        body: "保留人工补充",
        includeInMinutes: true,
        createdAt: Date(timeIntervalSince1970: 1_800_000_001),
        updatedAt: Date(timeIntervalSince1970: 1_800_000_002)
    )
    try store.upsertMeetingNote(note)
    let image = MeetingNoteImage(
        id: "image-1",
        noteID: note.id,
        filename: "board.png",
        mimeType: "image/png",
        originalData: Data([1, 2, 3, 4]),
        thumbnailData: Data([9, 8]),
        sha256: String(repeating: "a", count: 64),
        createdAt: Date(timeIntervalSince1970: 1_800_000_003),
        updatedAt: Date(timeIntervalSince1970: 1_800_000_004)
    )
    try store.upsertMeetingNoteImage(image)

    let snapshot = try store.loadSnapshot()
    #expect(snapshot.notesByMeeting[meeting.id]?.first?.body == "保留人工补充")
    #expect(snapshot.noteImagesByMeeting[meeting.id]?.first?.originalData == nil)
    #expect(snapshot.noteImagesByMeeting[meeting.id]?.first?.thumbnailData == Data([9, 8]))

    let loaded = try store.loadMeetingNotes(meetingID: meeting.id, includeOriginalData: true)
    #expect(loaded.0 == [note])
    #expect(loaded.1.first?.originalData == Data([1, 2, 3, 4]))

    try store.updateMeetingNoteImageVision(
        id: image.id,
        status: .completed,
        text: "图片中的结论",
        model: "vision-model",
        promptVersion: "1"
    )
    let visionLoaded = try store.loadMeetingNotes(meetingID: meeting.id, includeOriginalData: true)
    #expect(visionLoaded.1.first?.visionStatus == .completed)
    #expect(visionLoaded.1.first?.visionText == "图片中的结论")
}

@Test
func modelSourcePersistsVisionCapability() throws {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("ai-tingji-vision-model-\(UUID().uuidString).sqlite")
        .path
    defer { try? FileManager.default.removeItem(atPath: path) }

    let store = try AppPersistenceStore(path: path)
    try store.upsertModelSource(ModelSource(
        id: "vision-model",
        type: .agent,
        name: "视觉模型",
        baseURL: "https://example.test/v1",
        selectedModel: "vision-model",
        supportsVision: true
    ))

    #expect(try store.loadSnapshot().modelSources.first?.supportsVision == true)
}
