import Foundation
import Security
import os

enum SocketClientState: Equatable {
    case connected
    case waiting(retryIn: TimeInterval)
    case stopped(SocketClientStopReason)
}

enum SocketClientStopReason: Equatable {
    case rejectedByApp
    case socketPathTooLong
    /// This helper's own signature or location leaves no app it could trust.
    case cannotVerifyApp(PeerVerificationError)
}

/// An impostor on the socket is retried with backoff for as long as it stays there, so only the
/// first failure since the last trusted connection is worth an error.
struct UntrustedAppLog {
    private var reportedSinceLastSuccess = false

    mutating func levelForFailure() -> OSLogType {
        defer { reportedSinceLastSuccess = true }
        return reportedSinceLastSuccess ? .debug : .error
    }

    mutating func trustedAppConnected() {
        reportedSinceLastSuccess = false
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

/// Keeps a connection to the MacMute app, reconnecting with a growing delay while it is not running.
/// Every piece of connection state is only touched on `queue`.
final class SocketClient {
    static let defaultBackoff = RetryBackoff(first: 0.5, maximum: 10)
    static let defaultMaxLineLength = LineFramer.defaultMaxLineLength
    static let defaultMaxConnectionsWithoutData = 3

    typealias VerifyApp = (Int32) -> Result<Void, PeerVerificationError>
    typealias MakeVerifyApp = () -> Result<VerifyApp, PeerVerificationError>

    private let socketPath: String
    private let maxLineLength: Int
    private let maxConnectionsWithoutData: Int
    private let makeVerifyApp: MakeVerifyApp
    private var connectionsWithoutData = 0
    private var receivedDataOnConnection = false
    private var untrustedAppLog = UntrustedAppLog()
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
    /// Called on the client's queue with why a live connection ended.
    var onDisconnect: ((ConnectionEnd, String) -> Void)?

    /// Only talks to the app that bundles this helper; see `PeerCodeVerifier.trustedAppRequirement`.
    convenience init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.init(
            socketPath: home.appendingPathComponent("Library/Application Support/MacMute/macmute.sock").path,
            makeVerifyApp: Self.trustedAppCheck(ownCode: PeerCodeVerifier.ownStaticCode)
        )
    }

    /// `makeVerifyApp` runs before every connection attempt, so a rebuilt app is judged by its
    /// signature on disk at that moment.
    init(
        socketPath: String,
        makeVerifyApp: @escaping MakeVerifyApp,
        backoff: RetryBackoff = SocketClient.defaultBackoff,
        maxLineLength: Int = SocketClient.defaultMaxLineLength,
        maxConnectionsWithoutData: Int = SocketClient.defaultMaxConnectionsWithoutData
    ) {
        self.socketPath = socketPath
        self.makeVerifyApp = makeVerifyApp
        self.backoff = backoff
        self.maxLineLength = maxLineLength
        self.maxConnectionsWithoutData = maxConnectionsWithoutData
    }

    static func trustedAppCheck(ownCode: @escaping () -> Result<SecStaticCode, PeerVerificationError>) -> MakeVerifyApp {
        {
            ownCode().flatMap { helper in
                PeerCodeVerifier.path(of: helper).flatMap { path -> Result<SecRequirement, PeerVerificationError> in
                    guard let app = PeerCodeVerifier.containingApp(ofHelperAt: path) else { return .failure(.notInsideAnApp) }
                    return PeerCodeVerifier.trustedAppRequirement(signedLike: helper, appIdentifier: PeerCodeVerifier.appIdentifier, containingApp: app)
                }
            }
            .map { requirement in { socket in PeerCodeVerifier.verify(socket: socket, against: requirement) } }
        }
    }

    private var socketName: String { (socketPath as NSString).lastPathComponent }

    enum ConnectionEnd: Equatable {
        case closedByApp
        case failed
    }

    // A reset or any other error can come from an app that crashed while restarting, so only a
    // clean close can be the app turning this helper away.
    static func connectionEnd(afterReadReturning result: Int) -> ConnectionEnd {
        result == 0 ? .closedByApp : .failed
    }

    static func connectionEnd(afterWriteFailingWith code: Int32?) -> ConnectionEnd {
        code == EPIPE ? .closedByApp : .failed
    }

    func start() {
        queue.async { [weak self] in
            guard let self, !self.isRunning else { return }
            self.isRunning = true
            self.connectionsWithoutData = 0
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

            let fd = self.socketFD
            let (written, writeErrno) = writeFully(fd, messageData)
            // A partial line would glue itself to the next message, so the connection is unusable.
            if written != messageData.count, let source = self.readSource {
                let cause = writeErrno.map { String(cString: strerror($0)) } ?? "no buffer"
                self.disconnect(
                    fd, source: source,
                    reason: "write failed after \(written)/\(messageData.count) bytes (\(cause)), dropping \(preview(message))",
                    level: writeErrno == EPIPE ? .default : .error, end: Self.connectionEnd(afterWriteFailingWith: writeErrno)
                )
            }
        }
    }

    private func connect() {
        let verifyApp: VerifyApp
        switch makeVerifyApp() {
        case let .success(verify):
            verifyApp = verify
        case let .failure(error) where Self.leavesNoAppToTrust(error):
            HelperLog.logger.fault("Cannot verify the MacMute app, giving up: \(error.description, privacy: .public)")
            return finish(.cannotVerifyApp(error))
        case let .failure(error):
            HelperLog.logger.error("Cannot verify the MacMute app yet: \(error.description, privacy: .public)")
            return scheduleRetry()
        }
        guard var address = Self.address(for: socketPath) else {
            HelperLog.logger.fault("Socket path \(self.socketName, privacy: .public) does not fit in a socket address, giving up")
            return finish(.socketPathTooLong)
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
            let code = errno
            let level: OSLogType = code == ENOENT || code == ECONNREFUSED ? .info : .error
            HelperLog.logger.log(level: level, "Failed to connect to socket \(self.socketName, privacy: .public): \(String(cString: strerror(code)), privacy: .public)")
            close(fd)
            return scheduleRetry()
        }

        // Like SocketServer: an app that stops reading must not block this queue on write; the
        // write fails with EAGAIN instead and the connection is dropped.
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            HelperLog.logger.error("Failed to make the app socket non-blocking: \(String(cString: strerror(errno)), privacy: .public)")
            close(fd)
            return scheduleRetry()
        }

        if case let .failure(error) = verifyApp(fd) {
            let pid = PeerCodeVerifier.peerProcessID(of: fd).map(String.init) ?? "unknown"
            HelperLog.logger.log(level: untrustedAppLog.levelForFailure(), "Not talking to process \(pid, privacy: .public) at \(self.socketName, privacy: .public): \(error.description, privacy: .public)")
            close(fd)
            return scheduleRetry()
        }

        HelperLog.logger.notice("Connected to MacMute app")
        socketFD = fd
        receivedDataOnConnection = false
        untrustedAppLog.trustedAppConnected()
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
            var bytesRead: Int
            repeat { bytesRead = read(fd, &readBuffer, readBuffer.count) } while bytesRead < 0 && errno == EINTR
            if bytesRead < 0, errno == EAGAIN { return }

            guard bytesRead > 0 else {
                let code = errno
                let cause = bytesRead < 0 ? String(cString: strerror(code)) : "end of stream"
                return self.disconnect(
                    fd, source: source, reason: cause, level: bytesRead == 0 ? .default : .error,
                    end: Self.connectionEnd(afterReadReturning: bytesRead)
                )
            }
            if !self.receivedDataOnConnection {
                self.receivedDataOnConnection = true
                self.connectionsWithoutData = 0
            }

            let lines: [Data]
            do {
                lines = try framer.append(Data(readBuffer[0..<bytesRead]))
            } catch {
                return self.disconnect(fd, source: source, reason: "line over the \(self.maxLineLength) byte limit", level: .error, end: .failed)
            }
            for line in lines {
                let object: Any
                do {
                    object = try JSONSerialization.jsonObject(with: line)
                } catch {
                    HelperLog.logger.error("Dropping a \(line.count, privacy: .public) byte line from the app that is not JSON: \(jsonErrorDescription(error), privacy: .public)")
                    continue
                }
                guard let message = object as? [String: Any] else {
                    HelperLog.logger.error("Dropping a \(line.count, privacy: .public) byte line from the app that is not a JSON object")
                    continue
                }
                self.onMessageReceived?(message)
            }
        }

        source.setCancelHandler {
            close(fd)
        }

        source.resume()
        readSource = source
    }

    // The app sends get_state to every helper it accepts, so a connection it closes before
    // sending anything means it rejected this helper; retrying forever would only fill both logs.
    private func disconnect(_ fd: Int32, source: DispatchSourceRead, reason: String, level: OSLogType, end: ConnectionEnd) {
        HelperLog.logger.log(level: level, "Disconnected from app (\(reason, privacy: .public))")
        onDisconnect?(end, reason)
        source.cancel()
        guard socketFD == fd else { return }
        socketFD = -1
        readSource = nil
        guard isRunning else { return }
        if end == .closedByApp, !receivedDataOnConnection {
            connectionsWithoutData += 1
            if connectionsWithoutData >= maxConnectionsWithoutData {
                HelperLog.logger.fault("The app closed \(self.connectionsWithoutData, privacy: .public) connections in a row before sending anything, so it rejects this helper; giving up")
                return finish(.rejectedByApp)
            }
        }
        scheduleRetry()
    }

    private func finish(_ reason: SocketClientStopReason) {
        isRunning = false
        pendingRetry?.cancel()
        pendingRetry = nil
        onStateChange?(.stopped(reason))
    }

    /// A missing app on disk can come back (an update or a rebuild); the other failures cannot
    /// change while this helper process runs.
    private static func leavesNoAppToTrust(_ error: PeerVerificationError) -> Bool {
        if case .expectedCodeUnavailable = error { return false }
        return true
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
