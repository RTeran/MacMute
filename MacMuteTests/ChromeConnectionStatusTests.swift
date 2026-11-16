import XCTest

final class SocketServerReactionTests: XCTestCase {
    func testInstallsTheNativeMessagingHostOnceTheServerListens() {
        XCTAssertEqual(SocketServerReaction(.listening), .installNativeMessagingHost)
    }

    func testQuitsWhenAnotherInstanceIsRunning() {
        XCTAssertEqual(SocketServerReaction(.anotherInstanceRunning), .quit)
    }

    func testDoesNothingWhileRetryingOrAfterFailing() {
        XCTAssertEqual(SocketServerReaction(.retrying(after: 1)), .none)
        XCTAssertEqual(SocketServerReaction(.failed), .none)
    }
}

final class ChromeConnectionStatusTests: XCTestCase {
    func testIsConnectedWhileAHelperIsConnected() {
        let status = ChromeConnectionStatus(serverState: .listening, isConnected: true, nativeHostInstallFailed: false)

        XCTAssertEqual(status, .connected)
        XCTAssertNil(status.message)
    }

    func testIsNotConnectedWhenTheServerListensWithoutAHelper() {
        let status = ChromeConnectionStatus(serverState: .listening, isConnected: false, nativeHostInstallFailed: false)

        XCTAssertEqual(status, .notConnected)
        XCTAssertEqual(status.message, "No connection with Chrome")
    }

    func testIsNotConnectedBeforeTheServerReportsAState() {
        XCTAssertEqual(ChromeConnectionStatus(serverState: nil, isConnected: false, nativeHostInstallFailed: false), .notConnected)
    }

    func testCannotAcceptConnectionsWhenTheServerFailed() {
        let status = ChromeConnectionStatus(serverState: .failed, isConnected: false, nativeHostInstallFailed: false)

        XCTAssertEqual(status, .cannotAcceptConnections)
        XCTAssertEqual(status.message, "MacMute can't accept connections from Chrome. See Console for details.")
    }

    func testCannotAcceptConnectionsWhileTheServerRetries() {
        XCTAssertEqual(
            ChromeConnectionStatus(serverState: .retrying(after: 1), isConnected: false, nativeHostInstallFailed: false),
            .cannotAcceptConnections
        )
    }

    func testCannotAcceptConnectionsWhenTheNativeMessagingHostWasNotInstalled() {
        XCTAssertEqual(
            ChromeConnectionStatus(serverState: .listening, isConnected: false, nativeHostInstallFailed: true),
            .cannotAcceptConnections
        )
    }
}
