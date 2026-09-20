import AItingjiCore
import Foundation

/// 把会议产生的负责人姓名回落到人员库时的统一匹配规则。
///
/// 匹配从严格到宽松逐级尝试，只有唯一命中才算匹配成功；
/// 未命中时由调用方保留原始姓名，不猜测、不编造。
struct PersonNameResolver {
    /// 常见职务或称谓后缀，只在精确匹配失败后再剥离，
    /// 按长度从长到短排列，保证“李总经理”先按“总经理”剥离。
    private static let honorificSuffixes = [
        "总经理", "老师", "先生", "女士", "同学", "大夫", "医生",
        "总监", "经理", "主任", "老板", "总", "工",
    ]

    private let nameIndex: [String: VoiceprintPerson]
    private let aliasIndex: [String: VoiceprintPerson]

    init(people: [VoiceprintPerson]) {
        let active = people.filter(\.isActive)
        nameIndex = Self.uniqueIndex(active.map { ($0.displayName, $0) })
        aliasIndex = Self.uniqueIndex(active.flatMap { person in
            person.aliases.map { ($0, person) }
        })
    }

    /// 注入模型提示词的负责人匹配规则：先匹配人员库，人员库确实没有对应人员时才保留原文姓名。
    static let honorificGuidance = """
    负责人姓名规则：负责人必须优先使用上列人员的标准姓名，把“张老师”“李总”这类称呼归一到对应人员的标准姓名；只有当人员库确实没有对应人员时，才保留会议原文中的姓名，不得编造人员，也不得把岗位、角色、禅道账号或用户 ID 当作姓名。
    """

    /// 按标准姓名、称呼别名、去称谓的顺序匹配人员库。
    func resolve(_ rawName: String) -> VoiceprintPerson? {
        let key = Self.normalized(rawName)
        guard !key.isEmpty else { return nil }
        if let person = nameIndex[key] { return person }
        if let person = aliasIndex[key] { return person }
        for stripped in Self.keysStrippingHonorifics(key) {
            if let person = nameIndex[stripped] { return person }
            if let person = aliasIndex[stripped] { return person }
        }
        return nil
    }

    /// 命中人员库时返回标准姓名，人员库中没有对应人员时原样返回。
    func canonicalName(for rawName: String) -> String {
        guard let person = resolve(rawName) else { return rawName }
        return person.displayName
    }

    static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "zh_CN"))
    }

    private static func keysStrippingHonorifics(_ key: String) -> [String] {
        honorificSuffixes.compactMap { suffix in
            guard key.count > suffix.count, key.hasSuffix(suffix) else { return nil }
            return String(key.dropLast(suffix.count))
        }
    }

    /// 同一称呼指向多个人员时判为歧义，不做匹配，避免错误指派。
    private static func uniqueIndex(_ pairs: [(String, VoiceprintPerson)]) -> [String: VoiceprintPerson] {
        var buckets: [String: [VoiceprintPerson]] = [:]
        for (token, person) in pairs {
            let key = normalized(token)
            guard !key.isEmpty else { continue }
            buckets[key, default: []].append(person)
        }
        return buckets.compactMapValues { candidates in
            let ids = Set(candidates.map(\.id))
            return ids.count == 1 ? candidates[0] : nil
        }
    }
}
