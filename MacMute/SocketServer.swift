import Foundation
import os

enum SocketSendError: String, Error {
    case noSocketClient = "no_socket_client"
    case serializationFailed = "serialization_failed"
    case writeFailed = "write_failed"
    case appShuttingDown = "app_shutting_down"
}

enum SocketServerState: Equatable {
    case listening
    /// Opening the socket failed; the server tries again after the delay.
    case retrying(after: TimeInterval)
    /// The server cannot start with this setup and does not retry.
    case failed
    /// Another MacMute already serves the socket; this server leaves it alone.
    case anotherInstanceRunning
}

/// Identifies one connected helper, one per Chrome profile. Never reused while the server runs.
typealias ClientID = Int

class SocketServer {
    typealias VerifyPeer = (_ socket: Int32) -> Result<Void, PeerVerificationError>
    /// Called once when the server starts, so the trusted requirement cannot change while it runs.
    typealias MakeVerifyPeer = () -> Result<VerifyPeer, PeerVerificationError>

    static let defaultMaxClients = 16
    private static let listenBacklog: Int32 = 8
    private static let lockFileName = "macmute.lock"

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
    // Held from the first start until stop(), so only one MacMute may touch the socket path.
    private var lockFile: Int32 = -1
    // Only the socket this server bound is unlinked: a refused start must not remove whatever sits at
    // socketPath (e.g. behind a symlinked directory), nor a file that replaced the socket later.
    private var boundFile: (device: dev_t, inode: ino_t)?
    private var isRunning = false
    private var retryBackoff: RetryBackoff
    private var pendingRetry: DispatchWorkItem?
    private var lastFailure: String?
    private var listenSource: DispatchSourceRead?
    private var clients: [ClientID: Client] = [:]
    private var nextClientID: ClientID = 1
    private let queue = DispatchQueue(label: "com.macmute.socket", qos: .userInteractive)
    private let logger = Logger(subsystem: "com.macmute.app", category: "socket")

    /// Callbacks run on the main queue.
    var onMessageReceived: ((ClientID, [String: Any]) -> Void)?
    var onClientConnected: ((ClientID) -> Void)?
    var onClientDisconnected: ((ClientID) -> Void)?
    var onStateChange: ((SocketServerState) -> Void)?

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
                .map { trusted in { socket in PeerCodeVerifier.verify(socket: socket, against: trusted) } }
        }
    }

    static func trustedHelperRequirement(
        appBundle: URL,
        ownCode: () -> Result<SecStaticCode, PeerVerificationError>
    ) -> Result<TrustedPeer, PeerVerificationError> {
        ownCode().flatMap {
            PeerCodeVerifier.trustedHelperRequirement(
                signedLike: $0,
                helperIdentifier: PeerCodeVerifier.helperIdentifier,
                bundledHelper: appBundle.appendingPathComponent("Contents/Resources/MacMuteHelper")
            )
        }
    }

    init(
        socketPath: String,
        maxClients: Int = SocketServer.defaultMaxClients,
        retryBackoff: RetryBackoff = RetryBackoff(),
        makeVerifyPeer: @escaping MakeVerifyPeer
    ) {
        self.socketPath = socketPath
        self.maxClients = maxClients
        self.retryBackoff = retryBackoff
        self.makeVerifyPeer = makeVerifyPeer
    }

    /// Creates the directory, or restricts an existing one, so only the owner can reach the socket.
    static func prepareDirectory(_ url: URL) throws {
        let ownerOnly: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: ownerOnly)
        } catch {
            // Something already at the path is refused for what it is, not retried as an I/O error.
            var existing = stat()
            if lstat(url.path, &existing) == 0 { try checkOwnDirectory(url) }
            throw SocketDirectoryError.operationFailed("createDirectory", errorCode(error))
        }
        // Checked before setAttributes, which follows symbolic links.
        try checkOwnDirectory(url)
        do {
            try FileManager.default.setAttributes(ownerOnly, ofItemAtPath: url.path)
        } catch {
            throw SocketDirectoryError.operationFailed("setAttributes", errorCode(error))
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
            guard let self, !self.isRunning else { return }
            self.isRunning = true
            self.retryBackoff.reset()
            self.lastFailure = nil
            self.startServer()
        }
    }

    // Each fd is closed by its own source's cancel handler: closing it here first makes libdispatch
    // report a vanished resource, and the fd number could be reused before the handler runs.
    func stop() {
        dispatchPrecondition(condition: .notOnQueue(queue))
        queue.sync {
            isRunning = false
            pendingRetry?.cancel()
            pendingRetry = nil
            listenSource?.cancel()
            listenSource = nil
            clients.values.forEach { $0.readSource.cancel() }
            clients.removeAll()
            serverSocket = -1
            unlinkBoundFile()
            if lockFile >= 0 { close(lockFile) }
            lockFile = -1
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
            report(.failed)
            return
        }
        let directory = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
        do {
            try Self.prepareDirectory(directory)
        } catch let SocketDirectoryError.operationFailed(operation, reason) {
            failTransiently("Failed to prepare the socket directory \(directory.lastPathComponent): \(operation) failed: \(reason)")
            return
        } catch {
            logger.fault("Not starting the socket server: unsafe socket directory \(directory.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
            report(.failed)
            return
        }
        switch acquireLock(in: directory) {
        case .acquired:
            break
        case .heldByAnotherInstance:
            logger.error("Not starting the socket server: another MacMute holds the lock in \(directory.lastPathComponent, privacy: .public)")
            report(.anotherInstanceRunning)
            return
        case let .unsafe(reason):
            logger.fault("Not starting the socket server: \(reason, privacy: .public)")
            report(.failed)
            return
        case let .failed(message):
            failTransiently(message)
            return
        }
        switch makeVerifyPeer() {
        case let .success(verify):
            verifyPeer = verify
        case let .failure(error):
            logger.fault("Not starting the socket server: \(error.description, privacy: .public)")
            report(.failed)
            return
        }

        var existing = stat()
        if lstat(socketPath, &existing) == 0 {
            guard existing.st_mode & S_IFMT == S_IFSOCK else {
                logger.fault("Not starting the socket server: \(self.socketName, privacy: .public) exists and is not a socket")
                report(.failed)
                return
            }
            // Holding the lock means no other MacMute serves this socket, so it is stale.
            guard unlink(socketPath) == 0 else {
                failTransiently("Failed to remove the stale socket \(self.socketName): \(String(cString: strerror(errno)))")
                return
            }
        } else if errno != ENOENT {
            failTransiently("Failed to stat socket \(self.socketName): \(String(cString: strerror(errno)))")
            return
        }

        serverSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            failTransiently("Failed to create socket: \(String(cString: strerror(errno)))")
            return
        }

        guard Self.bind(serverSocket, to: address) == 0 else {
            failTransiently("Failed to bind socket \(self.socketName): \(String(cString: strerror(errno)))")
            return
        }
        var info = stat()
        guard lstat(socketPath, &info) == 0 else {
            failTransiently("Failed to stat socket \(self.socketName): \(String(cString: strerror(errno)))")
            return
        }
        boundFile = (info.st_dev, info.st_ino)

        guard chmod(socketPath, 0o600) == 0 else {
            failTransiently("Failed to restrict socket \(self.socketName) to the owner: \(String(cString: strerror(errno)))")
            return
        }

        guard listen(serverSocket, Self.listenBacklog) == 0 else {
            failTransiently("Failed to listen on socket: \(String(cString: strerror(errno)))")
            return
        }

        logger.notice("Socket server listening on \(self.socketName, privacy: .public)")
        lastFailure = nil
        report(.listening)

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

    private static func bind(_ fd: Int32, to address: sockaddr_un) -> Int32 {
        var address = address
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    private enum LockOutcome {
        case acquired
        case heldByAnotherInstance
        case unsafe(String)
        case failed(String)
    }

    // flock, unlike fcntl locks, belongs to the open file, so closing another descriptor of the
    // same file never drops it. The file is never unlinked: a new inode would let a second
    // instance lock it while the first still holds the old one.
    private func acquireLock(in directory: URL) -> LockOutcome {
        guard lockFile < 0 else { return .acquired }
        let path = directory.appendingPathComponent(Self.lockFileName).path
        let fd = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard fd >= 0 else {
            let code = errno
            let message = "Failed to open the lock file: \(String(cString: strerror(code)))"
            // A symbolic link or a directory at the path will not go away by retrying.
            return code == ELOOP || code == EISDIR ? .unsafe(message) : .failed(message)
        }
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            let message = "Failed to stat the lock file: \(String(cString: strerror(errno)))"
            close(fd)
            return .failed(message)
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else {
            close(fd)
            return .unsafe("the lock file is not a regular file owned by this user")
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(fd)
            return code == EWOULDBLOCK ? .heldByAnotherInstance : .failed("Failed to lock the lock file: \(String(cString: strerror(code)))")
        }
        lockFile = fd
        return .acquired
    }

    private func report(_ state: SocketServerState) {
        DispatchQueue.main.async { [weak self] in
            self?.onStateChange?(state)
        }
    }

    private func failTransiently(_ message: String) {
        // Repeats every 30 s at most, so a failure is logged as an error only when it is new.
        let level: OSLogType = message == lastFailure ? .debug : .error
        lastFailure = message
        logger.log(level: level, "\(message, privacy: .public)")
        abortStart()
        let delay = retryBackoff.nextDelay()
        let retry = DispatchWorkItem { [weak self] in
            guard let self, self.isRunning else { return }
            self.pendingRetry = nil
            self.startServer()
        }
        pendingRetry = retry
        queue.asyncAfter(deadline: .now() + delay, execute: retry)
        report(.retrying(after: delay))
    }

    private func abortStart() {
        if serverSocket >= 0 { close(serverSocket) }
        serverSocket = -1
        unlinkBoundFile()
    }

    private func unlinkBoundFile() {
        guard let bound = boundFile else { return }
        boundFile = nil
        var info = stat()
        guard lstat(socketPath, &info) == 0 else {
            let code = errno
            if code != ENOENT {
                logger.error("Leaving \(self.socketName, privacy: .public) in place: lstat failed: \(String(cString: strerror(code)), privacy: .public)")
            }
            return
        }
        guard info.st_mode & S_IFMT == S_IFSOCK, info.st_dev == bound.device, info.st_ino == bound.inode else {
            logger.error("Leaving \(self.socketName, privacy: .public) in place: it is no longer the socket this server bound")
            return
        }
        if unlink(socketPath) != 0 {
            let reason = String(cString: strerror(errno))
            logger.error("Failed to remove \(self.socketName, privacy: .public): \(reason, privacy: .public)")
        }
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
