import XCTest

final class SocketClientTests: XCTestCase {
    private var socketDirectory: URL!
    private var socketPath: String!
    private var server: SocketServer?
    private var client: SocketClient!
    private var states: [SocketClientState] = []
    private var awaitedState: (state: SocketClientState, arrived: XCTestExpectation)?
    private var helperIDs: [ClientID] = []
    private var helperConnected: XCTestExpectation?

    override func setUp() {
        super.setUp()
        socketDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mc-\(UUID().uuidString.prefix(8))")
        socketPath = socketDirectory.appendingPathComponent("s.sock").path
        client = makeClient()
    }

    override func tearDown() {
        client.stop()
        server?.stop()
        try? FileManager.default.removeItem(at: socketDirectory)
        super.tearDown()
    }

    func testRelaysMessagesFromTheApp() {
        startServer()
        let connected = expectHelper()
        client.start()
        wait(for: [connected], timeout: 2)
        let received = expectation(description: "message from the app")
        client.onMessageReceived = { message in
            XCTAssertEqual(message["type"] as? String, "get_state")
            received.fulfill()
        }

        server?.sendMessage(["type": "get_state"], to: helperIDs[0])

        wait(for: [received], timeout: 2)
    }

    func testSendsMessagesToTheApp() {
        let received = expectation(description: "message to the app")
        startServer()
        server?.onMessageReceived = { _, message in
            XCTAssertEqual(message["type"] as? String, "state_update")
            received.fulfill()
        }
        let connected = expectState(.connected)
        client.start()
        wait(for: [connected], timeout: 2)

        client.sendMessage(["type": "state_update", "muted": true])

        wait(for: [received], timeout: 2)
    }

    func testRetriesWithAGrowingDelayWhileTheAppIsNotRunning() {
        let capped = expectState(.waiting(retryIn: 0.05))

        client.start()

        wait(for: [capped], timeout: 2)
        XCTAssertEqual(Array(states.prefix(3)), [.waiting(retryIn: 0.02), .waiting(retryIn: 0.04), .waiting(retryIn: 0.05)])
    }

    func testConnectsOnceTheAppStarts() {
        let capped = expectState(.waiting(retryIn: 0.05))
        client.start()
        wait(for: [capped], timeout: 2)

        let connected = expectState(.connected)
        startServer()

        wait(for: [connected], timeout: 2)
    }

    func testStartsTheBackoffOverAfterAConnection() {
        let capped = expectState(.waiting(retryIn: 0.05))
        client.start()
        wait(for: [capped], timeout: 2)
        let connected = expectState(.connected)
        startServer()
        wait(for: [connected], timeout: 2)

        let firstDelay = expectState(.waiting(retryIn: 0.02))
        server?.stop()

        wait(for: [firstDelay], timeout: 2)
    }

    func testStopCancelsAPendingRetry() {
        let firstRetry = expectState(.waiting(retryIn: 0.02))
        client.start()
        wait(for: [firstRetry], timeout: 2)

        client.stop()
        startServer()
        let settled = expectation(description: "a retry would have run")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { settled.fulfill() }
        wait(for: [settled], timeout: 2)

        XCTAssertFalse(states.contains(.connected), "\(states)")
    }

    func testDisconnectsAndRetriesWhenTheAppSendsALineOverTheLimit() {
        client = makeClient(maxLineLength: 64)
        startServer()
        let connected = expectState(.connected)
        let helperAccepted = expectHelper()
        client.start()
        wait(for: [connected, helperAccepted], timeout: 2)
        client.onMessageReceived = { _ in XCTFail("an oversized line must not be delivered") }
        let statesBefore = states.count
        let reconnected = expectState(.connected)

        server?.sendMessage(["type": "get_state", "padding": String(repeating: "x", count: 64)], to: helperIDs[0])

        wait(for: [reconnected], timeout: 2)
        XCTAssertEqual(Array(states[statesBefore...]), [.waiting(retryIn: 0.02), .connected])
    }

    func testDeliversALineAtTheLimit() {
        client = makeClient(maxLineLength: 64)
        startServer()
        let connected = expectHelper()
        client.start()
        wait(for: [connected], timeout: 2)
        let received = expectation(description: "message at the limit")
        client.onMessageReceived = { _ in received.fulfill() }
        let message = ["type": "get_state", "padding": String(repeating: "x", count: 64 - 33)]
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: message).count, 64)

        server?.sendMessage(message, to: helperIDs[0])

        wait(for: [received], timeout: 2)
    }

    func testTheHelperAcceptsLinesUpTo64KB() {
        XCTAssertEqual(SocketClient.defaultMaxLineLength, 64 * 1024)
    }

    func testTheHelperBacksOffFromHalfASecondUpToTenSeconds() {
        var backoff = SocketClient.defaultBackoff

        XCTAssertEqual((0..<7).map { _ in backoff.nextDelay() }, [0.5, 1, 2, 4, 8, 10, 10])
    }

    private func makeClient(maxLineLength: Int = SocketClient.defaultMaxLineLength) -> SocketClient {
        let client = SocketClient(socketPath: socketPath, backoff: RetryBackoff(first: 0.02, maximum: 0.05), maxLineLength: maxLineLength)
        client.onStateChange = { [weak self] state in
            DispatchQueue.main.async { self?.record(state) }
        }
        return client
    }

    private func startServer() {
        let server = SocketServer(socketPath: socketPath, makeVerifyPeer: { .success { _ in .success(()) } })
        server.onClientConnected = { [weak self] id in
            self?.helperIDs.append(id)
            self?.helperConnected?.fulfill()
            self?.helperConnected = nil
        }
        server.start()
        self.server = server
    }

    private func expectHelper() -> XCTestExpectation {
        let connected = expectation(description: "helper connected")
        helperConnected = connected
        return connected
    }

    private func expectState(_ state: SocketClientState) -> XCTestExpectation {
        let arrived = expectation(description: "state \(state)")
        awaitedState = (state, arrived)
        return arrived
    }

    private func record(_ state: SocketClientState) {
        states.append(state)
        if let awaited = awaitedState, awaited.state == state {
            awaitedState = nil
            awaited.arrived.fulfill()
        }
    }
}
