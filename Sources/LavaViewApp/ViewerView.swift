import Foundation
import LavaUI
import LavaViewCore

/// The window: what is open along the top, the picture, the buttons along the
/// bottom.
///
/// Two thin strips rather than one, and the split is not decoration. Labels
/// change width with every picture and buttons must not move at all, so they
/// cannot share a row — see `TitleBar` and `ControlBar`, which are named for
/// the two halves of that. Everything else is the old Windows viewer: the
/// controls are on one row, at the bottom, and there is nowhere else to look.
struct ViewerView: View {
    @Bindable var session: ViewerSession

    /// Keys go here when nothing else has claimed them. A viewer is a window
    /// with exactly one keyboard target, which is what `setDefault` is for.
    private let keyTarget = NodeID.generate()

    var body: some View {
        // Re-asserted every body pass rather than once at mount, for the
        // reason the terminal does the same: the alternative is a lifecycle
        // question whose wrong answer is a window that silently ignores the
        // keyboard.
        FocusManager.setDefault(
            keyTarget,
            onKey: { [session] event in ViewerKeys.handle(event, session: session) },
            onChar: { _ in false }
        )

        return VStack(flexGrow: 1, spacing: 0) {
            TitleBar(session: session)
            // Divider()
            // Under the title and above the picture, like the editor's find
            // bar: a question about the file should not cover the file it is
            // about.
            if let target = session.pendingSave { confirmBar(target) }
            if let message = message { messageBar(message) }
            picture
            // Divider()
            ControlBar(session: session)
        }
        .background(Theme.current.background)
        .onDrop { urls in session.open(paths: urls.map(\.path)) }
        .windowDrag()
    }

    // MARK: - The picture

    private var picture: some View {
        Canvas(
            label: "picture",
            flexGrow: 1,
            minHeight: 80,
            onGesture: handleGesture,
            onWheel: { _, dy, x, y in session.wheelZoom(notches: dy, atX: x, atY: y) },
            paint: paint
        )
        .flexGrow(1)
        // A pointer that can move the picture should say so. `.pointer` is the
        // nearest thing to a grabbing hand in the shape set both run modes
        // agree on — see `CursorShape`.
        .cursor(session.canPan ? .pointer : .arrow)
        .agentId("picture")
    }

    /// Drag to pan, double-click to toggle fit and original size.
    ///
    /// Coordinates arrive local to the canvas and keep coming after the drag
    /// leaves it, so a fast pan does not stop at the window edge.
    private func handleGesture(_ gesture: CanvasGesture) {
        switch gesture.phase {
        case .began:
            FocusManager.clear()
            if gesture.button == PointerButton.left, gesture.clickCount == 2 {
                session.toggleFitActual()
            }
            dragAnchor = (gesture.localX, gesture.localY)
        case .moved:
            guard let anchor = dragAnchor else { return }
            session.pan(dx: gesture.localX - anchor.x, dy: gesture.localY - anchor.y)
            dragAnchor = (gesture.localX, gesture.localY)
        case .ended:
            dragAnchor = nil
        }
    }

    /// Where the pointer was on the previous move. `@DrawState` because
    /// nothing in the tree is built from it — it exists only between two
    /// pointer events.
    @DrawState private var dragAnchor: (x: Float, y: Float)?

    private func paint(_ list: DrawList, _ frame: CanvasFrame) {
        // Report the box first: fit is defined against it, so the very first
        // frame has to know how big it is. `setBox` compares before it writes
        // and only asks for a body pass on a real change, which is what stops
        // this re-dirtying the frame it is painting.
        if session.setBox(width: frame.w, height: frame.h) {
            ViewInvalidation.markDirty()
        }

        // Dark, and darker than the window. A picture is judged against what
        // surrounds it, and a light surround makes every photograph look
        // washed out — which is why every viewer that shows photographs for a
        // living uses a near-black mat.
        list.rect(x: frame.x, y: frame.y, w: frame.w, h: frame.h, color: Palette.mat)

        guard let image = session.resolveTexture() else {
            centred(list, frame, text: waitingText, color: Theme.current.textDim)
            return
        }

        let place = session.placement
        let w = session.displaySize.width * place.scale
        let h = session.displaySize.height * place.scale
        let x = frame.x + place.offsetX
        let y = frame.y + place.offsetY

        // Clipped to the canvas: at any zoom past fit the picture is larger
        // than its box, and without this it would paint over the control bar.
        list.pushClip(x: frame.x, y: frame.y, w: frame.w, h: frame.h)
        checkerboard(list, frame, x: x, y: y, w: w, h: h)
        list.image(image, x: x, y: y, w: w, h: h)
        // A hairline *around* the picture, so one that is black at the edges
        // still reads as a rectangle against a near-black mat. A stroke, not
        // a filled rect behind it — that version was invisible on every
        // opaque photograph and showed through every transparent PNG.
        list.strokedRect(x: x - 1, y: y - 1, w: w + 2, h: h + 2, color: Palette.edge)
        list.popClip()
    }

    /// The grey chequer every image editor puts behind transparency.
    ///
    /// Without it a transparent PNG is indistinguishable from one that is
    /// genuinely the colour of the mat, which is the single most common thing
    /// people open a viewer to check about a PNG.
    ///
    /// Only over the part of the picture that is actually on screen: at 3200%
    /// the picture is tens of thousands of pixels across and the squares
    /// outside the window are cells nobody can see. Bounded that way it is a
    /// few thousand quads of one colour with no texture change between them,
    /// so the renderer emits them as a single batch.
    private func checkerboard(
        _ list: DrawList, _ frame: CanvasFrame,
        x: Float, y: Float, w: Float, h: Float
    ) {
        let cell: Float = 12
        list.rect(x: x, y: y, w: w, h: h, color: Palette.checkerLight)

        let left = max(x, frame.x)
        let top = max(y, frame.y)
        let right = min(x + w, frame.x + frame.w)
        let bottom = min(y + h, frame.y + frame.h)
        guard right > left, bottom > top else { return }

        // Indices are counted from the picture's own origin, not the window's,
        // so the pattern is anchored to the image and does not crawl when it
        // is panned.
        let firstCol = Int(((left - x) / cell).rounded(.down))
        let lastCol = Int(((right - x) / cell).rounded(.up))
        let firstRow = Int(((top - y) / cell).rounded(.down))
        let lastRow = Int(((bottom - y) / cell).rounded(.up))

        for row in firstRow..<max(firstRow + 1, lastRow) {
            for col in firstCol..<max(firstCol + 1, lastCol) {
                guard (row + col) % 2 == 1 else { continue }
                let cx = x + Float(col) * cell
                let cy = y + Float(row) * cell
                // Clamped to the picture so the chequer never spills past the
                // edge it is standing in for.
                let cw = min(cell, x + w - cx)
                let ch = min(cell, y + h - cy)
                guard cw > 0, ch > 0 else { continue }
                list.rect(x: cx, y: cy, w: cw, h: ch, color: Palette.checkerDark)
            }
        }
    }

    private var waitingText: String {
        if session.loadError != nil { return session.loadError ?? "" }
        if session.folder.isEmpty { return "No image — drop one here, or press O" }
        switch session.status {
        case .turning: return "Turning \(session.currentName)…"
        case .saving: return "Saving…"
        case .failed(let message): return message
        case .ready: return "Opening \(session.currentName)…"
        }
    }

    private func centred(
        _ list: DrawList, _ frame: CanvasFrame, text: String, color: Color
    ) {
        guard let font = Environment.current.font ?? FontStore.default,
              !text.isEmpty
        else { return }
        let size = font.measure(text)
        list.text(
            text,
            // `DrawList.text` insets the pen by 4 to match the old renderText
            // path, so the box starts 4 to the left of where the glyphs do.
            x: frame.x + (frame.w - size.width) / 2 - 4,
            y: frame.y + (frame.h - font.lineHeight) / 2,
            w: size.width + 8, h: font.lineHeight,
            color: color, font: font
        )
    }

    // MARK: - Bars

    /// Overwriting a photograph gets a question, not a click.
    ///
    /// A bar rather than a modal for the reason the editor's find bar is one:
    /// it does not cover the thing being asked about, and the picture is
    /// exactly what the user needs to look at while deciding.
    private func confirmBar(_ target: SaveTarget) -> some View {
        HStack(padding: 10, alignment: .center, spacing: 10) {
            Text(
                target.confirmation(originalPath: session.currentPath ?? ""),
                color: Theme.current.textPrimary
            )
            Spacer()
            Button("Save", action: { session.confirmSave() })
                .agentId("confirm-save")
            Button("Save a Copy…", action: { session.saveCopy() })
                .agentId("save-copy")
            Button("Cancel", action: { session.cancelSave() })
                .agentId("cancel-save")
        }
        .background(Theme.current.panel)
    }

    private var message: (text: String, isError: Bool)? {
        if case .failed(let text) = session.status { return (text, true) }
        if let notice = session.notice { return (notice, false) }
        if session.loadError != nil, session.folder.count > 1 {
            return ("\(session.currentName) could not be opened", true)
        }
        return nil
    }

    private func messageBar(_ message: (text: String, isError: Bool)) -> some View {
        HStack(padding: 8, alignment: .center, spacing: 10) {
            Text(
                message.text,
                color: message.isError ? Palette.warning : Theme.current.textSecondary
            )
            Spacer()
            if session.loadError != nil {
                Text("Skip", color: .accent, onClick: { session.skipUnreadable() })
                    .padding(4)
                    .hoverBackground(Theme.current.hover)
                    .cornerRadius(4)
                    .cursor(.pointer)
                    .agentId("skip-unreadable")
            }
            Text("Dismiss", color: Theme.current.textDim, onClick: { session.dismissNotice() })
                .padding(4)
                .hoverBackground(Theme.current.hover)
                .cornerRadius(4)
                .cursor(.pointer)
                .agentId("dismiss-notice")
        }
        .background(Theme.current.panel)
    }

}

/// Colours that are the app's rather than the theme's.
enum Palette {
    /// The mat behind the picture. Not `theme.canvas` — this has to stay dark
    /// under a light theme too, because it is a viewing surround, not chrome.
    static let mat = Color(r: 0.07, g: 0.07, b: 0.08)
    static let edge = Color(r: 0.30, g: 0.30, b: 0.33)
    /// The chequer behind transparency. Mid greys rather than the usual white
    /// pair: this viewer's mat is near-black, and a white chequer would be the
    /// brightest thing in the window.
    static let checkerLight = Color(r: 0.29, g: 0.29, b: 0.31)
    static let checkerDark = Color(r: 0.22, g: 0.22, b: 0.24)
    static let warning = Color(r: 0.95, g: 0.55, b: 0.35)
}
