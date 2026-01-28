import Cocoa

class MenuBarOverlayManager {
    private var overlayWindows: [NSWindow] = []
    private let extraHeight: CGFloat = 10

    func updateOverlay(muted: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if muted {
                self.showOverlays()
            } else {
                self.hideOverlays()
            }
        }
    }

    private func showOverlays() {
        guard overlayWindows.isEmpty else { return }

        let menuBarHeight = NSStatusBar.system.thickness + extraHeight

        for screen in NSScreen.screens {
            let screenFrame = screen.frame
            let overlayFrame = NSRect(
                x: screenFrame.origin.x,
                y: screenFrame.origin.y + screenFrame.height - menuBarHeight,
                width: screenFrame.width,
                height: menuBarHeight
            )

            let window = NSWindow(
                contentRect: overlayFrame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )

            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) - 1)
            window.backgroundColor = NSColor.red.withAlphaComponent(0.7)
            window.isOpaque = false
            window.ignoresMouseEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .stationary]
            window.hasShadow = false
            window.alphaValue = 0

            window.orderFrontRegardless()

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                window.animator().alphaValue = 1.0
            }

            overlayWindows.append(window)
        }
    }

    private func hideOverlays() {
        let windows = overlayWindows
        overlayWindows = []

        for window in windows {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.2
                window.animator().alphaValue = 0
            }, completionHandler: {
                window.orderOut(nil)
            })
        }
    }
}
