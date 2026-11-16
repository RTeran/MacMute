import AppKit
import SwiftUI
import XCTest

final class OverlayModelTests: XCTestCase {
    private let red = NSColor.red.withAlphaComponent(0.7)
    private let blue = NSColor.systemBlue.withAlphaComponent(0.7)
    private let orange = NSColor.systemOrange
    private var model: OverlayModel!

    override func setUp() {
        super.setUp()
        model = OverlayModel()
    }

    private func state(micMuted: Bool = false, cameraOff: Bool = false, micColor: NSColor? = nil) -> OverlayModel.ConfirmedState {
        OverlayModel.ConfirmedState(micMuted: micMuted, cameraOff: cameraOff, micColor: micColor ?? red, cameraColor: blue)
    }

    private func borderStyle(micMuted: Bool = false, cameraOff: Bool = false, micColor: NSColor? = nil) -> BorderStyle {
        .state(micMuted: micMuted, cameraOff: cameraOff, micColor: micColor ?? red, cameraColor: blue)
    }

    func testShowsTheBorderWhenTheMicIsMuted() {
        XCTAssertEqual(model.updateConfirmed(state(micMuted: true)), .show(borderStyle(micMuted: true)))
    }

    func testDoesNothingWhenTheSameStateArrivesTwice() {
        _ = model.updateConfirmed(state(micMuted: true))

        XCTAssertNil(model.updateConfirmed(state(micMuted: true)))
    }

    func testTreatsColorsBuiltTheSameWayAsEqual() {
        let first = NSColor(Color.red).withAlphaComponent(0.7)
        let second = NSColor(Color.red).withAlphaComponent(0.7)
        _ = model.updateConfirmed(state(micMuted: true, micColor: first))

        XCTAssertNil(model.updateConfirmed(state(micMuted: true, micColor: second)))
    }

    func testRestylesWhenAColorChanges() {
        _ = model.updateConfirmed(state(micMuted: true))

        XCTAssertEqual(
            model.updateConfirmed(state(micMuted: true, micColor: .green)),
            .show(borderStyle(micMuted: true, micColor: .green))
        )
    }

    func testHidesWhenNothingIsMutedOrOff() {
        _ = model.updateConfirmed(state(cameraOff: true))

        XCTAssertEqual(model.updateConfirmed(state()), .hide)
    }

    func testDoesNothingWhenNothingIsShownAndNothingIsMuted() {
        XCTAssertNil(model.updateConfirmed(state()))
    }

    func testShowsTheUnconfirmedBorder() {
        XCTAssertEqual(model.showUnconfirmed(color: orange), .show(.unconfirmed(color: orange)))
    }

    func testKeepsTheUnconfirmedBorderWhileConfirmedUpdatesArrive() {
        _ = model.showUnconfirmed(color: orange)

        XCTAssertNil(model.updateConfirmed(state(micMuted: true)))
    }

    func testRestoresTheLatestConfirmedStateWhenTheUnconfirmedBorderEnds() {
        _ = model.updateConfirmed(state(micMuted: true))
        _ = model.showUnconfirmed(color: orange)
        _ = model.updateConfirmed(state(micMuted: false, cameraOff: true))

        XCTAssertEqual(model.hideUnconfirmed(), .show(borderStyle(cameraOff: true)))
    }

    func testDoesNothingWhenHidingAnUnconfirmedBorderThatIsNotShown() {
        _ = model.updateConfirmed(state(micMuted: true))

        XCTAssertNil(model.hideUnconfirmed())
    }

    func testReturnsTheCurrentRenderAgainWhenScreensChange() {
        _ = model.updateConfirmed(state(micMuted: true))

        XCTAssertEqual(model.screensChanged(), .show(borderStyle(micMuted: true)))
    }

    func testReturnsTheUnconfirmedBorderWhenScreensChangeDuringIt() {
        _ = model.showUnconfirmed(color: orange)

        XCTAssertEqual(model.screensChanged(), .show(.unconfirmed(color: orange)))
    }
}
