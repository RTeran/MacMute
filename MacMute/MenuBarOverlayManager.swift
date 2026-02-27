import Cocoa

class MenuBarOverlayManager {
    private var overlayWindows: [NSWindow] = []
    private let extraHeight: CGFloat = 10

    func updateOverlay(
        micMuted: Bool,
        cameraOff: Bool,
        micColor: NSColor = NSColor.red.withAlphaComponent(0.7),
        cameraColor: NSColor = NSColor.systemBlue.withAlphaComponent(0.7)
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if micMuted || cameraOff {
                self.showOverlays(micMuted: micMuted, cameraOff: cameraOff,
                                  micColor: micColor, cameraColor: cameraColor)
            } else {
                self.hideOverlays()
            }
        }
    }

    private func showOverlays(micMuted: Bool, cameraOff: Bool,
                              micColor: NSColor, cameraColor: NSColor) {
        // Rebuild overlays when state changes
        let windows = overlayWindows
        overlayWindows = []
        for window in windows {
            window.orderOut(nil)
        }

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
            window.isOpaque = false
            window.ignoresMouseEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .stationary]
            window.hasShadow = false
            window.alphaValue = 0
            window.backgroundColor = .clear

            let contentView = NSView(frame: NSRect(origin: .zero, size: overlayFrame.size))
            contentView.wantsLayer = true

            if micMuted && cameraOff {
                // Split: left half mic color, right half camera color
                let halfWidth = overlayFrame.width / 2

                let micView = NSView(frame: NSRect(x: 0, y: 0, width: halfWidth, height: overlayFrame.height))
                micView.wantsLayer = true
                micView.layer?.backgroundColor = micColor.cgColor

                let cameraView = NSView(frame: NSRect(x: halfWidth, y: 0, width: halfWidth, height: overlayFrame.height))
                cameraView.wantsLayer = true
                cameraView.layer?.backgroundColor = cameraColor.cgColor

                contentView.addSubview(micView)
                contentView.addSubview(cameraView)
            } else if micMuted {
                contentView.layer?.backgroundColor = micColor.cgColor
            } else {
                contentView.layer?.backgroundColor = cameraColor.cgColor
            }

            window.contentView = contentView
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
