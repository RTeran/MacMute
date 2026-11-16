import Foundation
import os

// MARK: - Native Messaging Protocol (stdin/stdout with 4-byte length prefix)

class NativeMessaging {
    static func writeMessage(_ message: [String: Any]) {
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: message)
        } catch {
            HelperLog.logger.error("Failed to serialize message for Chrome \(preview(message), privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }

        let length = UInt32(data.count)
        let lengthBytes: [UInt8] = [
            UInt8(length & 0xFF),
            UInt8((length >> 8) & 0xFF),
            UInt8((length >> 16) & 0xFF),
            UInt8((length >> 24) & 0xFF),
        ]

        let total = 4 + data.count
        let headerWritten = fwrite(lengthBytes, 1, 4, stdout)
        guard headerWritten == 4 else { failStdoutWrite(written: headerWritten, total: total, errno: errno) }
        let bodyWritten = data.withUnsafeBytes { rawBuffer in
            fwrite(rawBuffer.baseAddress, 1, data.count, stdout)
        }
        guard bodyWritten == data.count else { failStdoutWrite(written: 4 + bodyWritten, total: total, errno: errno) }
        guard fflush(stdout) == 0 else { failStdoutWrite(written: total, total: total, errno: errno) }
    }

    // A partial frame desyncs the length-prefixed stream, so any later message would be garbage.
    private static func failStdoutWrite(written: Int, total: Int, errno code: Int32) -> Never {
        HelperLog.logger.fault("Failed to write to Chrome (\(written, privacy: .public)/\(total, privacy: .public) bytes buffered): \(String(cString: strerror(code)), privacy: .public)")
        exit(1)
    }
}

// MARK: - Main

// Chrome closing stdout must surface as a write error, not a SIGPIPE that kills the helper.
signal(SIGPIPE, SIG_IGN)

let socketClient = SocketClient()

// Messages from the app → forward to Chrome extension
socketClient.onMessageReceived = { message in
    HelperLog.logger.info("Relaying app → extension: \(preview(message), privacy: .public)")
    NativeMessaging.writeMessage(message)
}

socketClient.onStateChange = { state in
    switch state {
    case .connected:
        break
    case let .waiting(delay):
        HelperLog.logger.info("Not connected to the app, retrying in \(delay, privacy: .public) s")
    case .stopped:
        // Chrome starts a new helper when the extension reconnects; this one can never connect.
        exit(1)
    }
}

socketClient.start()

// Read from stdin (Chrome extension messages) on a background thread
DispatchQueue.global(qos: .userInteractive).async {
    let reader = NativeMessageReader(fileDescriptor: STDIN_FILENO)
    while true {
        switch reader.next() {
        case .endOfInput:
            HelperLog.logger.notice("stdin closed, exiting")
            exit(0)
        case let .truncated(missingBytes):
            HelperLog.logger.error("stdin closed inside a frame, \(missingBytes, privacy: .public) bytes missing; exiting")
            exit(1)
        case let .readFailed(code):
            HelperLog.logger.error("Reading stdin failed: \(String(cString: strerror(code)), privacy: .public); exiting")
            exit(1)
        case let .skipped(reason):
            HelperLog.logger.error("Skipping a message from the extension: \(reason, privacy: .public)")
        case let .message(message):
            HelperLog.logger.info("Relaying extension → app: \(preview(message), privacy: .public)")
            socketClient.sendMessage(message)
        }
    }
}

// Keeps the process alive; it ends when Chrome closes stdin.
RunLoop.main.run()
