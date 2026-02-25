import Cocoa

class GlobalShortcutManager {
    static let shared = GlobalShortcutManager()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // Mic shortcut
    private var targetKeyCode: UInt16 = 0
    private var targetModifiers: CGEventFlags = []
    private var isConfigured = false
    var onShortcutTriggered: (() -> Void)?

    // Camera shortcut
    private var cameraKeyCode: UInt16 = 0
    private var cameraModifiers: CGEventFlags = []
    private var isCameraConfigured = false
    var onCameraShortcutTriggered: (() -> Void)?

    private init() {
        loadShortcut()
        loadCameraShortcut()
    }

    func start() {
        if AXIsProcessTrusted() {
            createEventTap()
        } else {
            // Prompt once, then poll until granted
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
            NSLog("MacMute: Accessibility permission not granted, waiting for user to allow...")
            pollForAccessibility()
        }
    }

    private func pollForAccessibility() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self else { return }
            if AXIsProcessTrusted() {
                NSLog("MacMute: Accessibility permission granted")
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
            NSLog("MacMute: Failed to create CGEvent tap.")
            return
        }

        self.eventTap = tap
        self.runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            NSLog("MacMute: Global shortcut listener started")
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
        let keyCode = UserDefaults.standard.integer(forKey: "shortcutKeyCode")
        let modifiersRaw = UserDefaults.standard.integer(forKey: "shortcutModifiers")

        if keyCode != 0 && modifiersRaw != 0 {
            targetKeyCode = UInt16(keyCode)
            targetModifiers = cgFlags(from: modifiersRaw)
            isConfigured = true
            NSLog("MacMute: Mic shortcut configured - keyCode: \(targetKeyCode)")
        } else {
            isConfigured = false
        }
    }

    private func loadCameraShortcut() {
        let keyCode = UserDefaults.standard.integer(forKey: "cameraShortcutKeyCode")
        let modifiersRaw = UserDefaults.standard.integer(forKey: "cameraShortcutModifiers")

        if keyCode != 0 && modifiersRaw != 0 {
            cameraKeyCode = UInt16(keyCode)
            cameraModifiers = cgFlags(from: modifiersRaw)
            isCameraConfigured = true
            NSLog("MacMute: Camera shortcut configured - keyCode: \(cameraKeyCode)")
        } else {
            isCameraConfigured = false
        }
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

    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passRetained(event)
        }

        guard type == .keyDown else {
            return Unmanaged.passRetained(event)
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let relevantFlags: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        let pressedModifiers = flags.intersection(relevantFlags)

        if isConfigured {
            let requiredModifiers = targetModifiers.intersection(relevantFlags)
            if keyCode == targetKeyCode && pressedModifiers == requiredModifiers {
                DispatchQueue.main.async { [weak self] in
                    self?.onShortcutTriggered?()
                }
                return nil // Consume the event
            }
        }

        if isCameraConfigured {
            let requiredModifiers = cameraModifiers.intersection(relevantFlags)
            if keyCode == cameraKeyCode && pressedModifiers == requiredModifiers {
                DispatchQueue.main.async { [weak self] in
                    self?.onCameraShortcutTriggered?()
                }
                return nil // Consume the event
            }
        }

        return Unmanaged.passRetained(event)
    }
}
