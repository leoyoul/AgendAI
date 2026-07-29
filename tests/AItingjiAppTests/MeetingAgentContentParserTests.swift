import Testing
@testable import AItingjiApp

@Suite("Meeting Agent content parser")
struct MeetingAgentContentParserTests {
    @Test("separates prose and fenced code without expanding code into many views")
    func fencedCode() {
        let blocks = MeetingAgentContentParser.parse("""
        先看结论。

        ```html
        <h1>方案</h1>
        <p>正文</p>
        ```

        完成。
        """)

        #expect(blocks == [
            .paragraph("先看结论。"),
            .code(language: "html", content: "<h1>方案</h1>\n<p>正文</p>"),
            .paragraph("完成。"),
        ])
    }

    @Test("keeps an unfinished streaming fence as one code block")
    func unfinishedFence() {
        let blocks = MeetingAgentContentParser.parse("```swift\nlet value = 1")
        #expect(blocks == [.code(language: "swift", content: "let value = 1")])
    }

    @Test("preserves paragraph, heading, list, quote, and divider structure")
    func richBlocks() {
        let blocks = MeetingAgentContentParser.parse("""
        ## 结论

        第一段包含 **重点**。

        1. 第一项
        2. 第二项

        - 风险一
        * 风险二

        > 请确认最终方案。

        ---

        请问是否直接执行？
        """)

        #expect(blocks == [
            .heading(level: 2, text: "结论"),
            .paragraph("第一段包含 **重点**。"),
            .orderedList(start: 1, items: ["第一项", "第二项"]),
            .unorderedList(["风险一", "风险二"]),
            .quote("请确认最终方案。"),
            .divider,
            .paragraph("请问是否直接执行？"),
        ])
    }

    @Test("keeps the proactive question separate from the preceding choices")
    func proactiveQuestionLayout() {
        let blocks = MeetingAgentContentParser.parse("""
        您可以选择以下两种方式之一：

        1. **直接生成文件**：写入当前工作目录。
        2. **生成代码块**：在对话中展示代码。

        请问需要我直接创建文件吗？
        """)

        #expect(blocks == [
            .paragraph("您可以选择以下两种方式之一："),
            .orderedList(
                start: 1,
                items: [
                    "**直接生成文件**：写入当前工作目录。",
                    "**生成代码块**：在对话中展示代码。",
                ]
            ),
            .paragraph("请问需要我直接创建文件吗？"),
        ])
    }

    @Test("parses GFM tables into structured rows")
    func markdownTable() {
        let blocks = MeetingAgentContentParser.parse("""
        分工如下：

        | 角色 | 负责人 | 说明 |
        | :--- | :---: | ---: |
        | 总协调 | **李明** | 推进初稿 |
        | 人防 | 杨倡堰 | 培训与演练 |

        请确认。
        """)

        #expect(blocks == [
            .paragraph("分工如下："),
            .table(
                headers: ["角色", "负责人", "说明"],
                rows: [
                    ["总协调", "**李明**", "推进初稿"],
                    ["人防", "杨倡堰", "培训与演练"],
                ]
            ),
            .paragraph("请确认。"),
        ])
    }

    @Test("keeps escaped and code pipes inside table cells")
    func tableCellPipes() {
        let blocks = MeetingAgentContentParser.parse("""
        名称 | 内容
        --- | ---
        A | 左\\|右
        B | `a|b`
        """)

        #expect(blocks == [
            .table(
                headers: ["名称", "内容"],
                rows: [["A", "左|右"], ["B", "`a|b`"]]
            ),
        ])
    }

    @Test("reuses cached blocks for long historical replies")
    func cachedHistoricalReply() {
        let paragraph = "## 结论\n\n这是包含 **重点** 的历史回复。\n\n- 第一项\n- 第二项"
        let content = Array(repeating: paragraph, count: 80).joined(separator: "\n\n")
        let expected = MeetingAgentContentParser.parse(content)

        for _ in 0..<20 {
            #expect(MeetingAgentMarkdownCache.shared.blocks(for: content) == expected)
        }
        let inline = MeetingAgentMarkdownCache.shared.attributedString(for: "包含 **重点**")
        #expect(String(inline.characters) == "包含 重点")
    }
}
