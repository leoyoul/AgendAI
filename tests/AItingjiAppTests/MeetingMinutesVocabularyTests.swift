import AItingjiCore
import Foundation
import Testing
@testable import AItingjiApp

@Suite("Meeting minutes vocabulary")
struct MeetingMinutesVocabularyTests {
    @Test("normalizes aliases without rewriting an existing canonical name")
    func normalizesAliases() {
        let vocabulary = fixtureVocabulary()

        let normalized = vocabulary.normalize("李总请示例准备方案，示例科技随后确认。")

        #expect(normalized == "李明请示例科技准备方案，示例科技随后确认。")
        #expect(vocabulary.normalize("小李和示例技术") == "李明和示例科技")
    }

    @Test("keeps longest-match, canonical-name, case and diacritic semantics")
    func keepsNormalizationSemantics() {
        let vocabulary = MeetingMinutesVocabulary(
            terminologyEntries: [
                TerminologyEntry(
                    id: "term-overlap",
                    canonicalName: "示例科技",
                    aliases: ["示例", "示例技术"],
                    category: "公司"
                ),
                TerminologyEntry(
                    id: "term-accent",
                    canonicalName: "Coffee",
                    aliases: ["cafe"],
                    category: "测试"
                )
            ],
            people: []
        )

        #expect(vocabulary.normalize("示例技术、示例科技和CAFÉ") == "示例科技、示例科技和Coffee")
    }

    @Test("prompt carries roles and ZenTao mapping but excludes inactive entries")
    func buildsPromptContext() {
        let vocabulary = fixtureVocabulary()

        #expect(vocabulary.promptContext.contains("标准名称：示例科技；别称：示例技术、示例"))
        #expect(vocabulary.promptContext.contains("标准姓名：李明；称呼：李总、小李"))
        #expect(vocabulary.promptContext.contains("产品负责人"))
        #expect(vocabulary.promptContext.contains("禅道账号 liming"))
        #expect(!vocabulary.promptContext.contains("停用词"))
    }

    @Test("mock generation uses canonical terms and names while raw transcript remains unchanged")
    func generatorAppliesVocabulary() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tinglan-vocabulary-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let meeting = Meeting(
            id: "vocabulary-meeting",
            title: "示例项目周会",
            status: .done,
            createdAt: Date(timeIntervalSince1970: 1_784_236_800)
        )
        let segment = TranscriptSegment(
            id: "vocabulary-segment",
            meetingID: meeting.id,
            startMs: 0,
            endMs: 2_000,
            speakerLabel: "李总",
            rawText: "李总安排示例准备方案。"
        )
        let source = ModelSource(
            id: "vocabulary-model",
            type: .meetingMinutes,
            name: "Mock",
            baseURL: "mock://meeting-minutes",
            selectedModel: "mock",
            isDefault: true
        )

        let artifact = try await MeetingMinutesGenerator(storageDirectory: directory).generate(
            meeting: meeting,
            segments: [segment],
            source: source,
            vocabulary: fixtureVocabulary()
        )

        #expect(artifact.document.meetingName == "示例科技项目周会")
        #expect(artifact.document.participants == ["李明"])
        #expect(artifact.document.summary.contains("示例科技项目周会"))
        #expect(!artifact.markdown.contains("李总"))
        #expect(segment.rawText == "李总安排示例准备方案。")
    }

    private func fixtureVocabulary() -> MeetingMinutesVocabulary {
        MeetingMinutesVocabulary(
            terminologyEntries: [
                TerminologyEntry(
                    id: "term-example",
                    canonicalName: "示例科技",
                    aliases: ["示例技术", "示例"],
                    category: "公司"
                ),
                TerminologyEntry(
                    id: "term-disabled",
                    canonicalName: "停用标准词",
                    aliases: ["停用词"],
                    isActive: false
                )
            ],
            people: [
                VoiceprintPerson(
                    id: "person-liming",
                    displayName: "李明",
                    aliases: ["李总", "小李"],
                    jobTitle: "产品负责人",
                    roleTags: ["产品", "项目"],
                    zentaoAccount: "liming",
                    zentaoUserID: "12"
                )
            ]
        )
    }
}
