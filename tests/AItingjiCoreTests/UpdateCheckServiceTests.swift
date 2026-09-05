import AItingjiCore
import Foundation
import Testing

private func releaseJSON(
    tag: String = "v0.1.2",
    name: String? = "会小纪 0.1.2",
    url: String = "https://github.com/leoyoul/AgendAI/releases/tag/v0.1.2",
    draft: Bool = false,
    prerelease: Bool = false
) -> Data {
    let encodedName = name.map { "\"\($0)\"" } ?? "null"
    return Data("{\"tag_name\":\"\(tag)\",\"name\":\(encodedName),\"html_url\":\"\(url)\",\"draft\":\(draft),\"prerelease\":\(prerelease)}".utf8)
}

@Test("release name falls back to its tag")
func missingReleaseNameUsesTag() async throws {
    let result = try await service(data: releaseJSON(name: nil)).check(currentVersion: "0.1.1")
    guard case .updateAvailable(let release) = result else {
        Issue.record("expected an available update")
        return
    }
    #expect(release.name == "v0.1.2")
}

private func service(data: Data, status: Int = 200) -> UpdateCheckService {
    UpdateCheckService { _ in
        let response = HTTPURLResponse(
            url: UpdateCheckService.latestReleaseURL,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        )!
        return (data, response)
    }
}

@Test("newer release is reported")
func newerReleaseIsReported() async throws {
    let result = try await service(data: releaseJSON()).check(currentVersion: "0.1.1")
    guard case .updateAvailable(let release) = result else {
        Issue.record("expected an available update")
        return
    }
    #expect(release.version.description == "0.1.2")
    #expect(release.name == "会小纪 0.1.2")
    #expect(release.htmlURL.absoluteString == "https://github.com/leoyoul/AgendAI/releases/tag/v0.1.2")
}

@Test("same or newer local version is up to date")
func sameOrNewerVersionIsUpToDate() async throws {
    let checker = service(data: releaseJSON(tag: "v0.1.10"))
    #expect(try await checker.check(currentVersion: "0.1.10") == .upToDate)
    #expect(try await checker.check(currentVersion: "0.1.11") == .upToDate)
}

@Test("numeric version comparison does not sort 10 before 9")
func numericVersionComparison() throws {
    let nine = try AppVersion("0.1.9")
    let ten = try AppVersion("v0.1.10")
    #expect(nine < ten)
}

@Test("invalid local and release versions fail safely")
func invalidVersionsFailSafely() async throws {
    #expect(throws: UpdateCheckError.invalidVersion("not-a-version")) {
        _ = try AppVersion("not-a-version")
    }
    let checker = service(data: releaseJSON(tag: "latest"))
    await #expect(throws: UpdateCheckError.invalidVersion("latest")) {
        try await checker.check(currentVersion: "0.1.1")
    }
}

@Test("HTTP failures are exposed with their status")
func httpFailureIsExposed() async throws {
    await #expect(throws: UpdateCheckError.httpStatus(429)) {
        try await service(data: releaseJSON(), status: 429).check(currentVersion: "0.1.1")
    }
}

@Test("network failures are exposed separately")
func networkFailureIsExposed() async throws {
    let checker = UpdateCheckService { _ in
        throw URLError(.notConnectedToInternet)
    }
    await #expect(throws: UpdateCheckError.self) {
        try await checker.check(currentVersion: "0.1.1")
    }
}

@Test("malformed JSON is a decoding failure")
func malformedJSONIsDecodingFailure() async throws {
    await #expect(throws: UpdateCheckError.decodingFailed) {
        try await service(data: Data("not json".utf8)).check(currentVersion: "0.1.1")
    }
}

@Test("drafts and prereleases are not offered")
func nonFormalReleasesAreRejected() async throws {
    await #expect(throws: UpdateCheckError.decodingFailed) {
        try await service(data: releaseJSON(draft: true)).check(currentVersion: "0.1.1")
    }
    await #expect(throws: UpdateCheckError.decodingFailed) {
        try await service(data: releaseJSON(prerelease: true)).check(currentVersion: "0.1.1")
    }
}

@Test("only official HTTPS release URLs are trusted")
func releaseURLAllowlist() {
    #expect(UpdateCheckService.isTrustedReleaseURL(URL(string: "https://github.com/leoyoul/AgendAI/releases/tag/v0.1.2")))
    #expect(!UpdateCheckService.isTrustedReleaseURL(URL(string: "http://github.com/leoyoul/AgendAI/releases/tag/v0.1.2")))
    #expect(!UpdateCheckService.isTrustedReleaseURL(URL(string: "https://github.com.evil.example/leoyoul/AgendAI/releases/tag/v0.1.2")))
    #expect(!UpdateCheckService.isTrustedReleaseURL(URL(string: "https://github.com/other/repo/releases/tag/v0.1.2")))
    #expect(!UpdateCheckService.isTrustedReleaseURL(URL(string: "https://github.com/leoyoul/AgendAI/issues/1")))
    #expect(!UpdateCheckService.isTrustedReleaseURL(URL(string: "https://github.com/leoyoul/AgendAI/releases/../issues/1")))
}

@Test("untrusted release URL is rejected")
func untrustedReleaseURLIsRejected() async throws {
    await #expect(throws: UpdateCheckError.untrustedReleaseURL) {
        try await service(data: releaseJSON(url: "https://example.com/leoyoul/AgendAI/releases/tag/v0.1.2"))
            .check(currentVersion: "0.1.1")
    }
}
