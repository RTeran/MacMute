import Foundation
import os

enum HelperLog {
    static let logger = Logger(subsystem: "com.macmute.app", category: "helper")
}

// MARK: - Native Messaging Protocol (stdin/stdout with 4-byte length prefix)

class NativeMessaging {
    static func readMessage() -> [String: Any]? {
        // Read 4-byte length prefix (uint32 little-endian)
        var lengthBytes = [UInt8](repeating: 0, count: 4)
        let bytesRead = fread(&lengthBytes, 1, 4, stdin)
        guard bytesRead == 4 else { return nil }

        let length = UInt32(lengthBytes[0])
            | (UInt32(lengthBytes[1]) << 8)
            | (UInt32(lengthBytes[2]) << 16)
            | (UInt32(lengthBytes[3]) << 24)

        guard length > 0, length < 1_000_000 else { return nil }

        var messageBytes = [UInt8](repeating: 0, count: Int(length))
        let messageRead = fread(&messageBytes, 1, Int(length), stdin)
        guard messageRead == Int(length) else { return nil }

        let data = Data(messageBytes)
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func writeMessage(_ message: [String: Any]) {
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: message)
        } catch {
            HelperLog.logger.error("Failed to serialize message for Chrome \(String(describing: message), privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }

        let length = UInt32(data.count)
        let lengthBytes: [UInt8] = [
            UInt8(length & 0xFF),
            UInt8((length >> 8) & 0xFF),
            UInt8((length >> 16) & 0xFF),
            UInt8((length >> 24) & 0xFF),
        ]

        let headerWritten = fwrite(lengthBytes, 1, 4, stdout)
        let bodyWritten = data.withUnsafeBytes { rawBuffer in
            fwrite(rawBuffer.baseAddress, 1, data.count, stdout)
        }
        guard headerWritten == 4, bodyWritten == data.count, fflush(stdout) == 0 else {
            failStdoutWrite(written: headerWritten + bodyWritten, total: 4 + data.count)
        }
    }

    // A partial frame desyncs the length-prefixed stream, so any later message would be garbage.
    private static func failStdoutWrite(written: Int, total: Int) -> Never {
        HelperLog.logger.fault("Failed to write to Chrome (\(written, privacy: .public)/\(total, privacy: .public) bytes): \(String(cString: strerror(errno)), privacy: .public)")
        exit(1)
    }
}

func writeFully(_ fd: Int32, _ data: Data) -> (written: Int, errno: Int32?) {
    data.withUnsafeBytes { rawBuffer in
        guard let base = rawBuffer.baseAddress else { return (0, nil) }
        var offset = 0
        while offset < data.count {
            let result = Darwin.write(fd, base + offset, data.count - offset)
            if result < 0 {
                if errno == EINTR { continue }
                return (offset, errno)
            }
            offset += result
        }
        return (offset, nil)
    }
}

// MARK: - Unix Domain Socket Client

class SocketClient {
    private let socketPath: String
    private var socketFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "com.macmute.helper.socket")

    var onMessageReceived: (([String: Any]) -> Void)?
    var onDisconnected: (() -> Void)?

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.socketPath = home
            .appendingPathComponent("Library/Application Support/MacMute/macmute.sock")
            .path
    }

    func connect() -> Bool {
        socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            HelperLog.logger.error("Failed to create socket: \(String(cString: strerror(errno)), privacy: .public)")
            return false
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let connectResult = withUnsafeMutablePointer(to: &addr) { addrPtr in
            socketPath.withCString { ptr in
                let sunPathOffset = MemoryLayout<sockaddr_un>.offset(of: \sockaddr_un.sun_path)!
                let sunPath = UnsafeMutableRawPointer(addrPtr).advanced(by: sunPathOffset)
                    .assumingMemoryBound(to: CChar.self)
                strncpy(sunPath, ptr, 104 - 1)
            }
            return addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(socketFD, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard connectResult == 0 else {
            HelperLog.logger.info("Failed to connect to socket at \(self.socketPath, privacy: .public): \(String(cString: strerror(errno)), privacy: .public)")
            close(socketFD)
            socketFD = -1
            return false
        }

        // Writing to an app that just quit must fail with EPIPE instead of killing the helper.
        var noSigPipe: Int32 = 1
        if setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size)) != 0 {
            HelperLog.logger.error("Failed to set SO_NOSIGPIPE: \(String(cString: strerror(errno)), privacy: .public)")
        }

        HelperLog.logger.notice("Connected to MacMute app")
        startReading()
        return true
    }

    // The read source's cancel handler owns closing the fd.
    func disconnect() {
        readSource?.cancel()
        readSource = nil
        socketFD = -1
    }

    func sendMessage(_ message: [String: Any]) {
        queue.async { [weak self] in
            guard let self = self, self.socketFD >= 0 else {
                HelperLog.logger.error("Cannot send to app, not connected: \(String(describing: message), privacy: .public)")
                return
            }

            var messageData: Data
            do {
                messageData = try JSONSerialization.data(withJSONObject: message)
            } catch {
                HelperLog.logger.error("Failed to serialize message for app \(String(describing: message), privacy: .public): \(error.localizedDescription, privacy: .public)")
                return
            }
            messageData.append(0x0A) // newline delimiter

            let (written, writeErrno) = writeFully(self.socketFD, messageData)
            if written != messageData.count {
                let cause = writeErrno.map { String(cString: strerror($0)) } ?? "no buffer"
                HelperLog.logger.error("Write to app failed (\(written, privacy: .public)/\(messageData.count, privacy: .public) bytes): \(cause, privacy: .public)")
            }
        }
    }

    private func startReading() {
        let fd = socketFD
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        var buffer = Data()

        source.setEventHandler { [weak self, unowned source] in
            guard let self = self else { return }
            var readBuffer = [UInt8](repeating: 0, count: 4096)
            let bytesRead = read(fd, &readBuffer, readBuffer.count)

            if bytesRead <= 0 {
                HelperLog.logger.notice("Disconnected from app (\(bytesRead < 0 ? String(cString: strerror(errno)) : "end of stream", privacy: .public))")
                source.cancel()
                if self.socketFD == fd {
                    self.socketFD = -1
                    self.readSource = nil
                }
                self.onDisconnected?()
                return
            }

            buffer.append(contentsOf: readBuffer[0..<bytesRead])

            while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let messageData = buffer[buffer.startIndex..<newlineIndex]
                buffer = Data(buffer[buffer.index(after: newlineIndex)...])

                guard let json = try? JSONSerialization.jsonObject(with: messageData) as? [String: Any] else {
                    HelperLog.logger.error("Dropping undecodable message from app: \(String(decoding: messageData, as: UTF8.self), privacy: .public)")
                    continue
                }
                self.onMessageReceived?(json)
            }
        }

        source.setCancelHandler {
            close(fd)
        }

        source.resume()
        self.readSource = source
    }
}

// MARK: - Main

// Chrome closing stdout must surface as a write error, not a SIGPIPE that kills the helper.
signal(SIGPIPE, SIG_IGN)

let socketClient = SocketClient()

// Messages from the app → forward to Chrome extension
socketClient.onMessageReceived = { message in
    HelperLog.logger.info("Relaying app → extension: \(String(describing: message), privacy: .public)")
    NativeMessaging.writeMessage(message)
}

func scheduleConnect(delay: TimeInterval = 0) {
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
        if socketClient.connect() {
            HelperLog.logger.notice("Socket connected")
        } else {
            HelperLog.logger.info("Connection failed, retrying in 2s")
            scheduleConnect(delay: 2.0)
        }
    }
}

socketClient.onDisconnected = {
    HelperLog.logger.notice("Socket disconnected, will reconnect")
    scheduleConnect(delay: 2.0)
}

// Start connection attempts (non-blocking)
scheduleConnect()

// Read from stdin (Chrome extension messages) on a background thread
DispatchQueue.global(qos: .userInteractive).async {
    while true {
        guard let message = NativeMessaging.readMessage() else {
            HelperLog.logger.notice("stdin closed, exiting")
            exit(0)
        }

        HelperLog.logger.info("Relaying extension → app: \(String(describing: message), privacy: .public)")
        socketClient.sendMessage(message)
    }
}

// Run the main run loop — needed for DispatchQueue.main scheduling
RunLoop.main.run()
