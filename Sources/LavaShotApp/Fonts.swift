import Foundation
import LavaShotCore
import LavaUI

/// The faces a label is drawn in, one per stroke weight.
///
/// Loaded once, because `loadUI` opens and rasterises a face and a screenshot
/// tool that did that per frame would stutter while somebody typed. Four
/// sizes, chosen to match the four stroke widths: the width picker is already
/// the "how loud is this annotation" control, and a second one for text size
/// would be two controls for one intention.
enum Fonts {
    private nonisolated(unsafe) static var faces: [Float: UIFont] = [:]

    /// Points of text per point of stroke. A four-point line and
    /// twenty-point text read as the same weight of mark on a screen.
    private static let sizeForWidth: [Float: Float] = [2: 14, 4: 20, 7: 28, 12: 40]

    static func warm() {
        for width in ShotOutput.widths {
            guard let size = sizeForWidth[width] else { continue }
            faces[width] = UIFont.loadUI(
                assetsRoot: LavaResources.root, pixelSize: size
            )
        }
    }

    /// The face for a stroke weight, falling back to the interface font so a
    /// label is never simply invisible.
    static func forStroke(_ width: Float) -> UIFont? {
        faces[width] ?? FontStore.default
    }
}
