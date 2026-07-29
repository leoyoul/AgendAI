import Foundation
import Testing
@testable import AItingjiCore

@Test func appPersistenceStoreCreatesDirectoryAndLoadsSnapshot() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ai-tingji-store-\(UUID().uuidString)")
    let path = root
        .appendingPathComponent("nested")
        .appendingPathComponent("app.sqlite")
        .path

    do {
        let store = try AppPersistenceStore(path: path)
        let databasePermissions = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        let directoryPermissions = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("nested").path)[.posixPermissions] as? NSNumber
        #expect((databasePermissions?.intValue ?? 0) & 0o077 == 0)
        #expect((directoryPermissions?.intValue ?? 0) & 0o077 == 0)
        let meeting = Meeting(
            id: "store-meeting",
            title: "启动读取会议",
            status: .draft,
            captureSource: .mixed,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        try store.upsertMeeting(meeting)
        try store.upsertSegment(
            TranscriptSegment(
                id: "store-segment",
                meetingID: meeting.id,
                startMs: 0,
                endMs: 3_000,
                speakerLabel: "未知发言人 1",
                rawText: "需要跨重启保留"
            )
        )
        try store.upsertPerson(VoiceprintPerson(
            id: "store-person",
            displayName: "赵六",
            aliases: ["赵总"],
            jobTitle: "研发负责人",
            roleTags: ["研发"],
            responsibilities: "负责研发计划、技术方案与交付质量",
            zentaoAccount: "zhaoliu",
            zentaoUserID: "26"
        ))
        try store.upsertTerminologyEntry(TerminologyEntry(
            id: "store-term",
            canonicalName: "示例科技",
            aliases: ["示例"],
            category: "公司"
        ))
        try store.upsertDiarizationRun(
            DiarizationRun(
                id: "store-run",
                meetingID: meeting.id,
                scope: .full,
                status: .succeeded,
                audioFilePath: "/tmp/store.wav",
                turns: [DiarizationTurn(startMs: 0, endMs: 3000, speakerKey: "SPEAKER_00", confidence: 0.9)]
            )
        )
        try store.upsertDiarizationSpeakerMapping(
            DiarizationSpeakerMapping(
                meetingID: meeting.id,
                speakerKey: "SPEAKER_00",
                speakerLabel: "未知发言人 1",
                personID: "store-person",
                personName: "赵六",
                confidence: 0.95
            )
        )
        try store.upsertModelSource(
            ModelSource(
                id: "store-model",
                type: .asr,
                name: "本地转写",
                baseURL: "http://localhost:9000/v1",
                selectedModel: "local-asr"
            )
        )
        try store.setAppSetting(AppSettingKey.microphoneDeviceID, value: "BuiltInMicrophoneDevice")
        try store.setAppSetting(AppSettingKey.currentUserPersonID, value: "store-person")
        store.close()
    }

    do {
        let store = try AppPersistenceStore(path: path)
        let snapshot = try store.loadSnapshot()
        #expect(snapshot.meetings.map(\.id) == ["store-meeting"])
        #expect(snapshot.segmentsByMeeting["store-meeting"]?.map(\.id) == ["store-segment"])
        #expect(snapshot.people.map(\.displayName) == ["赵六"])
        #expect(snapshot.people.first?.jobTitle == "研发负责人")
        #expect(snapshot.people.first?.responsibilities == "负责研发计划、技术方案与交付质量")
        #expect(snapshot.people.first?.zentaoAccount == "zhaoliu")
        #expect(snapshot.terminologyEntries.map(\.canonicalName) == ["示例科技"])
        #expect(snapshot.diarizationRunsByMeeting["store-meeting"]?.map(\.id) == ["store-run"])
        #expect(snapshot.diarizationMappingsByMeeting["store-meeting"]?.first?.personName == "赵六")
        #expect(snapshot.modelSources.map(\.selectedModel) == ["local-asr"])
        #expect(snapshot.appSettings[AppSettingKey.microphoneDeviceID] == "BuiltInMicrophoneDevice")
        #expect(snapshot.appSettings[AppSettingKey.currentUserPersonID] == "store-person")
        store.close()
    }

    try? FileManager.default.removeItem(at: root)
}

@Test func appPersistenceDefaultPathUsesApplicationSupport() {
    let path = AppPersistenceStore.defaultDatabasePath()

    #expect(path.contains("Application Support"))
    #expect(path.contains("会小纪"))
    #expect(path.hasSuffix("ai-tingji.sqlite"))
    #expect(!path.contains(FileManager.default.currentDirectoryPath + "/.data"))
}
