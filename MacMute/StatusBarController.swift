import Cocoa
import SwiftUI

class StatusBarController {
    private var statusItem: NSStatusItem
    private let muteStateManager: MuteStateManager
    private var popover: NSPopover

    init(muteStateManager: MuteStateManager) {
        self.muteStateManager = muteStateManager
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = NSPopover()

        let contentView = ShortcutConfigView(muteStateManager: muteStateManager)
        popover.contentSize = NSSize(width: 300, height: 250)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: contentView)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "MacMute")
            button.action = #selector(togglePopover)
            button.target = self
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(muteStateChanged),
            name: .muteStateDidChange,
            object: nil
        )
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    @objc private func muteStateChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let isMuted = self.muteStateManager.isMuted
            let symbolName = isMuted ? "mic.slash.fill" : "mic.fill"
            self.statusItem.button?.image = NSImage(
                systemSymbolName: symbolName,
                accessibilityDescription: isMuted ? "Muted" : "Unmuted"
            )
        }
    }
}
