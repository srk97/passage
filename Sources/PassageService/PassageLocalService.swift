import PassageCore
import Darwin
import Dispatch
import Foundation

public struct PassageServiceEndpoint: Hashable, Sendable {
    /// Darwin's `sockaddr_un.sun_path` stores 104 bytes including the terminating NUL.
    public static let maximumPathBytes = 103

    public let socketURL: URL

    public var path: String { socketURL.path }

    public init(socketURL: URL) throws {
        guard socketURL.isFileURL else {
            throw PassageServiceTransportError.invalidSocketPath("The endpoint must be a file URL.")
        }
        // Canonicalize existing path components up front (for example macOS's
        // /tmp -> /private/tmp link) and then refuse links introduced later.
        let standardizedURL = socketURL.standardizedFileURL.resolvingSymlinksInPath()
        let path = standardizedURL.path
        guard path.hasPrefix("/"), path != "/" else {
            throw PassageServiceTransportError.invalidSocketPath("The endpoint must use an absolute file path.")
        }
        guard !path.utf8.contains(0) else {
            throw PassageServiceTransportError.invalidSocketPath("The endpoint contains a NUL byte.")
        }
        guard path.utf8.count <= Self.maximumPathBytes else {
            throw PassageServiceTransportError.invalidSocketPath(
                "The endpoint is \(path.utf8.count) bytes; Darwin allows at most \(Self.maximumPathBytes)."
            )
        }
        self.socketURL = standardizedURL
    }

    /// The default endpoint lives in a private IPC subdirectory rather than directly
    /// in Application Support, allowing the service to enforce directory mode 0700.
    public static func live(fileManager: FileManager = .default) throws -> Self {
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let url = applicationSupport
            .appendingPathComponent("Chronicle", isDirectory: true)
            .appendingPathComponent("IPC", isDirectory: true)
            .appendingPathComponent("service.sock", isDirectory: false)
        return try Self(socketURL: url)
    }
}

public final class PassageLocalServiceServer: @unchecked Sendable {
    public let endpoint: PassageServiceEndpoint
    public let limits: PassageServiceLimits

    private let handler: any PassageServiceRequestHandling
    private let requireSameUser: Bool
    private let acceptQueue = DispatchQueue(
        label: "app.chronicle.local-service.accept",
        qos: .utility
    )
    private let stateLock = NSLock()
    private var listenerDescriptor: Int32?
    private var listenerGeneration: UInt64 = 0
    private var activeConnections: [Int32: UInt64] = [:]
    private var socketIdentity: PassageSocketIdentity?

    public init(
        endpoint: PassageServiceEndpoint,
        limits: PassageServiceLimits = PassageServiceLimits(),
        requireSameUser: Bool = true,
        handler: any PassageServiceRequestHandling
    ) {
        self.endpoint = endpoint
        self.limits = limits
        self.requireSameUser = requireSameUser
        self.handler = handler
    }

    public var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return listenerDescriptor != nil
    }

    public func start() throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard listenerDescriptor == nil else {
            throw PassageServiceTransportError.alreadyRunning
        }

        let listener = try PassageSocketSystem.createListener(
            endpoint: endpoint,
            backlog: Int32(limits.maximumConcurrentConnections)
        )
        listenerGeneration &+= 1
        let generation = listenerGeneration
        listenerDescriptor = listener.descriptor
        socketIdentity = listener.identity

        let reference = WeakServerReference(self)
        acceptQueue.async {
            Self.acceptConnections(
                reference: reference,
                listenerDescriptor: listener.descriptor,
                generation: generation
            )
        }
    }

    public func stop() {
        stateLock.lock()
        guard let listener = listenerDescriptor else {
            stateLock.unlock()
            return
        }
        let generation = listenerGeneration
        let identity = socketIdentity
        listenerDescriptor = nil
        socketIdentity = nil

        _ = Darwin.shutdown(listener, SHUT_RDWR)
        _ = Darwin.close(listener)
        for (descriptor, connectionGeneration) in activeConnections
        where connectionGeneration == generation {
            // The connection task remains the sole owner responsible for close().
            // shutdown() only wakes any blocked read or write without risking reuse.
            _ = Darwin.shutdown(descriptor, SHUT_RDWR)
        }
        stateLock.unlock()

        PassageSocketSystem.removeSocketIfOwned(endpoint: endpoint, identity: identity)
    }

    deinit {
        stop()
    }

    private static func acceptConnections(
        reference: WeakServerReference,
        listenerDescriptor: Int32,
        generation: UInt64
    ) {
        while reference.listenerIsActive(listenerDescriptor, generation: generation) {
            let descriptor = Darwin.accept(listenerDescriptor, nil, nil)
            if descriptor < 0 {
                let code = errno
                if code == EINTR { continue }
                if code == EBADF || code == EINVAL
                    || !reference.listenerIsActive(listenerDescriptor, generation: generation) {
                    return
                }
                continue
            }
            reference.routeAcceptedConnection(descriptor, generation: generation)
        }
    }

    private func routeAcceptedConnection(_ descriptor: Int32, generation: UInt64) {
        do {
            try PassageSocketSystem.configureConnectedSocket(
                descriptor,
                timeoutSeconds: limits.ioTimeoutSeconds
            )
            let peer = try PassageSocketSystem.peerCredentials(descriptor)
            guard !requireSameUser || peer.userID == UInt32(geteuid()) else {
                sendTerminalFailure(
                    descriptor: descriptor,
                    code: .denied,
                    message: "Passage only accepts connections from the current macOS user."
                )
                _ = Darwin.close(descriptor)
                return
            }
            guard registerConnection(descriptor, generation: generation) else {
                sendTerminalFailure(
                    descriptor: descriptor,
                    code: .busy,
                    message: "Passage is handling the maximum number of local requests.",
                    retryable: true
                )
                _ = Darwin.close(descriptor)
                return
            }

            Task.detached(priority: .utility) { [weak self] in
                guard let self else {
                    _ = Darwin.close(descriptor)
                    return
                }
                await self.serve(
                    descriptor: descriptor,
                    peer: peer,
                    generation: generation
                )
            }
        } catch {
            _ = Darwin.close(descriptor)
        }
    }

    private func serve(
        descriptor: Int32,
        peer: PassageServicePeer,
        generation: UInt64
    ) async {
        defer { finishConnection(descriptor, generation: generation) }

        var requestID: UUID?
        let response: PassageServiceResponse
        do {
            let payload = try PassageSocketIO.readFrame(
                descriptor: descriptor,
                maximumPayloadBytes: limits.maximumRequestBytes,
                direction: .request
            )
            let request = try PassageServiceJSONCodec().decode(
                PassageServiceRequest.self,
                from: payload
            )
            requestID = request.requestID
            try request.validate()
            let result = try await handler.handle(request, peer: peer)
            guard result.capability == request.capability else {
                throw PassageServiceTransportError.invalidResponse(
                    "The handler returned \(result.capability.rawValue) for a \(request.capability.rawValue) request."
                )
            }
            response = .success(requestID: request.requestID, result: result)
        } catch let rejection as PassageServiceRejection {
            response = PassageServiceResponse(
                requestID: requestID,
                failure: rejection.failure
            )
        } catch let error as PassageServiceTransportError {
            response = Self.failureResponse(for: error, requestID: requestID)
        } catch {
            response = .failed(
                requestID: requestID,
                code: .internalError,
                message: "Passage could not complete the local request: \(error.localizedDescription)"
            )
        }

        send(response, descriptor: descriptor)
    }

    private func send(_ response: PassageServiceResponse, descriptor: Int32) {
        do {
            try PassageSocketIO.writeMessage(
                response,
                descriptor: descriptor,
                maximumPayloadBytes: limits.maximumResponseBytes,
                direction: .response
            )
        } catch PassageServiceTransportError.messageTooLarge {
            let fallback = PassageServiceResponse.failed(
                requestID: response.requestID,
                code: .responseTooLarge,
                message: "The requested result exceeds Passage's local response-size limit."
            )
            try? PassageSocketIO.writeMessage(
                fallback,
                descriptor: descriptor,
                maximumPayloadBytes: limits.maximumResponseBytes,
                direction: .response
            )
        } catch {
            // The caller may have disconnected. The connection is closed by defer.
        }
    }

    private func sendTerminalFailure(
        descriptor: Int32,
        code: PassageServiceFailureCode,
        message: String,
        retryable: Bool = false
    ) {
        let response = PassageServiceResponse.failed(
            requestID: nil,
            code: code,
            message: message,
            retryable: retryable
        )
        try? PassageSocketIO.writeMessage(
            response,
            descriptor: descriptor,
            maximumPayloadBytes: limits.maximumResponseBytes,
            direction: .response
        )
    }

    private static func failureResponse(
        for error: PassageServiceTransportError,
        requestID: UUID?
    ) -> PassageServiceResponse {
        switch error {
        case .messageTooLarge(let direction, _, _):
            return .failed(
                requestID: requestID,
                code: direction == .request ? .requestTooLarge : .responseTooLarge,
                message: error.localizedDescription
            )
        case .protocolVersionMismatch:
            return .failed(requestID: requestID, code: .protocolMismatch, message: error.localizedDescription)
        case .invalidRequest:
            return .failed(requestID: requestID, code: .invalidRequest, message: error.localizedDescription)
        case .decoding, .invalidFrameLength:
            return .failed(requestID: requestID, code: .malformedMessage, message: error.localizedDescription)
        case .invalidResponse:
            return .failed(requestID: requestID, code: .internalError, message: error.localizedDescription)
        default:
            return .failed(requestID: requestID, code: .internalError, message: error.localizedDescription)
        }
    }

    private func listenerIsActive(_ descriptor: Int32, generation: UInt64) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return listenerDescriptor == descriptor && listenerGeneration == generation
    }

    private func registerConnection(_ descriptor: Int32, generation: UInt64) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard listenerDescriptor != nil, listenerGeneration == generation else { return false }
        let generationCount = activeConnections.values.lazy.filter { $0 == generation }.count
        guard generationCount < limits.maximumConcurrentConnections else { return false }
        activeConnections[descriptor] = generation
        return true
    }

    private func finishConnection(_ descriptor: Int32, generation: UInt64) {
        stateLock.lock()
        if activeConnections[descriptor] == generation {
            activeConnections.removeValue(forKey: descriptor)
            _ = Darwin.shutdown(descriptor, SHUT_RDWR)
            _ = Darwin.close(descriptor)
        }
        stateLock.unlock()
    }

    /// The accept queue owns this box, not the server. That allows releasing the last
    /// app reference to synchronously run deinit/stop and wake a blocked accept().
    private final class WeakServerReference: @unchecked Sendable {
        weak var server: PassageLocalServiceServer?

        init(_ server: PassageLocalServiceServer) {
            self.server = server
        }

        func listenerIsActive(_ descriptor: Int32, generation: UInt64) -> Bool {
            server?.listenerIsActive(descriptor, generation: generation) ?? false
        }

        func routeAcceptedConnection(_ descriptor: Int32, generation: UInt64) {
            guard let server else {
                _ = Darwin.close(descriptor)
                return
            }
            server.routeAcceptedConnection(descriptor, generation: generation)
        }
    }
}

/// A synchronous, one-request-per-connection client suitable for the command-line
/// tool. The app-facing server remains asynchronous at the injected handler boundary.
public struct PassageLocalServiceClient: Sendable {
    public let endpoint: PassageServiceEndpoint
    public let identity: PassageServiceClientIdentity
    public let limits: PassageServiceLimits

    public init(
        endpoint: PassageServiceEndpoint,
        identity: PassageServiceClientIdentity,
        limits: PassageServiceLimits = PassageServiceLimits()
    ) {
        self.endpoint = endpoint
        self.identity = identity
        self.limits = limits
    }

    public func perform(_ request: PassageServiceRequest) throws -> PassageServiceResponse {
        guard request.client == identity else {
            throw PassageServiceTransportError.invalidRequest(
                "The request identity does not match this Passage service client."
            )
        }
        try request.validate()
        let requestPayload = try PassageServiceJSONCodec().encode(request)
        let requestFrame = try PassageServiceFraming.frame(
            payload: requestPayload,
            maximumPayloadBytes: limits.maximumRequestBytes,
            direction: .request
        )

        let descriptor = try PassageSocketSystem.connect(
            endpoint: endpoint,
            timeoutSeconds: limits.ioTimeoutSeconds
        )
        defer {
            _ = Darwin.shutdown(descriptor, SHUT_RDWR)
            _ = Darwin.close(descriptor)
        }

        try PassageSocketIO.writeAll(requestFrame, descriptor: descriptor)
        let responsePayload = try PassageSocketIO.readFrame(
            descriptor: descriptor,
            maximumPayloadBytes: limits.maximumResponseBytes,
            direction: .response
        )
        let response = try PassageServiceJSONCodec().decode(
            PassageServiceResponse.self,
            from: responsePayload
        )
        try response.validate(for: request)
        if let failure = response.failure {
            throw PassageServiceTransportError.remote(failure)
        }
        return response
    }

    public func search(_ query: SearchQuery) throws -> [SearchHit] {
        let response = try perform(.search(query, client: identity))
        guard case .search(let hits) = response.result else {
            throw PassageServiceTransportError.invalidResponse("Search response has no search result.")
        }
        return hits
    }

    public func capabilities() throws -> PassageServiceCapabilities {
        let response = try perform(.capabilities(client: identity))
        guard case .capabilities(let capabilities) = response.result else {
            throw PassageServiceTransportError.invalidResponse(
                "Capabilities response has no capabilities result."
            )
        }
        return capabilities
    }

    public func health() throws -> PassageServiceHealth {
        let response = try perform(.health(client: identity))
        guard case .health(let health) = response.result else {
            throw PassageServiceTransportError.invalidResponse(
                "Health response has no health result."
            )
        }
        return health
    }

    public func bundle(
        _ request: PassageContextBundleRequest
    ) throws -> PassageContextBundleManifest {
        let response = try perform(.bundle(request, client: identity))
        guard case .bundle(let bundle) = response.result else {
            throw PassageServiceTransportError.invalidResponse(
                "Bundle response has no context bundle result."
            )
        }
        return bundle
    }

    public func visualSearch(
        _ request: PassageAgentVisualSearchRequest
    ) throws -> PassageAgentVisualSearchManifest {
        let response = try perform(.visualSearch(request, client: identity))
        guard case .visualSearch(let manifest) = response.result else {
            throw PassageServiceTransportError.invalidResponse(
                "Visual-search response has no visual-search result."
            )
        }
        return manifest
    }

    public func memoryCapsule(
        _ request: PassageMemoryCapsuleRequest
    ) throws -> PassageMemoryCapsuleManifest {
        let response = try perform(.memoryCapsule(request, client: identity))
        guard case .memoryCapsule(let manifest) = response.result else {
            throw PassageServiceTransportError.invalidResponse(
                "Memory-capsule response has no memory-capsule result."
            )
        }
        return manifest
    }

    public func recent(limit: Int = 50) throws -> [SearchHit] {
        let response = try perform(.recent(limit: limit, client: identity))
        guard case .recent(let hits) = response.result else {
            throw PassageServiceTransportError.invalidResponse("Recent response has no recent result.")
        }
        return hits
    }

    public func sessions(
        _ query: ActivitySessionQuery = ActivitySessionQuery(includeSensitive: false)
    ) throws -> [ActivitySessionSummary] {
        let response = try perform(.sessions(query, client: identity))
        guard case .sessions(let sessions) = response.result else {
            throw PassageServiceTransportError.invalidResponse(
                "Sessions response has no activity-session result."
            )
        }
        return sessions
    }

    public func frame(id: FrameID) throws -> FrameDocument? {
        let response = try perform(.frame(id: id, client: identity))
        guard case .frame(let frame) = response.result else {
            throw PassageServiceTransportError.invalidResponse("Frame response has no frame result.")
        }
        return frame
    }

    public func statistics() throws -> StoreStatistics {
        let response = try perform(.statistics(client: identity))
        guard case .statistics(let statistics) = response.result else {
            throw PassageServiceTransportError.invalidResponse("Statistics response has no statistics result.")
        }
        return statistics
    }
}

private struct PassageSocketIdentity: Equatable, Sendable {
    let device: dev_t
    let inode: ino_t
}

private enum PassageSocketSystem {
    struct Listener {
        let descriptor: Int32
        let identity: PassageSocketIdentity
    }

    static func createListener(
        endpoint: PassageServiceEndpoint,
        backlog: Int32
    ) throws -> Listener {
        try preparePrivateDirectory(for: endpoint)
        try removeStaleSocketIfSafe(endpoint: endpoint)

        let descriptor = try makeSocket()
        var didBind = false
        do {
            let bindResult = withAddress(for: endpoint) { address, length in
                Darwin.bind(descriptor, address, length)
            }
            guard bindResult == 0 else {
                let code = errno
                if code == EADDRINUSE {
                    throw PassageServiceTransportError.endpointInUse(endpoint.path)
                }
                throw systemError("bind", code: code)
            }
            didBind = true

            guard Darwin.chmod(endpoint.path, S_IRUSR | S_IWUSR) == 0 else {
                throw systemError("chmod socket", code: errno)
            }
            guard Darwin.listen(descriptor, backlog) == 0 else {
                throw systemError("listen", code: errno)
            }
            let identity = try socketIdentity(at: endpoint.path)
            return Listener(descriptor: descriptor, identity: identity)
        } catch {
            _ = Darwin.close(descriptor)
            if didBind { _ = Darwin.unlink(endpoint.path) }
            throw error
        }
    }

    static func connect(
        endpoint: PassageServiceEndpoint,
        timeoutSeconds: TimeInterval
    ) throws -> Int32 {
        try verifyClientEndpoint(endpoint)
        let descriptor = try makeSocket()
        do {
            try configureConnectedSocket(descriptor, timeoutSeconds: timeoutSeconds)
            let result = withAddress(for: endpoint) { address, length in
                Darwin.connect(descriptor, address, length)
            }
            guard result == 0 else {
                let code = errno
                if code == ENOENT || code == ECONNREFUSED {
                    throw PassageServiceTransportError.serviceUnavailable(endpoint.path)
                }
                throw systemError("connect", code: code)
            }
            return descriptor
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    static func configureConnectedSocket(
        _ descriptor: Int32,
        timeoutSeconds: TimeInterval
    ) throws {
        try setCloseOnExec(descriptor)
        var noSignal: Int32 = 1
        guard Darwin.setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSignal,
            socklen_t(MemoryLayout.size(ofValue: noSignal))
        ) == 0 else {
            throw systemError("setsockopt SO_NOSIGPIPE", code: errno)
        }

        let wholeSeconds = floor(timeoutSeconds)
        var timeout = timeval(
            tv_sec: Int(wholeSeconds),
            tv_usec: Int32((timeoutSeconds - wholeSeconds) * 1_000_000)
        )
        for option in [SO_RCVTIMEO, SO_SNDTIMEO] {
            guard Darwin.setsockopt(
                descriptor,
                SOL_SOCKET,
                option,
                &timeout,
                socklen_t(MemoryLayout.size(ofValue: timeout))
            ) == 0 else {
                throw systemError("setsockopt timeout", code: errno)
            }
        }
    }

    static func peerCredentials(_ descriptor: Int32) throws -> PassageServicePeer {
        var userID: uid_t = 0
        var groupID: gid_t = 0
        guard Darwin.getpeereid(descriptor, &userID, &groupID) == 0 else {
            throw systemError("getpeereid", code: errno)
        }
        return PassageServicePeer(userID: UInt32(userID), groupID: UInt32(groupID))
    }

    static func removeSocketIfOwned(
        endpoint: PassageServiceEndpoint,
        identity: PassageSocketIdentity?
    ) {
        guard let identity,
              let current = try? socketIdentity(at: endpoint.path),
              current == identity else { return }
        _ = Darwin.unlink(endpoint.path)
    }

    private static func makeSocket() throws -> Int32 {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw systemError("socket", code: errno)
        }
        do {
            try setCloseOnExec(descriptor)
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
        return descriptor
    }

    private static func setCloseOnExec(_ descriptor: Int32) throws {
        guard Darwin.fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
            let code = errno
            throw systemError("fcntl FD_CLOEXEC", code: code)
        }
    }

    private static func preparePrivateDirectory(for endpoint: PassageServiceEndpoint) throws {
        let directory = endpoint.socketURL.deletingLastPathComponent()
        guard directory.path != "/" else {
            throw PassageServiceTransportError.insecureSocketDirectory(
                "Refusing to place a private service socket directly in /."
            )
        }
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw PassageServiceTransportError.insecureSocketDirectory(error.localizedDescription)
        }

        var information = stat()
        guard Darwin.lstat(directory.path, &information) == 0 else {
            throw systemError("lstat socket directory", code: errno)
        }
        guard information.st_mode & S_IFMT == S_IFDIR else {
            throw PassageServiceTransportError.insecureSocketDirectory(
                "\(directory.path) is not a real directory (symbolic links are not accepted)."
            )
        }
        guard information.st_uid == geteuid() else {
            throw PassageServiceTransportError.insecureSocketDirectory(
                "\(directory.path) is not owned by the current macOS user."
            )
        }
        guard directory.resolvingSymlinksInPath().standardizedFileURL.path == directory.standardizedFileURL.path else {
            throw PassageServiceTransportError.insecureSocketDirectory(
                "\(directory.path) contains a symbolic-link path component."
            )
        }
        guard Darwin.chmod(directory.path, S_IRWXU) == 0 else {
            throw systemError("chmod socket directory", code: errno)
        }
    }

    private static func verifyClientEndpoint(_ endpoint: PassageServiceEndpoint) throws {
        var information = stat()
        guard Darwin.lstat(endpoint.path, &information) == 0 else {
            let code = errno
            if code == ENOENT {
                throw PassageServiceTransportError.serviceUnavailable(endpoint.path)
            }
            throw systemError("lstat service socket", code: code)
        }
        guard information.st_mode & S_IFMT == S_IFSOCK,
              information.st_uid == geteuid(),
              information.st_mode & 0o077 == 0 else {
            throw PassageServiceTransportError.serviceUnavailable(endpoint.path)
        }
    }

    private static func removeStaleSocketIfSafe(endpoint: PassageServiceEndpoint) throws {
        var information = stat()
        guard Darwin.lstat(endpoint.path, &information) == 0 else {
            if errno == ENOENT { return }
            throw systemError("lstat socket", code: errno)
        }
        guard information.st_mode & S_IFMT == S_IFSOCK,
              information.st_uid == geteuid() else {
            throw PassageServiceTransportError.endpointInUse(endpoint.path)
        }

        let probe = try makeSocket()
        defer { _ = Darwin.close(probe) }
        let result = withAddress(for: endpoint) { address, length in
            Darwin.connect(probe, address, length)
        }
        if result == 0 {
            throw PassageServiceTransportError.endpointInUse(endpoint.path)
        }
        let code = errno
        guard code == ECONNREFUSED || code == ENOENT else {
            throw systemError("probe existing socket", code: code)
        }
        guard Darwin.unlink(endpoint.path) == 0 || errno == ENOENT else {
            throw systemError("unlink stale socket", code: errno)
        }
    }

    private static func socketIdentity(at path: String) throws -> PassageSocketIdentity {
        var information = stat()
        guard Darwin.lstat(path, &information) == 0 else {
            throw systemError("lstat socket", code: errno)
        }
        guard information.st_mode & S_IFMT == S_IFSOCK,
              information.st_uid == geteuid() else {
            throw PassageServiceTransportError.endpointInUse(path)
        }
        return PassageSocketIdentity(device: information.st_dev, inode: information.st_ino)
    }

    private static func withAddress<Result>(
        for endpoint: PassageServiceEndpoint,
        _ body: (UnsafePointer<sockaddr>, socklen_t) -> Result
    ) -> Result {
        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.initializeMemory(as: UInt8.self, repeating: 0)
            for (index, byte) in endpoint.path.utf8.enumerated() {
                buffer[index] = byte
            }
        }
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    fileprivate static func systemError(
        _ operation: String,
        code: Int32
    ) -> PassageServiceTransportError {
        PassageServiceTransportError.systemCall(
            operation: operation,
            code: code,
            message: String(cString: strerror(code))
        )
    }
}

private enum PassageSocketIO {
    static func readFrame(
        descriptor: Int32,
        maximumPayloadBytes: Int,
        direction: PassageServiceMessageDirection
    ) throws -> Data {
        let header = try readExactly(
            PassageServiceFraming.headerByteCount,
            descriptor: descriptor
        )
        let payloadLength = try PassageServiceFraming.payloadLength(
            from: header,
            maximumPayloadBytes: maximumPayloadBytes,
            direction: direction
        )
        return try readExactly(payloadLength, descriptor: descriptor)
    }

    static func writeMessage<T: Encodable>(
        _ message: T,
        descriptor: Int32,
        maximumPayloadBytes: Int,
        direction: PassageServiceMessageDirection
    ) throws {
        let payload = try PassageServiceJSONCodec().encode(message)
        let frame = try PassageServiceFraming.frame(
            payload: payload,
            maximumPayloadBytes: maximumPayloadBytes,
            direction: direction
        )
        try writeAll(frame, descriptor: descriptor)
    }

    static func readExactly(_ count: Int, descriptor: Int32) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                throw PassageServiceTransportError.invalidFrameLength(count)
            }
            var offset = 0
            while offset < count {
                let result = Darwin.read(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    count - offset
                )
                if result > 0 {
                    offset += result
                    continue
                }
                if result == 0 {
                    throw PassageServiceTransportError.connectionClosed
                }
                let code = errno
                if code == EINTR { continue }
                if code == EAGAIN || code == EWOULDBLOCK {
                    throw PassageServiceTransportError.timedOut
                }
                if code == ECONNRESET {
                    throw PassageServiceTransportError.connectionClosed
                }
                throw PassageSocketSystem.systemError("read", code: code)
            }
        }
        return data
    }

    static func writeAll(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let result = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    data.count - offset
                )
                if result > 0 {
                    offset += result
                    continue
                }
                if result == 0 {
                    throw PassageServiceTransportError.connectionClosed
                }
                let code = errno
                if code == EINTR { continue }
                if code == EAGAIN || code == EWOULDBLOCK {
                    throw PassageServiceTransportError.timedOut
                }
                if code == EPIPE || code == ECONNRESET {
                    throw PassageServiceTransportError.connectionClosed
                }
                throw PassageSocketSystem.systemError("write", code: code)
            }
        }
    }
}
