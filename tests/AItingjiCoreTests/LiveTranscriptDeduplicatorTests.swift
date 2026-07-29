import AItingjiCore
import Testing

@Test
func liveTranscriptDeduplicatorKeepsTextWhenThereIsNoPreviousSegment() {
    let result = LiveTranscriptDeduplicator.appendableText(
        previousText: nil,
        currentText: "我们先确认今天的目标和范围。"
    )

    #expect(result == "我们先确认今天的目标和范围。")
}

@Test
func liveTranscriptDeduplicatorDropsExactDuplicateText() {
    let result = LiveTranscriptDeduplicator.appendableText(
        previousText: "临时发言人",
        currentText: "临时发言人"
    )

    #expect(result == nil)
}

@Test
func liveTranscriptDeduplicatorTrimsRepeatedPrefixOverlap() {
    let result = LiveTranscriptDeduplicator.appendableText(
        previousText: "我们先确认今天的目标和范围",
        currentText: "今天的目标和范围需要再补充两点"
    )

    #expect(result == "需要再补充两点")
}

@Test
func liveTranscriptDeduplicatorTrimsRepeatedWindowCopies() {
    let result = LiveTranscriptDeduplicator.appendableText(
        previousText: "我们先确认今天的目标和范围",
        currentText: "我们先确认今天的目标和范围我们先确认今天的目标和范围需要再补充两点"
    )

    #expect(result == "需要再补充两点")
}

@Test
func liveTranscriptDeduplicatorDropsDuplicateWithinRecentWindow() {
    // 幻觉：一模一样的短语两段之外又冒出来。
    let result = LiveTranscriptDeduplicator.appendableText(
        recentTexts: [
            "谢谢观看",
            "我们继续讨论方案",
            "接下来是第二个议题"
        ],
        currentText: "谢谢观看"
    )
    #expect(result == nil)
}

@Test
func liveTranscriptDeduplicatorDropsHighlySimilarSegment() {
    // 标点/微调后的重复。
    let result = LiveTranscriptDeduplicator.appendableText(
        recentTexts: ["我们先确认今天的目标和范围。"],
        currentText: "我们先确认下今天的目标和范围"
    )
    #expect(result == nil)
}

@Test
func liveTranscriptDeduplicatorAllowsFreshContentAfterRecentWindow() {
    let result = LiveTranscriptDeduplicator.appendableText(
        recentTexts: [
            "谢谢观看",
            "我们继续讨论方案",
            "接下来是第二个议题"
        ],
        currentText: "第三个议题是关于交付节奏"
    )
    #expect(result == "第三个议题是关于交付节奏")
}

@Test
func liveTranscriptDeduplicatorTrimsPrefixThenDropsIfRemainderDuplicate() {
    // 首尾裁剪后剩余部分仍与更早段落重复 → 丢弃
    let result = LiveTranscriptDeduplicator.appendableText(
        recentTexts: [
            "谢谢观看",
            "我们先确认今天的目标和范围"
        ],
        currentText: "我们先确认今天的目标和范围谢谢观看"
    )
    #expect(result == nil)
}
