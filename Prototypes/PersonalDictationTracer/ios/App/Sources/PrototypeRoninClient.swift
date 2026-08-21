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
    enum ClientError: LocalizedError {
        case invalidServerURL
        case nonHTTPResponse
        case rejected(status: Int, message: String)
        case mismatchedRequestID

        var errorDescription: String? {
            switch self {
            case .invalidServerURL:
                "Enter an HTTPS Ronin URL. HTTP is accepted only for loopback development."
            case .nonHTTPResponse:
                "The Ronin server returned a non-HTTP response."
            case let .rejected(status, message):
                "Ronin rejected the request (HTTP \(status)): \(message)"
            case .mismatchedRequestID:
                "Ronin returned a response for a different request."
            }
        }
    }

    static func transcribe(
        recordingURL: URL,
        serverURLString: String,
        token: String,
        requestID: UUID
    ) async throws -> PrototypeRoninResponse {
        guard
            let baseURL = URL(string: serverURLString.trimmingCharacters(in: .whitespacesAndNewlines)),
            let scheme = baseURL.scheme?.lowercased(),
            let host = baseURL.host?.lowercased(),
            scheme == "https" || (scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host))
        else {
            throw ClientError.invalidServerURL
        }

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
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClientError.nonHTTPResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "No response body"
            throw ClientError.rejected(status: httpResponse.statusCode, message: body)
        }

        let decoded = try JSONDecoder().decode(PrototypeRoninResponse.self, from: data)
        guard UUID(uuidString: decoded.requestID) == requestID else {
            throw ClientError.mismatchedRequestID
        }
        return decoded
    }
}
