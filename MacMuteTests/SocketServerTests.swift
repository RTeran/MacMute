import XCTest

final class SocketServerTests: XCTestCase {
    private var socketPath: String!
    private var server: SocketServer!
    private var clients: [Int32] = []
    private var connections: [XCTestExpectation] = []

    override func setUp() {
        super.setUp()
        socketPath = NSTemporaryDirectory() + "mm-\(UUID().uuidString.prefix(8)).sock"
        server = SocketServer(socketPath: socketPath)
        server.onClientConnected = { [weak self] in
            self?.connections.removeFirst().fulfill()
        }
        server.start()
    }

    override func tearDown() {
        server.stop()
        clients.forEach { close($0) }
        unlink(socketPath)
        super.tearDown()
    }

    func testKeepsTheNewestHelperWhenASecondOneConnects() {
        let first = connectHelper()
        let second = connectHelper()

        XCTAssertEqual(send(["type": "ping"]), "sent")
        XCTAssertEqual(readLine(from: second), #"{"type":"ping"}"#)
        XCTAssertEqual(readLine(from: first), nil)
    }

    func testAcceptsAHelperAgainAfterThePreviousOneDropped() {
        let first = connectHelper()
        XCTAssertEqual(send(["type": "ping"]), "sent")
        XCTAssertEqual(readLine(from: first), #"{"type":"ping"}"#)
        close(first)
        clients.removeAll { $0 == first }

        let second = connectHelper()

        XCTAssertEqual(send(["type": "pong"]), "sent")
        XCTAssertEqual(readLine(from: second), #"{"type":"pong"}"#)
    }

    private func connectHelper(file: StaticString = #filePath, line: UInt = #line) -> Int32 {
        let connected = expectation(description: "helper connected")
        connections.append(connected)

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
        clients.append(fd)
        wait(for: [connected], timeout: 2)
        return fd
    }

    private func send(_ message: [String: Any]) -> String? {
        let sent = expectation(description: "message sent")
        var outcome: String?
        server.sendMessage(message) { result in
            switch result {
            case .success: outcome = "sent"
            case let .failure(error): outcome = error.rawValue
            }
            sent.fulfill()
        }
        wait(for: [sent], timeout: 2)
        return outcome
    }

    private func readLine(from fd: Int32) -> String? {
        var buffer = [UInt8](repeating: 0, count: 1024)
        let count = read(fd, &buffer, buffer.count)
        guard count > 0 else { return nil }
        return String(decoding: buffer[0..<count], as: UTF8.self)
            .trimmingCharacters(in: .newlines)
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
