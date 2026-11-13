import Cocoa
import SwiftUI

class StatusBarController {
    private var statusItem: NSStatusItem
    private let muteStateManager: MuteStateManager
    private var popover: NSPopover
    private var outsideClickMonitor: Any?

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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(popoverDidClose),
            name: NSPopover.didCloseNotification,
            object: popover
        )
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            // MacMute is an agent app (LSUIElement), so it is not active when the popover opens and
            // `.transient` never sees clicks outside it. Activating also lets the shortcut recorder get keys.
            activateApp()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            startMonitoringOutsideClicks()
            DispatchQueue.main.async { [weak self] in
                self?.constrainPopoverToScreen()
            }
        }
    }

    private func activateApp() {
        if #available(macOS 14, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // A global monitor only sees events sent to other apps, so clicks on the status button
    // or inside the popover never reach it. That covers other menu-bar items too.
    private func startMonitoringOutsideClicks() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.popover.performClose(nil)
        }
    }

    @objc private func popoverDidClose() {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
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
