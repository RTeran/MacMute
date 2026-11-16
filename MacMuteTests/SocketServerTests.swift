import Security
import XCTest

final class SocketServerTests: XCTestCase {
    private var socketDirectory: URL!
    private var socketPath: String!
    private var server: SocketServer!
    private var clients: [Int32] = []
    private var connections: [XCTestExpectation] = []
    private var connectedIDs: [ClientID] = []
    private var disconnections: [ClientID: XCTestExpectation] = [:]
    private var received: [(ClientID, [String: Any])] = []
    private var messageArrived: XCTestExpectation?
    private var states: [SocketServerState] = []
    private var awaitedState: (state: SocketServerState, arrived: XCTestExpectation)?
    private var serverGeneration = 0

    override func setUp() {
        super.setUp()
        socketDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mm-\(UUID().uuidString.prefix(8))")
        socketPath = socketDirectory.appendingPathComponent("s.sock").path
        startServer()
    }

    // Closing the helpers first makes a write that regressed to blocking fail with EPIPE, so the
    // suite goes red instead of hanging in stop().
    override func tearDown() {
        clients.forEach { close($0) }
        server.stop()
        chflags(socketPath, 0)
        unlink(socketPath)
        try? FileManager.default.removeItem(at: socketDirectory)
        super.tearDown()
    }

    private func startServer(
        maxClients: Int = SocketServer.defaultMaxClients,
        verifyPeer: @escaping SocketServer.VerifyPeer = { _ in .success(()) }
    ) {
        startServer(maxClients: maxClients, makeVerifyPeer: { .success(verifyPeer) })
    }

    private func startServer(maxClients: Int, makeVerifyPeer: @escaping SocketServer.MakeVerifyPeer) {
        server = SocketServer(
            socketPath: socketPath,
            maxClients: maxClients,
            retryBackoff: RetryBackoff(first: 0.02, maximum: 0.05),
            makeVerifyPeer: makeVerifyPeer
        )
        // Reports of a stopped server can still be queued on main; they must not count for this one.
        serverGeneration += 1
        states = []
        let generation = serverGeneration
        server.onStateChange = { [weak self] state in
            guard let self, generation == self.serverGeneration else { return }
            self.states.append(state)
            if let awaited = self.awaitedState, awaited.state == state {
                self.awaitedState = nil
                awaited.arrived.fulfill()
            }
        }
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

    func testClosesARejectedPeerWithoutGivingItASlot() {
        server.stop()
        var verifications = 0
        startServer(maxClients: 1) { _ in
            verifications += 1
            return verifications == 1 ? .failure(.requirementNotSatisfied(errSecCSReqFailed)) : .success(())
        }

        let rejected = rawConnect()
        writeLine(#"{"type":"state_update","muted":true}"#, to: rejected)
        XCTAssertTrue(waitForEndOfStream(on: rejected))
        let (helper, id) = connectHelper()

        XCTAssertEqual(connectedIDs, [id])
        XCTAssertTrue(received.isEmpty)
        XCTAssertEqual(send(["type": "ping"], to: id), "sent")
        XCTAssertEqual(readLine(from: helper), #"{"type":"ping"}"#)
    }

    func testTheProductionCheckTrustsTheHelperBundledInTheAppResources() throws {
        let app = try appBundle(withHelper: true)

        let verifyPeer = try SocketServer.trustedHelperCheck(appBundle: app, ownCode: adHocCode)().get()

        var pair: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        defer { pair.forEach { close($0) } }
        XCTAssertNoThrow(try verifyPeer(pair[0]).get())
    }

    func testTheProductionCheckRejectsAPeerThatIsNotTheBundledHelper() throws {
        let app = try appBundle(withHelper: false)
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: "/bin/ls"),
            to: app.appendingPathComponent("Contents/Resources/MacMuteHelper")
        )

        let verifyPeer = try SocketServer.trustedHelperCheck(appBundle: app, ownCode: adHocCode)().get()

        var pair: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        defer { pair.forEach { close($0) } }
        guard case .failure(.requirementNotSatisfied) = verifyPeer(pair[0]) else {
            return XCTFail("Expected requirementNotSatisfied")
        }
    }

    func testTheProductionRequirementOfASignedAppNamesTheHelperIdentifier() throws {
        let app = socketDirectory.appendingPathComponent("Signed.app")
        let signedApp: () -> Result<SecStaticCode, PeerVerificationError> = {
            var code: SecStaticCode?
            let status = SecStaticCodeCreateWithPath(URL(fileURLWithPath: "/bin/ls") as CFURL, [], &code)
            return code.map { .success($0) } ?? .failure(.ownSignatureUnavailable(status))
        }

        let requirement = try SocketServer.trustedHelperRequirement(appBundle: app, ownCode: signedApp).get()

        var text: CFString?
        XCTAssertEqual(SecRequirementCopyString(requirement, [], &text), errSecSuccess)
        let expectedPrefix = "identifier \"\(PeerCodeVerifier.helperIdentifier)\" and certificate leaf"
        XCTAssertTrue((text as String?)?.hasPrefix(expectedPrefix) == true, text as String? ?? "nil")
    }

    func testTheHelperIsSignedWithTheIdentifierTheAppTrusts() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let flag = "--identifier \(PeerCodeVerifier.helperIdentifier)"

        let release = try String(contentsOf: root.appendingPathComponent("scripts/release.sh"), encoding: .utf8)
        let project = try String(contentsOf: root.appendingPathComponent("MacMute.xcodeproj/project.pbxproj"), encoding: .utf8)

        XCTAssertTrue(release.contains(flag), "scripts/release.sh must sign the helper with \(flag)")
        XCTAssertEqual(project.components(separatedBy: "OTHER_CODE_SIGN_FLAGS = \"\(flag)\";").count - 1, 2)
    }

    func testTheProductionCheckCannotBeBuiltWithoutTheBundledHelper() throws {
        let app = try appBundle(withHelper: false)

        let result = SocketServer.trustedHelperCheck(appBundle: app, ownCode: adHocCode)()

        guard case let .failure(.expectedCodeUnavailable(path, _)) = result else {
            return XCTFail("Expected expectedCodeUnavailable, got \(result)")
        }
        XCTAssertEqual(path, app.appendingPathComponent("Contents/Resources/MacMuteHelper").path)
    }

    func testTheProductionCheckFailsWhenTheAppSignatureIsUnavailable() throws {
        let app = try appBundle(withHelper: true)

        let result = SocketServer.trustedHelperCheck(appBundle: app) { .failure(.ownSignatureUnavailable(errSecCSUnsigned)) }()

        guard case .failure(.ownSignatureUnavailable(errSecCSUnsigned)) = result else {
            return XCTFail("Expected ownSignatureUnavailable, got \(result)")
        }
    }

    func testOnlyTheOwnerCanUseTheSocket() throws {
        _ = connectHelper()

        let attributes = try FileManager.default.attributesOfItem(atPath: socketPath)

        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testBuildsThePeerCheckOnceWhenItStarts() {
        server.stop()
        var builds = 0
        startServer(maxClients: 4, makeVerifyPeer: {
            builds += 1
            return .success { _ in .success(()) }
        })

        _ = connectHelper()
        _ = connectHelper()

        XCTAssertEqual(builds, 1)
    }

    func testDoesNotListenWhenTheAppSignatureDoesNotMatchTheRunningCode() throws {
        server.stop()
        let app = try appBundle(withHelper: true)
        startServer(maxClients: 1, makeVerifyPeer: SocketServer.trustedHelperCheck(appBundle: app) {
            .failure(.ownSignatureInvalid(errSecCSStaticCodeChanged))
        })

        XCTAssertEqual(send(["type": "ping"], to: 1), "no_socket_client")
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
    }

    func testBuildsTheAddressOfTheLongestPathThatFits() throws {
        let path = "/" + String(repeating: "a", count: 102)

        var address = try SocketServer.socketAddress(for: path).get()

        let stored = withUnsafeBytes(of: &address.sun_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        XCTAssertEqual(stored, path)
    }

    func testRefusesAPathLongerThanASocketAddressHolds() {
        let path = "/" + String(repeating: "a", count: 103)

        let result = SocketServer.socketAddress(for: path)

        guard case .failure(.pathTooLong(length: 104, maximum: 103)) = result else {
            return XCTFail("Expected pathTooLong, got \(result)")
        }
    }

    func testDoesNotTouchTheFileSystemWhenTheSocketPathIsTooLong() throws {
        server.stop()
        try FileManager.default.removeItem(at: socketDirectory)
        socketPath = socketDirectory.appendingPathComponent(String(repeating: "a", count: 120)).path
        let failed = expectState(.failed)
        startServer()
        wait(for: [failed], timeout: 2)
        waitLongerThanARetry()
        server.stop()

        XCTAssertEqual(states, [.failed])
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketDirectory.path))
    }

    func testDoesNotListenWhenTheTrustedRequirementCannotBeBuilt() {
        server.stop()
        let failed = expectState(.failed)
        startServer(maxClients: 1, makeVerifyPeer: { .failure(.ownSignatureUnavailable(errSecCSUnsigned)) })
        wait(for: [failed], timeout: 2)
        let settled = expectation(description: "a retry would have run")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { settled.fulfill() }
        wait(for: [settled], timeout: 2)

        XCTAssertEqual(send(["type": "ping"], to: 1), "no_socket_client")
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
        XCTAssertFalse(states.contains { if case .retrying = $0 { return true } else { return false } }, "\(states)")
    }

    func testDoesNotListenWhenTheSocketDirectoryIsASymbolicLink() throws {
        server.stop()
        try FileManager.default.removeItem(at: socketDirectory)
        let target = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mm-target-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: target) }
        try FileManager.default.createSymbolicLink(at: socketDirectory, withDestinationURL: target)
        let failed = expectState(.failed)
        startServer()
        wait(for: [failed], timeout: 2)
        waitLongerThanARetry()

        XCTAssertEqual(states, [.failed])
        XCTAssertEqual(send(["type": "ping"], to: 1), "no_socket_client")
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("s.sock").path))
    }

    func testStoppingAListeningServerRemovesItsSocket() {
        _ = connectHelper()

        server.stop()

        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
    }

    func testASecondServerOnTheSamePathLeavesTheFirstOneListening() throws {
        server.stop()
        startServer { _ in .failure(.requirementNotSatisfied(errSecCSReqFailed)) }
        XCTAssertTrue(waitForEndOfStream(on: rawConnect()))
        let firstSocket = try inode(of: socketPath)

        let second = SocketServer(socketPath: socketPath, makeVerifyPeer: { .success { _ in .success(()) } })
        let reported = expectation(description: "second server state")
        var secondStates: [SocketServerState] = []
        second.onStateChange = { secondStates.append($0); reported.fulfill() }
        second.start()
        wait(for: [reported], timeout: 2)
        second.stop()

        XCTAssertEqual(secondStates, [.anotherInstanceRunning])
        XCTAssertEqual(try inode(of: socketPath), firstSocket)
        XCTAssertTrue(waitForEndOfStream(on: rawConnect()))
    }

    func testASecondServerWaitsForTheFirstOneEvenBeforeItListens() throws {
        server.stop()
        try leaveUnremovableStaleSocket()
        let staleSocket = try inode(of: socketPath)
        let firstRetry = expectState(.retrying(after: 0.02))
        startServer()
        wait(for: [firstRetry], timeout: 2)

        let second = SocketServer(socketPath: socketPath, makeVerifyPeer: { .success { _ in .success(()) } })
        let reported = expectation(description: "second server state")
        var secondStates: [SocketServerState] = []
        second.onStateChange = { secondStates.append($0); reported.fulfill() }
        second.start()
        wait(for: [reported], timeout: 2)
        second.stop()

        XCTAssertEqual(secondStates, [.anotherInstanceRunning])
        XCTAssertEqual(try inode(of: socketPath), staleSocket)
        let listening = expectState(.listening)
        allowRemovingTheStaleSocket()
        wait(for: [listening], timeout: 2)
        _ = connectHelper()
    }

    func testStartingARunningServerAgainKeepsItsSocket() throws {
        _ = connectHelper()
        let socketInode = try inode(of: socketPath)

        server.start()
        waitLongerThanARetry()

        XCTAssertEqual(states, [.listening])
        XCTAssertEqual(try inode(of: socketPath), socketInode)
        _ = connectHelper()
    }

    func testANewServerStartsOnceTheFirstOneStops() {
        server.stop()

        startServer()

        _ = connectHelper()
    }

    func testRetriesWhileTheSocketDirectoryCannotBeCreated() throws {
        server.stop()
        socketPath = socketDirectory.appendingPathComponent("sub/s.sock").path
        XCTAssertEqual(chmod(socketDirectory.path, 0o500), 0)
        defer { chmod(socketDirectory.path, 0o700) }
        let firstRetry = expectState(.retrying(after: 0.02))
        startServer()
        wait(for: [firstRetry], timeout: 2)

        let listening = expectState(.listening)
        XCTAssertEqual(chmod(socketDirectory.path, 0o700), 0)
        wait(for: [listening], timeout: 2)
        _ = connectHelper()
    }

    func testDoesNotListenWhenSomethingOtherThanASocketIsAtThePath() throws {
        server.stop()
        XCTAssertTrue(FileManager.default.createFile(atPath: socketPath, contents: Data("other".utf8)))
        let failed = expectState(.failed)
        startServer()
        wait(for: [failed], timeout: 2)
        server.stop()

        XCTAssertEqual(states, [.failed])
        XCTAssertEqual(FileManager.default.contents(atPath: socketPath), Data("other".utf8))
    }

    func testReplacesAStaleSocketLeftByAServerThatIsGone() throws {
        server.stop()
        try leaveStaleSocket()
        let listening = expectState(.listening)

        startServer()

        wait(for: [listening], timeout: 2)
        XCTAssertEqual(states, [.listening])
        _ = connectHelper()
    }

    func testRetriesUntilTheStaleSocketCanBeRemoved() throws {
        server.stop()
        try leaveUnremovableStaleSocket()
        let cappedRetry = expectState(.retrying(after: 0.05))
        startServer()
        wait(for: [cappedRetry], timeout: 2)

        let listening = expectState(.listening)
        allowRemovingTheStaleSocket()
        wait(for: [listening], timeout: 2)

        XCTAssertEqual(Array(states.prefix(3)), [.retrying(after: 0.02), .retrying(after: 0.04), .retrying(after: 0.05)])
        _ = connectHelper()
    }

    func testRetriesDoNotLeakDescriptors() throws {
        server.stop()
        try leaveUnremovableStaleSocket()
        let firstRetry = expectState(.retrying(after: 0.02))
        startServer()
        wait(for: [firstRetry], timeout: 2)
        let afterFirstRetry = openServerDescriptors()

        for _ in 0..<3 {
            let retry = expectState(.retrying(after: 0.05))
            wait(for: [retry], timeout: 2)
        }

        XCTAssertEqual(openServerDescriptors(), afterFirstRetry)
    }

    func testARefusedSecondServerDoesNotLeakDescriptors() {
        server.stop()
        let listening = expectState(.listening)
        startServer()
        wait(for: [listening], timeout: 2)
        let before = openServerDescriptors()
        let second = SocketServer(socketPath: socketPath, makeVerifyPeer: { .success { _ in .success(()) } })
        let reported = expectation(description: "second server state")
        second.onStateChange = { _ in reported.fulfill() }

        second.start()
        wait(for: [reported], timeout: 2)

        XCTAssertEqual(openServerDescriptors(), before)
        second.stop()
    }

    func testStoppingCancelsAPendingRetry() throws {
        server.stop()
        try leaveUnremovableStaleSocket()
        let firstRetry = expectState(.retrying(after: 0.02))
        startServer()
        wait(for: [firstRetry], timeout: 2)

        server.stop()
        allowRemovingTheStaleSocket()
        try FileManager.default.removeItem(atPath: socketPath)
        let settled = expectation(description: "retries would have run")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { settled.fulfill() }
        wait(for: [settled], timeout: 2)

        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
        XCTAssertFalse(states.contains(.listening), "\(states)")
    }

    func testStartingAgainBeginsTheBackoffFromTheFirstDelay() throws {
        server.stop()
        try leaveUnremovableStaleSocket()
        let cappedRetry = expectState(.retrying(after: 0.05))
        startServer()
        wait(for: [cappedRetry], timeout: 2)
        server.stop()

        // Once capped, only 0.05 is reported, so a 0.02 can only come from the new start.
        let firstRetry = expectState(.retrying(after: 0.02))
        server.start()
        wait(for: [firstRetry], timeout: 2)
    }

    func testStoppingLeavesASocketThatReplacedItsOwn() throws {
        _ = connectHelper()
        unlink(socketPath)
        let replacement = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(replacement) }
        var address = try SocketServer.socketAddress(for: socketPath).get()
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(replacement, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(bound, 0)
        let replacementInode = try inode(of: socketPath)

        server.stop()

        XCTAssertEqual(try inode(of: socketPath), replacementInode)
    }

    func testStoppingLeavesAFileThatReplacedItsSocket() {
        _ = connectHelper()
        unlink(socketPath)
        XCTAssertTrue(FileManager.default.createFile(atPath: socketPath, contents: Data("other".utf8)))

        server.stop()

        XCTAssertEqual(FileManager.default.contents(atPath: socketPath), Data("other".utf8))
    }

    func testStoppingAServerThatRefusedToStartLeavesTheFileAtItsPathAlone() throws {
        server.stop()
        try FileManager.default.removeItem(at: socketDirectory)
        let target = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mm-target-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: target) }
        let victim = target.appendingPathComponent("s.sock")
        XCTAssertTrue(FileManager.default.createFile(atPath: victim.path, contents: Data("keep".utf8)))
        try FileManager.default.createSymbolicLink(at: socketDirectory, withDestinationURL: target)
        startServer()

        server.stop()

        XCTAssertTrue(FileManager.default.fileExists(atPath: victim.path))
    }

    func testRefusingASymbolicLinkLeavesThePermissionsOfItsTargetAlone() throws {
        let target = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mm-target-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        let link = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mm-link-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        defer {
            try? FileManager.default.removeItem(at: link)
            try? FileManager.default.removeItem(at: target)
        }

        XCTAssertThrowsError(try SocketServer.prepareDirectory(link))

        let mode = try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o755)
    }

    func testRefusesASocketDirectoryPathTakenByAFile() throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mm-file-\(UUID().uuidString)")
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: Data()))
        defer { try? FileManager.default.removeItem(at: file) }

        XCTAssertThrowsError(try SocketServer.prepareDirectory(file)) { error in
            guard case SocketDirectoryError.notADirectory = error else {
                return XCTFail("Unexpected error \(error)")
            }
        }
    }

    func testRefusesASocketDirectoryThatIsASymbolicLink() throws {
        let target = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mm-target-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let link = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mm-link-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        defer {
            try? FileManager.default.removeItem(at: link)
            try? FileManager.default.removeItem(at: target)
        }

        XCTAssertThrowsError(try SocketServer.prepareDirectory(link)) { error in
            guard case SocketDirectoryError.symbolicLink = error else {
                return XCTFail("Unexpected error \(error)")
            }
        }
    }

    func testCreatesTheSocketDirectoryForTheOwnerOnly() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mm-dir-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        try SocketServer.prepareDirectory(directory)

        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testRestrictsAnExistingSocketDirectoryToTheOwner() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mm-dir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        defer { try? FileManager.default.removeItem(at: directory) }

        try SocketServer.prepareDirectory(directory)

        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
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

    private func expectState(_ state: SocketServerState) -> XCTestExpectation {
        let arrived = expectation(description: "state \(state)")
        awaitedState = (state, arrived)
        return arrived
    }

    /// Leaves a socket file nobody listens on, as a crashed server would.
    private func leaveStaleSocket() throws {
        let stale = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(stale) }
        var address = try SocketServer.socketAddress(for: socketPath).get()
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(stale, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(bound, 0)
    }

    /// Makes unlinking the stale socket fail with EPERM, a failure the server retries.
    private func leaveUnremovableStaleSocket() throws {
        try leaveStaleSocket()
        XCTAssertEqual(chflags(socketPath, UInt32(UF_IMMUTABLE)), 0)
    }

    private func allowRemovingTheStaleSocket() {
        XCTAssertEqual(chflags(socketPath, 0), 0)
    }

    /// Sockets plus descriptors of this test's lock file; the test runner keeps other files open.
    private func openServerDescriptors() -> Int {
        let lockName = "\(socketDirectory.lastPathComponent)/macmute.lock"
        let descriptors = (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd")) ?? []
        return descriptors.compactMap { Int32($0) }.filter { fd in
            var info = stat()
            guard fstat(fd, &info) == 0 else { return false }
            if info.st_mode & S_IFMT == S_IFSOCK { return true }
            var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard fcntl(fd, F_GETPATH, &path) == 0 else { return false }
            return String(cString: path).hasSuffix(lockName)
        }.count
    }

    private func waitLongerThanARetry() {
        let settled = expectation(description: "a retry would have run")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { settled.fulfill() }
        wait(for: [settled], timeout: 2)
    }

    private func inode(of path: String) throws -> ino_t {
        var info = stat()
        guard lstat(path, &info) == 0 else { throw POSIXError(.ENOENT) }
        return info.st_ino
    }

    private func adHocCode() -> Result<SecStaticCode, PeerVerificationError> {
        var code: SecStaticCode?
        let status = SecStaticCodeCreateWithPath(Bundle(for: Self.self).bundleURL as CFURL, [], &code)
        return code.map { .success($0) } ?? .failure(.ownSignatureUnavailable(status))
    }

    // The running process stands in for the helper, so a socketpair peer satisfies its requirement.
    private func appBundle(withHelper: Bool) throws -> URL {
        var info: CFDictionary?
        XCTAssertEqual(SecCodeCopySigningInformation(try adHocCode().get(), SecCSFlags(rawValue: kSecCSSigningInformation), &info), errSecSuccess)
        if let certificates = (info as? [String: Any])?[kSecCodeInfoCertificates as String] as? [Any], !certificates.isEmpty {
            throw XCTSkip("The test bundle is signed with a certificate; these tests need an ad-hoc one")
        }
        let app = socketDirectory.appendingPathComponent("Fake.app")
        let resources = app.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        guard withHelper else { return app }
        var selfCode: SecCode?
        XCTAssertEqual(SecCodeCopySelf([], &selfCode), errSecSuccess)
        var selfStatic: SecStaticCode?
        XCTAssertEqual(SecCodeCopyStaticCode(try XCTUnwrap(selfCode), [], &selfStatic), errSecSuccess)
        var path: CFURL?
        XCTAssertEqual(SecCodeCopyPath(try XCTUnwrap(selfStatic), [], &path), errSecSuccess)
        try FileManager.default.copyItem(at: try XCTUnwrap(path) as URL, to: resources.appendingPathComponent("MacMuteHelper"))
        return app
    }

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
            // Set before connecting: the server may close a rejected peer before this returns.
            var noSigPipe: Int32 = 1
            let set = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            XCTAssertEqual(set, 0, "SO_NOSIGPIPE: \(String(cString: strerror(errno)))", file: file, line: line)
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

final class PeerRejectionLogTests: XCTestCase {
    func testReportsTheFirstRejectionOfAProcessAsAnErrorAndLaterOnesAsDebug() {
        var log = PeerRejectionLog()

        let first = log.entry(for: .peerCodeUnavailable(-1), pid: 42)
        let second = log.entry(for: .peerCodeUnavailable(-1), pid: 42)
        let other = log.entry(for: .peerCodeUnavailable(-1), pid: 43)

        XCTAssertEqual(first.level, .error)
        XCTAssertEqual(second.level, .debug)
        XCTAssertEqual(other.level, .error)
    }

    func testForgetsTheReportedProcessesOnceItRemembersTooMany() {
        var log = PeerRejectionLog()
        for pid in pid_t(1)...257 {
            _ = log.entry(for: .peerCodeUnavailable(-1), pid: pid)
        }

        XCTAssertEqual(log.entry(for: .peerCodeUnavailable(-1), pid: 1).level, .error)
    }

    func testReportsEveryRejectionOfAnUnknownProcessAsAnError() {
        var log = PeerRejectionLog()

        let first = log.entry(for: .peerCodeUnavailable(-1), pid: nil)
        let second = log.entry(for: .peerCodeUnavailable(-1), pid: nil)

        XCTAssertEqual(first.level, .error)
        XCTAssertEqual(second.level, .error)
    }

    func testNamesTheProcessAndTheReason() {
        var log = PeerRejectionLog()

        let entry = log.entry(for: .peerCodeUnavailable(-67068), pid: 42)

        XCTAssertTrue(entry.message.contains("pid 42"), entry.message)
        XCTAssertTrue(entry.message.contains(PeerVerificationError.peerCodeUnavailable(-67068).description), entry.message)
        XCTAssertFalse(entry.message.contains("reload"), entry.message)
    }

    func testSuggestsReloadingTheExtensionWhenTheSignatureDoesNotMatch() {
        var log = PeerRejectionLog()

        let entry = log.entry(for: .requirementNotSatisfied(-67050), pid: nil)

        XCTAssertTrue(entry.message.contains("pid unknown"), entry.message)
        XCTAssertTrue(entry.message.contains("reload the MacMute extension"), entry.message)
    }
}

final class RetryBackoffTests: XCTestCase {
    func testDoublesTheDelayFromOneSecondUpToThirty() {
        var backoff = RetryBackoff()

        let delays = (0..<8).map { _ in backoff.nextDelay() }

        XCTAssertEqual(delays, [1, 2, 4, 8, 16, 30, 30, 30])
    }

    func testStartsOverAfterAReset() {
        var backoff = RetryBackoff()
        _ = backoff.nextDelay()
        _ = backoff.nextDelay()

        backoff.reset()

        XCTAssertEqual(backoff.nextDelay(), 1)
    }

    func testScalesForShorterDelays() {
        var backoff = RetryBackoff(first: 0.01, maximum: 0.03)

        XCTAssertEqual((0..<3).map { _ in backoff.nextDelay() }, [0.01, 0.02, 0.03])
    }
}
