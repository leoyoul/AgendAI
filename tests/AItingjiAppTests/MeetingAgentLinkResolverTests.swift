import Foundation
import Testing
@testable import AItingjiApp

@Suite("Meeting Agent link resolver")
struct MeetingAgentLinkResolverTests {
    private let workspace = URL(fileURLWithPath: "/Users/test/Documents", isDirectory: true)

    @Test("opens an absolute Markdown path as a local file")
    func absolutePath() throws {
        let url = try #require(URL(string: "/Users/test/Documents/%E6%96%B9%E6%A1%88.html"))

        #expect(MeetingAgentLinkResolver.resolve(url, workspaceDirectory: workspace) == .localFile(
            URL(fileURLWithPath: "/Users/test/Documents/方案.html")
        ))
    }

    @Test("keeps file URLs as local files")
    func fileURL() {
        let url = URL(fileURLWithPath: "/Users/test/Documents/report.md")

        #expect(MeetingAgentLinkResolver.resolve(url, workspaceDirectory: workspace) == .localFile(url))
    }

    @Test("resolves relative paths inside the Agent workspace")
    func relativePath() throws {
        let url = try #require(URL(string: "reports/summary.html"))

        #expect(MeetingAgentLinkResolver.resolve(url, workspaceDirectory: workspace) == .localFile(
            URL(fileURLWithPath: "/Users/test/Documents/reports/summary.html")
        ))
    }

    @Test("keeps web links as web links")
    func webURL() throws {
        let url = try #require(URL(string: "https://openai.com/docs"))

        #expect(MeetingAgentLinkResolver.resolve(url, workspaceDirectory: workspace) == .web(url))
    }

    @Test("rejects unsupported schemes and relative workspace escapes")
    func rejectsUnsafeLinks() throws {
        let custom = try #require(URL(string: "javascript:alert(1)"))
        let escape = try #require(URL(string: "../secret.txt"))

        #expect(MeetingAgentLinkResolver.resolve(custom, workspaceDirectory: workspace) == .unsupported)
        #expect(MeetingAgentLinkResolver.resolve(escape, workspaceDirectory: workspace) == .unsupported)
    }
}
