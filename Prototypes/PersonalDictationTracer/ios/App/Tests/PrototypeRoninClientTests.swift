import Foundation
@testable import HexKeyboardTracer
import XCTest

final class PrototypeRoninClientTests: XCTestCase {
    func testHealthRequestUsesFixedEndpointFromCanonicalOrigin() async throws {
        let recorder = RoninRequestRecorder()
        let session = RoninTestURLProtocol.session { request in
            recorder.record(request)
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )
            )
            return (response, Data(#"{"status":"ready"}"#.utf8))
        }

        try await PrototypeRoninClient.verifyReady(
            serverURLString: "https://ronin.tail451960.ts.net:8443/",
            token: String(repeating: "a", count: 64),
            session: session
        )

        XCTAssertEqual(
            recorder.request?.url?.absoluteString,
            "https://ronin.tail451960.ts.net:8443/health"
        )
    }

    func testServerURLRejectsAuthorityAndPathAmbiguity() async {
        let invalidURLs = [
            "https://owner@ronin.example:8443",
            "https://ronin.example:8443?route=health",
            "https://ronin.example:8443#health",
            "https://ronin.example:8443/v1/transcribe",
            "https://ronin.example:8443//",
            "https://ronin.example:8443",
            "https://ronin.tail451960.ts.net",
            "https://ronin.tail451960.ts.net:443",
        ]
        let session = RoninTestURLProtocol.session { _ in
            throw RoninTestFailure.unexpectedRequest
        }

        for invalidURL in invalidURLs {
            do {
                try await PrototypeRoninClient.verifyReady(
                    serverURLString: invalidURL,
                    token: String(repeating: "a", count: 64),
                    session: session
                )
                XCTFail("Expected an invalid origin for \(invalidURL)")
            } catch PrototypeRoninClient.ClientError.invalidServerURL {
                continue
            } catch {
                XCTFail("Unexpected error for \(invalidURL): \(error)")
            }
        }
    }

    func testIsolatedSessionHasNoAmbientHTTPState() {
        let session = PrototypeRoninClient.makeIsolatedSession()
        let configuration = session.configuration

        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(
            configuration.requestCachePolicy,
            .reloadIgnoringLocalCacheData
        )
    }

    func testHealthRequestRefusesRedirects() async {
        RoninRedirectURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RoninRedirectURLProtocol.self]
        let session = URLSession(configuration: configuration)

        do {
            try await PrototypeRoninClient.verifyReady(
                serverURLString: "https://ronin.tail451960.ts.net:8443",
                token: String(repeating: "a", count: 64),
                session: session
            )
            XCTFail("A pinned Ronin request must not follow a redirect")
        } catch PrototypeRoninClient.ClientError.rejected(status: 302) {
            // Refusing the redirect exposes the original response for status handling.
        } catch {
            XCTFail("Unexpected redirect error: \(error)")
        }

        XCTAssertFalse(RoninRedirectURLProtocol.requestedRedirectDestination)
    }

    func testTaskCancellationCancelsUnderlyingHealthRequest() async throws {
        let probe = RoninCancellationProbe()
        let session = RoninHangingURLProtocol.session(probe: probe)
        defer { session.invalidateAndCancel() }

        let requestTask = Task {
            try await PrototypeRoninClient.verifyReady(
                serverURLString: "https://ronin.tail451960.ts.net:8443",
                token: String(repeating: "a", count: 64),
                session: session
            )
        }

        XCTAssertEqual(
            probe.started.wait(timeout: .now() + 2),
            .success,
            "The test URL task did not start"
        )
        requestTask.cancel()

        do {
            try await requestTask.value
            XCTFail("Expected workflow cancellation to propagate")
        } catch is CancellationError {
            // The cancellation bridge owns the result rather than leaking a
            // transport-specific URLError.cancelled into the workflow.
        } catch {
            XCTFail("Unexpected cancellation error: \(error)")
        }

        XCTAssertEqual(
            probe.stopped.wait(timeout: .now() + 2),
            .success,
            "Cancelling the Swift task did not stop the URL loading system"
        )
    }

    func testPreCancelledTaskDoesNotStartUnderlyingHealthRequest() async {
        let gate = RoninCancellationGate()
        let probe = RoninCancellationProbe()
        let session = RoninHangingURLProtocol.session(probe: probe)
        defer { session.invalidateAndCancel() }

        let requestTask = Task {
            await gate.wait()
            try await PrototypeRoninClient.verifyReady(
                serverURLString: "https://ronin.tail451960.ts.net:8443",
                token: String(repeating: "a", count: 64),
                session: session
            )
        }

        XCTAssertEqual(
            gate.waiting.wait(timeout: .now() + 2),
            .success,
            "The request task did not reach the deterministic gate"
        )
        requestTask.cancel()
        gate.open()

        do {
            try await requestTask.value
            XCTFail("Expected pre-start cancellation to propagate")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected cancellation error: \(error)")
        }

        XCTAssertEqual(
            probe.started.wait(timeout: .now() + 0.2),
            .timedOut,
            "A pre-cancelled workflow must not create a URL task"
        )
    }

    func testHealthRejectsOversizedDeclaredResponseBeforeDecoding() async throws {
        let session = RoninTestURLProtocol.session { request in
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Length": "16385"]
                )
            )
            return (response, Data())
        }

        do {
            try await PrototypeRoninClient.verifyReady(
                serverURLString: "https://ronin.tail451960.ts.net:8443",
                token: String(repeating: "a", count: 64),
                session: session
            )
            XCTFail("Expected the declared health response size to be rejected")
        } catch PrototypeRoninClient.ClientError.responseTooLarge(let maximumBytes) {
            XCTAssertEqual(maximumBytes, 16 * 1_024)
        }
    }

    func testHealthRejectsOversizedChunkedResponse() async throws {
        let session = RoninTestURLProtocol.chunkedSession { request in
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )
            )
            return (
                response,
                [Data(repeating: 0x20, count: 9_000), Data(repeating: 0x20, count: 9_000)]
            )
        }

        do {
            try await PrototypeRoninClient.verifyReady(
                serverURLString: "https://ronin.tail451960.ts.net:8443",
                token: String(repeating: "a", count: 64),
                session: session
            )
            XCTFail("Expected the streamed health response size to be rejected")
        } catch PrototypeRoninClient.ClientError.responseTooLarge(let maximumBytes) {
            XCTAssertEqual(maximumBytes, 16 * 1_024)
        }
    }

    func testTranscriptionRejectsOversizedDeclaredResponseBeforeDecoding() async throws {
        let recordingURL = try temporaryRecordingURL()
        defer { try? FileManager.default.removeItem(at: recordingURL) }
        let session = RoninTestURLProtocol.session { request in
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Length": "262145"]
                )
            )
            return (response, Data())
        }

        do {
            _ = try await PrototypeRoninClient.transcribe(
                recordingURL: recordingURL,
                serverURLString: "https://ronin.tail451960.ts.net:8443",
                token: String(repeating: "a", count: 64),
                requestID: UUID(),
                session: session
            )
            XCTFail("Expected the declared transcription response size to be rejected")
        } catch PrototypeRoninClient.ClientError.responseTooLarge(let maximumBytes) {
            XCTAssertEqual(maximumBytes, 256 * 1_024)
        }
    }

    func testTranscriptionRejectsOversizedChunkedResponse() async throws {
        let recordingURL = try temporaryRecordingURL()
        defer { try? FileManager.default.removeItem(at: recordingURL) }
        let session = RoninTestURLProtocol.chunkedSession { request in
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )
            )
            return (
                response,
                [
                    Data(repeating: 0x20, count: 128 * 1_024),
                    Data(repeating: 0x20, count: 128 * 1_024),
                    Data([0x20]),
                ]
            )
        }

        do {
            _ = try await PrototypeRoninClient.transcribe(
                recordingURL: recordingURL,
                serverURLString: "https://ronin.tail451960.ts.net:8443",
                token: String(repeating: "a", count: 64),
                requestID: UUID(),
                session: session
            )
            XCTFail("Expected the streamed transcription response size to be rejected")
        } catch PrototypeRoninClient.ClientError.responseTooLarge(let maximumBytes) {
            XCTAssertEqual(maximumBytes, 256 * 1_024)
        }
    }

    private func temporaryRecordingURL() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ronin-client-test-\(UUID().uuidString).wav")
        try Data("test-audio".utf8).write(to: url, options: .atomic)
        return url
    }
}

private enum RoninTestFailure: Error {
    case unexpectedRequest
}

private final class RoninRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequest: URLRequest?

    var request: URLRequest? {
        lock.withLock { storedRequest }
    }

    func record(_ request: URLRequest) {
        lock.withLock { storedRequest = request }
    }
}

private final class RoninTestURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    typealias ChunkedHandler = @Sendable (URLRequest) throws -> (HTTPURLResponse, [Data])

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: ChunkedHandler?

    static func session(handler: @escaping Handler) -> URLSession {
        session { request in
            let (response, data) = try handler(request)
            return (response, [data])
        }
    }

    static func chunkedSession(handler: @escaping ChunkedHandler) -> URLSession {
        session(handler: handler)
    }

    private static func session(handler: @escaping ChunkedHandler) -> URLSession {
        lock.withLock { self.handler = handler }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RoninTestURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let handler = Self.lock.withLock { Self.handler }
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (response, chunks) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for chunk in chunks {
                client?.urlProtocol(self, didLoad: chunk)
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class RoninRedirectURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var followedRedirect = false

    static var requestedRedirectDestination: Bool {
        lock.withLock { followedRedirect }
    }

    static func reset() {
        lock.withLock { followedRedirect = false }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard request.url?.host == "ronin.tail451960.ts.net" else {
            Self.lock.withLock { Self.followedRedirect = true }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"status":"ready"}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        let redirectURL = URL(string: "https://attacker.example/health")!
        let redirectRequest = URLRequest(url: redirectURL)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 302,
            httpVersion: nil,
            headerFields: ["Location": redirectURL.absoluteString]
        )!
        client?.urlProtocol(
            self,
            wasRedirectedTo: redirectRequest,
            redirectResponse: response
        )
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class RoninCancellationProbe: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let stopped = DispatchSemaphore(value: 0)
}

private final class RoninCancellationGate: @unchecked Sendable {
    let waiting = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.withLock {
                self.continuation = continuation
            }
            waiting.signal()
        }
    }

    func open() {
        let continuation = lock.withLock {
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume()
    }
}

private final class RoninHangingURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var probe: RoninCancellationProbe?

    static func session(probe: RoninCancellationProbe) -> URLSession {
        lock.withLock { self.probe = probe }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RoninHangingURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.withLock { Self.probe }?.started.signal()
    }

    override func stopLoading() {
        Self.lock.withLock { Self.probe }?.stopped.signal()
    }
}
