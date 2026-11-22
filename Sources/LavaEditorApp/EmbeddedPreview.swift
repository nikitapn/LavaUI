#if canImport(LavaEditorExtensionAPI)
import Foundation
import LavaClient
import LavaEditorExtensionAPI
import LavaUI
import NPRPC

/// Immutable after validation on the RPC thread. Only the UI thread replays it.
private struct SurfaceReply: @unchecked Sendable {
    let frame: EmbeddedDrawFrame
    let images: [SurfaceImage]
    let state: [UInt8]

    init?(_ wire: SurfaceFrame) {
        guard wire.state.count <= 64 * 1024, wire.images.count <= 32 else { return nil }
        var ids = Set<UInt32>()
        var bytes = 0
        for image in wire.images {
            guard image.id != 0, ids.insert(image.id).inserted,
                  (1...2048).contains(image.width), (1...2048).contains(image.height),
                  image.rgba.count == Int(image.width * image.height) * 4 else { return nil }
            bytes += image.rgba.count
        }
        guard bytes <= 4 << 20,
              let frame = EmbeddedDrawFrame(commands: wire.commands, glyphs: wire.glyphs, imageIDs: ids)
        else { return nil }
        self.frame = frame
        images = wire.images
        state = wire.state
    }
}

private final class SurfaceService: EmbeddedSurfaceProviderServant, @unchecked Sendable {
    private struct Call {
        let request: SurfaceRequest
        let document: PreviewDocument
        var reply: SurfaceReply?
    }
    private let lock = NSLock()
    private var calls: [UInt64: Call] = [:]
    private static let endpoint = Result<(SurfaceService, String), Error> {
        let poa = try ClientRpcRuntime.start().createPoa(maxObjects: 1)
        let service = SurfaceService()
        let id = try poa.activateObject(service, flags: .shm)
        guard let object = NPRPCObject.fromObjectId(id) else {
            throw SelectionExtension.Failure(message: "Could not open the surface endpoint.")
        }
        return (service, object.toString())
    }

    static func render(provider: InstalledCommand, document: PreviewDocument, request: SurfaceRequest) throws -> SurfaceReply {
        let (service, reference) = try endpoint.get()
        let token = service.lock.withLock {
            let token = invocationToken(excluding: service.calls)
            service.calls[token] = Call(request: request, document: document)
            return token
        }
        defer { service.lock.withLock { service.calls[token] = nil } }
        try ExtensionHost.invoke(provider, reference: reference, invocation: token, timeoutMS: 10_000, reuse: true)
        guard let reply = service.lock.withLock({ service.calls[token]?.reply }) else {
            throw SelectionExtension.Failure(message: "The extension returned without a valid surface frame.")
        }
        return reply
    }

    override func readRequest(invocation: UInt64) throws -> SurfaceRequest {
        try lock.withLock {
            guard let call = calls[invocation] else { throw ExpiredInvocation() }
            return call.request
        }
    }

    override func readDocument(invocation: UInt64) throws -> PreviewDocument {
        try lock.withLock {
            guard let call = calls[invocation] else { throw ExpiredInvocation() }
            return call.document
        }
    }

    override func submitFrame(invocation: UInt64, frame: SurfaceFrame) -> Bool {
        lock.withLock {
            guard let call = calls[invocation], call.reply == nil,
                  frame.viewportId == call.request.viewport.id, frame.frameId == call.request.frameId,
                  let reply = SurfaceReply(frame) else { return false }
            calls[invocation]?.reply = reply
            return true
        }
    }
}

/// All mutable surface state belongs to the editor's UI loop. Background
/// calls carry immutable snapshots and hand their result back to that loop.
final class EmbeddedPreview: @unchecked Sendable {
    let focusID = NodeID.generate()
    private let provider: InstalledCommand
    private let source: PreviewDocument
    private var viewport = SurfaceViewport()
    private var nextFrame: UInt64 = 0
    private var presented: UInt64 = 0
    private var accepted: UInt64 = 0
    private var visible = false
    private var focused = false
    private var busy = false
    private var needsFrame = false
    private var events: [SurfaceInput] = []
    private var state: [UInt8] = []
    private var frame: EmbeddedDrawFrame?
    private var images: [UInt32: UIImage] = [:]
    private var imageData: [UInt32: SurfaceImage] = [:]
    private var resources: (any GPUResourceHost)?
    private var error: String?

    init(provider: InstalledCommand, source: PreviewDocument) {
        self.provider = provider
        self.source = source
    }

    deinit {
        let keys = images.values.map(\.cacheKey)
        if !keys.isEmpty {
            MainQueue.async { [resources] in
                for key in keys { resources?.releaseImage(key: key) }
            }
        }
    }

    func hide() {
        visible = false
        if focused { input(.focus, code: 0) }
        focused = false
        input(.cancel)
        FocusManager.resignFocus(focusID)
    }

    func paint(_ list: DrawList, box: CanvasFrame, editor: Editor, font: UIFont, foreground: Color) {
        guard box.w > 0, box.h > 0 else { return }
        visible = true
        resources = editor.resources
        if viewport.width != box.w || viewport.height != box.h || viewport.scale != list.displayScale ||
            viewport.fontSha256 != font.contentDigest || viewport.fontPath != font.path || viewport.size26_6 != font.pixelSize26_6 ||
            viewport.face != font.faceIndex || viewport.rasterFlags != font.raster.raw {
            if presented != 0 { input(.cancel) }
            viewport = SurfaceViewport(id: viewport.id + 1, width: box.w, height: box.h, scale: list.displayScale,
                                       fontPath: font.path, fontSha256: font.contentDigest, face: font.faceIndex, size26_6: font.pixelSize26_6,
                                       rasterFlags: font.raster.raw)
            presented = 0
            frame = nil
            needsFrame = true
        }
        let hasFocus = FocusManager.isFocused(focusID)
        if hasFocus != focused, presented != 0 {
            focused = hasFocus
            input(.focus, code: focused ? 1 : 0)
        }
        schedule()
        if let frame, error == nil {
            list.drawEmbedded(frame, in: box, font: font, images: images)
            presented = accepted
        } else {
            list.pushClip(x: box.x, y: box.y, w: box.w, h: box.h)
            list.text(error ?? "Loading preview…", x: box.x + 12, y: box.y + 12, w: box.w, h: font.lineHeight,
                      color: foreground, font: font)
            list.popClip()
        }
    }

    @discardableResult
    func input(_ kind: SurfaceInputKind, x: Float = 0, y: Float = 0, dx: Float = 0, dy: Float = 0,
               code: Int32 = 0, mods: Int32 = 0, repeated: Bool = false, text: String = "") -> Bool {
        guard presented != 0, error == nil else { return false }
        let event = SurfaceInput(kind: kind, viewportId: viewport.id, frameId: presented, x: x, y: y,
                                 dx: dx, dy: dy, code: code, mods: mods, repeatKey: repeated, text: text)
        if (kind == .motion || kind == .drag), events.last?.kind == kind, events.last?.frameId == presented {
            events[events.count - 1] = event
        } else {
            guard events.count < 256 else {
                fail("Preview input queue filled. Reopen the preview to retry.")
                return false
            }
            events.append(event)
        }
        needsFrame = true
        schedule()
        return true
    }

    private func schedule() {
        guard visible, !busy, needsFrame, error == nil else { return }
        busy = true
        needsFrame = false
        nextFrame += 1
        let request = SurfaceRequest(viewport: viewport, frameId: nextFrame, state: state, events: events)
        events.removeAll(keepingCapacity: true)
        DispatchQueue.global(qos: .userInitiated).async { [weak self, provider, source] in
            let result = Result { try SurfaceService.render(provider: provider, document: source, request: request) }
            MainQueue.async { [weak self] in self?.finish(result, request: request) }
        }
    }

    private func fail(_ message: String) {
        error = message
        events.removeAll()
        ViewInvalidation.markDirty()
    }

    private func finish(_ result: Result<SurfaceReply, Error>, request: SurfaceRequest) {
        busy = false
        guard error == nil else { return }
        switch result {
        case .failure(let failure):
            fail(failure.localizedDescription)
        case .success(let reply):
            state = reply.state
            if request.viewport.id == viewport.id, let resources {
                var mapped: [UInt32: UIImage] = [:]
                var uploaded: [UIImage] = []
                for image in reply.images {
                    if let previous = imageData[image.id], previous.width == image.width,
                       previous.height == image.height, previous.rgba == image.rgba, let existing = images[image.id] {
                        mapped[image.id] = existing
                        continue
                    }
                    let texture = image.rgba.withUnsafeBytes {
                        resources.uploadPixels($0, width: image.width, height: image.height,
                                            stride: image.width * 4, format: .rgba8)
                    }
                    guard let texture else {
                        for image in uploaded { resources.releaseImage(key: image.cacheKey) }
                        fail("Could not upload the preview image.")
                        return
                    }
                    uploaded.append(texture)
                    mapped[image.id] = texture
                }
                for (id, image) in images where image !== mapped[id] {
                    resources.releaseImage(key: image.cacheKey)
                }
                imageData = Dictionary(uniqueKeysWithValues: reply.images.map { ($0.id, $0) })
                images = mapped
                accepted = request.frameId
                frame = reply.frame
                ViewInvalidation.markDirty()
            }
            schedule()
        }
    }
}

struct EmbeddedPreviewCanvas: View {
    let surface: EmbeddedPreview
    let editor: Editor
    let font: UIFont
    let foreground: Color

    var body: some View {
        Canvas(label: "Extension surface", width: .pct(100), flexGrow: 1, onGesture: { [surface] gesture in
            let kind: SurfaceInputKind
            switch gesture.phase {
            case .began:
                kind = .press
                FocusManager.focus(surface.focusID, onKey: { [weak surface] key in
                    surface?.input(.key, code: key.key, mods: key.mods, repeated: key.isRepeat) ?? false
                }, onChar: { [weak surface] char in surface?.input(.character, text: String(char)) ?? false })
            case .moved: kind = .drag
            case .ended: kind = .release
            }
            surface.input(kind, x: gesture.localX, y: gesture.localY, code: gesture.button, mods: gesture.mods)
        }, onWheel: { dx, dy, x, y in
            surface.input(.wheel, x: x, y: y, dx: dx, dy: dy)
        }, onHover: { inside in
            if !inside { surface.input(.leave) }
        }, onPointerMove: { x, y in
            surface.input(.motion, x: x, y: y)
            return nil
        }, focusID: surface.focusID) { list, box in
            surface.paint(list, box: box, editor: editor, font: font, foreground: foreground)
        }
        .agentId("extension-surface")
    }
}
#endif
