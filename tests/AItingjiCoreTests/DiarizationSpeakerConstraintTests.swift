import AItingjiCore
import Testing

@Test
func diarizationSpeakerPresetDefaultsToAutomaticOneToTwelveSpeakers() {
    // 自动预设保持宽范围（1-12），不做人数硬约束；
    // 说话人数由拼接层的自然相似度 gap 判定。
    let preset = DiarizationSpeakerPreset.parse(nil)

    #expect(preset == .automatic)
    #expect(preset.constraint.minSpeakers == 1)
    #expect(preset.constraint.maxSpeakers == 12)
    #expect(preset.constraint.numSpeakers == nil)
}

@Test
func diarizationSpeakerPresetTwoIsHardCountOfTwo() {
    // 用户仍可显式选"2 人"作为高级选项 → 走 sidecar 的 preset_spk_num=2。
    // 这条测试只是校验枚举语义，不代表 App 默认使用它。
    let constraint = DiarizationSpeakerPreset.two.constraint

    #expect(constraint.minSpeakers == nil)
    #expect(constraint.maxSpeakers == nil)
    #expect(constraint.numSpeakers == 2)
}

@Test
func fixedDiarizationSpeakerPresetValuesSendFixedSpeakerCount() {
    let cases: [(String, Int)] = [
        ("one", 1),
        ("three", 3),
        ("four", 4),
        ("five", 5),
        ("six", 6),
        ("eight", 8)
    ]

    for (value, expectedCount) in cases {
        let preset = DiarizationSpeakerPreset.parse(value)

        #expect(preset.constraint.minSpeakers == nil)
        #expect(preset.constraint.maxSpeakers == nil)
        #expect(preset.constraint.numSpeakers == expectedCount)
    }
}
