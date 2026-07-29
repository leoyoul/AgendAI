import AItingjiCore
import Foundation
import Testing

@Test
func httpSessionFactorySharedSessionCarriesConfiguredTimeouts() {
    let session = HTTPSessionFactory.shared()
    #expect(session.configuration.timeoutIntervalForRequest == HTTPSessionFactory.defaultRequestTimeout)
    #expect(session.configuration.timeoutIntervalForResource == HTTPSessionFactory.defaultResourceTimeout)
    #expect(session.configuration.waitsForConnectivity == false)
}

@Test
func httpSessionFactoryReturnsCachedSharedSession() {
    let first = HTTPSessionFactory.shared()
    let second = HTTPSessionFactory.shared()
    #expect(first === second)
}

@Test
func httpSessionFactoryHonorsCustomConfiguration() {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.timeoutIntervalForRequest = 1
    let session = HTTPSessionFactory.make(configuration: cfg)
    #expect(session.configuration.timeoutIntervalForRequest == 1)
}

@Test
func meetingMinutesGenerationSessionUsesLongTimeouts() {
    let session = HTTPSessionFactory.generation()

    #expect(HTTPSessionFactory.generationRequestTimeout == 900)
    #expect(HTTPSessionFactory.generationResourceTimeout == 900)
    #expect(session.configuration.timeoutIntervalForRequest == HTTPSessionFactory.generationRequestTimeout)
    #expect(session.configuration.timeoutIntervalForResource == HTTPSessionFactory.generationResourceTimeout)
    #expect(session.configuration.waitsForConnectivity == false)
}

@Test
func asrSessionAllowsSlowLocalInferenceWithoutParallelConnections() {
    let session = HTTPSessionFactory.asr()

    #expect(HTTPSessionFactory.asrRequestTimeout == 900)
    #expect(HTTPSessionFactory.asrResourceTimeout == 900)
    #expect(session.configuration.timeoutIntervalForRequest == HTTPSessionFactory.asrRequestTimeout)
    #expect(session.configuration.timeoutIntervalForResource == HTTPSessionFactory.asrResourceTimeout)
    #expect(session.configuration.httpMaximumConnectionsPerHost == 1)
    #expect(session.configuration.waitsForConnectivity == false)
}
