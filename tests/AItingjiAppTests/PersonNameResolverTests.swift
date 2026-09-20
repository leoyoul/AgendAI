import AItingjiCore
import Testing
@testable import AItingjiApp

@Suite("Person name resolver")
struct PersonNameResolverTests {
    @Test("resolves canonical names, aliases, and honorific forms by priority")
    func resolvesByPriority() {
        let resolver = fixtureResolver()

        #expect(resolver.resolve("张敏")?.id == "person-zhang")
        #expect(resolver.resolve("敏姐")?.id == "person-zhang")
        #expect(resolver.resolve("张敏老师")?.id == "person-zhang")
        #expect(resolver.resolve("张 敏")?.id == "person-zhang")
        #expect(resolver.resolve("  张敏 ")?.id == "person-zhang")
        #expect(resolver.resolve("李总")?.id == "person-li")
        #expect(resolver.resolve("李总经理")?.id == "person-li")

        #expect(resolver.canonicalName(for: "张敏老师") == "张敏")
        #expect(resolver.canonicalName(for: "敏姐") == "张敏")
        #expect(resolver.canonicalName(for: "李总") == "李明")
    }

    @Test("keeps the original name when the people table has no match")
    func keepsUnknownNames() {
        let resolver = fixtureResolver()

        #expect(resolver.resolve("王小明") == nil)
        #expect(resolver.resolve("") == nil)
        #expect(resolver.canonicalName(for: "王小明") == "王小明")
        #expect(resolver.canonicalName(for: "待确认") == "待确认")
    }

    @Test("ignores inactive people and refuses ambiguous tokens")
    func skipsInactiveAndAmbiguous() {
        let resolver = fixtureResolver()

        #expect(resolver.resolve("王磊") == nil)
        #expect(resolver.resolve("王磊老师") == nil)
        // 两个同名人员互相冲突时不做匹配，避免错误指派。
        #expect(resolver.resolve("李强") == nil)
    }

    private func fixtureResolver() -> PersonNameResolver {
        PersonNameResolver(people: [
            VoiceprintPerson(id: "person-zhang", displayName: "张敏", aliases: ["敏姐"]),
            VoiceprintPerson(id: "person-li", displayName: "李明", aliases: ["李总"]),
            VoiceprintPerson(id: "person-inactive", displayName: "王磊", isActive: false),
            VoiceprintPerson(id: "person-dup-a", displayName: "李强"),
            VoiceprintPerson(id: "person-dup-b", displayName: "李强"),
        ])
    }
}

@Suite("Meeting minutes action owners")
struct MeetingMinutesActionOwnerTests {
    @Test("rewrites matched owners to canonical names and keeps strangers")
    func resolvesActionOwners() {
        let document = makeDocument(owners: ["张敏老师", "李总", "王小明"])
        let vocabulary = MeetingMinutesVocabulary(terminologyEntries: [], people: [
            VoiceprintPerson(id: "person-zhang", displayName: "张敏", aliases: ["敏姐"]),
            VoiceprintPerson(id: "person-li", displayName: "李明", aliases: ["李总"]),
        ])

        let resolved = MeetingMinutesGenerator.resolvingActionOwners(document, vocabulary: vocabulary)

        #expect(resolved.actions.first?.owners == ["张敏", "李明", "王小明"])
    }

    @Test("deduplicates owners that resolve to the same person")
    func deduplicatesResolvedOwners() {
        let document = makeDocument(owners: ["张敏", "张敏老师"])
        let vocabulary = MeetingMinutesVocabulary(terminologyEntries: [], people: [
            VoiceprintPerson(id: "person-zhang", displayName: "张敏"),
        ])

        let resolved = MeetingMinutesGenerator.resolvingActionOwners(document, vocabulary: vocabulary)

        #expect(resolved.actions.first?.owners == ["张敏"])
    }

    @Test("keeps owners untouched when the people table is empty")
    func keepsOwnersWithoutPeople() {
        let document = makeDocument(owners: ["张老师"])

        let resolved = MeetingMinutesGenerator.resolvingActionOwners(document, vocabulary: .empty)

        #expect(resolved.actions.first?.owners == ["张老师"])
    }

    private func makeDocument(owners: [String]) -> MeetingMinutesDocument {
        MeetingMinutesDocument(
            meetingID: "minutes-owners",
            title: "项目评审",
            meetingName: "项目评审会",
            meetingDate: "2026年9月14日",
            meetingTime: "10:00-10:30",
            duration: "约30分钟",
            participants: [],
            sources: ["会议转写"],
            subtitle: "方案评审",
            summary: "确认方案边界。",
            conclusions: [],
            actions: [
                MeetingMinutesAction(action: "整理交付计划", owners: owners, deadline: "待确认")
            ],
            risks: [],
            milestones: [],
            archiveItems: [],
            sensitiveNote: "无",
            preparedDate: "2026年9月14日"
        )
    }
}
