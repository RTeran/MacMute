import XCTest

final class LogPreviewTests: XCTestCase {
    func testKeepsAShortTextAsItIs() {
        XCTAssertEqual(preview("no_meet_tab"), "no_meet_tab")
    }

    func testCutsALongTextTo128BytesAndSaysHowLongItWas() {
        let text = String(repeating: "a", count: 1000)

        XCTAssertEqual(preview(text), String(repeating: "a", count: 128) + "… (1000 bytes)")
    }

    func testDescribesAMessageByItsKeysOnly() {
        let message: [String: Any] = ["type": "toggle_result", "ok": true, "reason": String(repeating: "x", count: 500)]

        XCTAssertEqual(preview(message), "keys=[ok, reason, type]")
    }
}
