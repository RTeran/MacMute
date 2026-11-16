import AppKit
import CoreGraphics
import XCTest

final class ShortcutMatcherTests: XCTestCase {
    private let micKey: UInt16 = 46
    private let cameraKey: UInt16 = 8
    private var matcher: ShortcutMatcher!

    override func setUp() {
        super.setUp()
        matcher = ShortcutMatcher(
            mic: Shortcut(keyCode: micKey, modifiers: [.maskCommand, .maskShift]),
            camera: Shortcut(keyCode: cameraKey, modifiers: [.maskControl])
        )
    }

    func testTriggersTheMicWhenKeyAndModifiersMatch() {
        XCTAssertEqual(matcher.match(keyCode: micKey, flags: [.maskCommand, .maskShift]), .triggered(.mic))
    }

    func testTriggersTheCameraWhenKeyAndModifiersMatch() {
        XCTAssertEqual(matcher.match(keyCode: cameraKey, flags: [.maskControl]), .triggered(.camera))
    }

    func testIgnoresFlagsThatAreNotShortcutModifiers() {
        XCTAssertEqual(
            matcher.match(keyCode: micKey, flags: [.maskCommand, .maskShift, .maskAlphaShift, .maskNonCoalesced]),
            .triggered(.mic)
        )
    }

    func testReportsAModifierMismatchWhenOnlyTheKeyMatches() {
        XCTAssertEqual(matcher.match(keyCode: micKey, flags: [.maskCommand]), .modifiersMismatch(.mic))
        XCTAssertEqual(matcher.match(keyCode: cameraKey, flags: []), .modifiersMismatch(.camera))
    }

    func testDoesNotMatchOtherKeys() {
        XCTAssertEqual(matcher.match(keyCode: 0, flags: [.maskCommand, .maskShift]), .none)
    }

    func testDoesNotMatchAnUnconfiguredShortcut() {
        let micOnly = ShortcutMatcher(mic: Shortcut(keyCode: micKey, modifiers: [.maskCommand]), camera: nil)

        XCTAssertEqual(micOnly.match(keyCode: cameraKey, flags: [.maskControl]), .none)
    }
}

final class ShortcutStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = UUID().uuidString
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func read() -> Shortcut? {
        ShortcutStore.read(keyCodeKey: "keyCode", modifiersKey: "modifiers", from: defaults)
    }

    private func store(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        defaults.set(Int(keyCode), forKey: "keyCode")
        defaults.set(modifiers.rawValue, forKey: "modifiers")
    }

    func testReadsAShortcutOnTheAKey() {
        store(keyCode: 0, modifiers: [.command, .shift])

        XCTAssertEqual(read(), Shortcut(keyCode: 0, modifiers: [.maskCommand, .maskShift]))
    }

    func testReadsAShortcutOnAnotherKey() {
        store(keyCode: 46, modifiers: [.control, .option])

        XCTAssertEqual(read(), Shortcut(keyCode: 46, modifiers: [.maskControl, .maskAlternate]))
    }

    func testReturnsNilWhenNothingIsStored() {
        XCTAssertNil(read())
    }

    func testReturnsNilWhenNoModifiersAreStored() {
        store(keyCode: 46, modifiers: [])

        XCTAssertNil(read())
    }
}
