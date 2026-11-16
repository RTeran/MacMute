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
        XCTAssertEqual(matcher.match(keyCode: micKey, flags: [.maskCommand, .maskShift], isAutorepeat: false), .triggered(.mic))
    }

    func testTriggersTheCameraWhenKeyAndModifiersMatch() {
        XCTAssertEqual(matcher.match(keyCode: cameraKey, flags: [.maskControl], isAutorepeat: false), .triggered(.camera))
    }

    func testIgnoresFlagsThatAreNotShortcutModifiers() {
        XCTAssertEqual(
            matcher.match(keyCode: micKey, flags: [.maskCommand, .maskShift, .maskAlphaShift, .maskNonCoalesced], isAutorepeat: false),
            .triggered(.mic)
        )
    }

    func testReportsAModifierMismatchWhenOnlyTheKeyMatches() {
        XCTAssertEqual(matcher.match(keyCode: micKey, flags: [.maskCommand], isAutorepeat: false), .modifiersMismatch(.mic))
        XCTAssertEqual(matcher.match(keyCode: cameraKey, flags: [], isAutorepeat: false), .modifiersMismatch(.camera))
    }

    func testDoesNotMatchOtherKeys() {
        XCTAssertEqual(matcher.match(keyCode: 0, flags: [.maskCommand, .maskShift], isAutorepeat: false), .none)
    }

    func testDoesNotMatchAnUnconfiguredShortcut() {
        let micOnly = ShortcutMatcher(mic: Shortcut(keyCode: micKey, modifiers: [.maskCommand]), camera: nil)

        XCTAssertEqual(micOnly.match(keyCode: cameraKey, flags: [.maskControl], isAutorepeat: false), .none)
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

final class ShortcutEventActionTests: XCTestCase {
    private let micKey: UInt16 = 46
    private let matcher = ShortcutMatcher(
        mic: Shortcut(keyCode: 46, modifiers: [.maskCommand, .maskShift]),
        camera: nil
    )

    private func keyDown(_ keyCode: UInt16, flags: CGEventFlags, autorepeat: Bool = false) -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true)!
        event.flags = flags
        if autorepeat {
            event.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        }
        return event
    }

    func testTogglesOnAFreshPressOfTheShortcut() {
        XCTAssertEqual(matcher.action(for: keyDown(micKey, flags: [.maskCommand, .maskShift])), .toggle(.mic))
    }

    func testConsumesAnAutorepeatOfTheShortcutWithoutToggling() {
        let event = keyDown(micKey, flags: [.maskCommand, .maskShift], autorepeat: true)

        XCTAssertEqual(matcher.action(for: event), .consume)
    }

    func testPassesOtherKeysAndTheirAutorepeat() {
        XCTAssertEqual(matcher.action(for: keyDown(0, flags: [])), .pass)
        XCTAssertEqual(matcher.action(for: keyDown(0, flags: [], autorepeat: true)), .pass)
    }

    func testPassesTheShortcutKeyWithOtherModifiers() {
        XCTAssertEqual(matcher.action(for: keyDown(micKey, flags: [.maskCommand])), .pass)
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

final class ShortcutRecordingTests: XCTestCase {
    private let micShortcut = Shortcut(keyCode: 46, modifiers: [.maskCommand, .maskShift])
    private let cameraShortcut = Shortcut(keyCode: 8, modifiers: [.maskControl])
    private var matcher: ShortcutMatcher!

    override func setUp() {
        super.setUp()
        matcher = ShortcutMatcher(mic: micShortcut, camera: cameraShortcut)
    }

    func testPassesTheShortcutWhileSuspendedForRecording() {
        matcher.isSuspended = true
        let event = CGEvent(keyboardEventSource: nil, virtualKey: 46, keyDown: true)!
        event.flags = [.maskCommand, .maskShift]

        XCTAssertEqual(matcher.action(for: event), .pass)
    }

    func testReportsTheOtherTargetWhenTheCombinationIsTaken() {
        XCTAssertEqual(matcher.conflict(for: micShortcut, recording: .camera), .mic)
        XCTAssertEqual(matcher.conflict(for: cameraShortcut, recording: .mic), .camera)
    }

    func testIgnoresFlagsThatAreNotShortcutModifiersWhenLookingForConflicts() {
        let candidate = Shortcut(keyCode: 46, modifiers: [.maskCommand, .maskShift, .maskAlphaShift])

        XCTAssertEqual(matcher.conflict(for: candidate, recording: .camera), .mic)
    }

    func testDoesNotReportAConflictForADifferentCombination() {
        let sameKeyOtherModifiers = Shortcut(keyCode: 46, modifiers: [.maskCommand])
        let otherKeySameModifiers = Shortcut(keyCode: 47, modifiers: [.maskCommand, .maskShift])

        XCTAssertNil(matcher.conflict(for: sameKeyOtherModifiers, recording: .camera))
        XCTAssertNil(matcher.conflict(for: otherKeySameModifiers, recording: .camera))
    }

    func testDoesNotReportAConflictWithTheShortcutBeingReRecorded() {
        XCTAssertNil(matcher.conflict(for: micShortcut, recording: .mic))
    }

    func testDoesNotReportAConflictWhenTheOtherShortcutIsNotConfigured() {
        let micOnly = ShortcutMatcher(mic: micShortcut, camera: nil)

        XCTAssertNil(micOnly.conflict(for: cameraShortcut, recording: .mic))
    }

    func testBuildsAShortcutFromRecordedModifierFlags() {
        let shortcut = Shortcut(keyCode: 46, modifierFlags: [.command, .shift, .capsLock])

        XCTAssertEqual(shortcut, Shortcut(keyCode: 46, modifiers: [.maskCommand, .maskShift]))
    }
}
