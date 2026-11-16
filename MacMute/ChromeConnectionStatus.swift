enum SocketServerReaction: Equatable {
    case installNativeMessagingHost
    case quit
    case none

    init(_ state: SocketServerState) {
        switch state {
        case .listening: self = .installNativeMessagingHost
        case .anotherInstanceRunning: self = .quit
        case .retrying, .failed: self = .none
        }
    }
}

enum ChromeConnectionStatus: Equatable {
    case connected
    case notConnected
    case cannotAcceptConnections

    // A connected helper proves the path works, whatever the server or the install reported before.
    init(serverState: SocketServerState?, isConnected: Bool, nativeHostInstallFailed: Bool) {
        if isConnected {
            self = .connected
            return
        }
        switch serverState {
        case .failed?, .retrying?:
            self = .cannotAcceptConnections
        case .listening?, .anotherInstanceRunning?, nil:
            self = nativeHostInstallFailed ? .cannotAcceptConnections : .notConnected
        }
    }

    var message: String? {
        switch self {
        case .connected: return nil
        case .notConnected: return "No connection with Chrome"
        case .cannotAcceptConnections: return "MacMute can't accept connections from Chrome. See Console for details."
        }
    }
}
