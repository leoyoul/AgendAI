import Foundation
import Testing
@testable import AItingjiCore

@Suite("Transcript import parser")
struct TranscriptImportParserTests {
    @Test("preserves all readable Markdown content without inferring its structure")
    func preservesMarkdownContentForAgent() throws {
        let content = """
        # 外部会议

        - 会议ID：legacy-id
        - 状态：done
        - 采集来源：microphone

        ## 记录

        - [00:01-00:03] 张三：确认本周交付。
        - [00:03-00:06] 李四：周五前提交验收材料。
        """

        let records = try TranscriptImportParser.parse(content, fileExtension: "md")

        #expect(records.count == 4)
        #expect(records.allSatisfy { $0.speakerLabel == TranscriptImportParser.unassignedSpeakerLabel })
        #expect(records[0].text == "外部会议")
        #expect(records[1].text.contains("会议ID：legacy-id"))
        #expect(records[2].text == "记录")
        #expect(records[3].text.contains("[00:01-00:03] 张三：确认本周交付。"))
        #expect(records[3].text.contains("[00:03-00:06] 李四：周五前提交验收材料。"))
    }

    @Test("imports SRT timestamps, speakers, and multiline cues")
    func importsSRT() throws {
        let content = """
        1
        00:00:01,250 --> 00:00:04,500
        张三：第一行
        第二行

        2
        00:00:05,000 --> 00:00:07,000
        没有发言人的内容
        """

        let records = try TranscriptImportParser.parse(content, fileExtension: "srt")

        #expect(records.count == 2)
        #expect(records[0].startMs == 1_250)
        #expect(records[0].endMs == 4_500)
        #expect(records[0].speakerLabel == "张三")
        #expect(records[0].text == "第一行 第二行")
        #expect(records[1].speakerLabel == TranscriptImportParser.unassignedSpeakerLabel)
    }

    @Test("imports WebVTT voice markup")
    func importsWebVTT() throws {
        let content = """
        WEBVTT

        00:00:02.000 --> 00:00:05.000
        <v 李四>请补充风险清单。
        """

        let records = try TranscriptImportParser.parse(content, fileExtension: "vtt")

        #expect(records.count == 1)
        #expect(records[0].speakerLabel == "李四")
        #expect(records[0].text == "请补充风险清单。")
    }

    @Test("estimates a continuous timeline for plain text")
    func estimatesPlainTextTimeline() throws {
        let content = """
        张三：讨论第一项安排。
        补充说明第一项的验收标准。

        李四：确认第二项安排。
        """

        let records = try TranscriptImportParser.parse(content, fileExtension: "txt")

        #expect(records.count == 2)
        #expect(records[0].speakerLabel == TranscriptImportParser.unassignedSpeakerLabel)
        #expect(records[0].text.contains("张三：讨论第一项安排。"))
        #expect(records[0].text.contains("补充说明"))
        #expect(records[0].startMs == 0)
        #expect(records[0].endMs > records[0].startMs)
        #expect(records[1].startMs == records[0].endMs)
    }

    @Test("does not turn headings or list labels into speakers")
    func doesNotInferSpeakersFromFormattedText() throws {
        let content = """
        ## 说话人1（郝老师）

        今天重点讨论参赛材料：需要补齐多元数据说明。

        - 第一主战场：申报单位如何用好自身数据。
        - 第二主战场：如何赋能产业链上下游。
        """

        let records = try TranscriptImportParser.parse(content, fileExtension: "md")

        #expect(records.allSatisfy { $0.speakerLabel == TranscriptImportParser.unassignedSpeakerLabel })
        #expect(records.map(\.text).joined(separator: "\n").contains("说话人1（郝老师）"))
        #expect(records.map(\.text).joined(separator: "\n").contains("第一主战场：申报单位如何用好自身数据。"))
    }

    @Test("keeps arrow text in non-timed files")
    func keepsArrowTextInPlainText() throws {
        let records = try TranscriptImportParser.parse(
            "方案从数据治理 --> 智能体服务形成闭环。",
            fileExtension: "txt"
        )

        #expect(records.count == 1)
        #expect(records[0].text == "方案从数据治理 --> 智能体服务形成闭环。")
    }

    @Test("rejects empty transcript content")
    func rejectsEmptyContent() {
        #expect(throws: TranscriptImportError.emptyContent) {
            try TranscriptImportParser.parse(" \n\n ", fileExtension: "txt")
        }
    }
}
