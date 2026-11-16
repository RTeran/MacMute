import XCTest

final class LogPreviewTests: XCTestCase {
    func testKeepsAShortTextAsItIs() {
        XCTAssertEqual(preview("no_meet_tab"), "no_meet_tab")
    }

    func testKeepsATextOfExactly128Bytes() {
        let text = String(repeating: "a", count: 128)

        XCTAssertEqual(preview(text), text)
    }

    func testCutsATextOf129BytesAndSaysHowLongItWas() {
        let text = String(repeating: "a", count: 129)

        XCTAssertEqual(preview(text), String(repeating: "a", count: 128) + "… (129 bytes)")
    }

    func testCountsBytesNotCharactersAndReplacesACutCharacter() {
        let text = "a" + String(repeating: "😀", count: 100)

        XCTAssertEqual(preview(text), "a" + String(repeating: "😀", count: 31) + "\u{FFFD}… (401 bytes)")
    }

    func testEscapesControlCharactersSoAPeerCannotForgeLogLines() {
        XCTAssertEqual(preview("a\nfake line\u{1B}"), "a\\u{A}fake line\\u{1B}")
    }

    func testDescribesAMessageByItsKeysAndValueTypes() {
        let message: [String: Any] = ["muted": "yes", "ok": true, "count": 2, "reason": String(repeating: "x", count: 500)]

        XCTAssertEqual(preview(message), "count:Number, muted:String, ok:Bool, reason:String")
    }

    func testShowsABoundedTypeAndTarget() {
        let message: [String: Any] = ["type": "state_update", "target": "mic\nx"]

        XCTAssertEqual(preview(message), "target:String=\"mic\\u{A}x\", type:String=\"state_update\"")
    }

    func testBoundsAMessageWithALongKey() {
        let message: [String: Any] = [String(repeating: "k", count: 200): 1]

        XCTAssertTrue(preview(message).hasSuffix("… (207 bytes)"))
    }
}
