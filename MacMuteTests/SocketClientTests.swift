import os
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
        let received = expectation(description: "message from the app")
        client.onMessageReceived = { message in
            XCTAssertEqual(message["type"] as? String, "get_state")
            received.fulfill()
        }
        let connected = expectHelper()
        client.start()
        wait(for: [connected], timeout: 2)

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
        let reconnected = expectState(.connected)
        server?.start()

        wait(for: [reconnected], timeout: 2)
    }

    func testStopsWhenTheSocketPathIsTooLong() {
        socketPath = socketDirectory.appendingPathComponent(String(repeating: "d", count: 60)).appendingPathComponent(String(repeating: "s", count: 60)).path
        client = makeClient()
        let stopped = expectState(.stopped(.socketPathTooLong))

        client.start()

        wait(for: [stopped], timeout: 2)
        assertStaysStopped(.socketPathTooLong)
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketDirectory.path))
    }

    // The reply is queued from the client's own queue, so it is written before the client reads the
    // end of stream; without SO_NOSIGPIPE that write would kill the test process.
    func testSurvivesWritingToAnAppThatJustQuit() throws {
        let app = try FakeApp(path: socketPath)
        let connected = expectState(.connected)
        client.start()
        let connection = try app.acceptConnection()
        wait(for: [connected], timeout: 2)
        client.onMessageReceived = { [client] _ in
            app.close(connection)
            usleep(20_000)
            for _ in 0..<5 { client?.sendMessage(["type": "state_update"]) }
        }
        let retry = expectState(.waiting(retryIn: 0.02))

        app.write(#"{"type":"get_state"}"# + "\n", to: connection)

        wait(for: [retry], timeout: 2)
    }

    func testDropsAndReconnectsWhenTheAppStopsReading() throws {
        let app = try FakeApp(path: socketPath)
        let connected = expectState(.connected)
        client.start()
        _ = try app.acceptConnection()
        wait(for: [connected], timeout: 2)
        let retry = expectState(.waiting(retryIn: 0.02))

        let padding = String(repeating: "x", count: 1024)
        for _ in 0..<512 { client.sendMessage(["type": "state_update", "padding": padding]) }

        wait(for: [retry], timeout: 2)
        let reconnected = expectState(.connected)
        _ = try app.acceptConnection()
        wait(for: [reconnected], timeout: 2)
    }

    func testSplitsTwoMessagesThatArriveInOneWrite() throws {
        let app = try FakeApp(path: socketPath)
        var types: [String] = []
        let received = expectation(description: "two messages")
        received.expectedFulfillmentCount = 2
        client.onMessageReceived = { message in
            DispatchQueue.main.async { types.append(message["type"] as? String ?? "") }
            received.fulfill()
        }
        client.start()
        let connection = try app.acceptConnection()

        app.write(#"{"type":"a"}"# + "\n" + #"{"type":"b"}"# + "\n", to: connection)

        wait(for: [received], timeout: 2)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(types, ["a", "b"])
    }

    func testJoinsAMessageThatArrivesInTwoWrites() throws {
        let app = try FakeApp(path: socketPath)
        let received = expectation(description: "joined message")
        client.onMessageReceived = { message in
            XCTAssertEqual(message["type"] as? String, "joined")
            received.fulfill()
        }
        client.start()
        let connection = try app.acceptConnection()

        app.write(#"{"type":"jo"#, to: connection)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        app.write(#"ined"}"# + "\n", to: connection)

        wait(for: [received], timeout: 2)
    }

    func testDropsALineThatIsNotJSONAndStaysConnected() throws {
        let app = try FakeApp(path: socketPath)
        let received = expectation(description: "message after the bad line")
        client.onMessageReceived = { message in
            XCTAssertEqual(message["type"] as? String, "good")
            received.fulfill()
        }
        let connected = expectState(.connected)
        client.start()
        let connection = try app.acceptConnection()
        wait(for: [connected], timeout: 2)

        app.write("not json\n" + #"{"type":"good"}"# + "\n", to: connection)

        wait(for: [received], timeout: 2)
        XCTAssertEqual(states.last, .connected)
    }

    func testStartingTwiceOpensOneConnection() {
        startServer()
        let connected = expectHelper()

        client.start()
        client.start()

        wait(for: [connected], timeout: 2)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(helperIDs.count, 1)
    }

    func testStopClosesALiveConnectionWithoutRetrying() {
        startServer()
        let connected = expectState(.connected)
        let helperAccepted = expectHelper()
        client.start()
        wait(for: [connected, helperAccepted], timeout: 2)
        let disconnected = expectation(description: "app sees the helper leave")
        server?.onClientDisconnected = { _ in disconnected.fulfill() }

        client.stop()

        wait(for: [disconnected], timeout: 2)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(states.last, .connected)
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

    func testAWriteThatFindsTheAppGoneBeforeAnyDataCountsAsARejection() throws {
        let app = try FakeApp(path: socketPath)
        client = makeClient(verifyApp: { [weak self] in
            .success { _ in
                guard let connection = try? app.acceptConnection() else { return .failure(.peerTokenUnavailable(errno: ENOTCONN)) }
                app.close(connection)
                self?.client.sendMessage(["type": "state_update"])
                return .success(())
            }
        }, maxConnectionsWithoutData: 1)
        var disconnects: [(end: SocketClient.ConnectionEnd, reason: String)] = []
        client.onDisconnect = { end, reason in DispatchQueue.main.async { disconnects.append((end, reason)) } }
        let stopped = expectState(.stopped(.rejectedByApp))

        client.start()

        wait(for: [stopped], timeout: 2)
        XCTAssertEqual(disconnects.count, 1)
        XCTAssertEqual(disconnects.first?.end, .closedByApp)
        XCTAssertEqual(disconnects.first?.reason.hasPrefix("write failed"), true, disconnects.first?.reason ?? "")
        XCTAssertEqual(disconnects.first?.reason.contains(#"type:String="state_update""#), true, disconnects.first?.reason ?? "")
    }

    func testOnlyACleanCloseByTheAppCanMeanARejection() {
        XCTAssertEqual(SocketClient.connectionEnd(afterReadReturning: 0), .closedByApp)
        XCTAssertEqual(SocketClient.connectionEnd(afterReadReturning: -1), .failed)
        XCTAssertEqual(SocketClient.connectionEnd(afterWriteFailingWith: EPIPE), .closedByApp)
        XCTAssertEqual(SocketClient.connectionEnd(afterWriteFailingWith: ECONNRESET), .failed)
        XCTAssertEqual(SocketClient.connectionEnd(afterWriteFailingWith: EAGAIN), .failed)
        XCTAssertEqual(SocketClient.connectionEnd(afterWriteFailingWith: nil), .failed)
    }

    func testAnAppThatFailsVerificationDoesNotChangeTheRejectionCount() {
        var attempts = 0
        client = makeClient(verifyApp: {
            .success { _ in
                attempts += 1
                return attempts == 2 ? .failure(.requirementNotSatisfied(errSecCSReqFailed)) : .success(())
            }
        }, maxConnectionsWithoutData: 3)
        startServer(rejectingHelpers: true)
        let stopped = expectState(.stopped(.rejectedByApp))

        client.start()

        wait(for: [stopped], timeout: 2)
        XCTAssertEqual(states.filter { $0 == .connected }.count, 3)
    }

    func testReportsTheFirstUntrustedAppAsAnErrorAndRepeatsQuietlyUntilASuccess() {
        var log = UntrustedAppLog()

        XCTAssertEqual(log.levelForFailure(), .error)
        XCTAssertEqual(log.levelForFailure(), .debug)
        log.trustedAppConnected()
        XCTAssertEqual(log.levelForFailure(), .error)
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

    func testAnAdHocHelperBuildsItsRequirementFromTheContainingApp() throws {
        let app = socketDirectory.appendingPathComponent("Fake.app")
        let helper = app.appendingPathComponent("Contents/Resources/MacMuteHelper")
        try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Bundle(for: Self.self).bundleURL, to: helper)
        let helperCode = try staticCode(at: helper)
        try skipUnlessAdHoc(helperCode)

        let result = SocketClient.trustedAppCheck(ownCode: { .success(helperCode) })()

        guard case let .failure(.expectedCodeUnavailable(path, _)) = result else {
            return XCTFail("Expected the requirement to read the containing app, got \(result)")
        }
        XCTAssertEqual(URL(fileURLWithPath: path).resolvingSymlinksInPath().path, app.resolvingSymlinksInPath().path)
    }

    func testASignedHelperInsideAnAppBuildsARequirementThatOtherCodeFails() throws {
        let helper = socketDirectory.appendingPathComponent("Fake.app/Contents/Resources/MacMuteHelper")
        try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/ls"), to: helper)
        let helperCode = try staticCode(at: helper)
        var sockets: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        defer { sockets.forEach { close($0) } }

        let verify = try SocketClient.trustedAppCheck(ownCode: { .success(helperCode) })().get()

        guard case .failure(.requirementNotSatisfied) = verify(sockets[0]) else {
            return XCTFail("Expected the test process to fail the app requirement")
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

    private func staticCode(at url: URL) throws -> SecStaticCode {
        var code: SecStaticCode?
        XCTAssertEqual(SecStaticCodeCreateWithPath(url as CFURL, [], &code), errSecSuccess)
        return try XCTUnwrap(code)
    }

    private func skipUnlessAdHoc(_ code: SecStaticCode) throws {
        var info: CFDictionary?
        XCTAssertEqual(SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info), errSecSuccess)
        if let certificates = (info as? [String: Any])?[kSecCodeInfoCertificates as String] as? [Any], !certificates.isEmpty {
            throw XCTSkip("The test bundle is signed with a certificate; this test needs an ad-hoc one")
        }
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

private final class FakeApp {
    struct Failure: Error { let step: String; let code: Int32 }

    private let listener: Int32
    private var connections: [Int32] = []

    init(path: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { throw Failure(step: "bind", code: errno) }
        guard listen(listener, 4) == 0 else { throw Failure(step: "listen", code: errno) }
    }

    deinit {
        connections.forEach { close($0) }
        close(listener)
    }

    func acceptConnection() throws -> Int32 {
        var ready = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        guard poll(&ready, 1, 2000) == 1 else { throw Failure(step: "poll", code: errno) }
        let connection = accept(listener, nil, nil)
        guard connection >= 0 else { throw Failure(step: "accept", code: errno) }
        var noSigPipe: Int32 = 1
        setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        connections.append(connection)
        return connection
    }

    func close(_ connection: Int32) {
        connections.removeAll { $0 == connection }
        Darwin.close(connection)
    }

    func write(_ text: String, to connection: Int32) {
        let bytes = Array(text.utf8)
        XCTAssertEqual(Darwin.write(connection, bytes, bytes.count), bytes.count)
    }
}
