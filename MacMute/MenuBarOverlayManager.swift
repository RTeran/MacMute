import Cocoa

private enum BorderStyle {
    case state(micMuted: Bool, cameraOff: Bool, micColor: NSColor, cameraColor: NSColor)
    case unconfirmed(color: NSColor)
}

class MenuBarOverlayManager {
    private struct ConfirmedState {
        var micMuted = false
        var cameraOff = false
        var micColor = NSColor.red.withAlphaComponent(0.7)
        var cameraColor = NSColor.systemBlue.withAlphaComponent(0.7)
    }

    private var overlayWindows: [NSWindow] = []
    private var confirmedState = ConfirmedState()
    private var isShowingUnconfirmed = false

    func updateOverlay(
        micMuted: Bool,
        cameraOff: Bool,
        micColor: NSColor = NSColor.red.withAlphaComponent(0.7),
        cameraColor: NSColor = NSColor.systemBlue.withAlphaComponent(0.7)
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.confirmedState = ConfirmedState(
                micMuted: micMuted, cameraOff: cameraOff,
                micColor: micColor, cameraColor: cameraColor
            )
            // The unconfirmed border stays until hideUnconfirmed() restores the latest confirmed state.
            guard !self.isShowingUnconfirmed else { return }
            self.renderConfirmedState()
        }
    }

    func showUnconfirmed(color: NSColor) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isShowingUnconfirmed = true
            self.showOverlays(style: .unconfirmed(color: color))
        }
    }

    func hideUnconfirmed() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isShowingUnconfirmed else { return }
            self.isShowingUnconfirmed = false
            self.renderConfirmedState()
        }
    }

    private func renderConfirmedState() {
        let state = confirmedState
        if state.micMuted || state.cameraOff {
            showOverlays(style: .state(
                micMuted: state.micMuted, cameraOff: state.cameraOff,
                micColor: state.micColor, cameraColor: state.cameraColor
            ))
        } else {
            hideOverlays()
        }
    }

    private func showOverlays(style: BorderStyle) {
        let windows = overlayWindows
        overlayWindows = []
        for window in windows {
            window.orderOut(nil)
        }

        for screen in NSScreen.screens {
            let overlayFrame = screen.frame
            let builtIn = isBuiltInDisplay(screen)

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
            window.sharingType = .none
            window.alphaValue = 0
            window.backgroundColor = .clear

            let borderView = ScreenBorderView(frame: NSRect(origin: .zero, size: overlayFrame.size))
            borderView.configure(style: style, roundTopCorners: builtIn)
            window.contentView = borderView
            window.orderFrontRegardless()

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                window.animator().alphaValue = 1.0
            }
            if case .unconfirmed = style {
                borderView.startPulsing()
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

    private func isBuiltInDisplay(_ screen: NSScreen) -> Bool {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return false
        }
        return CGDisplayIsBuiltin(CGDirectDisplayID(number.uint32Value)) != 0
    }
}

// Profundidad del degradado como porcentaje del alto de la pantalla
private let gradientDepthRatio: CGFloat = 0.03

// Radio de las esquinas superiores en la pantalla built-in del MacBook
private let builtInCornerRadius: CGFloat = 12

private class ScreenBorderView: NSView {
    private var style: BorderStyle = .state(micMuted: false, cameraOff: false, micColor: .red, cameraColor: .blue)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    func configure(style: BorderStyle, roundTopCorners: Bool) {
        self.style = style

        if roundTopCorners {
            // layerMinXMaxYCorner = top-left, layerMaxXMaxYCorner = top-right
            // (NSView no-flipped: max Y = top of view)
            layer?.cornerRadius = builtInCornerRadius
            layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
            layer?.masksToBounds = true
        } else {
            layer?.cornerRadius = 0
            layer?.masksToBounds = false
        }

        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // Fondo completamente transparente
        NSColor.clear.setFill()
        NSBezierPath.fill(bounds)

        let d = bounds.height * gradientDepthRatio
        let w = bounds.width
        let h = bounds.height
        let half = w / 2

        switch style {
        case let .state(micMuted, cameraOff, micColor, cameraColor) where micMuted && cameraOff:
            // Borde superior: mitad izquierda mic, mitad derecha cámara
            drawGradient(micColor,    rect: NSRect(x: 0,    y: h - d, width: half,    height: d), angle: 270)
            drawGradient(cameraColor, rect: NSRect(x: half, y: h - d, width: w - half, height: d), angle: 270)
            // Borde inferior: mitad izquierda mic, mitad derecha cámara
            drawGradient(micColor,    rect: NSRect(x: 0,    y: 0, width: half,    height: d), angle: 90)
            drawGradient(cameraColor, rect: NSRect(x: half, y: 0, width: w - half, height: d), angle: 90)
            // Borde lateral izquierdo: mic (alto total)
            drawGradient(micColor,    rect: NSRect(x: 0,    y: 0, width: d, height: h), angle: 0)
            // Borde lateral derecho: cámara (alto total)
            drawGradient(cameraColor, rect: NSRect(x: w - d, y: 0, width: d, height: h), angle: 180)
        case let .state(micMuted, _, micColor, cameraColor):
            drawFullBorder(micMuted ? micColor : cameraColor, depth: d)
        case let .unconfirmed(color):
            drawFullBorder(color, depth: d)
        }
    }

    func startPulsing() {
        layer?.add(UnconfirmedFeedback.blinkAnimation(), forKey: "unconfirmedPulse")
    }

    private func drawFullBorder(_ color: NSColor, depth d: CGFloat) {
        let w = bounds.width
        let h = bounds.height
        drawGradient(color, rect: NSRect(x: 0,    y: h - d, width: w, height: d), angle: 270) // superior
        drawGradient(color, rect: NSRect(x: 0,    y: 0,     width: w, height: d), angle: 90)  // inferior
        drawGradient(color, rect: NSRect(x: 0,    y: 0,     width: d, height: h), angle: 0)   // izquierdo
        drawGradient(color, rect: NSRect(x: w - d, y: 0,    width: d, height: h), angle: 180) // derecho
    }

    // Dibuja un gradiente de `color` → transparente en `rect`.
    // angle=0: color a izquierda; 90: color abajo; 180: color a derecha; 270: color arriba.
    private func drawGradient(_ color: NSColor, rect: NSRect, angle: CGFloat) {
        guard let gradient = NSGradient(starting: color, ending: .clear) else { return }
        gradient.draw(in: rect, angle: angle)
    }
}
