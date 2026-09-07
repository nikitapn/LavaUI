import XCTest

@testable import LavaViewCore

/// The arithmetic behind Fit, 1:1, and the wheel.
///
/// All of it is reachable without a window, which is the point of keeping it
/// here: "zoom towards the cursor" is one subtraction away from "zoom towards
/// the corner", and the difference is invisible in a layout tree and obvious
/// only when a person tries it.
final class ViewportTests: XCTestCase {
    private let box = PixelSize(width: 800, height: 600)
    private let photo = PixelSize(width: 4000, height: 3000)
    private let icon = PixelSize(width: 64, height: 64)

    // MARK: - Fit

    func testFitShrinksToTheTighterAxis() {
        // 800/4000 = 0.2, 600/3000 = 0.2 — same here, so use a shape where
        // they differ: a panorama is limited by width.
        let panorama = PixelSize(width: 4000, height: 500)
        XCTAssertEqual(ViewportMath.fitScale(image: panorama, box: box), 0.2, accuracy: 1e-6)
    }

    func testFitNeverEnlarges() {
        XCTAssertEqual(ViewportMath.fitScale(image: icon, box: box), 1)
    }

    func testFitOfAnEmptyImageIsHarmless() {
        let empty = PixelSize(width: 0, height: 0)
        XCTAssertEqual(ViewportMath.fitScale(image: empty, box: box), 1)
        XCTAssertEqual(ViewportMath.fitScale(image: photo, box: empty), 1)
    }

    func testModesResolveAgainstTheBox() {
        XCTAssertEqual(
            ViewportMath.scale(for: .fit, image: photo, box: box, free: 7), 0.2,
            accuracy: 1e-6
        )
        XCTAssertEqual(ViewportMath.scale(for: .actual, image: photo, box: box, free: 7), 1)
        XCTAssertEqual(ViewportMath.scale(for: .free, image: photo, box: box, free: 7), 7)
    }

    // MARK: - Placement

    func testAnImageSmallerThanTheBoxIsCentred() {
        let placed = ViewportMath.clamped(
            Viewport(scale: 1, offsetX: -500, offsetY: 900), image: icon, box: box
        )
        XCTAssertEqual(placed.offsetX, (800 - 64) / 2, accuracy: 1e-4)
        XCTAssertEqual(placed.offsetY, (600 - 64) / 2, accuracy: 1e-4)
    }

    func testALargerImageCannotShowAGapAtAnEdge() {
        // At 1:1 the photo is 4000×3000 in an 800×600 box.
        let dragged = ViewportMath.clamped(
            Viewport(scale: 1, offsetX: 300, offsetY: 200), image: photo, box: box
        )
        XCTAssertEqual(dragged.offsetX, 0, accuracy: 1e-4)
        XCTAssertEqual(dragged.offsetY, 0, accuracy: 1e-4)

        let far = ViewportMath.clamped(
            Viewport(scale: 1, offsetX: -9999, offsetY: -9999), image: photo, box: box
        )
        XCTAssertEqual(far.offsetX, 800 - 4000, accuracy: 1e-4)
        XCTAssertEqual(far.offsetY, 600 - 3000, accuracy: 1e-4)
    }

    func testAxesAreClampedIndependently() {
        // Wider than the box, shorter than it: pannable in X, centred in Y.
        let letterbox = PixelSize(width: 4000, height: 200)
        let placed = ViewportMath.clamped(
            Viewport(scale: 1, offsetX: -100, offsetY: 999), image: letterbox, box: box
        )
        XCTAssertEqual(placed.offsetX, -100, accuracy: 1e-4)
        XCTAssertEqual(placed.offsetY, (600 - 200) / 2, accuracy: 1e-4)
    }

    // MARK: - Zoom towards the cursor

    func testZoomKeepsThePixelUnderTheCursorStill() {
        // Start fitted, then zoom in with the pointer at a specific spot.
        let start = ViewportMath.centered(
            scale: ViewportMath.fitScale(image: photo, box: box), image: photo, box: box
        )
        let anchorX: Float = 640
        let anchorY: Float = 150
        // Which pixel of the photograph is under the pointer right now.
        let sourceX = (anchorX - start.offsetX) / start.scale
        let sourceY = (anchorY - start.offsetY) / start.scale

        let zoomed = ViewportMath.zoomed(
            start, to: start.scale * 4, anchorX: anchorX, anchorY: anchorY,
            image: photo, box: box
        )

        // The same photograph pixel must still land under the same point.
        XCTAssertEqual(zoomed.offsetX + sourceX * zoomed.scale, anchorX, accuracy: 0.01)
        XCTAssertEqual(zoomed.offsetY + sourceY * zoomed.scale, anchorY, accuracy: 0.01)
    }

    func testZoomingOutPastFitRecentres() {
        let start = ViewportMath.centered(scale: 1, image: photo, box: box)
        let out = ViewportMath.zoomed(
            start, to: 0.05, anchorX: 0, anchorY: 0, image: photo, box: box
        )
        // 4000 * 0.05 = 200, well inside the box, so the anchor stops
        // mattering entirely.
        XCTAssertEqual(out.offsetX, (800 - 200) / 2, accuracy: 1e-4)
        XCTAssertEqual(out.offsetY, (600 - 150) / 2, accuracy: 1e-4)
    }

    func testScaleIsClampedBothWays() {
        let start = ViewportMath.centered(scale: 1, image: photo, box: box)
        XCTAssertEqual(
            ViewportMath.zoomed(
                start, to: 5000, anchorX: 0, anchorY: 0, image: photo, box: box
            ).scale,
            ViewportMath.maxScale
        )
        XCTAssertEqual(
            ViewportMath.zoomed(
                start, to: 0.0001, anchorX: 0, anchorY: 0, image: photo, box: box
            ).scale,
            ViewportMath.minScale
        )
    }

    // MARK: - Panning

    func testPanIsRefusedWhenEverythingIsVisible() {
        let fitted = ViewportMath.centered(scale: 0.2, image: photo, box: box)
        XCTAssertFalse(ViewportMath.isPannable(fitted, image: photo, box: box))
        let panned = ViewportMath.panned(
            fitted, dx: 50, dy: 50, image: photo, box: box
        )
        XCTAssertEqual(panned.offsetX, fitted.offsetX, accuracy: 1e-4)
    }

    func testPanMovesAndThenStops() {
        // Centred at 1:1 a 4000-wide photo in an 800-wide box starts at
        // -1600, which is the middle, not an edge.
        var v = ViewportMath.centered(scale: 1, image: photo, box: box)
        XCTAssertTrue(ViewportMath.isPannable(v, image: photo, box: box))
        XCTAssertEqual(v.offsetX, -1600, accuracy: 1e-4)

        v = ViewportMath.panned(v, dx: -100, dy: 0, image: photo, box: box)
        XCTAssertEqual(v.offsetX, -1700, accuracy: 1e-4)

        // Dragging far right stops with the picture's left edge at the box's,
        // never past it.
        v = ViewportMath.panned(v, dx: 9999, dy: 0, image: photo, box: box)
        XCTAssertEqual(v.offsetX, 0, accuracy: 1e-4)

        // And far left stops with its right edge at the box's.
        v = ViewportMath.panned(v, dx: -9999, dy: 0, image: photo, box: box)
        XCTAssertEqual(v.offsetX, 800 - 4000, accuracy: 1e-4)
    }

    // MARK: - The ladder

    func testLadderStepsPastTheCurrentScale() {
        XCTAssertEqual(ZoomLadder.next(above: 1.0), 1.5, accuracy: 1e-6)
        XCTAssertEqual(ZoomLadder.next(below: 1.0), 0.66, accuracy: 1e-6)
    }

    func testLadderStopsAtTheEnds() {
        XCTAssertEqual(ZoomLadder.next(above: 999), ZoomLadder.stops.last!)
        XCTAssertEqual(ZoomLadder.next(below: 0.001), ZoomLadder.stops.first!)
    }

    func testLadderIsNotDefeatedByFloatingPointOnAStop() {
        // 0.5 arrived at by arithmetic rather than typed in.
        let half = Float(1) / Float(2)
        XCTAssertEqual(ZoomLadder.next(above: half), 0.66, accuracy: 1e-6)
        XCTAssertEqual(ZoomLadder.next(below: half), 0.33, accuracy: 1e-6)
    }

    func testWheelIsReversible() {
        // In and straight back out returns to where it started, which is the
        // whole reason the wheel is geometric rather than a linear step.
        let there = ZoomLadder.wheeled(0.37, notches: 3)
        let back = ZoomLadder.wheeled(there, notches: -3)
        XCTAssertEqual(back, 0.37, accuracy: 1e-4)
    }

    func testWheelHonoursTheScaleLimits() {
        XCTAssertEqual(ZoomLadder.wheeled(30, notches: 20), ViewportMath.maxScale)
        XCTAssertEqual(ZoomLadder.wheeled(0.03, notches: -20), ViewportMath.minScale)
    }

    // MARK: - Readout

    func testVisibleSourceNeverExceedsTheImage() {
        let fitted = ViewportMath.centered(scale: 0.2, image: photo, box: box)
        let seen = ViewportMath.visibleSource(fitted, image: photo, box: box)
        XCTAssertEqual(seen.width, 4000, accuracy: 1e-4)
        let zoomed = ViewportMath.centered(scale: 2, image: photo, box: box)
        XCTAssertEqual(
            ViewportMath.visibleSource(zoomed, image: photo, box: box).width,
            400, accuracy: 1e-4
        )
    }
}
