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
    private struct HealthResponse: Decodable {
        let status: String
    }

    private struct ErrorResponse: Decodable {
        let error: String
    }

    enum ClientError: LocalizedError {
        case missingToken
        case invalidServerURL
        case nonHTTPResponse
        case rejected(status: Int, message: String)
        case mismatchedRequestID
        case serverNotReady

        var errorDescription: String? {
            switch self {
            case .missingToken:
                "Enter the Ronin bearer token before arming Hex."
            case .invalidServerURL:
                "Enter an HTTPS Ronin URL. HTTP is accepted only for loopback development."
            case .nonHTTPResponse:
                "The Ronin server returned a non-HTTP response."
            case let .rejected(status, _) where status == 401:
                "Ronin rejected the bearer token. Update it under Private server."
            case let .rejected(status, message):
                "Ronin rejected the request (HTTP \(status)): \(message)"
            case .mismatchedRequestID:
                "Ronin returned a response for a different request."
            case .serverNotReady:
                "Ronin is reachable, but Parakeet is not ready."
            }
        }
    }

    static func verifyReady(
        serverURLString: String,
        token: String
    ) async throws {
        let baseURL = try validatedBaseURL(serverURLString)
        let token = try validatedToken(token)
        var request = URLRequest(url: baseURL.appendingPathComponent("health"))
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = try validatedHTTPResponse(response)
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw ClientError.rejected(
                status: httpResponse.statusCode,
                message: errorMessage(from: data)
            )
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
        requestID: UUID
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

        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: recordingURL)
        let httpResponse = try validatedHTTPResponse(response)
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw ClientError.rejected(
                status: httpResponse.statusCode,
                message: errorMessage(from: data)
            )
        }

        let decoded = try JSONDecoder().decode(PrototypeRoninResponse.self, from: data)
        guard UUID(uuidString: decoded.requestID) == requestID else {
            throw ClientError.mismatchedRequestID
        }
        return decoded
    }

    private static func validatedBaseURL(_ rawValue: String) throws -> URL {
        guard
            let baseURL = URL(
                string: rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            ),
            let scheme = baseURL.scheme?.lowercased(),
            let host = baseURL.host?.lowercased(),
            scheme == "https"
                || (scheme == "http"
                    && ["localhost", "127.0.0.1", "::1"].contains(host))
        else {
            throw ClientError.invalidServerURL
        }
        return baseURL
    }

    private static func validatedToken(_ rawValue: String) throws -> String {
        let token = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw ClientError.missingToken
        }
        return token
    }

    private static func validatedHTTPResponse(_ response: URLResponse) throws -> HTTPURLResponse {
        guard let response = response as? HTTPURLResponse else {
            throw ClientError.nonHTTPResponse
        }
        return response
    }

    private static func errorMessage(from data: Data) -> String {
        if let response = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
            return response.error
        }
        return String(data: data, encoding: .utf8) ?? "No response body"
    }
}
