import Foundation
import os

enum SocketSendError: String, Error {
    case noSocketClient = "no_socket_client"
    case serializationFailed = "serialization_failed"
    case writeFailed = "write_failed"
}

class SocketServer {
    private let socketPath: String
    private var serverSocket: Int32 = -1
    private var clientSocket: Int32 = -1
    private var listenSource: DispatchSourceRead?
    private var readSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "com.macmute.socket", qos: .userInteractive)
    private let logger = Logger(subsystem: "com.macmute.app", category: "socket")

    var onMessageReceived: (([String: Any]) -> Void)?
    var onClientConnected: (() -> Void)?

    convenience init() {
        let appSupport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MacMute")
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        self.init(socketPath: appSupport.appendingPathComponent("macmute.sock").path)
    }

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    func start() {
        queue.async { [weak self] in
            self?.startServer()
        }
    }

    // Each fd is closed by its own source's cancel handler: closing it here first makes libdispatch
    // report a vanished resource, and the fd number could be reused before the handler runs.
    func stop() {
        queue.sync {
            listenSource?.cancel()
            listenSource = nil
            readSource?.cancel()
            readSource = nil
            serverSocket = -1
            clientSocket = -1
        }
        unlink(socketPath)
    }

    /// `completion` runs on the main queue.
    func sendMessage(_ message: [String: Any], completion: ((Result<Void, SocketSendError>) -> Void)? = nil) {
        queue.async { [weak self] in
            let result = self?.write(message) ?? .failure(.noSocketClient)
            if let completion = completion {
                DispatchQueue.main.async { completion(result) }
            }
        }
    }

    private func write(_ message: [String: Any]) -> Result<Void, SocketSendError> {
        guard clientSocket >= 0 else {
            logger.error("No helper connected, cannot send \(String(describing: message), privacy: .public)")
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
        guard written == total else {
            let cause = writeErrno.map { String(cString: strerror($0)) } ?? "no buffer"
            logger.error("Failed to write to helper (\(written, privacy: .public)/\(total, privacy: .public) bytes): \(cause, privacy: .public)")
            return .failure(.writeFailed)
        }
        logger.info("Sent to helper: \(String(describing: message), privacy: .public)")
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
            logger.error("Failed to bind socket at \(self.socketPath, privacy: .public): \(String(cString: strerror(errno)), privacy: .public)")
            close(serverSocket)
            return
        }

        guard listen(serverSocket, 1) == 0 else {
            logger.error("Failed to listen on socket: \(String(cString: strerror(errno)), privacy: .public)")
            close(serverSocket)
            return
        }

        logger.notice("Socket server listening at \(self.socketPath, privacy: .public)")

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

        if clientSocket >= 0 {
            logger.notice("Replacing the connected helper with a new one")
            readSource?.cancel()
        }

        // Without this, writing to a helper that just died raises SIGPIPE and kills the app.
        var noSigPipe: Int32 = 1
        if setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size)) != 0 {
            logger.error("Failed to set SO_NOSIGPIPE: \(String(cString: strerror(errno)), privacy: .public)")
        }

        clientSocket = client
        logger.notice("Helper connected")

        startReading()

        DispatchQueue.main.async { [weak self] in
            self?.onClientConnected?()
        }
    }

    private func startReading() {
        let client = clientSocket
        let source = DispatchSource.makeReadSource(fileDescriptor: client, queue: queue)
        var buffer = Data()

        source.setEventHandler { [weak self, unowned source] in
            guard let self = self else { return }
            var readBuffer = [UInt8](repeating: 0, count: 4096)
            let bytesRead = read(client, &readBuffer, readBuffer.count)

            if bytesRead <= 0 {
                let cause = bytesRead < 0 ? String(cString: strerror(errno)) : "end of stream"
                self.logger.notice("Helper disconnected (\(cause, privacy: .public))")
                source.cancel()
                if self.clientSocket == client {
                    self.clientSocket = -1
                    self.readSource = nil
                }
                return
            }

            buffer.append(contentsOf: readBuffer[0..<bytesRead])

            // Process newline-delimited messages
            while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let messageData = buffer[buffer.startIndex..<newlineIndex]
                buffer = Data(buffer[buffer.index(after: newlineIndex)...])

                guard let json = try? JSONSerialization.jsonObject(with: messageData) as? [String: Any] else {
                    self.logger.error("Dropping undecodable message from helper: \(String(decoding: messageData, as: UTF8.self), privacy: .public)")
                    continue
                }
                DispatchQueue.main.async {
                    self.onMessageReceived?(json)
                }
            }
        }

        source.setCancelHandler {
            close(client)
        }

        source.resume()
        self.readSource = source
    }
}
