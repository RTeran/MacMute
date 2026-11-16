import Foundation
import os

enum SocketSendError: String, Error {
    case noSocketClient = "no_socket_client"
    case serializationFailed = "serialization_failed"
    case writeFailed = "write_failed"
    case appShuttingDown = "app_shutting_down"
}

/// Identifies one connected helper, one per Chrome profile. Never reused while the server runs.
typealias ClientID = Int

class SocketServer {
    typealias VerifyPeer = (_ socket: Int32) -> Result<Void, PeerVerificationError>
    /// Called once when the server starts, so the trusted requirement cannot change while it runs.
    typealias MakeVerifyPeer = () -> Result<VerifyPeer, PeerVerificationError>

    static let defaultMaxClients = 16
    private static let listenBacklog: Int32 = 8

    private struct Client {
        let fd: Int32
        let readSource: DispatchSourceRead
    }

    private let socketPath: String
    private let maxClients: Int
    private let makeVerifyPeer: MakeVerifyPeer
    private var verifyPeer: VerifyPeer = { _ in .failure(.requirementNotSatisfied(errSecCSReqFailed)) }
    private var rejectionLog = PeerRejectionLog()
    private var serverSocket: Int32 = -1
    // A refused start must not unlink whatever sits at socketPath, e.g. behind a symlinked directory.
    private var didBind = false
    private var listenSource: DispatchSourceRead?
    private var clients: [ClientID: Client] = [:]
    private var nextClientID: ClientID = 1
    private let queue = DispatchQueue(label: "com.macmute.socket", qos: .userInteractive)
    private let logger = Logger(subsystem: "com.macmute.app", category: "socket")

    /// Callbacks run on the main queue.
    var onMessageReceived: ((ClientID, [String: Any]) -> Void)?
    var onClientConnected: ((ClientID) -> Void)?
    var onClientDisconnected: ((ClientID) -> Void)?

    /// Only accepts helpers this app trusts; see `PeerCodeVerifier.trustedHelperRequirement`.
    convenience init() {
        let appSupport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MacMute")
        self.init(
            socketPath: appSupport.appendingPathComponent("macmute.sock").path,
            makeVerifyPeer: Self.trustedHelperCheck(appBundle: Bundle.main.bundleURL, ownCode: PeerCodeVerifier.ownStaticCode)
        )
    }

    static func trustedHelperCheck(
        appBundle: URL,
        ownCode: @escaping () -> Result<SecStaticCode, PeerVerificationError>
    ) -> MakeVerifyPeer {
        {
            trustedHelperRequirement(appBundle: appBundle, ownCode: ownCode)
                .map { requirement in { socket in PeerCodeVerifier.verify(socket: socket, against: requirement) } }
        }
    }

    static func trustedHelperRequirement(
        appBundle: URL,
        ownCode: () -> Result<SecStaticCode, PeerVerificationError>
    ) -> Result<SecRequirement, PeerVerificationError> {
        ownCode().flatMap {
            PeerCodeVerifier.trustedHelperRequirement(
                signedLike: $0,
                helperIdentifier: PeerCodeVerifier.helperIdentifier,
                bundledHelper: appBundle.appendingPathComponent("Contents/Resources/MacMuteHelper")
            )
        }
    }

    init(socketPath: String, maxClients: Int = SocketServer.defaultMaxClients, makeVerifyPeer: @escaping MakeVerifyPeer) {
        self.socketPath = socketPath
        self.maxClients = maxClients
        self.makeVerifyPeer = makeVerifyPeer
    }

    /// Creates the directory, or restricts an existing one, so only the owner can reach the socket.
    static func prepareDirectory(_ url: URL) throws {
        let ownerOnly: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: ownerOnly)
        } catch {
            throw SocketDirectoryError.operationFailed("createDirectory", Self.errorCode(error))
        }
        // Checked before setAttributes, which follows symbolic links.
        try checkOwnDirectory(url)
        do {
            try FileManager.default.setAttributes(ownerOnly, ofItemAtPath: url.path)
        } catch {
            throw SocketDirectoryError.operationFailed("setAttributes", Self.errorCode(error))
        }
        let info = try checkOwnDirectory(url)
        guard info.st_mode & 0o077 == 0 else { throw SocketDirectoryError.accessibleByOthers(info.st_mode & 0o777) }
    }

    @discardableResult
    private static func checkOwnDirectory(_ url: URL) throws -> stat {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw SocketDirectoryError.operationFailed("lstat", String(cString: strerror(errno)))
        }
        let type = info.st_mode & S_IFMT
        guard type != S_IFLNK else { throw SocketDirectoryError.symbolicLink }
        guard type == S_IFDIR else { throw SocketDirectoryError.notADirectory }
        guard info.st_uid == getuid() else { throw SocketDirectoryError.ownedByAnotherUser(info.st_uid) }
        return info
    }

    // NSError descriptions carry the full path, which contains the user name.
    private static func errorCode(_ error: Error) -> String {
        let nsError = error as NSError
        let underlying = (nsError.userInfo[NSUnderlyingErrorKey] as? NSError).map { ", \($0.domain) \($0.code)" } ?? ""
        return "\(nsError.domain) \(nsError.code)\(underlying)"
    }

    /// Fails instead of truncating: a truncated path would bind or connect somewhere else.
    static func socketAddress(for path: String) -> Result<sockaddr_un, SocketPathError> {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let maximum = MemoryLayout.size(ofValue: address.sun_path) - 1
        guard bytes.count <= maximum else { return .failure(.pathTooLong(length: bytes.count, maximum: maximum)) }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return .success(address)
    }

    // The full path contains the user name.
    private var socketName: String { (socketPath as NSString).lastPathComponent }

    func start() {
        queue.async { [weak self] in
            self?.startServer()
        }
    }

    // Each fd is closed by its own source's cancel handler: closing it here first makes libdispatch
    // report a vanished resource, and the fd number could be reused before the handler runs.
    func stop() {
        dispatchPrecondition(condition: .notOnQueue(queue))
        queue.sync {
            listenSource?.cancel()
            listenSource = nil
            clients.values.forEach { $0.readSource.cancel() }
            clients.removeAll()
            serverSocket = -1
            if didBind { unlink(socketPath) }
            didBind = false
        }
    }

    /// `completion` runs on the main queue.
    func sendMessage(
        _ message: [String: Any],
        to client: ClientID,
        completion: ((Result<Void, SocketSendError>) -> Void)? = nil
    ) {
        queue.async { [weak self] in
            let result = self?.write(message, to: client) ?? .failure(.noSocketClient)
            if let completion = completion {
                DispatchQueue.main.async { completion(result) }
            }
        }
    }

    private func write(_ message: [String: Any], to clientID: ClientID) -> Result<Void, SocketSendError> {
        guard let clientSocket = clients[clientID]?.fd else {
            logger.error("Helper \(clientID, privacy: .public) not connected, cannot send \(String(describing: message), privacy: .public)")
            return .failure(.noSocketClient)
        }

        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: message)
        } catch {
            logger.error("Failed to serialize message \(String(describing: message), privacy: .public): \(error.localizedDescription, privacy: .public)")
            return .failure(.serializationFailed)
        }
        var messageData = data
        messageData.append(0x0A) // newline delimiter

        let total = messageData.count
        let (written, writeErrno) = messageData.withUnsafeBytes { rawBuffer -> (Int, Int32?) in
            guard let base = rawBuffer.baseAddress else { return (0, nil) }
            var offset = 0
            while offset < total {
                let result = Darwin.write(clientSocket, base + offset, total - offset)
                if result < 0 {
                    if errno == EINTR { continue }
                    return (offset, errno)
                }
                offset += result
            }
            return (offset, nil)
        }
        // The socket is non-blocking: a helper that stops reading must not stall the queue, and
        // a partly written line would corrupt the stream, so the helper is dropped.
        guard written == total else {
            let cause = writeErrno.map { String(cString: strerror($0)) } ?? "no buffer"
            logger.error("Disconnecting helper \(clientID, privacy: .public): wrote \(written, privacy: .public)/\(total, privacy: .public) bytes: \(cause, privacy: .public)")
            dropClient(clientID)
            return .failure(.writeFailed)
        }
        logger.info("Sent to helper \(clientID, privacy: .public): \(String(describing: message), privacy: .public)")
        return .success(())
    }

    private func startServer() {
        let address: sockaddr_un
        switch Self.socketAddress(for: socketPath) {
        case let .success(built):
            address = built
        case let .failure(error):
            logger.fault("Not starting the socket server: \(error.description, privacy: .public)")
            return
        }
        let directory = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
        do {
            try Self.prepareDirectory(directory)
        } catch {
            logger.fault("Not starting the socket server: unsafe socket directory \(directory.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
            return
        }
        switch makeVerifyPeer() {
        case let .success(verify):
            verifyPeer = verify
        case let .failure(error):
            logger.fault("Not starting the socket server: \(error.description, privacy: .public)")
            return
        }

        // Remove existing socket file
        unlink(socketPath)

        serverSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            logger.error("Failed to create socket: \(String(cString: strerror(errno)), privacy: .public)")
            return
        }

        var addr = address
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(serverSocket, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard bindResult == 0 else {
            logger.error("Failed to bind socket \(self.socketName, privacy: .public): \(String(cString: strerror(errno)), privacy: .public)")
            close(serverSocket)
            return
        }
        didBind = true

        guard chmod(socketPath, 0o600) == 0 else {
            logger.error("Failed to restrict socket \(self.socketName, privacy: .public) to the owner: \(String(cString: strerror(errno)), privacy: .public)")
            close(serverSocket)
            unlink(socketPath)
            didBind = false
            return
        }

        guard listen(serverSocket, Self.listenBacklog) == 0 else {
            logger.error("Failed to listen on socket: \(String(cString: strerror(errno)), privacy: .public)")
            close(serverSocket)
            return
        }

        logger.notice("Socket server listening on \(self.socketName, privacy: .public)")

        let listeningSocket = serverSocket
        let source = DispatchSource.makeReadSource(fileDescriptor: listeningSocket, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptConnection()
        }
        source.setCancelHandler {
            close(listeningSocket)
        }
        source.resume()
        self.listenSource = source
    }

    private func acceptConnection() {
        let client = accept(serverSocket, nil, nil)
        guard client >= 0 else {
            logger.error("Failed to accept connection: \(String(cString: strerror(errno)), privacy: .public)")
            return
        }

        // Checked before the limit, so peers that fail it cannot use up the slots.
        if case let .failure(error) = verifyPeer(client) {
            let entry = rejectionLog.entry(for: error, pid: PeerCodeVerifier.peerProcessID(of: client))
            logger.log(level: entry.level, "\(entry.message, privacy: .public)")
            close(client)
            return
        }

        guard clients.count < maxClients else {
            logger.error("Rejecting helper: already \(self.maxClients, privacy: .public) connected")
            close(client)
            return
        }

        // Without this, writing to a helper that just died raises SIGPIPE and kills the app.
        var noSigPipe: Int32 = 1
        if setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size)) != 0 {
            logger.error("Failed to set SO_NOSIGPIPE: \(String(cString: strerror(errno)), privacy: .public)")
        }

        let flags = fcntl(client, F_GETFL)
        guard flags >= 0, fcntl(client, F_SETFL, flags | O_NONBLOCK) == 0 else {
            logger.error("Rejecting helper: cannot make its socket non-blocking: \(String(cString: strerror(errno)), privacy: .public)")
            close(client)
            return
        }

        let id = nextClientID
        nextClientID += 1
        clients[id] = Client(fd: client, readSource: makeReadSource(for: client, id: id))
        logger.notice("Helper \(id, privacy: .public) connected (\(self.clients.count, privacy: .public) total)")

        DispatchQueue.main.async { [weak self] in
            self?.onClientConnected?(id)
        }
    }

    private func makeReadSource(for client: Int32, id: ClientID) -> DispatchSourceRead {
        let source = DispatchSource.makeReadSource(fileDescriptor: client, queue: queue)
        var framer = LineFramer()

        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            var readBuffer = [UInt8](repeating: 0, count: 4096)
            let bytesRead = read(client, &readBuffer, readBuffer.count)

            if bytesRead < 0 && (errno == EAGAIN || errno == EINTR) {
                return
            }
            if bytesRead <= 0 {
                let cause = bytesRead < 0 ? String(cString: strerror(errno)) : "end of stream"
                self.logger.notice("Helper \(id, privacy: .public) disconnected (\(cause, privacy: .public))")
                self.dropClient(id)
                return
            }

            let lines: [Data]
            do {
                lines = try framer.append(Data(readBuffer[0..<bytesRead]))
            } catch {
                self.logger.error("Disconnecting helper \(id, privacy: .public): line longer than \(framer.maxLineLength, privacy: .public) bytes")
                self.dropClient(id)
                return
            }

            for messageData in lines {
                guard let json = try? JSONSerialization.jsonObject(with: messageData) as? [String: Any] else {
                    let text = preview(String(decoding: messageData, as: UTF8.self))
                    self.logger.error("Dropping undecodable message from helper \(id, privacy: .public) (\(messageData.count, privacy: .public) bytes): \(text, privacy: .public)")
                    continue
                }
                DispatchQueue.main.async {
                    self.onMessageReceived?(id, json)
                }
            }
        }

        source.setCancelHandler {
            close(client)
        }

        source.resume()
        return source
    }

    private func dropClient(_ id: ClientID) {
        guard let client = clients.removeValue(forKey: id) else { return }
        client.readSource.cancel()
        DispatchQueue.main.async { [weak self] in
            self?.onClientDisconnected?(id)
        }
    }
}

enum SocketPathError: Error, Equatable, CustomStringConvertible {
    case pathTooLong(length: Int, maximum: Int)

    var description: String {
        switch self {
        case let .pathTooLong(length, maximum):
            return "the socket path is \(length) bytes long; a socket address holds at most \(maximum)"
        }
    }
}

enum SocketDirectoryError: Error, CustomStringConvertible {
    case operationFailed(_ operation: String, _ reason: String)
    case symbolicLink
    case notADirectory
    case ownedByAnotherUser(uid_t)
    case accessibleByOthers(mode_t)

    var description: String {
        switch self {
        case let .operationFailed(operation, reason): return "\(operation) failed: \(reason)"
        case .symbolicLink: return "it is a symbolic link"
        case .notADirectory: return "it is not a directory"
        case let .ownedByAnotherUser(uid): return "it is owned by uid \(uid)"
        case let .accessibleByOthers(mode): return "its mode \(String(mode, radix: 8)) lets other users in"
        }
    }
}

/// A rejected helper retries every few seconds; only the first rejection of each process is an error.
struct PeerRejectionLog {
    private static let maxRemembered = 256
    private var reported: Set<pid_t> = []

    mutating func entry(for error: PeerVerificationError, pid: pid_t?) -> (level: OSLogType, message: String) {
        if reported.count >= Self.maxRemembered { reported.removeAll() }
        // Unknown processes cannot be told apart, so each rejection is reported.
        let isFirst = pid.map { reported.insert($0).inserted } ?? true
        var message = "Rejecting peer pid \(pid.map(String.init) ?? "unknown"): \(error.description)"
        if case .requirementNotSatisfied = error {
            message += ". If it is the MacMute helper of another build, reload the MacMute extension in Chrome."
        }
        return (isFirst ? .error : .debug, message)
    }
}
