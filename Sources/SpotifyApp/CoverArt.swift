import Foundation
import LavaUI
import SpotifyCore

#if canImport(CxxCanvas)

/// Async cover: network (`CoverCache`) then decode (`ImageStore`), placeholder
/// while either is outstanding.
///
/// Only the *download* boundary is a body-level change now: `Image(path:)`
/// resolves the texture at emit, so the decode finishing costs a redraw rather
/// than a rebuild of the whole tree, and only covers the frame actually draws
/// are ever requested — viewport gating comes for free from the draw-list cull
/// instead of being this view's problem.
struct CoverArt: View {
    var image: CoverImage?
    var size: Float
    var cornerRadius: Float
    var editor: Editor
    var onClick: (() -> Void)?

    init(
        _ image: CoverImage?,
        size: Float = 140,
        cornerRadius: Float = 4,
        editor: Editor,
        onClick: (() -> Void)? = nil
    ) {
        self.image = image
        self.size = size
        self.cornerRadius = cornerRadius
        self.editor = editor
        self.onClick = onClick
    }

    var body: some View {
        let box = size
        if let url = image?.url,
           let path = CoverCache.pathIfReady(for: url, onReady: {
               // Still `body`: until the file exists there is no path to hand
               // the leaf, so this boundary really does change the view.
               MainQueue.async { ViewInvalidation.markNeedsBody() }
           })
        {
            // Decoded to the box size, not the file's 300px. That is what lets
            // covers live in the shared atlas: anything wider than one cell
            // becomes its own texture and its own descriptor binding.
            Image(
                path: path,
                width: .pt(box),
                height: .pt(box),
                placeholder: SpotifyTheme.coverPlaceholder,
                placeholderCornerRadius: cornerRadius,
                contentMode: .fill,
                onClick: onClick
            )
            .cornerRadius(cornerRadius)
            .frame(width: .pt(box), height: .pt(box))
        } else {
            // Placeholder while the download runs.
            Text(" ", color: .dim, onClick: onClick)
                .frame(width: .pt(box), height: .pt(box))
                .background(SpotifyTheme.coverPlaceholder)
                .cornerRadius(cornerRadius)
        }
    }
}

#endif
