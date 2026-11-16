import XCTest

final class NativeMessageReaderTests: XCTestCase {
    private var pipe: Pipe!
    private var reader: NativeMessageReader!

    override func setUp() {
        super.setUp()
        pipe = Pipe()
        reader = NativeMessageReader(fileDescriptor: pipe.fileHandleForReading.fileDescriptor, chunkSize: 1024)
    }

    override func tearDown() {
        try? pipe.fileHandleForWriting.close()
        try? pipe.fileHandleForReading.close()
        super.tearDown()
    }

    func testReadsAMessage() {
        send(frame(#"{"type":"toggle","requestId":3}"#))

        let message = nextMessage()

        XCTAssertEqual(message?["type"] as? String, "toggle")
        XCTAssertEqual(message?["requestId"] as? Int, 3)
    }

    func testReadsMessagesInOrder() {
        send(frame(#"{"n":1}"#) + frame(#"{"n":2}"#))

        XCTAssertEqual(nextMessage()?["n"] as? Int, 1)
        XCTAssertEqual(nextMessage()?["n"] as? Int, 2)
    }

    func testSkipsJSONThatIsNotAnObjectAndKeepsReading() {
        send(frame(#"["toggle"]"#) + frame(#""toggle""#) + frame(#"{"n":1}"#))

        XCTAssertTrue(nextIsSkipped())
        XCTAssertTrue(nextIsSkipped())
        XCTAssertEqual(nextMessage()?["n"] as? Int, 1)
    }

    func testSkipsAFrameThatIsNotJSONWithTheParserError() {
        send(frame("not json") + frame(#"{"n":1}"#))

        XCTAssertEqual(nextSkipReason()?.hasPrefix("frame of 8 bytes is not JSON: "), true)
        XCTAssertEqual(nextMessage()?["n"] as? Int, 1)
    }

    func testSkipsAnEmptyFrame() {
        send(frame("") + frame(#"{"n":1}"#))

        XCTAssertEqual(nextSkipReason(), "empty frame")
        XCTAssertEqual(nextMessage()?["n"] as? Int, 1)
    }

    func testReadsAFrameWrittenInTwoParts() {
        let whole = frame(#"{"n":1}"#)
        send(whole.prefix(6))
        let handle = pipe.fileHandleForWriting
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { handle.write(whole.dropFirst(6)) }

        XCTAssertEqual(nextMessage()?["n"] as? Int, 1)
    }

    func testKeepsReadingWhenASignalInterruptsTheRead() {
        var ignore = sigaction()
        ignore.__sigaction_u.__sa_handler = { _ in }
        sigemptyset(&ignore.sa_mask)
        ignore.sa_flags = 0
        var previous = sigaction()
        XCTAssertEqual(sigaction(SIGALRM, &ignore, &previous), 0)
        defer { sigaction(SIGALRM, &previous, nil) }
        let readingThread = pthread_self()
        let handle = pipe.fileHandleForWriting
        let message = frame(#"{"n":1}"#)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            pthread_kill(readingThread, SIGALRM)
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { handle.write(message) }
        }

        XCTAssertEqual(nextMessage()?["n"] as? Int, 1)
    }

    func testReportsAFailedRead() {
        let reader = NativeMessageReader(fileDescriptor: -1)

        guard case .readFailed(errno: EBADF) = reader.next() else { return XCTFail("Expected readFailed(EBADF)") }
    }

    func testDiscardsAFrameLargerThanTheLimitAndReadsTheNextOne() {
        let oversized = "{\"pad\":\"" + String(repeating: "a", count: NativeMessageReader.maxMessageLength) + "\"}"
        sendInBackground(frame(oversized) + frame(#"{"n":1}"#))

        guard case let .skipped(reason) = reader.next() else { return XCTFail("Expected the oversized frame to be skipped") }
        XCTAssertTrue(reason.contains("\(oversized.utf8.count)"), reason)
        XCTAssertEqual(nextMessage()?["n"] as? Int, 1)
    }

    func testAcceptsAFrameOfExactlyTheLimit() {
        let prefix = "{\"pad\":\""
        let suffix = "\"}"
        let padding = String(repeating: "a", count: NativeMessageReader.maxMessageLength - prefix.utf8.count - suffix.utf8.count)
        sendInBackground(frame(prefix + padding + suffix))

        XCTAssertEqual((nextMessage()?["pad"] as? String)?.count, padding.count)
    }

    func testEndsAtTheEndOfInput() {
        send(frame(#"{"n":1}"#))
        try? pipe.fileHandleForWriting.close()

        XCTAssertEqual(nextMessage()?["n"] as? Int, 1)
        XCTAssertTrue(nextIsEnd())
    }

    func testReportsATruncatedLengthPrefix() {
        send(Data([5, 0]))
        try? pipe.fileHandleForWriting.close()

        XCTAssertEqual(nextMissingBytes(), 2)
    }

    func testReportsATruncatedMessage() {
        send(frame(#"{"n":1}"#).dropLast(2))
        try? pipe.fileHandleForWriting.close()

        XCTAssertEqual(nextMissingBytes(), 2)
    }

    func testReportsATruncatedDiscardedFrame() {
        send(header(UInt32(NativeMessageReader.maxMessageLength + 1)) + Data(repeating: 0x61, count: 10))
        try? pipe.fileHandleForWriting.close()

        XCTAssertEqual(nextMissingBytes(), NativeMessageReader.maxMessageLength + 1 - 10)
    }

    func testDrainsTheLargestPossibleLengthInChunks() {
        send(header(.max) + Data(repeating: 0x61, count: 3000))
        try? pipe.fileHandleForWriting.close()

        XCTAssertEqual(nextMissingBytes(), Int(UInt32.max) - 3000)
    }

    private func frame(_ json: String) -> Data {
        let body = Data(json.utf8)
        var length = UInt32(body.count).littleEndian
        return Data(bytes: &length, count: 4) + body
    }

    private func header(_ length: UInt32) -> Data {
        var littleEndian = length.littleEndian
        return Data(bytes: &littleEndian, count: 4)
    }

    private func send(_ data: Data) {
        pipe.fileHandleForWriting.write(data)
    }

    // A frame above the pipe buffer would block the writer until the reader drains it.
    private func sendInBackground(_ data: Data) {
        let handle = pipe.fileHandleForWriting
        DispatchQueue.global().async { handle.write(data) }
    }

    private func nextMessage(file: StaticString = #filePath, line: UInt = #line) -> [String: Any]? {
        guard case let .message(message) = reader.next() else {
            XCTFail("Expected a message", file: file, line: line)
            return nil
        }
        return message
    }

    private func nextSkipReason() -> String? {
        guard case let .skipped(reason) = reader.next() else { return nil }
        return reason
    }

    private func nextMissingBytes() -> Int? {
        guard case let .truncated(missingBytes) = reader.next() else { return nil }
        return missingBytes
    }

    private func nextIsSkipped() -> Bool {
        if case .skipped = reader.next() { return true }
        return false
    }

    private func nextIsEnd() -> Bool {
        if case .endOfInput = reader.next() { return true }
        return false
    }
}
