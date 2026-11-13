import QuartzCore

enum UnconfirmedFeedback {
    static let blinkCount = 3
    static let blinkPeriod: TimeInterval = 0.6

    // The feedback timer must end right after the last blink, or the border keeps blinking.
    static var duration: TimeInterval { Double(blinkCount) * blinkPeriod }

    static func blinkAnimation() -> CABasicAnimation {
        let blink = CABasicAnimation(keyPath: "opacity")
        blink.fromValue = 1.0
        blink.toValue = 0.25
        blink.duration = blinkPeriod / 2
        blink.autoreverses = true
        blink.repeatCount = Float(blinkCount)
        return blink
    }
}
