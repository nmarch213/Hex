import Foundation

struct PrototypeRoninResponse: Decodable, Sendable {
    struct Timings: Decodable, Sendable {
        let upstreamMS: Int?
        let totalMS: Int
    }

    let requestID: String
    let transcript: String
    let timings: Timings
}

enum PrototypeRoninClient {
    private static let pinnedRoninHost = "ronin.tail451960.ts.net"
    private static let pinnedRoninPort = 8443
    private static let maximumHealthResponseBytes = 16 * 1_024
    private static let maximumTranscriptionResponseBytes = 256 * 1_024
    private static let isolatedSession = makeIsolatedSession()

    private struct HealthResponse: Decodable {
        let status: String
    }

    enum ClientError: LocalizedError {
        case missingToken
        case invalidTokenFormat
        case invalidServerURL
        case nonHTTPResponse
        case rejected(status: Int)
        case responseTooLarge(maximumBytes: Int)
        case mismatchedRequestID
        case serverNotReady

        var errorDescription: String? {
            switch self {
            case .missingToken:
                "Enter the Ronin Device Credential before arming Hex."
            case .invalidTokenFormat:
                "Use the 64-character lowercase hexadecimal credential generated on Ronin."
            case .invalidServerURL:
                "Hex accepts only its pinned private Ronin origin."
            case .nonHTTPResponse:
                "The Ronin server returned a non-HTTP response."
            case let .rejected(status) where status == 401:
                "Ronin rejected the Device Credential. Update it under Private server."
            case let .rejected(status) where status == 503:
                "Ronin is busy or still starting. Try this Dictation again."
            case let .rejected(status):
                "Ronin rejected the request (HTTP \(status))."
            case let .responseTooLarge(maximumBytes):
                "Ronin returned more than the allowed \(maximumBytes)-byte response."
            case .mismatchedRequestID:
                "Ronin returned a response for a different request."
            case .serverNotReady:
                "Ronin is reachable, but Parakeet is not ready."
            }
        }
    }

    static func verifyReady(
        serverURLString: String,
        token: String,
        session: URLSession = isolatedSession
    ) async throws {
        let baseURL = try validatedBaseURL(serverURLString)
        let token = try validatedToken(token)
        var request = URLRequest(url: baseURL.appendingPathComponent("health"))
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await boundedResponse(
            for: request,
            uploading: nil,
            maximumBytes: maximumHealthResponseBytes,
            session: session
        )
        let httpResponse = try validatedHTTPResponse(response)
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw ClientError.rejected(status: httpResponse.statusCode)
        }
        let health = try JSONDecoder().decode(HealthResponse.self, from: data)
        guard health.status == "ready" else {
            throw ClientError.serverNotReady
        }
    }

    static func transcribe(
        recordingURL: URL,
        serverURLString: String,
        token: String,
        requestID: UUID,
        session: URLSession = isolatedSession
    ) async throws -> PrototypeRoninResponse {
        let baseURL = try validatedBaseURL(serverURLString)
        let token = try validatedToken(token)

        let endpoint = baseURL.path.hasSuffix("/v1/transcribe")
            ? baseURL
            : baseURL.appendingPathComponent("v1/transcribe")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(requestID.uuidString, forHTTPHeaderField: "X-Hex-Request-ID")

        let (data, response) = try await boundedResponse(
            for: request,
            uploading: recordingURL,
            maximumBytes: maximumTranscriptionResponseBytes,
            session: session
        )
        let httpResponse = try validatedHTTPResponse(response)
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw ClientError.rejected(status: httpResponse.statusCode)
        }

        let decoded = try JSONDecoder().decode(PrototypeRoninResponse.self, from: data)
        guard UUID(uuidString: decoded.requestID) == requestID else {
            throw ClientError.mismatchedRequestID
        }
        return decoded
    }

    private static func validatedBaseURL(_ rawValue: String) throws -> URL {
        let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let components = URLComponents(string: trimmedValue),
            components.user == nil,
            components.password == nil,
            components.query == nil,
            components.fragment == nil,
            components.percentEncodedPath.isEmpty || components.percentEncodedPath == "/",
            let scheme = components.scheme?.lowercased(),
            let host = components.host?.lowercased(),
            !host.isEmpty,
            isAllowedOrigin(scheme: scheme, host: host, port: components.port)
            , let baseURL = components.url
        else {
            throw ClientError.invalidServerURL
        }
        return baseURL
    }

    private static func isAllowedOrigin(
        scheme: String,
        host: String,
        port: Int?
    ) -> Bool {
        if scheme == "https",
           host == pinnedRoninHost,
           port == pinnedRoninPort {
            return true
        }
#if DEBUG
        return scheme == "http"
            && ["localhost", "127.0.0.1", "::1"].contains(host)
#else
        return false
#endif
    }

    static func makeIsolatedSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }

    private static func boundedResponse(
        for request: URLRequest,
        uploading recordingURL: URL?,
        maximumBytes: Int,
        session: URLSession
    ) async throws -> (Data, URLResponse) {
        try await PrototypeRoninBoundedRequest.perform(
            configuration: session.configuration,
            request: request,
            uploading: recordingURL,
            maximumBytes: maximumBytes
        )
    }

    private static func validatedToken(_ rawValue: String) throws -> String {
        let token = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw ClientError.missingToken
        }
        guard token.range(
            of: "^[0-9a-f]{64}$",
            options: .regularExpression
        ) != nil else {
            throw ClientError.invalidTokenFormat
        }
        return token
    }

    private static func validatedHTTPResponse(_ response: URLResponse) throws -> HTTPURLResponse {
        guard let response = response as? HTTPURLResponse else {
            throw ClientError.nonHTTPResponse
        }
        return response
    }
}

private final class PrototypeRoninBoundedRequest: NSObject,
    URLSessionDataDelegate,
    @unchecked Sendable
{
    private typealias Output = (Data, URLResponse)
    private typealias Completion = @Sendable (Result<Output, Error>) -> Void

    private let maximumBytes: Int
    private let lock = NSLock()
    private var responseData = Data()
    private var response: URLResponse?
    private var completion: Completion?
    private var session: URLSession?
    private var task: URLSessionTask?
    private var isCancellationRequested = false
    private var isFinished = false

    private init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    static func perform(
        configuration: URLSessionConfiguration,
        request: URLRequest,
        uploading recordingURL: URL?,
        maximumBytes: Int
    ) async throws -> (Data, URLResponse) {
        let operation = PrototypeRoninBoundedRequest(maximumBytes: maximumBytes)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                operation.start(
                    configuration: configuration,
                    request: request,
                    uploading: recordingURL
                ) { result in
                    continuation.resume(with: result)
                }
            }
        } onCancel: {
            operation.cancel()
        }
    }

    private func start(
        configuration: URLSessionConfiguration,
        request: URLRequest,
        uploading recordingURL: URL?,
        completion: @escaping Completion
    ) {
        let cancellationWon = lock.withLock {
            guard !isFinished else { return true }
            self.completion = completion
            guard !isCancellationRequested else {
                isFinished = true
                self.completion = nil
                return true
            }
            return false
        }
        guard !cancellationWon else {
            completion(.failure(CancellationError()))
            return
        }

        let session = URLSession(
            configuration: configuration,
            delegate: self,
            delegateQueue: nil
        )
        let task: URLSessionTask = if let recordingURL {
            session.uploadTask(with: request, fromFile: recordingURL)
        } else {
            session.dataTask(with: request)
        }
        let shouldStart = lock.withLock {
            guard !isFinished, !isCancellationRequested else { return false }
            self.session = session
            self.task = task
            return true
        }
        guard shouldStart else {
            task.cancel()
            session.invalidateAndCancel()
            return
        }
        task.resume()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        let expectedBytes = response.expectedContentLength
        guard expectedBytes < 0 || expectedBytes <= maximumBytes else {
            completionHandler(.cancel)
            finish(.failure(
                PrototypeRoninClient.ClientError.responseTooLarge(
                    maximumBytes: maximumBytes
                )
            ))
            return
        }
        lock.withLock {
            guard !isFinished else { return }
            self.response = response
        }
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        let exceededLimit = lock.withLock {
            guard !isFinished else { return false }
            guard data.count <= maximumBytes - responseData.count else {
                return true
            }
            responseData.append(data)
            return false
        }
        guard exceededLimit else { return }
        dataTask.cancel()
        finish(.failure(
            PrototypeRoninClient.ClientError.responseTooLarge(
                maximumBytes: maximumBytes
            )
        ))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            finish(.failure(error))
            return
        }
        let output = lock.withLock { () -> Output? in
            guard let response else { return nil }
            return (responseData, response)
        }
        guard let output else {
            finish(.failure(PrototypeRoninClient.ClientError.nonHTTPResponse))
            return
        }
        finish(.success(output))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    private func finish(_ result: Result<Output, Error>) {
        let resources = lock.withLock { () -> (Completion, URLSession?)? in
            guard !isFinished, let completion else { return nil }
            isFinished = true
            self.completion = nil
            let session = self.session
            self.session = nil
            task = nil
            return (completion, session)
        }
        guard let (completion, session) = resources else { return }
        session?.finishTasksAndInvalidate()
        completion(result)
    }

    private func cancel() {
        let resources = lock.withLock {
            () -> (Completion?, URLSessionTask?, URLSession?)? in
            guard !isFinished else { return nil }
            isCancellationRequested = true
            guard let completion else {
                return (nil, task, session)
            }
            isFinished = true
            self.completion = nil
            let task = self.task
            self.task = nil
            let session = self.session
            self.session = nil
            return (completion, task, session)
        }
        guard let (completion, task, session) = resources else { return }
        task?.cancel()
        session?.invalidateAndCancel()
        completion?(.failure(CancellationError()))
    }
}
