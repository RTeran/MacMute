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

    static let defaultMaxClients = 16
    private static let listenBacklog: Int32 = 8

    private struct Client {
        let fd: Int32
        let readSource: DispatchSourceRead
    }

    private let socketPath: String
    private let maxClients: Int
    private let verifyPeer: VerifyPeer
    private var serverSocket: Int32 = -1
    private var listenSource: DispatchSourceRead?
    private var clients: [ClientID: Client] = [:]
    private var nextClientID: ClientID = 1
    private let queue = DispatchQueue(label: "com.macmute.socket", qos: .userInteractive)
    private let logger = Logger(subsystem: "com.macmute.app", category: "socket")

    /// Callbacks run on the main queue.
    var onMessageReceived: ((ClientID, [String: Any]) -> Void)?
    var onClientConnected: ((ClientID) -> Void)?
    var onClientDisconnected: ((ClientID) -> Void)?

    /// Only accepts helpers signed like the one bundled in this app.
    convenience init() {
        let appSupport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MacMute")
        do {
            try Self.prepareDirectory(appSupport)
        } catch {
            Logger(subsystem: "com.macmute.app", category: "socket")
                .error("Cannot restrict the socket directory to the owner: \(error.localizedDescription, privacy: .public)")
        }
        let bundledHelper = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/MacMuteHelper")
        self.init(socketPath: appSupport.appendingPathComponent("macmute.sock").path) { socket in
            PeerCodeVerifier.verify(socket: socket, againstCodeAt: bundledHelper)
        }
    }

    init(socketPath: String, maxClients: Int = SocketServer.defaultMaxClients, verifyPeer: @escaping VerifyPeer) {
        self.socketPath = socketPath
        self.maxClients = maxClients
        self.verifyPeer = verifyPeer
    }

    static func prepareDirectory(_ url: URL) throws {
        let ownerOnly: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: ownerOnly)
        try FileManager.default.setAttributes(ownerOnly, ofItemAtPath: url.path)
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
        }
        unlink(socketPath)
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
        // Remove existing socket file
        unlink(socketPath)

        serverSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            logger.error("Failed to create socket: \(String(cString: strerror(errno)), privacy: .public)")
            return
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let bindResult = withUnsafeMutablePointer(to: &addr) { addrPtr in
            socketPath.withCString { ptr in
                let sunPathOffset = MemoryLayout<sockaddr_un>.offset(of: \sockaddr_un.sun_path)!
                let sunPath = UnsafeMutableRawPointer(addrPtr).advanced(by: sunPathOffset)
                    .assumingMemoryBound(to: CChar.self)
                strncpy(sunPath, ptr, 104 - 1)
            }
            return addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(serverSocket, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard bindResult == 0 else {
            logger.error("Failed to bind socket \(self.socketName, privacy: .public): \(String(cString: strerror(errno)), privacy: .public)")
            close(serverSocket)
            return
        }

        guard chmod(socketPath, 0o600) == 0 else {
            logger.error("Failed to restrict socket \(self.socketName, privacy: .public) to the owner: \(String(cString: strerror(errno)), privacy: .public)")
            close(serverSocket)
            unlink(socketPath)
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
            logger.error("Rejecting peer: its code signature does not match the bundled helper (\(String(describing: error), privacy: .public))")
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
