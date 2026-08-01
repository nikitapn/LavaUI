import Foundation
import LavaUI
import SpotifyCore

#if canImport(CxxCanvas)

/// Async cover: network (`CoverCache`) then decode (`ImageStore`), placeholder
/// while either is outstanding.
///
/// Request only the covers that appear in the current view tree — the image
/// cache doc is explicit that request windowing is the app's job. A home shelf
/// of ~12 albums is fine; a library of thousands would need viewport gating.
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
               MainQueue.async { ViewInvalidation.markNeedsBody() }
           }),
           let ui = ImageStore.imageIfLoaded(path: path, into: editor)
        {
            Image(ui, width: .pt(box), height: .pt(box), contentMode: .fill, onClick: onClick)
                .cornerRadius(cornerRadius)
                .frame(width: .pt(box), height: .pt(box))
        } else {
            // Placeholder while download/decode run.
            Text(" ", color: .dim, onClick: onClick)
                .frame(width: .pt(box), height: .pt(box))
                .background(SpotifyTheme.coverPlaceholder)
                .cornerRadius(cornerRadius)
        }
    }
}

#endif
