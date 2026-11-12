import Foundation

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
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }

        let length = UInt32(data.count)
        var lengthBytes = [UInt8](repeating: 0, count: 4)
        lengthBytes[0] = UInt8(length & 0xFF)
        lengthBytes[1] = UInt8((length >> 8) & 0xFF)
        lengthBytes[2] = UInt8((length >> 16) & 0xFF)
        lengthBytes[3] = UInt8((length >> 24) & 0xFF)

        fwrite(lengthBytes, 1, 4, stdout)
        _ = data.withUnsafeBytes { rawBuffer in
            fwrite(rawBuffer.baseAddress, 1, data.count, stdout)
        }
        fflush(stdout)
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
            NSLog("MacMuteHelper: Failed to create socket")
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
            NSLog("MacMuteHelper: Failed to connect to socket at \(socketPath): \(String(cString: strerror(errno)))")
            close(socketFD)
            socketFD = -1
            return false
        }

        // Writing to an app that just quit must fail with EPIPE instead of killing the helper.
        var noSigPipe: Int32 = 1
        if setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size)) != 0 {
            NSLog("MacMuteHelper: Failed to set SO_NOSIGPIPE: \(String(cString: strerror(errno)))")
        }

        NSLog("MacMuteHelper: Connected to MacMute app")
        startReading()
        return true
    }

    func disconnect() {
        readSource?.cancel()
        if socketFD >= 0 {
            close(socketFD)
            socketFD = -1
        }
    }

    func sendMessage(_ message: [String: Any]) {
        queue.async { [weak self] in
            guard let self = self, self.socketFD >= 0 else {
                NSLog("MacMuteHelper: Cannot send, not connected to app")
                return
            }

            guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
            var messageData = data
            messageData.append(0x0A) // newline delimiter

            messageData.withUnsafeBytes { rawBuffer in
                guard let ptr = rawBuffer.baseAddress else { return }
                let written = Darwin.write(self.socketFD, ptr, messageData.count)
                if written < 0 {
                    NSLog("MacMuteHelper: Write to socket failed: \(String(cString: strerror(errno)))")
                }
            }
        }
    }

    private func startReading() {
        let source = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: queue)
        var buffer = Data()

        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            var readBuffer = [UInt8](repeating: 0, count: 4096)
            let bytesRead = read(self.socketFD, &readBuffer, readBuffer.count)

            if bytesRead <= 0 {
                NSLog("MacMuteHelper: Disconnected from app")
                self.readSource?.cancel()
                self.socketFD = -1
                self.onDisconnected?()
                return
            }

            buffer.append(contentsOf: readBuffer[0..<bytesRead])

            while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let messageData = buffer[buffer.startIndex..<newlineIndex]
                buffer = Data(buffer[buffer.index(after: newlineIndex)...])

                guard let json = try? JSONSerialization.jsonObject(with: messageData) as? [String: Any] else {
                    NSLog("MacMuteHelper: Dropping undecodable message from app: \(String(decoding: messageData, as: UTF8.self))")
                    continue
                }
                self.onMessageReceived?(json)
            }
        }

        source.setCancelHandler { [weak self] in
            if let fd = self?.socketFD, fd >= 0 {
                close(fd)
                self?.socketFD = -1
            }
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
    NSLog("MacMuteHelper: Relaying app → extension: \(message)")
    NativeMessaging.writeMessage(message)
}

func scheduleConnect(delay: TimeInterval = 0) {
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
        if socketClient.connect() {
            NSLog("MacMuteHelper: Socket connected")
        } else {
            NSLog("MacMuteHelper: Connection failed, retrying in 2s...")
            scheduleConnect(delay: 2.0)
        }
    }
}

socketClient.onDisconnected = {
    NSLog("MacMuteHelper: Socket disconnected, will reconnect")
    scheduleConnect(delay: 2.0)
}

// Start connection attempts (non-blocking)
scheduleConnect()

// Read from stdin (Chrome extension messages) on a background thread
DispatchQueue.global(qos: .userInteractive).async {
    while true {
        guard let message = NativeMessaging.readMessage() else {
            NSLog("MacMuteHelper: stdin closed, exiting")
            exit(0)
        }

        NSLog("MacMuteHelper: Relaying extension → app: \(message)")
        socketClient.sendMessage(message)
    }
}

// Run the main run loop — needed for DispatchQueue.main scheduling
RunLoop.main.run()
