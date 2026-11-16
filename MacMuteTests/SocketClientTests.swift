import Security
import XCTest

final class SocketClientTests: XCTestCase {
    private var socketDirectory: URL!
    private var socketPath: String!
    private var server: SocketServer?
    private var client: SocketClient!
    private var states: [SocketClientState] = []
    private var awaitedState: (state: SocketClientState, arrived: XCTestExpectation)?
    private var awaitedStateRepeats = false
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

    func testDoesNotTrustAnAppThatFailsVerification() {
        client = makeClient(verifyApp: { .success { _ in .failure(.requirementNotSatisfied(errSecCSReqFailed)) } })
        startServer()
        waitUntilListening()
        let thirdRetry = expectState(.waiting(retryIn: 0.05))

        client.start()

        wait(for: [thirdRetry], timeout: 2)
        XCTAssertEqual(states, [.waiting(retryIn: 0.02), .waiting(retryIn: 0.04), .waiting(retryIn: 0.05)])
    }

    func testConnectsToAnAppThatSatisfiesTheRealRequirement() throws {
        let requirement = try ownDesignatedRequirement()
        client = makeClient(verifyApp: { .success { PeerCodeVerifier.verify(socket: $0, against: requirement) } })
        startServer()
        let connected = expectState(.connected)

        client.start()

        wait(for: [connected], timeout: 2)
    }

    func testDoesNotConnectToAnAppWithAnotherIdentifier() throws {
        var requirement: SecRequirement?
        XCTAssertEqual(SecRequirementCreateWithString(#"identifier "com.macmute.app""# as CFString, [], &requirement), errSecSuccess)
        let appRequirement = try XCTUnwrap(requirement)
        client = makeClient(verifyApp: { .success { PeerCodeVerifier.verify(socket: $0, against: appRequirement) } })
        startServer()
        waitUntilListening()
        let thirdRetry = expectState(.waiting(retryIn: 0.05))

        client.start()

        wait(for: [thirdRetry], timeout: 2)
        XCTAssertFalse(states.contains(.connected))
    }

    func testStopsWhenTheAppRejectsItRepeatedly() {
        client = makeClient(maxConnectionsWithoutData: 3)
        startServer(rejectingHelpers: true)
        let stopped = expectState(.stopped(.rejectedByApp))

        client.start()

        wait(for: [stopped], timeout: 2)
        XCTAssertEqual(states.filter { $0 == .connected }.count, 3)
        assertStaysStopped(.rejectedByApp)
    }

    func testStopsWhenTheAppRejectsItWhileTheHelperVerifiesTheApp() throws {
        let requirement = try ownDesignatedRequirement()
        client = makeClient(verifyApp: { .success { PeerCodeVerifier.verify(socket: $0, against: requirement) } }, maxConnectionsWithoutData: 3)
        startServer(rejectingHelpers: true)
        let stopped = expectState(.stopped(.rejectedByApp))

        client.start()

        wait(for: [stopped], timeout: 2)
    }

    func testDataFromTheAppStartsTheRejectionCountOver() {
        client = makeClient(maxConnectionsWithoutData: 2)
        startServer()
        var connected = expectState(.connected)
        var helperAccepted = expectHelper()
        client.start()
        wait(for: [connected, helperAccepted], timeout: 2)

        restartServer()
        connected = expectState(.connected)
        helperAccepted = expectHelper()
        wait(for: [connected, helperAccepted], timeout: 2)
        let received = expectation(description: "message from the app")
        client.onMessageReceived = { _ in received.fulfill() }
        server?.sendMessage(["type": "get_state"], to: helperIDs.last!)
        wait(for: [received], timeout: 2)

        connected = expectState(.connected)
        restartServer()
        wait(for: [connected], timeout: 2)
        connected = expectState(.connected)
        restartServer()

        wait(for: [connected], timeout: 2)
        XCTAssertFalse(states.contains(.stopped(.rejectedByApp)))
    }

    func testKeepsRetryingWhileTheAppIsNotRunning() {
        client = makeClient(maxConnectionsWithoutData: 2)
        let fourthRetry = expectState(.waiting(retryIn: 0.05))
        fourthRetry.expectedFulfillmentCount = 2
        fourthRetry.assertForOverFulfill = false
        awaitedStateRepeats = true

        client.start()

        wait(for: [fourthRetry], timeout: 2)
        XCTAssertEqual(Array(states.prefix(4)), [.waiting(retryIn: 0.02), .waiting(retryIn: 0.04), .waiting(retryIn: 0.05), .waiting(retryIn: 0.05)])
    }

    func testStopsWhenTheHelperCannotTrustAnyApp() {
        client = makeClient(verifyApp: { .failure(.ownSignatureInvalid(errSecCSStaticCodeChanged)) })
        startServer()
        server?.onClientConnected = { _ in XCTFail("the helper must not connect") }
        let stopped = expectState(.stopped(.cannotVerifyApp(.ownSignatureInvalid(errSecCSStaticCodeChanged))))

        client.start()

        wait(for: [stopped], timeout: 2)
        assertStaysStopped(.cannotVerifyApp(.ownSignatureInvalid(errSecCSStaticCodeChanged)))
    }

    func testBuildsTheAppRequirementAgainForEachConnection() {
        var attempts = 0
        client = makeClient(verifyApp: {
            attempts += 1
            guard attempts > 2 else { return .failure(.expectedCodeUnavailable(path: "/MacMute.app", status: errSecCSStaticCodeNotFound)) }
            return .success { _ in .success(()) }
        })
        startServer()
        let connected = expectState(.connected)

        client.start()

        wait(for: [connected], timeout: 2)
        XCTAssertEqual(states, [.waiting(retryIn: 0.02), .waiting(retryIn: 0.04), .connected])
    }

    func testAHelperOutsideAnAppCannotTrustAnyApp() throws {
        var code: SecStaticCode?
        XCTAssertEqual(SecStaticCodeCreateWithPath(Bundle(for: Self.self).bundleURL as CFURL, [], &code), errSecSuccess)
        let testBundle = try XCTUnwrap(code)

        let result = SocketClient.trustedAppCheck(ownCode: { .success(testBundle) })()

        guard case .failure(.notInsideAnApp) = result else {
            return XCTFail("Expected notInsideAnApp, got \(result)")
        }
    }

    func testTheHelperGivesUpAfterThreeConnectionsWithoutData() {
        XCTAssertEqual(SocketClient.defaultMaxConnectionsWithoutData, 3)
    }

    func testTheHelperBacksOffFromHalfASecondUpToTenSeconds() {
        var backoff = SocketClient.defaultBackoff

        XCTAssertEqual((0..<7).map { _ in backoff.nextDelay() }, [0.5, 1, 2, 4, 8, 10, 10])
    }

    private func makeClient(
        verifyApp: @escaping SocketClient.MakeVerifyApp = { .success { _ in .success(()) } },
        maxLineLength: Int = SocketClient.defaultMaxLineLength,
        maxConnectionsWithoutData: Int = SocketClient.defaultMaxConnectionsWithoutData
    ) -> SocketClient {
        let client = SocketClient(
            socketPath: socketPath,
            makeVerifyApp: verifyApp,
            backoff: RetryBackoff(first: 0.02, maximum: 0.05),
            maxLineLength: maxLineLength,
            maxConnectionsWithoutData: maxConnectionsWithoutData
        )
        client.onStateChange = { [weak self] state in
            DispatchQueue.main.async { self?.record(state) }
        }
        return client
    }

    private func startServer(rejectingHelpers: Bool = false) {
        let verdict: Result<Void, PeerVerificationError> = rejectingHelpers ? .failure(.requirementNotSatisfied(errSecCSReqFailed)) : .success(())
        let server = SocketServer(socketPath: socketPath, makeVerifyPeer: { .success { _ in verdict } })
        server.onClientConnected = { [weak self] id in
            self?.helperIDs.append(id)
            self?.helperConnected?.fulfill()
            self?.helperConnected = nil
        }
        server.start()
        self.server = server
    }

    private func waitUntilListening() {
        let listening = expectation(description: "server listening")
        server?.onStateChange = { [weak server] state in
            guard state == .listening else { return }
            server?.onStateChange = nil
            listening.fulfill()
        }
        wait(for: [listening], timeout: 2)
    }

    private func restartServer() {
        server?.stop()
        server?.start()
    }

    private func assertStaysStopped(_ reason: SocketClientStopReason, file: StaticString = #filePath, line: UInt = #line) {
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(states.last, .stopped(reason), "states \(states)", file: file, line: line)
        XCTAssertEqual(states.filter { $0 == .stopped(reason) }.count, 1, file: file, line: line)
    }

    private func ownDesignatedRequirement() throws -> SecRequirement {
        var code: SecCode?
        XCTAssertEqual(SecCodeCopySelf([], &code), errSecSuccess)
        var staticCode: SecStaticCode?
        XCTAssertEqual(SecCodeCopyStaticCode(try XCTUnwrap(code), [], &staticCode), errSecSuccess)
        var requirement: SecRequirement?
        XCTAssertEqual(SecCodeCopyDesignatedRequirement(try XCTUnwrap(staticCode), [], &requirement), errSecSuccess)
        return try XCTUnwrap(requirement)
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
            if !awaitedStateRepeats { awaitedState = nil }
            awaited.arrived.fulfill()
        }
    }
}
