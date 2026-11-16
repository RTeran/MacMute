import Foundation
import os

enum HelperLog {
    static let logger = Logger(subsystem: "com.macmute.app", category: "helper")
}

enum SocketClientState: Equatable {
    case connected
    case waiting(retryIn: TimeInterval)
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

/// Keeps a connection to the MacMute app, reconnecting with a growing delay while it is not running.
/// Every piece of connection state is only touched on `queue`.
final class SocketClient {
    static let defaultBackoff = RetryBackoff(first: 0.5, maximum: 10)
    static let defaultMaxLineLength = LineFramer.defaultMaxLineLength

    private let socketPath: String
    private let maxLineLength: Int
    private let queue = DispatchQueue(label: "com.macmute.helper.socket")
    private var backoff: RetryBackoff
    private var socketFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var pendingRetry: DispatchWorkItem?
    private var isRunning = false

    /// Called on the client's queue.
    var onMessageReceived: (([String: Any]) -> Void)?
    /// Called on the client's queue.
    var onStateChange: ((SocketClientState) -> Void)?

    convenience init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.init(socketPath: home.appendingPathComponent("Library/Application Support/MacMute/macmute.sock").path)
    }

    init(socketPath: String, backoff: RetryBackoff = SocketClient.defaultBackoff, maxLineLength: Int = SocketClient.defaultMaxLineLength) {
        self.socketPath = socketPath
        self.backoff = backoff
        self.maxLineLength = maxLineLength
    }

    private var socketName: String { (socketPath as NSString).lastPathComponent }

    func start() {
        queue.async { [weak self] in
            guard let self, !self.isRunning else { return }
            self.isRunning = true
            self.connect()
        }
    }

    // The read source's cancel handler owns closing the fd.
    func stop() {
        dispatchPrecondition(condition: .notOnQueue(queue))
        queue.sync {
            isRunning = false
            pendingRetry?.cancel()
            pendingRetry = nil
            readSource?.cancel()
            readSource = nil
            socketFD = -1
        }
    }

    func sendMessage(_ message: [String: Any]) {
        queue.async { [weak self] in
            guard let self, self.socketFD >= 0 else {
                HelperLog.logger.error("Cannot send to app, not connected: \(preview(message), privacy: .public)")
                return
            }

            var messageData: Data
            do {
                messageData = try JSONSerialization.data(withJSONObject: message)
            } catch {
                HelperLog.logger.error("Failed to serialize message for app \(preview(message), privacy: .public): \(error.localizedDescription, privacy: .public)")
                return
            }
            messageData.append(0x0A)

            let (written, writeErrno) = writeFully(self.socketFD, messageData)
            if written != messageData.count {
                let cause = writeErrno.map { String(cString: strerror($0)) } ?? "no buffer"
                HelperLog.logger.error("Write to app failed (\(written, privacy: .public)/\(messageData.count, privacy: .public) bytes): \(cause, privacy: .public)")
            }
        }
    }

    private func connect() {
        guard var address = Self.address(for: socketPath) else {
            HelperLog.logger.fault("Socket path \(self.socketName, privacy: .public) does not fit in a socket address")
            return
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            HelperLog.logger.error("Failed to create socket: \(String(cString: strerror(errno)), privacy: .public)")
            return scheduleRetry()
        }
        // Writing to an app that just quit must fail with EPIPE instead of killing the helper.
        var noSigPipe: Int32 = 1
        if setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size)) != 0 {
            HelperLog.logger.error("Failed to set SO_NOSIGPIPE: \(String(cString: strerror(errno)), privacy: .public)")
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            HelperLog.logger.info("Failed to connect to socket \(self.socketName, privacy: .public): \(String(cString: strerror(errno)), privacy: .public)")
            close(fd)
            return scheduleRetry()
        }

        HelperLog.logger.notice("Connected to MacMute app")
        socketFD = fd
        backoff.reset()
        startReading(fd)
        onStateChange?(.connected)
    }

    private func scheduleRetry() {
        let delay = backoff.nextDelay()
        let retry = DispatchWorkItem { [weak self] in
            guard let self, self.isRunning else { return }
            self.pendingRetry = nil
            self.connect()
        }
        pendingRetry = retry
        queue.asyncAfter(deadline: .now() + delay, execute: retry)
        onStateChange?(.waiting(retryIn: delay))
    }

    private func startReading(_ fd: Int32) {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        var framer = LineFramer(maxLineLength: maxLineLength)

        source.setEventHandler { [weak self, unowned source] in
            guard let self else { return }
            var readBuffer = [UInt8](repeating: 0, count: 4096)
            let bytesRead = read(fd, &readBuffer, readBuffer.count)

            guard bytesRead > 0 else {
                let cause = bytesRead < 0 ? String(cString: strerror(errno)) : "end of stream"
                return self.disconnect(fd, source: source, reason: cause)
            }

            let lines: [Data]
            do {
                lines = try framer.append(Data(readBuffer[0..<bytesRead]))
            } catch {
                return self.disconnect(fd, source: source, reason: "line over the \(self.maxLineLength) byte limit")
            }
            for line in lines {
                guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    HelperLog.logger.error("Dropping undecodable message from app: \(preview(String(decoding: line, as: UTF8.self)), privacy: .public)")
                    continue
                }
                self.onMessageReceived?(json)
            }
        }

        source.setCancelHandler {
            close(fd)
        }

        source.resume()
        readSource = source
    }

    private func disconnect(_ fd: Int32, source: DispatchSourceRead, reason: String) {
        HelperLog.logger.notice("Disconnected from app (\(reason, privacy: .public))")
        source.cancel()
        guard socketFD == fd else { return }
        socketFD = -1
        readSource = nil
        if isRunning { scheduleRetry() }
    }

    private static func address(for path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }
}
