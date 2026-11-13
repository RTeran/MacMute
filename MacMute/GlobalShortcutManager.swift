import Cocoa
import os

struct Shortcut: Equatable {
    let keyCode: UInt16
    let modifiers: CGEventFlags
}

enum ShortcutMatch: Equatable {
    case triggered(ToggleTarget)
    case modifiersMismatch(ToggleTarget)
    case none
}

struct ShortcutMatcher {
    static let relevantModifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]

    var mic: Shortcut?
    var camera: Shortcut?

    func match(keyCode: UInt16, flags: CGEventFlags) -> ShortcutMatch {
        let pressed = flags.intersection(Self.relevantModifiers)
        let configured = [(ToggleTarget.mic, mic), (.camera, camera)]
            .compactMap { target, shortcut in shortcut.map { (target, $0) } }
            .filter { $0.1.keyCode == keyCode }

        if let (target, _) = configured.first(where: { $0.1.modifiers.intersection(Self.relevantModifiers) == pressed }) {
            return .triggered(target)
        }
        if let (target, _) = configured.first {
            return .modifiersMismatch(target)
        }
        return .none
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
                guard let refcon = refcon else { return Unmanaged.passRetained(event) }
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
        let keyCode = UserDefaults.standard.integer(forKey: keyCodeKey)
        let modifiersRaw = UserDefaults.standard.integer(forKey: modifiersKey)

        guard keyCode != 0 && modifiersRaw != 0 else {
            logger.notice("No \(target.rawValue, privacy: .public) shortcut configured")
            return nil
        }
        let shortcut = Shortcut(keyCode: UInt16(keyCode), modifiers: cgFlags(from: modifiersRaw))
        logger.notice("\(target.rawValue, privacy: .public) shortcut configured: keyCode \(shortcut.keyCode, privacy: .public), modifiers \(Self.describe(shortcut.modifiers), privacy: .public)")
        return shortcut
    }

    private func cgFlags(from modifiersRaw: Int) -> CGEventFlags {
        let nsFlags = NSEvent.ModifierFlags(rawValue: UInt(modifiersRaw))
        var cgFlags: CGEventFlags = []
        if nsFlags.contains(.command) { cgFlags.insert(.maskCommand) }
        if nsFlags.contains(.control) { cgFlags.insert(.maskControl) }
        if nsFlags.contains(.option) { cgFlags.insert(.maskAlternate) }
        if nsFlags.contains(.shift) { cgFlags.insert(.maskShift) }
        return cgFlags
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
            return Unmanaged.passRetained(event)
        }

        guard type == .keyDown else {
            return Unmanaged.passRetained(event)
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        switch matcher.match(keyCode: keyCode, flags: event.flags) {
        case let .triggered(target):
            logger.notice("\(target.rawValue, privacy: .public) shortcut pressed")
            DispatchQueue.main.async { [weak self] in
                switch target {
                case .mic: self?.onShortcutTriggered?()
                case .camera: self?.onCameraShortcutTriggered?()
                }
            }
            return nil // Consume the event
        case let .modifiersMismatch(target):
            logger.debug("\(target.rawValue, privacy: .public) shortcut key pressed with modifiers \(Self.describe(event.flags.intersection(ShortcutMatcher.relevantModifiers)), privacy: .public), not matching")
            return Unmanaged.passRetained(event)
        case .none:
            return Unmanaged.passRetained(event)
        }
    }
}
