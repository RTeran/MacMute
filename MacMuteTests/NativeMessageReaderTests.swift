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

    func testSkipsAFrameThatIsNotJSON() {
        send(frame("not json") + frame(#"{"n":1}"#))

        XCTAssertTrue(nextIsSkipped())
        XCTAssertEqual(nextMessage()?["n"] as? Int, 1)
    }

    func testSkipsAnEmptyFrame() {
        send(frame("") + frame(#"{"n":1}"#))

        XCTAssertTrue(nextIsSkipped())
        XCTAssertEqual(nextMessage()?["n"] as? Int, 1)
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

    func testEndsWhenTheInputStopsInsideTheLengthPrefix() {
        send(Data([5, 0]))
        try? pipe.fileHandleForWriting.close()

        XCTAssertTrue(nextIsEnd())
    }

    func testEndsWhenTheInputStopsInsideAMessage() {
        send(frame(#"{"n":1}"#).dropLast(2))
        try? pipe.fileHandleForWriting.close()

        XCTAssertTrue(nextIsEnd())
    }

    func testEndsWhenTheInputStopsInsideADiscardedFrame() {
        var header = Data(count: 4)
        header.withUnsafeMutableBytes { $0.storeBytes(of: UInt32(NativeMessageReader.maxMessageLength + 1).littleEndian, as: UInt32.self) }
        send(header + Data(repeating: 0x61, count: 10))
        try? pipe.fileHandleForWriting.close()

        XCTAssertTrue(nextIsEnd())
    }

    private func frame(_ json: String) -> Data {
        let body = Data(json.utf8)
        var length = UInt32(body.count).littleEndian
        return Data(bytes: &length, count: 4) + body
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

    private func nextIsSkipped() -> Bool {
        if case .skipped = reader.next() { return true }
        return false
    }

    private func nextIsEnd() -> Bool {
        if case .endOfInput = reader.next() { return true }
        return false
    }
}
