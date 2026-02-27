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
        let hostingController = NSHostingController(rootView: contentView)
        // Set contentSize upfront so macOS positions the popover correctly below the menu bar.
        // Without this, macOS may flip the popover above the button (off-screen).
        let naturalSize = hostingController.sizeThatFits(in: CGSize(width: 280, height: CGFloat.greatestFiniteMagnitude))
        popover.contentSize = naturalSize
        popover.behavior = .transient
        popover.contentViewController = hostingController

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
            DispatchQueue.main.async { [weak self] in
                self?.constrainPopoverToScreen()
            }
        }
    }

    private func constrainPopoverToScreen() {
        guard let popoverWindow = popover.contentViewController?.view.window,
              let screen = popoverWindow.screen ?? NSScreen.main else { return }

        var frame = popoverWindow.frame
        let topBound = screen.visibleFrame.maxY

        if frame.maxY > topBound {
            frame.origin.y = topBound - frame.height
            popoverWindow.setFrameOrigin(frame.origin)
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
