import Cocoa
import os

struct Shortcut: Equatable {
    let keyCode: UInt16
    let modifiers: CGEventFlags

    var usesShiftAsOnlyModifier: Bool {
        modifiers.intersection(ShortcutMatcher.relevantModifiers) == .maskShift
    }

    func hasSameCombination(as other: Shortcut) -> Bool {
        keyCode == other.keyCode
            && modifiers.intersection(ShortcutMatcher.relevantModifiers)
                == other.modifiers.intersection(ShortcutMatcher.relevantModifiers)
    }
}

extension Shortcut {
    init(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) {
        self.init(keyCode: keyCode, modifiers: ShortcutStore.cgFlags(from: Int(modifierFlags.rawValue)))
    }
}

enum ShortcutMatch: Equatable {
    case triggered(ToggleTarget)
    case repeated(ToggleTarget)
    case modifiersMismatch(ToggleTarget)
    case none

    var action: ShortcutEventAction {
        switch self {
        case let .triggered(target): return .toggle(target)
        case .repeated: return .consume
        case .modifiersMismatch, .none: return .pass
        }
    }
}

enum ShortcutEventAction: Equatable {
    case toggle(ToggleTarget)
    case consume
    case pass
}

struct ShortcutMatcher {
    static let relevantModifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]

    var mic: Shortcut?
    var camera: Shortcut?
    var isSuspended = false

    func action(for event: CGEvent) -> ShortcutEventAction {
        match(event).action
    }

    func conflict(for candidate: Shortcut, recording target: ToggleTarget) -> ToggleTarget? {
        let other: ToggleTarget = target == .mic ? .camera : .mic
        let otherShortcut = other == .mic ? mic : camera
        guard let otherShortcut, otherShortcut.hasSameCombination(as: candidate) else { return nil }
        return other
    }

    func match(_ event: CGEvent) -> ShortcutMatch {
        guard !isSuspended else { return .none }
        return match(
            keyCode: UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)),
            flags: event.flags,
            isAutorepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        )
    }

    func match(keyCode: UInt16, flags: CGEventFlags, isAutorepeat: Bool) -> ShortcutMatch {
        let pressed = flags.intersection(Self.relevantModifiers)
        let configured = [(ToggleTarget.mic, mic), (.camera, camera)]
            .compactMap { target, shortcut in shortcut.map { (target, $0) } }
            .filter { $0.1.keyCode == keyCode }

        if let (target, _) = configured.first(where: { $0.1.modifiers.intersection(Self.relevantModifiers) == pressed }) {
            return isAutorepeat ? .repeated(target) : .triggered(target)
        }
        if let (target, _) = configured.first {
            return .modifiersMismatch(target)
        }
        return .none
    }
}

enum ShortcutReadResult: Equatable {
    case configured(Shortcut)
    case notConfigured
    case invalid(keyCode: Int, modifiersRaw: Int)

    var shortcut: Shortcut? {
        if case let .configured(shortcut) = self { return shortcut }
        return nil
    }
}

enum ShortcutStore {
    static func read(keyCodeKey: String, modifiersKey: String, from defaults: UserDefaults) -> ShortcutReadResult {
        // keyCode 0 is the A key, so presence of the value marks a configured shortcut.
        guard defaults.object(forKey: keyCodeKey) != nil else { return .notConfigured }
        let keyCode = defaults.integer(forKey: keyCodeKey)
        let modifiersRaw = defaults.integer(forKey: modifiersKey)
        let modifiers = cgFlags(from: modifiersRaw)
        guard !modifiers.isEmpty, let validKeyCode = UInt16(exactly: keyCode) else {
            return .invalid(keyCode: keyCode, modifiersRaw: modifiersRaw)
        }
        return .configured(Shortcut(keyCode: validKeyCode, modifiers: modifiers))
    }

    static func cgFlags(from modifiersRaw: Int) -> CGEventFlags {
        let nsFlags = NSEvent.ModifierFlags(rawValue: UInt(modifiersRaw))
        var cgFlags: CGEventFlags = []
        if nsFlags.contains(.command) { cgFlags.insert(.maskCommand) }
        if nsFlags.contains(.control) { cgFlags.insert(.maskControl) }
        if nsFlags.contains(.option) { cgFlags.insert(.maskAlternate) }
        if nsFlags.contains(.shift) { cgFlags.insert(.maskShift) }
        return cgFlags
    }
}

class GlobalShortcutManager {
    static let shared = GlobalShortcutManager()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var matcher = ShortcutMatcher()
    private let logger = Logger(subsystem: "com.macmute.app", category: "shortcut")

    var onShortcutTriggered: (() -> Void)?
    var onCameraShortcutTriggered: (() -> Void)?

    private init() {
        loadShortcut()
        loadCameraShortcut()
    }

    func start() {
        if AXIsProcessTrusted() {
            logger.notice("Accessibility permission granted")
            createEventTap()
        } else {
            // Prompt once, then poll until granted
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
            logger.error("Accessibility permission not granted, waiting for user to allow it")
            pollForAccessibility()
        }
    }

    private func pollForAccessibility() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self else { return }
            if AXIsProcessTrusted() {
                self.logger.notice("Accessibility permission granted after waiting")
                self.createEventTap()
            } else {
                self.pollForAccessibility()
            }
        }
    }

    private func createEventTap() {
        guard eventTap == nil else { return }

        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<GlobalShortcutManager>.fromOpaque(refcon).takeUnretainedValue()
                return manager.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            logger.error("Failed to create the CGEvent tap")
            return
        }

        self.eventTap = tap
        self.runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            logger.notice("Global shortcut listener started")
        }
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    func updateShortcut() {
        loadShortcut()
    }

    func updateCameraShortcut() {
        loadCameraShortcut()
    }

    private func loadShortcut() {
        matcher.mic = readShortcut(keyCodeKey: "shortcutKeyCode", modifiersKey: "shortcutModifiers", target: .mic)
    }

    private func loadCameraShortcut() {
        matcher.camera = readShortcut(
            keyCodeKey: "cameraShortcutKeyCode", modifiersKey: "cameraShortcutModifiers", target: .camera
        )
    }

    private func readShortcut(keyCodeKey: String, modifiersKey: String, target: ToggleTarget) -> Shortcut? {
        switch ShortcutStore.read(keyCodeKey: keyCodeKey, modifiersKey: modifiersKey, from: .standard) {
        case let .configured(shortcut):
            logger.notice("\(target.rawValue, privacy: .public) shortcut configured: keyCode \(shortcut.keyCode, privacy: .public), modifiers \(Self.describe(shortcut.modifiers), privacy: .public)")
            return shortcut
        case .notConfigured:
            logger.notice("No \(target.rawValue, privacy: .public) shortcut configured")
            return nil
        case let .invalid(keyCode, modifiersRaw):
            logger.error("Ignoring invalid \(target.rawValue, privacy: .public) shortcut: keyCode \(keyCode, privacy: .public), modifiers raw \(modifiersRaw, privacy: .public)")
            return nil
        }
    }

    private static func describe(_ flags: CGEventFlags) -> String {
        let names: [(CGEventFlags, String)] = [
            (.maskControl, "ctrl"), (.maskAlternate, "opt"), (.maskShift, "shift"), (.maskCommand, "cmd"),
        ]
        let present = names.filter { flags.contains($0.0) }.map(\.1)
        return present.isEmpty ? "none" : present.joined(separator: "+")
    }

    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            logger.error("Event tap disabled (type \(type.rawValue, privacy: .public)), re-enabling it")
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }

        let match = matcher.match(event)
        if case let .modifiersMismatch(target) = match {
            logger.debug("\(target.rawValue, privacy: .public) shortcut key pressed with modifiers \(Self.describe(event.flags.intersection(ShortcutMatcher.relevantModifiers)), privacy: .public), not matching")
        }

        switch match.action {
        case let .toggle(target):
            logger.notice("\(target.rawValue, privacy: .public) shortcut pressed")
            DispatchQueue.main.async { [weak self] in
                switch target {
                case .mic: self?.onShortcutTriggered?()
                case .camera: self?.onCameraShortcutTriggered?()
                }
            }
            return nil
        case .consume:
            return nil
        case .pass:
            return Unmanaged.passUnretained(event)
        }
    }
}
