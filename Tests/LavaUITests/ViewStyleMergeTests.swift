import XCTest

@testable import LavaUI

/// `ViewStyle.merged(over:)` must carry every field it has.
///
/// It copies field by field into a fresh `ViewStyle()`, so a field left out is
/// not merged conservatively — it is dropped, from both sides, with nothing to
/// notice it. That is not hypothetical: `fillGradient` was added to the struct
/// and to every consumer but not to the merge, and because `.frame()` and
/// `.background()` are two styles that merge, a gradient background silently
/// became the flat `fill` sitting beside it. A box that should have been a
/// red-to-black ramp drew solid red, and every other modifier still worked.
///
/// This is written to fail on the *next* omission rather than to re-test that
/// one. `everyFieldSet` must have all of them, and `assertNothingDropped`
/// checks via `Mirror` that nothing came back nil — so adding a field to
/// `ViewStyle` and forgetting either place breaks a test instead of a screen.
final class ViewStyleMergeTests: XCTestCase {
    /// Every field non-nil. Add to this when adding to `ViewStyle`; the first
    /// assertion below is what tells you that you have to.
    private func everyFieldSet() -> ViewStyle {
        var s = ViewStyle()
        s.padding = EdgeInsets(.all, 7)
        s.fill = Color(r: 1, g: 0, b: 0)
        s.fillGradient = Gradient(from: Color(r: 1, g: 0, b: 0),
                                  to: Color(r: 0, g: 0, b: 1), angle: 0.5)
        s.hoverFill = Color(r: 0, g: 1, b: 0)
        s.cornerRadius = 3
        s.width = .pt(120)
        s.height = .pt(40)
        s.minWidth = 10
        s.minHeight = 11
        s.flexGrow = 1
        s.flexShrink = 0
        s.backdropBlurRadius = 6
        s.contentBlurRadius = 5
        s.clipsContent = true
        s.isHidden = false
        return s
    }

    /// Fails naming the field, so a failure says what to fix rather than that
    /// some count disagreed.
    private func assertNothingNil(
        _ style: ViewStyle, _ what: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        for child in Mirror(reflecting: style).children {
            let label = child.label ?? "<unnamed>"
            // Optionals reflect as `.optional` with no children when nil.
            let isNil = Mirror(reflecting: child.value).displayStyle == .optional
                && Mirror(reflecting: child.value).children.isEmpty
            XCTAssertFalse(
                isNil, "\(what): '\(label)' is nil — add it to \(what)",
                file: file, line: line
            )
        }
    }

    func testEveryFieldIsCoveredByTheFixture() {
        assertNothingNil(everyFieldSet(), "everyFieldSet()")
    }

    func testMergingOverEmptyKeepsEveryField() {
        let merged = everyFieldSet().merged(over: ViewStyle())
        assertNothingNil(merged, "merged(over:)")
    }

    func testMergingEmptyOverAFullBaseKeepsEveryField() {
        // The other direction: an empty style must fall through to the base
        // for every field, not just the ones someone remembered.
        let merged = ViewStyle().merged(over: everyFieldSet())
        assertNothingNil(merged, "merged(over:)")
    }

    /// The specific regression, kept because it is the one a person can read.
    func testGradientSurvivesAlongsideAFlatFill() {
        var frame = ViewStyle()
        frame.width = .pt(200)
        var background = ViewStyle()
        let gradient = Gradient(from: Color(r: 1, g: 0, b: 0),
                                to: Color(r: 0, g: 0, b: 0), angle: .pi / 4)
        background.fillGradient = gradient
        background.fill = gradient.from

        let merged = background.merged(over: frame)
        XCTAssertEqual(merged.fillGradient, gradient,
                       "the gradient must survive being merged with .frame()")
        XCTAssertEqual(merged.width, .pt(200))
    }
}
