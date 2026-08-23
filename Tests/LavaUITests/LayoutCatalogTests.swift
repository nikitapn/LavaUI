import XCTest

@testable import LavaUI

/// One place for layout scenarios that used to live only as eyeballs in
/// DemoExample: stacks, flex, percent, and the Image cases that go wrong
/// when a single axis is specified.
///
/// Each test is a small tree under a start-aligned host so the root Yoga
/// node filling the viewport cannot stretch the specimen. Labels on
/// `Canvas` / `Image` are the handles; keep them unique inside a tree.
final class LayoutCatalogTests: XCTestCase {

    // MARK: - Host

    private func frames(
        of view: some View,
        width: Float = 400,
        height: Float = 400
    ) -> [LayoutFrame] {
        let host = LayoutHost()
        host.setRoot(
            VStack(width: .pt(width), height: .pt(height), alignment: .start) {
                view
            }
        )
        return host.calculateLayout(width: width, height: height)
    }

    private func named(
        _ frames: [LayoutFrame], _ label: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> LayoutFrame {
        let matches = frames.filter { $0.label == label }
        XCTAssertEqual(
            matches.count, 1,
            "expected one '\(label)', found \(matches.count): \(frames.map(\.label))",
            file: file, line: line
        )
        return try XCTUnwrap(matches.first, file: file, line: line)
    }

    private func image(
        _ name: String, w: Float, h: Float
    ) -> UIImage {
        UIImage(
            path: name, textureId: 0,
            pixelWidth: w, pixelHeight: h
        )
    }

    private func sized(
        _ label: String, width: LavaUI.Dimension, height: LavaUI.Dimension,
        flexGrow: Float = 0, minWidth: Float = 0
    ) -> some View {
        Canvas(
            label: label,
            width: width,
            height: height,
            flexGrow: flexGrow,
            minWidth: minWidth,
            paint: { _, _ in }
        )
    }

    // MARK: - Image

    /// Both axes auto: the bitmap's native pixels.
    func testImageIntrinsicSize() throws {
        let frames = frames(
            of: Image(image("lab:native", w: 200, h: 100))
        )
        let box = try named(frames, "Image \"lab:native\" 200×100")
        XCTAssertEqual(box.w, 200, accuracy: 0.5)
        XCTAssertEqual(box.h, 100, accuracy: 0.5)
    }

    /// The bug: width set, height left auto, used to keep the native height
    /// so a 200×100 picture at width 80 was an 80×100 strip.
    func testImageWidthWithoutHeightPreservesAspect() throws {
        let frames = frames(
            of: Image(image("lab:w-only", w: 200, h: 100), width: .pt(80))
        )
        let box = try named(frames, "Image \"lab:w-only\" 200×100")
        XCTAssertEqual(box.w, 80, accuracy: 0.5)
        XCTAssertEqual(box.h, 40, accuracy: 0.5)
    }

    func testImageHeightWithoutWidthPreservesAspect() throws {
        let frames = frames(
            of: Image(image("lab:h-only", w: 200, h: 100), height: .pt(40))
        )
        let box = try named(frames, "Image \"lab:h-only\" 200×100")
        XCTAssertEqual(box.w, 80, accuracy: 0.5)
        XCTAssertEqual(box.h, 40, accuracy: 0.5)
    }

    /// Both axes set: the box is the box, `contentMode` only affects paint.
    func testImageBothAxesHonourTheBox() throws {
        let frames = frames(
            of: Image(
                image("lab:both", w: 200, h: 100),
                width: .pt(80), height: .pt(80),
                contentMode: .fit
            )
        )
        let box = try named(frames, "Image \"lab:both\" 200×100")
        XCTAssertEqual(box.w, 80, accuracy: 0.5)
        XCTAssertEqual(box.h, 80, accuracy: 0.5)
    }

    /// Percent width, height auto: half of a 400pt column is 200×100 on a 2:1.
    func testImagePercentWidthWithoutHeight() throws {
        let frames = frames(
            of: Image(
                image("lab:pct", w: 200, h: 100),
                width: .pct(50)
            ),
            width: 400, height: 400
        )
        let box = try named(frames, "Image \"lab:pct\" 200×100")
        XCTAssertEqual(box.w, 200, accuracy: 0.5)
        XCTAssertEqual(box.h, 100, accuracy: 0.5)
    }

    /// `.frame(width:height:)` pins the box; the ratio must not win.
    func testImageFrameBothAxesKeepTheBox() throws {
        let frames = frames(
            of: Image(image("lab:frame-both", w: 200, h: 100))
                .frame(width: .pt(80), height: .pt(80))
        )
        let box = try named(frames, "Image \"lab:frame-both\" 200×100")
        XCTAssertEqual(box.w, 80, accuracy: 0.5)
        XCTAssertEqual(box.h, 80, accuracy: 0.5)
    }

    /// `.frame(width:)` is the other spelling of "width, not height".
    func testImageFrameWidthModifierPreservesAspect() throws {
        let frames = frames(
            of: Image(image("lab:frame-w", w: 200, h: 100))
                .frame(width: .pt(80))
        )
        let box = try named(frames, "Image \"lab:frame-w\" 200×100")
        XCTAssertEqual(box.w, 80, accuracy: 0.5)
        XCTAssertEqual(box.h, 40, accuracy: 0.5)
    }

    /// Default column alignment is stretch. An auto-width image should take
    /// the column and compute height, not sit at native pixels.
    func testImageStretchesInColumnAndKeepsAspect() throws {
        let host = LayoutHost()
        host.setRoot(
            VStack(width: .pt(200), height: .pt(400)) {
                Image(image("lab:stretch", w: 400, h: 100))
            }
        )
        let frames = host.calculateLayout(width: 200, height: 400)
        let box = try named(frames, "Image \"lab:stretch\" 400×100")
        XCTAssertEqual(box.w, 200, accuracy: 0.5)
        XCTAssertEqual(box.h, 50, accuracy: 0.5)
    }

    /// Square bitmap, width only.
    func testImageSquareWidthOnly() throws {
        let frames = frames(
            of: Image(image("lab:sq", w: 64, h: 64), width: .pt(32))
        )
        let box = try named(frames, "Image \"lab:sq\" 64×64")
        XCTAssertEqual(box.w, 32, accuracy: 0.5)
        XCTAssertEqual(box.h, 32, accuracy: 0.5)
    }

    /// A portrait bitmap sized by height.
    func testImagePortraitHeightOnly() throws {
        let frames = frames(
            of: Image(image("lab:port", w: 100, h: 200), height: .pt(80))
        )
        let box = try named(frames, "Image \"lab:port\" 100×200")
        XCTAssertEqual(box.w, 40, accuracy: 0.5)
        XCTAssertEqual(box.h, 80, accuracy: 0.5)
    }

    // MARK: - Stacks

    func testHStackSpacingBetweenChildren() throws {
        let frames = frames(
            of: HStack(spacing: 8) {
                sized("hs-a", width: .pt(10), height: .pt(10))
                sized("hs-b", width: .pt(10), height: .pt(10))
                sized("hs-c", width: .pt(10), height: .pt(10))
            }
        )
        let a = try named(frames, "hs-a")
        let b = try named(frames, "hs-b")
        let c = try named(frames, "hs-c")
        XCTAssertEqual(b.x - a.x, 18, accuracy: 0.5)
        XCTAssertEqual(c.x - b.x, 18, accuracy: 0.5)
        XCTAssertEqual(a.y, b.y, accuracy: 0.5)
    }

    func testHStackZeroSpacingPacksFlush() throws {
        let frames = frames(
            of: HStack(spacing: 0) {
                sized("hz-a", width: .pt(12), height: .pt(8))
                sized("hz-b", width: .pt(12), height: .pt(8))
            }
        )
        let a = try named(frames, "hz-a")
        let b = try named(frames, "hz-b")
        XCTAssertEqual(b.x - a.x, 12, accuracy: 0.5)
    }

    func testHStackCenterAlignsCrossAxis() throws {
        let frames = frames(
            of: HStack(alignment: .center, spacing: 0) {
                sized("hc-tall", width: .pt(10), height: .pt(40))
                sized("hc-short", width: .pt(10), height: .pt(10))
            }
        )
        let tall = try named(frames, "hc-tall")
        let short = try named(frames, "hc-short")
        XCTAssertEqual(short.y - tall.y, 15, accuracy: 0.5)
    }

    func testHStackStartAlignsToTop() throws {
        let frames = frames(
            of: HStack(alignment: .start, spacing: 0) {
                sized("ht-tall", width: .pt(10), height: .pt(40))
                sized("ht-short", width: .pt(10), height: .pt(10))
            }
        )
        let tall = try named(frames, "ht-tall")
        let short = try named(frames, "ht-short")
        XCTAssertEqual(short.y, tall.y, accuracy: 0.5)
    }

    func testVStackStartDoesNotStretchChildren() throws {
        let frames = frames(
            of: VStack(width: .pt(200), alignment: .start, spacing: 0) {
                sized("vs-a", width: .pt(40), height: .pt(10))
            },
            width: 200, height: 200
        )
        let a = try named(frames, "vs-a")
        XCTAssertEqual(a.w, 40, accuracy: 0.5)
        XCTAssertEqual(a.h, 10, accuracy: 0.5)
    }

    func testNestedHStackInsideVStack() throws {
        let frames = frames(
            of: VStack(spacing: 4) {
                sized("nest-top", width: .pt(30), height: .pt(10))
                HStack(spacing: 4) {
                    sized("nest-l", width: .pt(10), height: .pt(10))
                    sized("nest-r", width: .pt(10), height: .pt(10))
                }
            }
        )
        let top = try named(frames, "nest-top")
        let left = try named(frames, "nest-l")
        let right = try named(frames, "nest-r")
        XCTAssertEqual(left.y - top.y, 14, accuracy: 0.5)
        XCTAssertEqual(right.x - left.x, 14, accuracy: 0.5)
        XCTAssertEqual(left.y, right.y, accuracy: 0.5)
    }

    // MARK: - Flex

    func testFlexGrowSharesLeftoverEqually() throws {
        let frames = frames(
            of: HStack(width: .pt(300), height: .pt(20), spacing: 0) {
                sized("fg-a", width: .auto, height: .pt(20), flexGrow: 1)
                sized("fg-b", width: .auto, height: .pt(20), flexGrow: 1)
            },
            width: 300, height: 40
        )
        let a = try named(frames, "fg-a")
        let b = try named(frames, "fg-b")
        XCTAssertEqual(a.w, 150, accuracy: 0.5)
        XCTAssertEqual(b.w, 150, accuracy: 0.5)
    }

    func testSpacerTakesLeftoverBetweenFixedChildren() throws {
        let frames = frames(
            of: HStack(width: .pt(300), height: .pt(20), spacing: 0) {
                sized("sp-l", width: .pt(50), height: .pt(20))
                Spacer()
                sized("sp-r", width: .pt(50), height: .pt(20))
            },
            width: 300, height: 40
        )
        let l = try named(frames, "sp-l")
        let r = try named(frames, "sp-r")
        XCTAssertEqual(l.w, 50, accuracy: 0.5)
        XCTAssertEqual(r.w, 50, accuracy: 0.5)
        XCTAssertEqual(r.x - (l.x + l.w), 200, accuracy: 0.5)
    }

    func testFlexGrowTwoToOne() throws {
        let frames = frames(
            of: HStack(width: .pt(300), height: .pt(20), spacing: 0) {
                sized("fr-a", width: .auto, height: .pt(20), flexGrow: 2)
                sized("fr-b", width: .auto, height: .pt(20), flexGrow: 1)
            },
            width: 300, height: 40
        )
        let a = try named(frames, "fr-a")
        let b = try named(frames, "fr-b")
        XCTAssertEqual(a.w, 200, accuracy: 0.5)
        XCTAssertEqual(b.w, 100, accuracy: 0.5)
    }

    // MARK: - Percent / min / padding

    func testPercentWidthIsHalfOfParent() throws {
        let frames = frames(
            of: sized("pct-half", width: .pct(50), height: .pt(20)),
            width: 400, height: 80
        )
        let box = try named(frames, "pct-half")
        XCTAssertEqual(box.w, 200, accuracy: 0.5)
        XCTAssertEqual(box.h, 20, accuracy: 0.5)
    }

    func testMinWidthFloorsAShrinkingBox() throws {
        let frames = frames(
            of: HStack(width: .pt(60), height: .pt(20), spacing: 0) {
                sized(
                    "min-w",
                    width: .pt(200),
                    height: .pt(20),
                    flexGrow: 1,
                    minWidth: 80
                )
            },
            width: 60, height: 40
        )
        let box = try named(frames, "min-w")
        XCTAssertEqual(box.w, 80, accuracy: 0.5)
    }

    func testCanvasExplicitSizeIsTheBox() throws {
        let frames = frames(
            of: sized("cv", width: .pt(64), height: .pt(18))
        )
        let box = try named(frames, "cv")
        XCTAssertEqual(box.w, 64, accuracy: 0.5)
        XCTAssertEqual(box.h, 18, accuracy: 0.5)
    }

    func testHorizontalPaddingGrowsTheWrapperOnly() throws {
        let frames = frames(
            of: EmptyView()
                .frame(width: .pt(10), height: .pt(10))
                .padding(.horizontal, 12)
        )
        let inner = try named(frames, "EmptyView")
        let wrapper = try named(frames, "Modified")
        XCTAssertEqual(inner.w, 10, accuracy: 0.5)
        XCTAssertEqual(wrapper.w, 34, accuracy: 0.5)
        XCTAssertEqual(inner.x - wrapper.x, 12, accuracy: 0.5)
    }
}
