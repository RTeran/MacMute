import Foundation

class SocketServer {
    private let socketPath: String
    private var serverSocket: Int32 = -1
    private var clientSocket: Int32 = -1
    private var listenSource: DispatchSourceRead?
    private var readSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "com.macmute.socket", qos: .userInteractive)

    var onMessageReceived: (([String: Any]) -> Void)?
    var onClientConnected: (() -> Void)?

    init() {
        let appSupport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MacMute")
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        self.socketPath = appSupport.appendingPathComponent("macmute.sock").path
    }

    func start() {
        queue.async { [weak self] in
            self?.startServer()
        }
    }

    func stop() {
        listenSource?.cancel()
        readSource?.cancel()
        if clientSocket >= 0 { close(clientSocket) }
        if serverSocket >= 0 { close(serverSocket) }
        unlink(socketPath)
    }

    /// `completion` runs on the main queue with `false` when no helper is connected or the write fails.
    func sendMessage(_ message: [String: Any], completion: ((Bool) -> Void)? = nil) {
        queue.async { [weak self] in
            let sent = self?.write(message) ?? false
            if let completion = completion {
                DispatchQueue.main.async { completion(sent) }
            }
        }
    }

    private func write(_ message: [String: Any]) -> Bool {
        guard clientSocket >= 0 else {
            NSLog("MacMute: No client connected, cannot send message")
            return false
        }

        guard let data = try? JSONSerialization.data(withJSONObject: message) else {
            NSLog("MacMute: Failed to serialize message: \(message)")
            return false
        }
        var messageData = data
        messageData.append(0x0A) // newline delimiter

        let written = messageData.withUnsafeBytes { rawBuffer -> Int in
            guard let ptr = rawBuffer.baseAddress else { return -1 }
            return Darwin.write(clientSocket, ptr, messageData.count)
        }
        guard written == messageData.count else {
            NSLog("MacMute: Failed to write to socket: \(String(cString: strerror(errno)))")
            return false
        }
        NSLog("MacMute: Sent message to helper: \(message)")
        return true
    }

    private func startServer() {
        // Remove existing socket file
        unlink(socketPath)

        serverSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            NSLog("MacMute: Failed to create socket: \(String(cString: strerror(errno)))")
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
            NSLog("MacMute: Failed to bind socket: \(String(cString: strerror(errno)))")
            close(serverSocket)
            return
        }

        guard listen(serverSocket, 1) == 0 else {
            NSLog("MacMute: Failed to listen on socket: \(String(cString: strerror(errno)))")
            close(serverSocket)
            return
        }

        NSLog("MacMute: Socket server listening at \(socketPath)")

        let source = DispatchSource.makeReadSource(fileDescriptor: serverSocket, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptConnection()
        }
        source.setCancelHandler { [weak self] in
            if let fd = self?.serverSocket, fd >= 0 {
                close(fd)
            }
        }
        source.resume()
        self.listenSource = source
    }

    private func acceptConnection() {
        let client = accept(serverSocket, nil, nil)
        guard client >= 0 else {
            NSLog("MacMute: Failed to accept connection: \(String(cString: strerror(errno)))")
            return
        }

        // Close previous client if any
        if clientSocket >= 0 {
            readSource?.cancel()
            close(clientSocket)
        }

        clientSocket = client
        NSLog("MacMute: Helper connected")

        startReading()

        DispatchQueue.main.async { [weak self] in
            self?.onClientConnected?()
        }
    }

    private func startReading() {
        let source = DispatchSource.makeReadSource(fileDescriptor: clientSocket, queue: queue)
        var buffer = Data()

        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            var readBuffer = [UInt8](repeating: 0, count: 4096)
            let bytesRead = read(self.clientSocket, &readBuffer, readBuffer.count)

            if bytesRead <= 0 {
                NSLog("MacMute: Helper disconnected")
                self.readSource?.cancel()
                close(self.clientSocket)
                self.clientSocket = -1
                return
            }

            buffer.append(contentsOf: readBuffer[0..<bytesRead])

            // Process newline-delimited messages
            while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let messageData = buffer[buffer.startIndex..<newlineIndex]
                buffer = Data(buffer[buffer.index(after: newlineIndex)...])

                if let json = try? JSONSerialization.jsonObject(with: messageData) as? [String: Any] {
                    DispatchQueue.main.async {
                        self.onMessageReceived?(json)
                    }
                }
            }
        }

        source.setCancelHandler { [weak self] in
            if let fd = self?.clientSocket, fd >= 0 {
                close(fd)
                self?.clientSocket = -1
            }
        }

        source.resume()
        self.readSource = source
    }
}
