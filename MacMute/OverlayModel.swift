import Cocoa

enum BorderStyle: Equatable {
    case state(micMuted: Bool, cameraOff: Bool, micColor: NSColor, cameraColor: NSColor)
    case unconfirmed(color: NSColor)
}

struct OverlayModel {
    struct ConfirmedState: Equatable {
        var micMuted = false
        var cameraOff = false
        var micColor = NSColor.red.withAlphaComponent(0.7)
        var cameraColor = NSColor.systemBlue.withAlphaComponent(0.7)
    }

    enum Render: Equatable {
        case show(BorderStyle)
        case hide
    }

    private var confirmed = ConfirmedState()
    private var unconfirmedColor: NSColor?
    private var rendered: Render = .hide

    mutating func updateConfirmed(_ state: ConfirmedState) -> Render? {
        confirmed = state
        return apply(desiredRender)
    }

    // Always rendered, even when already shown: a restarted feedback must restart the blinking.
    mutating func showUnconfirmed(color: NSColor) -> Render {
        unconfirmedColor = color
        rendered = desiredRender
        return rendered
    }

    mutating func hideUnconfirmed() -> Render? {
        guard unconfirmedColor != nil else { return nil }
        unconfirmedColor = nil
        return apply(desiredRender)
    }

    mutating func screensChanged() -> Render {
        rendered = desiredRender
        return rendered
    }

    private var desiredRender: Render {
        if let unconfirmedColor { return .show(.unconfirmed(color: unconfirmedColor)) }
        guard confirmed.micMuted || confirmed.cameraOff else { return .hide }
        return .show(.state(
            micMuted: confirmed.micMuted, cameraOff: confirmed.cameraOff,
            micColor: confirmed.micColor, cameraColor: confirmed.cameraColor
        ))
    }

    private mutating func apply(_ render: Render) -> Render? {
        guard render != rendered else { return nil }
        rendered = render
        return render
    }
}
