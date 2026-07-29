import AItingjiCore
import Foundation
import Testing

private actor RequestConcurrencyProbe {
    private(set) var activeCount = 0
    private(set) var maximumActiveCount = 0

    func enter() {
        activeCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)
    }

    func leave() {
        activeCount -= 1
    }
}

@Test("model requests to the same origin run serially")
func sameOriginModelRequestsRunSerially() async throws {
    let coordinator = HTTPOriginRequestCoordinator()
    let probe = RequestConcurrencyProbe()
    let asrURL = try #require(URL(string: "http://127.0.0.1:18001/v1/audio/transcriptions"))
    let minutesURL = try #require(URL(string: "http://127.0.0.1:18001/v1/chat/completions"))

    await withTaskGroup(of: Void.self) { group in
        for url in [asrURL, minutesURL] {
            group.addTask {
                await coordinator.perform(for: url) {
                    await probe.enter()
                    try? await Task.sleep(for: .milliseconds(50))
                    await probe.leave()
                }
            }
        }
    }

    #expect(await probe.maximumActiveCount == 1)
}

@Test("same origin requests honor a configured maximum concurrency")
func sameOriginModelRequestsHonorMaximumConcurrency() async throws {
    let coordinator = HTTPOriginRequestCoordinator()
    let probe = RequestConcurrencyProbe()
    let url = try #require(URL(string: "http://127.0.0.1:18001/v1/chat/completions"))

    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<4 {
            group.addTask {
                await coordinator.perform(for: url, maximumConcurrency: 2) {
                    await probe.enter()
                    try? await Task.sleep(for: .milliseconds(50))
                    await probe.leave()
                }
            }
        }
    }

    #expect(await probe.maximumActiveCount == 2)
}

@Test("same origin requests can explicitly opt out of coordination")
func sameOriginModelRequestsCanOptOutOfCoordination() async throws {
    let coordinator = HTTPOriginRequestCoordinator()
    let probe = RequestConcurrencyProbe()
    let url = try #require(URL(string: "http://127.0.0.1:18001/v1/chat/completions"))

    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<3 {
            group.addTask {
                await coordinator.perform(for: url, maximumConcurrency: nil) {
                    await probe.enter()
                    try? await Task.sleep(for: .milliseconds(50))
                    await probe.leave()
                }
            }
        }
    }

    #expect(await probe.maximumActiveCount == 3)
}
