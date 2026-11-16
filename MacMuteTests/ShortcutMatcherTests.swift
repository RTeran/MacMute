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

    func testSwallowsAutorepeatOfAMatchingShortcutWithoutTriggering() {
        XCTAssertEqual(
            matcher.match(keyCode: micKey, flags: [.maskCommand, .maskShift], isAutorepeat: true),
            .repeated(.mic)
        )
    }

    func testLetsAutorepeatOfOtherKeysThrough() {
        XCTAssertEqual(matcher.match(keyCode: 0, flags: [], isAutorepeat: true), .none)
        XCTAssertEqual(
            matcher.match(keyCode: micKey, flags: [.maskCommand], isAutorepeat: true),
            .modifiersMismatch(.mic)
        )
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

    private func read() -> ShortcutReadResult {
        ShortcutStore.read(keyCodeKey: "keyCode", modifiersKey: "modifiers", from: defaults)
    }

    private func store(keyCode: Int, modifiersRaw: UInt) {
        defaults.set(keyCode, forKey: "keyCode")
        defaults.set(modifiersRaw, forKey: "modifiers")
    }

    private func store(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        store(keyCode: Int(keyCode), modifiersRaw: modifiers.rawValue)
    }

    func testReadsAShortcutOnTheAKey() {
        store(keyCode: 0, modifiers: [.command, .shift])

        XCTAssertEqual(read(), .configured(Shortcut(keyCode: 0, modifiers: [.maskCommand, .maskShift])))
    }

    func testReadsAShortcutOnAnotherKey() {
        store(keyCode: 46, modifiers: [.control, .option])

        XCTAssertEqual(read(), .configured(Shortcut(keyCode: 46, modifiers: [.maskControl, .maskAlternate])))
    }

    func testKeepsOnlyShortcutModifiersFromTheRecordedFlags() {
        let recorded = NSEvent.ModifierFlags([.command, .shift, .capsLock, .function]).rawValue | 0x100
        store(keyCode: 46, modifiersRaw: recorded)

        XCTAssertEqual(read(), .configured(Shortcut(keyCode: 46, modifiers: [.maskCommand, .maskShift])))
    }

    func testKeepsTheShiftOnlyWarningWhenTheRecordedFlagsIncludeFunction() {
        let recorded = NSEvent.ModifierFlags([.shift, .function]).rawValue
        store(keyCode: 46, modifiersRaw: recorded)

        XCTAssertEqual(read().shortcut?.usesShiftAsOnlyModifier, true)
    }

    func testIsNotConfiguredWhenNothingIsStored() {
        XCTAssertEqual(read(), .notConfigured)
    }

    func testIsInvalidWhenNoModifiersAreStored() {
        store(keyCode: 46, modifiers: [])

        XCTAssertEqual(read(), .invalid(keyCode: 46, modifiersRaw: 0))
    }

    func testIsInvalidWhenOnlyNonShortcutModifiersAreStored() {
        let raw = NSEvent.ModifierFlags([.capsLock, .function, .numericPad]).rawValue

        store(keyCode: 46, modifiersRaw: raw)

        XCTAssertEqual(read(), .invalid(keyCode: 46, modifiersRaw: Int(raw)))
    }

    func testIsInvalidWhenTheKeyCodeIsOutOfRange() {
        let raw = NSEvent.ModifierFlags.command.rawValue

        store(keyCode: -1, modifiersRaw: raw)
        XCTAssertEqual(read(), .invalid(keyCode: -1, modifiersRaw: Int(raw)))

        store(keyCode: 70000, modifiersRaw: raw)
        XCTAssertEqual(read(), .invalid(keyCode: 70000, modifiersRaw: Int(raw)))
    }
}

final class ShortcutShiftOnlyTests: XCTestCase {
    func testDetectsShiftAsTheOnlyModifier() {
        XCTAssertTrue(Shortcut(keyCode: 46, modifiers: [.maskShift]).usesShiftAsOnlyModifier)
    }

    func testIgnoresFlagsThatAreNotShortcutModifiers() {
        XCTAssertTrue(Shortcut(keyCode: 46, modifiers: [.maskShift, .maskAlphaShift]).usesShiftAsOnlyModifier)
        XCTAssertTrue(Shortcut(keyCode: 46, modifiers: [.maskShift, .maskSecondaryFn]).usesShiftAsOnlyModifier)
    }

    func testDoesNotFlagShiftCombinedWithAnotherModifier() {
        XCTAssertFalse(Shortcut(keyCode: 46, modifiers: [.maskCommand, .maskShift]).usesShiftAsOnlyModifier)
    }

    func testDoesNotFlagShortcutsWithoutShift() {
        XCTAssertFalse(Shortcut(keyCode: 46, modifiers: [.maskCommand]).usesShiftAsOnlyModifier)
    }
}
