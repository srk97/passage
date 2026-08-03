import Foundation

public struct SessionIntelligenceHTTPResponse: Sendable {
    public let statusCode: Int
    public let body: Data

    public init(statusCode: Int, body: Data) {
        self.statusCode = statusCode
        self.body = body
    }
}

public protocol SessionIntelligenceHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> SessionIntelligenceHTTPResponse
}

public final class URLSessionSessionIntelligenceTransport:
    SessionIntelligenceHTTPTransport,
    @unchecked Sendable
{
    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            self.session = URLSession(configuration: configuration)
        }
    }

    public func send(_ request: URLRequest) async throws -> SessionIntelligenceHTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw SessionIntelligenceError.nonHTTPResponse
        }
        return SessionIntelligenceHTTPResponse(statusCode: response.statusCode, body: data)
    }
}
