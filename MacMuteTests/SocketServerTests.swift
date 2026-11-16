import XCTest

final class SocketServerTests: XCTestCase {
    private var socketPath: String!
    private var server: SocketServer!
    private var clients: [Int32] = []
    private var connections: [XCTestExpectation] = []
    private var connectedIDs: [ClientID] = []
    private var disconnections: [ClientID: XCTestExpectation] = [:]
    private var received: [(ClientID, [String: Any])] = []
    private var messageArrived: XCTestExpectation?

    override func setUp() {
        super.setUp()
        socketPath = NSTemporaryDirectory() + "mm-\(UUID().uuidString.prefix(8)).sock"
        startServer()
    }

    // Closing the helpers first makes a write that regressed to blocking fail with EPIPE, so the
    // suite goes red instead of hanging in stop().
    override func tearDown() {
        clients.forEach { close($0) }
        server.stop()
        unlink(socketPath)
        super.tearDown()
    }

    private func startServer(maxClients: Int = SocketServer.defaultMaxClients) {
        server = SocketServer(socketPath: socketPath, maxClients: maxClients)
        server.onClientConnected = { [weak self] id in
            guard let self else { return }
            self.connectedIDs.append(id)
            guard !self.connections.isEmpty else {
                return XCTFail("Unexpected helper \(id) connected")
            }
            self.connections.removeFirst().fulfill()
        }
        server.onClientDisconnected = { [weak self] id in
            self?.disconnections.removeValue(forKey: id)?.fulfill()
        }
        server.onMessageReceived = { [weak self] id, message in
            self?.received.append((id, message))
            self?.messageArrived?.fulfill()
        }
        server.start()
    }

    func testKeepsBothHelpersAndSendsEachMessageOnlyToItsRecipient() {
        let (first, firstID) = connectHelper()
        let (second, secondID) = connectHelper()

        XCTAssertEqual(send(["type": "to-first"], to: firstID), "sent")
        XCTAssertEqual(send(["type": "to-second"], to: secondID), "sent")

        XCTAssertEqual(readLine(from: first), #"{"type":"to-first"}"#)
        XCTAssertEqual(readLine(from: second), #"{"type":"to-second"}"#)
        XCTAssertNotEqual(firstID, secondID)
    }

    func testOneHelperDroppingDoesNotAffectTheOther() {
        let (first, firstID) = connectHelper()
        let (second, secondID) = connectHelper()

        drop(first, id: firstID)

        XCTAssertEqual(send(["type": "ping"], to: firstID), "no_socket_client")
        XCTAssertEqual(send(["type": "ping"], to: secondID), "sent")
        XCTAssertEqual(readLine(from: second), #"{"type":"ping"}"#)
    }

    func testReportsWhichHelperSentAMessage() {
        _ = connectHelper()
        let (second, secondID) = connectHelper()
        messageArrived = expectation(description: "message received")

        writeLine(#"{"type":"state_update","muted":true}"#, to: second)
        wait(for: [messageArrived!], timeout: 2)

        XCTAssertEqual(received.first?.0, secondID)
        XCTAssertEqual(received.first?.1["muted"] as? Bool, true)
    }

    func testAcceptsAHelperAgainAfterThePreviousOneDropped() {
        let (first, firstID) = connectHelper()
        drop(first, id: firstID)

        let (second, secondID) = connectHelper()

        XCTAssertNotEqual(secondID, firstID)
        XCTAssertEqual(send(["type": "ping"], to: firstID), "no_socket_client")
        XCTAssertEqual(send(["type": "pong"], to: secondID), "sent")
        XCTAssertEqual(readLine(from: second), #"{"type":"pong"}"#)
    }

    func testStopClosesTheHelperConnections() {
        let (helper, _) = connectHelper()

        server.stop()

        XCTAssertTrue(waitForEndOfStream(on: helper))
    }

    func testFramesLinesPerHelperAcrossAndWithinWrites() {
        let (first, firstID) = connectHelper()
        let (second, secondID) = connectHelper()
        messageArrived = expectation(description: "messages received")
        messageArrived?.expectedFulfillmentCount = 4

        writeRaw(#"{"type":"a","#, to: first)
        writeRaw(#"{"type":"b"#, to: second)
        writeRaw(#""n":1}"#, to: first)
        writeRaw("\n" + #"{"type":"c"}"# + "\n", to: first)
        writeRaw(#""}"# + "\n" + #"{"type":"d"}"# + "\n", to: second)
        wait(for: [messageArrived!], timeout: 2)

        let fromFirst = received.filter { $0.0 == firstID }.compactMap { $0.1["type"] as? String }
        let fromSecond = received.filter { $0.0 == secondID }.compactMap { $0.1["type"] as? String }
        XCTAssertEqual(fromFirst, ["a", "c"])
        XCTAssertEqual(fromSecond, ["b", "d"])
    }

    func testClosesHelpersBeyondTheLimitAndKeepsTheOthers() {
        server.stop()
        startServer(maxClients: 1)
        let (first, firstID) = connectHelper()

        let extra = rawConnect()

        XCTAssertTrue(waitForEndOfStream(on: extra))
        XCTAssertEqual(send(["type": "ping"], to: firstID), "sent")
        XCTAssertEqual(readLine(from: first), #"{"type":"ping"}"#)
    }

    func testDisconnectsAHelperThatSendsALineLongerThanTheLimit() {
        let (helper, id) = connectHelper()
        let disconnected = expectDisconnection(of: id)

        let oversized = [UInt8](repeating: UInt8(ascii: "a"), count: LineFramer.defaultMaxLineLength + 1)
        _ = oversized.withUnsafeBytes { Darwin.write(helper, $0.baseAddress, $0.count) }

        XCTAssertTrue(waitForEndOfStream(on: helper))
        wait(for: [disconnected], timeout: 2)
    }

    func testDisconnectsAHelperThatStopsReadingWithoutBlockingTheOthers() {
        let (_, stuckID) = connectHelper()
        let (other, otherID) = connectHelper()
        let disconnected = expectDisconnection(of: stuckID)
        let bulky: [String: Any] = ["type": "bulk", "padding": String(repeating: "x", count: 32 * 1024)]

        var outcome = send(bulky, to: stuckID)
        for _ in 0..<100 where outcome == "sent" {
            outcome = send(bulky, to: stuckID)
        }

        XCTAssertEqual(outcome, "write_failed")
        wait(for: [disconnected], timeout: 2)
        XCTAssertEqual(send(["type": "ping"], to: otherID), "sent")
        XCTAssertEqual(readLine(from: other), #"{"type":"ping"}"#)
    }

    func testStopReturnsWhileAHelperIsNotReading() {
        let (_, stuckID) = connectHelper()
        let bulky: [String: Any] = ["type": "bulk", "padding": String(repeating: "x", count: 32 * 1024)]
        var outcome = send(bulky, to: stuckID)
        for _ in 0..<100 where outcome == "sent" {
            outcome = send(bulky, to: stuckID)
        }
        let stopped = expectation(description: "stop returned")

        DispatchQueue.global().async { [server] in
            server?.stop()
            stopped.fulfill()
        }

        wait(for: [stopped], timeout: 2)
    }

    // MARK: - Helpers

    private func connectHelper(file: StaticString = #filePath, line: UInt = #line) -> (Int32, ClientID) {
        let connected = expectation(description: "helper connected")
        connections.append(connected)
        let fd = rawConnect(file: file, line: line)
        wait(for: [connected], timeout: 2)
        return (fd, connectedIDs.last ?? -1)
    }

    private func rawConnect(file: StaticString = #filePath, line: UInt = #line) -> Int32 {
        let deadline = Date().addingTimeInterval(2)
        var fd: Int32 = -1
        while Date() < deadline {
            fd = socket(AF_UNIX, SOCK_STREAM, 0)
            if connectUnix(fd, to: socketPath) == 0 { break }
            close(fd)
            fd = -1
            usleep(10_000)
        }
        guard fd >= 0 else {
            XCTFail("Could not connect to \(socketPath!)", file: file, line: line)
            return -1
        }
        var timeout = timeval(tv_sec: 0, tv_usec: 300_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        clients.append(fd)
        return fd
    }

    private func expectDisconnection(of id: ClientID) -> XCTestExpectation {
        let disconnected = expectation(description: "helper \(id) disconnected")
        disconnections[id] = disconnected
        return disconnected
    }

    private func drop(_ fd: Int32, id: ClientID) {
        let disconnected = expectDisconnection(of: id)
        close(fd)
        clients.removeAll { $0 == fd }
        wait(for: [disconnected], timeout: 2)
    }

    private func send(_ message: [String: Any], to client: ClientID) -> String? {
        let sent = expectation(description: "message sent")
        var outcome: String?
        server.sendMessage(message, to: client) { result in
            switch result {
            case .success: outcome = "sent"
            case let .failure(error): outcome = error.rawValue
            }
            sent.fulfill()
        }
        wait(for: [sent], timeout: 2)
        return outcome
    }

    private func writeLine(_ line: String, to fd: Int32) {
        writeRaw(line + "\n", to: fd)
    }

    private func writeRaw(_ text: String, to fd: Int32) {
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
    }

    private func readLine(from fd: Int32) -> String? {
        var buffer = [UInt8](repeating: 0, count: 1024)
        let count = read(fd, &buffer, buffer.count)
        guard count > 0 else { return nil }
        return String(decoding: buffer[0..<count], as: UTF8.self)
            .trimmingCharacters(in: .newlines)
    }

    private func waitForEndOfStream(on fd: Int32) -> Bool {
        let deadline = Date().addingTimeInterval(2)
        var buffer = [UInt8](repeating: 0, count: 1024)
        while Date() < deadline {
            let count = read(fd, &buffer, buffer.count)
            if count == 0 { return true }
            if count < 0 && errno != EAGAIN && errno != EINTR { return true }
        }
        return false
    }

    private func connectUnix(_ fd: Int32, to path: String) -> Int32 {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { sunPath in
            path.utf8CString.withUnsafeBytes { bytes in
                sunPath.copyMemory(from: UnsafeRawBufferPointer(rebasing: bytes.prefix(sunPath.count - 1)))
            }
        }
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }
}
