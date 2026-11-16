import Cocoa

class MenuBarOverlayManager {
    private struct ScreenKey: Equatable {
        let displayID: CGDirectDisplayID?
        let frame: NSRect
    }

    private var model = OverlayModel()
    private var overlayWindows: [NSWindow] = []
    private var screenLayout: [ScreenKey] = []
    private var isHidden = true
    private var screenObserver: NSObjectProtocol?

    init() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.screensChanged()
        }
    }

    deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }

    func updateOverlay(
        micMuted: Bool,
        cameraOff: Bool,
        micColor: NSColor = NSColor.red.withAlphaComponent(0.7),
        cameraColor: NSColor = NSColor.systemBlue.withAlphaComponent(0.7)
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let state = OverlayModel.ConfirmedState(
                micMuted: micMuted, cameraOff: cameraOff,
                micColor: micColor, cameraColor: cameraColor
            )
            self.render(self.model.updateConfirmed(state))
        }
    }

    func showUnconfirmed(color: NSColor) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.render(self.model.showUnconfirmed(color: color))
        }
    }

    func hideUnconfirmed() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.render(self.model.hideUnconfirmed())
        }
    }

    private func screensChanged() {
        guard currentScreenLayout() != screenLayout else { return }
        let render = model.screensChanged()
        for window in overlayWindows {
            window.orderOut(nil)
        }
        overlayWindows = []
        screenLayout = []
        isHidden = true
        self.render(render)
    }

    private func render(_ render: OverlayModel.Render?) {
        switch render {
        case let .show(style): showOverlays(style: style)
        case .hide: hideOverlays()
        case nil: break
        }
    }

    private func showOverlays(style: BorderStyle) {
        if overlayWindows.isEmpty || currentScreenLayout() != screenLayout {
            rebuildWindows()
        }

        for window in overlayWindows {
            guard let borderView = window.contentView as? ScreenBorderView else { continue }
            borderView.configure(style: style)
            if case .unconfirmed = style {
                borderView.startPulsing()
            } else {
                borderView.stopPulsing()
            }
        }

        guard isHidden else { return }
        isHidden = false
        for window in overlayWindows {
            window.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                window.animator().alphaValue = 1.0
            }
        }
    }

    private func hideOverlays() {
        guard !isHidden else { return }
        isHidden = true

        for window in overlayWindows {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.2
                window.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                // A show may have started while this fade-out was running.
                guard self?.isHidden ?? true else { return }
                window.orderOut(nil)
            })
        }
    }

    private func rebuildWindows() {
        for window in overlayWindows {
            window.orderOut(nil)
        }
        isHidden = true
        screenLayout = currentScreenLayout()
        overlayWindows = NSScreen.screens.map(makeWindow)
    }

    private func makeWindow(for screen: NSScreen) -> NSWindow {
        let overlayFrame = screen.frame
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
        borderView.setRoundTopCorners(isBuiltInDisplay(screen))
        window.contentView = borderView
        return window
    }

    private func currentScreenLayout() -> [ScreenKey] {
        NSScreen.screens.map { ScreenKey(displayID: displayID(of: $0), frame: $0.frame) }
    }

    private func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(number.uint32Value)
    }

    private func isBuiltInDisplay(_ screen: NSScreen) -> Bool {
        guard let id = displayID(of: screen) else { return false }
        return CGDisplayIsBuiltin(id) != 0
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

    func configure(style: BorderStyle) {
        guard style != self.style else { return }
        self.style = style
        needsDisplay = true
    }

    func setRoundTopCorners(_ roundTopCorners: Bool) {
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
        guard layer?.animation(forKey: Self.pulseKey) == nil else { return }
        layer?.add(UnconfirmedFeedback.blinkAnimation(), forKey: Self.pulseKey)
    }

    func stopPulsing() {
        layer?.removeAnimation(forKey: Self.pulseKey)
    }

    private static let pulseKey = "unconfirmedPulse"

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
