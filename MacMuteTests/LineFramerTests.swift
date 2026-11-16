import XCTest

final class LineFramerTests: XCTestCase {
    func testReturnsEachCompleteLineWithoutItsNewline() throws {
        var framer = LineFramer()

        let lines = try framer.append(Data("one\ntwo\n".utf8))

        XCTAssertEqual(lines, [Data("one".utf8), Data("two".utf8)])
    }

    func testKeepsAPartialLineUntilItsNewlineArrives() throws {
        var framer = LineFramer()

        XCTAssertEqual(try framer.append(Data("{\"ty".utf8)), [])
        XCTAssertEqual(try framer.append(Data("pe\":1}\nnext".utf8)), [Data("{\"type\":1}".utf8)])
        XCTAssertEqual(try framer.append(Data("\n".utf8)), [Data("next".utf8)])
    }

    func testAcceptsALineAsLongAsTheLimit() throws {
        var framer = LineFramer(maxLineLength: 4)

        XCTAssertEqual(try framer.append(Data("abcd".utf8)), [])
        XCTAssertEqual(try framer.append(Data("\n".utf8)), [Data("abcd".utf8)])
    }

    func testRejectsAPendingLineLongerThanTheLimit() {
        var framer = LineFramer(maxLineLength: 4)

        XCTAssertThrowsError(try framer.append(Data("abcde".utf8))) { error in
            XCTAssertEqual(error as? LineFramer.LineTooLong, LineFramer.LineTooLong(limit: 4))
        }
    }

    func testRejectsACompleteLineLongerThanTheLimit() {
        var framer = LineFramer(maxLineLength: 4)

        XCTAssertThrowsError(try framer.append(Data("abcde\n".utf8)))
    }

    func testRejectsALineThatGrowsPastTheLimitAcrossChunks() throws {
        var framer = LineFramer(maxLineLength: 4)

        _ = try framer.append(Data("abc".utf8))

        XCTAssertThrowsError(try framer.append(Data("de".utf8)))
    }

    func testSkipsEmptyLines() throws {
        var framer = LineFramer()

        XCTAssertEqual(try framer.append(Data("\none\n\n\ntwo\n".utf8)), [Data("one".utf8), Data("two".utf8)])
    }

    func testReturnsManyLinesFromOneChunk() throws {
        var framer = LineFramer()
        let chunk = (1...1000).map { "line\($0)\n" }.joined()

        let lines = try framer.append(Data(chunk.utf8))

        XCTAssertEqual(lines.count, 1000)
        XCTAssertEqual(lines.last, Data("line1000".utf8))
    }

    func testDefaultLimitIs64KB() {
        XCTAssertEqual(LineFramer.defaultMaxLineLength, 64 * 1024)
    }
}
