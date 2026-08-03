import Foundation

public enum SessionIntelligenceError: Error, Equatable, LocalizedError, Sendable {
    case missingAPIKey
    case invalidSafetyIdentifier
    case emptyInput
    case requestEncodingFailed
    case transportFailed
    case nonHTTPResponse
    case httpFailure(statusCode: Int)
    case refused
    case incomplete(reason: String?)
    case malformedResponse
    case invalidCitations
    case cacheCorrupted
    case cacheAuthenticationFailed

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "An OpenAI API key has not been configured."
        case .invalidSafetyIdentifier:
            "A stable privacy-preserving safety identifier is required."
        case .emptyInput:
            "The activity session has no text evidence to summarize."
        case .requestEncodingFailed:
            "The session-intelligence request could not be encoded."
        case .transportFailed:
            "The session-intelligence provider could not be reached."
        case .nonHTTPResponse:
            "The session-intelligence provider returned an invalid response."
        case .httpFailure(let statusCode):
            "The session-intelligence provider returned HTTP status \(statusCode)."
        case .refused:
            "The session-intelligence provider declined this request."
        case .incomplete(let reason):
            reason.map { "The session-intelligence response was incomplete (\($0))." }
                ?? "The session-intelligence response was incomplete."
        case .malformedResponse:
            "The session-intelligence provider returned malformed output."
        case .invalidCitations:
            "The session-intelligence output cited evidence outside this activity session."
        case .cacheCorrupted:
            "The encrypted session-intelligence cache entry is invalid."
        case .cacheAuthenticationFailed:
            "The encrypted session-intelligence cache entry could not be authenticated."
        }
    }
}
