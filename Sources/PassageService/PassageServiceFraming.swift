import Foundation

public struct PassageServiceLimits: Hashable, Sendable {
    public static let defaultMaximumRequestBytes = 1 * 1_024 * 1_024
    public static let defaultMaximumResponseBytes = 16 * 1_024 * 1_024

    public var maximumRequestBytes: Int
    public var maximumResponseBytes: Int
    public var maximumConcurrentConnections: Int
    public var ioTimeoutSeconds: TimeInterval

    public init(
        maximumRequestBytes: Int = Self.defaultMaximumRequestBytes,
        maximumResponseBytes: Int = Self.defaultMaximumResponseBytes,
        maximumConcurrentConnections: Int = 16,
        ioTimeoutSeconds: TimeInterval = 15
    ) {
        self.maximumRequestBytes = min(max(maximumRequestBytes, 1), Int(UInt32.max))
        self.maximumResponseBytes = min(max(maximumResponseBytes, 1), Int(UInt32.max))
        self.maximumConcurrentConnections = min(max(maximumConcurrentConnections, 1), 256)
        self.ioTimeoutSeconds = ioTimeoutSeconds.isFinite
            ? min(max(ioTimeoutSeconds, 0.1), 300)
            : 15
    }
}

public enum PassageServiceMessageDirection: String, Hashable, Sendable {
    case request
    case response
}

public enum PassageServiceTransportError: Error, Equatable, LocalizedError, Sendable {
    case invalidSocketPath(String)
    case insecureSocketDirectory(String)
    case endpointInUse(String)
    case alreadyRunning
    case serviceUnavailable(String)
    case invalidFrameLength(Int)
    case messageTooLarge(direction: PassageServiceMessageDirection, actual: Int, limit: Int)
    case connectionClosed
    case timedOut
    case systemCall(operation: String, code: Int32, message: String)
    case encoding(String)
    case decoding(String)
    case invalidRequest(String)
    case invalidResponse(String)
    case protocolVersionMismatch(received: UInt16, supported: UInt16)
    case remote(PassageServiceFailure)

    public var errorDescription: String? {
        switch self {
        case .invalidSocketPath(let message):
            "Invalid Passage service socket path: \(message)"
        case .insecureSocketDirectory(let message):
            "Insecure Passage service directory: \(message)"
        case .endpointInUse(let path):
            "Another Passage service is already listening at \(path)."
        case .alreadyRunning:
            "This Passage service server is already running."
        case .serviceUnavailable(let path):
            "The Passage app service is not available at \(path). Open Passage and try again."
        case .invalidFrameLength(let length):
            "The Passage service sent an invalid frame length (\(length))."
        case .messageTooLarge(let direction, let actual, let limit):
            "The Passage service \(direction.rawValue) is \(actual) bytes; the limit is \(limit) bytes."
        case .connectionClosed:
            "The Passage service connection closed before the message was complete."
        case .timedOut:
            "The Passage service connection timed out."
        case .systemCall(let operation, let code, let message):
            "Passage service \(operation) failed (errno \(code)): \(message)"
        case .encoding(let message):
            "Could not encode the Passage service message: \(message)"
        case .decoding(let message):
            "Could not decode the Passage service message: \(message)"
        case .invalidRequest(let message):
            "Invalid Passage service request: \(message)"
        case .invalidResponse(let message):
            "Invalid Passage service response: \(message)"
        case .protocolVersionMismatch(let received, let supported):
            "Passage service protocol version \(received) is unsupported; this build supports version \(supported)."
        case .remote(let failure):
            failure.message
        }
    }
}

/// The wire protocol uses a four-byte unsigned big-endian payload length followed by
/// one Codable JSON document. The helpers are public so framing can be fuzzed and
/// unit-tested independently from sockets.
public enum PassageServiceFraming {
    public static let headerByteCount = 4

    public static func frame(
        payload: Data,
        maximumPayloadBytes: Int,
        direction: PassageServiceMessageDirection
    ) throws -> Data {
        guard !payload.isEmpty else {
            throw PassageServiceTransportError.invalidFrameLength(0)
        }
        guard payload.count <= maximumPayloadBytes else {
            throw PassageServiceTransportError.messageTooLarge(
                direction: direction,
                actual: payload.count,
                limit: maximumPayloadBytes
            )
        }
        guard payload.count <= Int(UInt32.max) else {
            throw PassageServiceTransportError.messageTooLarge(
                direction: direction,
                actual: payload.count,
                limit: min(maximumPayloadBytes, Int(UInt32.max))
            )
        }

        let length = UInt32(payload.count)
        var data = Data(capacity: headerByteCount + payload.count)
        data.append(UInt8((length >> 24) & 0xff))
        data.append(UInt8((length >> 16) & 0xff))
        data.append(UInt8((length >> 8) & 0xff))
        data.append(UInt8(length & 0xff))
        data.append(payload)
        return data
    }

    public static func payloadLength(
        from header: Data,
        maximumPayloadBytes: Int,
        direction: PassageServiceMessageDirection
    ) throws -> Int {
        guard header.count == headerByteCount else {
            throw PassageServiceTransportError.invalidFrameLength(header.count)
        }
        let bytes = [UInt8](header)
        let length = Int(
            (UInt32(bytes[0]) << 24)
                | (UInt32(bytes[1]) << 16)
                | (UInt32(bytes[2]) << 8)
                | UInt32(bytes[3])
        )
        guard length > 0 else {
            throw PassageServiceTransportError.invalidFrameLength(length)
        }
        guard length <= maximumPayloadBytes else {
            throw PassageServiceTransportError.messageTooLarge(
                direction: direction,
                actual: length,
                limit: maximumPayloadBytes
            )
        }
        return length
    }
}

public struct PassageServiceJSONCodec: Sendable {
    public init() {}

    public func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            return try encoder.encode(value)
        } catch {
            throw PassageServiceTransportError.encoding(error.localizedDescription)
        }
    }

    public func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw PassageServiceTransportError.decoding(error.localizedDescription)
        }
    }
}
