#if canImport(CxxCanvas)
import Foundation

public struct Vector3: Equatable, Sendable, Animatable,
    ExpressibleByArrayLiteral
{
    public var x: Float
    public var y: Float
    public var z: Float

    public init(_ x: Float = 0, _ y: Float = 0, _ z: Float = 0) {
        self.x = x; self.y = y; self.z = z
    }

    public init(arrayLiteral elements: Float...) {
        self.init(
            elements.indices.contains(0) ? elements[0] : 0,
            elements.indices.contains(1) ? elements[1] : 0,
            elements.indices.contains(2) ? elements[2] : 0
        )
    }

    public static func interpolate(_ from: Vector3, _ to: Vector3, _ t: Float) -> Vector3 {
        Vector3(
            Float.interpolate(from.x, to.x, t),
            Float.interpolate(from.y, to.y, t),
            Float.interpolate(from.z, to.z, t)
        )
    }
}

public struct Angle3D: Equatable, Sendable {
    public var radians: Float
    public static let zero = Angle3D(radians: 0)
    public static func radians(_ value: Float) -> Angle3D { Angle3D(radians: value) }
    public static func degrees(_ value: Float) -> Angle3D {
        Angle3D(radians: value * .pi / 180)
    }
}

public struct Transform3D: Equatable, Sendable {
    public var position: Vector3
    public var rotation: Vector3
    public var scale: Vector3

    public init(
        position: Vector3 = Vector3(0, 0, 0),
        rotation: Vector3 = Vector3(0, 0, 0),
        scale: Vector3 = [1, 1, 1]
    ) {
        self.position = position; self.rotation = rotation; self.scale = scale
    }
}

public struct Camera3D: Equatable, Sendable {
    public var position: Vector3
    public var target: Vector3
    public var fieldOfView: Angle3D
    public var near: Float
    public var far: Float

    public static func perspective(
        position: Vector3 = [0, 0, 7], target: Vector3 = [0, 0, 0],
        fieldOfView: Angle3D = .degrees(42), near: Float = 0.05, far: Float = 100
    ) -> Camera3D {
        Camera3D(
            position: position, target: target, fieldOfView: fieldOfView,
            near: near, far: far
        )
    }
}

public struct CameraControls3D: Equatable, Sendable {
    public var orbitSensitivity: Float
    public var panSensitivity: Float
    public var zoomSensitivity: Float
    public var minimumDistance: Float
    public var maximumDistance: Float
    public var minimumPitch: Angle3D
    public var maximumPitch: Angle3D
    public var inertia: Bool
    /// Fraction of drag velocity retained per 60 Hz frame.
    public var deceleration: Float

    public init(
        orbitSensitivity: Float = 0.006,
        panSensitivity: Float = 0.0018,
        zoomSensitivity: Float = 0.12,
        minimumDistance: Float = 2,
        maximumDistance: Float = 20,
        minimumPitch: Angle3D = .degrees(-75),
        maximumPitch: Angle3D = .degrees(75),
        inertia: Bool = true,
        deceleration: Float = 0.88
    ) {
        self.orbitSensitivity = max(0, orbitSensitivity)
        self.panSensitivity = max(0, panSensitivity)
        self.zoomSensitivity = max(0, zoomSensitivity)
        self.minimumDistance = max(0.01, minimumDistance)
        self.maximumDistance = max(self.minimumDistance, maximumDistance)
        self.minimumPitch = Angle3D(radians: min(minimumPitch.radians, maximumPitch.radians))
        self.maximumPitch = Angle3D(radians: max(minimumPitch.radians, maximumPitch.radians))
        self.inertia = inertia
        self.deceleration = min(0.999, max(0, deceleration))
    }

    public static func orbit(
        minimumDistance: Float = 2, maximumDistance: Float = 20,
        inertia: Bool = true
    ) -> CameraControls3D {
        CameraControls3D(
            minimumDistance: minimumDistance,
            maximumDistance: maximumDistance,
            inertia: inertia
        )
    }
}

public struct SpatialAnimation: Equatable, Sendable {
    public var duration: Double
    public var curve: AnimationCurve

    public init(duration: Double = 0.22, curve: AnimationCurve = .easeOut) {
        self.duration = duration; self.curve = curve
    }

    public static func smooth(
        duration: Double = 0.22, curve: AnimationCurve = .easeOut
    ) -> SpatialAnimation {
        SpatialAnimation(duration: duration, curve: curve)
    }

    /// A physically shaped hover/selection transition. `response` controls
    /// how quickly the spring reacts; `dampingFraction` controls its bounce.
    public static func spring(
        response: Double = 0.32, dampingFraction: Double = 0.72
    ) -> SpatialAnimation {
        let response = max(0.01, response)
        let damping = max(0.01, dampingFraction)
        let omega = 2 * Double.pi / response
        let threshold = 0.002
        let duration: Double
        if damping <= 1 {
            duration = -log(threshold) / (damping * omega)
        } else {
            let slowRate = omega * (damping - sqrt(damping * damping - 1))
            duration = -log(threshold) / slowRate
        }
        return SpatialAnimation(
            duration: max(response, min(duration, response * 10)),
            curve: .spring(response: response, dampingFraction: damping)
        )
    }
}

public struct Material3D: Sendable {
    public var color: Color
    public var frontTexture: UIImage?
    public var edgeColor: Color

    public init(
        color: Color = Color(r: 1, g: 1, b: 1),
        texture: UIImage? = nil,
        edgeColor: Color? = nil
    ) {
        self.color = color
        self.frontTexture = texture
        self.edgeColor = edgeColor ?? color
    }

    public static func albumCover(
        front: UIImage, edgeColor: Color = Color(r: 0.12, g: 0.12, b: 0.14)
    ) -> Material3D {
        Material3D(texture: front, edgeColor: edgeColor)
    }
}

public struct Shadow3DStyle: Equatable, Sendable {
    public var color: Color
    public var radius: Float
    public var offsetX: Float
    public var offsetY: Float
    public var opacity: Float

    public init(
        color: Color = Color(r: 0, g: 0, b: 0), radius: Float = 16,
        offsetX: Float = 7, offsetY: Float = 11, opacity: Float = 0.32
    ) {
        self.color = color
        self.radius = max(0, radius)
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.opacity = min(1, max(0, opacity))
    }
}

public protocol View3D {
    func spatialElements() -> [SpatialElement]
}

@resultBuilder
public enum View3DBuilder {
    public static func buildExpression<V: View3D>(_ value: V) -> [SpatialElement] {
        value.spatialElements()
    }
    public static func buildBlock(_ components: [SpatialElement]...) -> [SpatialElement] {
        components.flatMap { $0 }
    }
    public static func buildOptional(_ component: [SpatialElement]?) -> [SpatialElement] {
        component ?? []
    }
    public static func buildEither(first: [SpatialElement]) -> [SpatialElement] { first }
    public static func buildEither(second: [SpatialElement]) -> [SpatialElement] { second }
    public static func buildArray(_ components: [[SpatialElement]]) -> [SpatialElement] {
        components.flatMap { $0 }
    }
}

public struct SpatialElement: View3D {
    enum Geometry: Equatable {
        case plane(width: Float, height: Float)
        case box(Vector3)
        case ambientLight(intensity: Float)
        case directionalLight(direction: Vector3, intensity: Float)
    }
    var id: AnyHashable
    var geometry: Geometry
    var color: Color
    var material: Material3D?
    var shadow: Shadow3DStyle?
    var transform = Transform3D()
    var animation: SpatialAnimation?
    var onHover: ((Bool) -> Void)?
    var onTap: (() -> Void)?

    public func spatialElements() -> [SpatialElement] { [self] }
}

public struct AmbientLight3D: View3D {
    private var element: SpatialElement
    public init(color: Color = Color(r: 1, g: 1, b: 1), intensity: Float = 0.3) {
        element = SpatialElement(
            id: AnyHashable("lavaui.ambient-light"),
            geometry: .ambientLight(intensity: max(0, intensity)), color: color
        )
    }
    public func spatialElements() -> [SpatialElement] { [element] }
}

public struct DirectionalLight3D: View3D {
    private var element: SpatialElement
    public init(
        direction: Vector3 = [-0.4, -0.7, -1],
        color: Color = Color(r: 1, g: 1, b: 1), intensity: Float = 0.9
    ) {
        element = SpatialElement(
            id: AnyHashable("lavaui.directional-light"),
            geometry: .directionalLight(direction: direction, intensity: max(0, intensity)),
            color: color
        )
    }
    public func spatialElements() -> [SpatialElement] { [element] }
}

public struct Plane3D: View3D {
    private var element: SpatialElement
    public init<ID: Hashable>(
        id: ID, width: Float = 1, height: Float = 1, color: Color = .accent
    ) {
        element = SpatialElement(
            id: AnyHashable(id), geometry: .plane(width: width, height: height),
            color: color
        )
    }
    public func spatialElements() -> [SpatialElement] { [element] }
}

public struct Box3D: View3D {
    private var element: SpatialElement
    public init<ID: Hashable>(
        id: ID, width: Float = 1, height: Float = 1, depth: Float = 0.08,
        color: Color = .accent
    ) {
        element = SpatialElement(
            id: AnyHashable(id), geometry: .box([width, height, depth]), color: color
        )
    }
    public func spatialElements() -> [SpatialElement] { [element] }
}

private struct ModifiedView3D<Base: View3D>: View3D {
    var base: Base
    var modify: (inout SpatialElement) -> Void
    func spatialElements() -> [SpatialElement] {
        base.spatialElements().map { value in var copy = value; modify(&copy); return copy }
    }
}

extension View3D {
    public func position(_ value: Vector3) -> some View3D {
        ModifiedView3D(base: self) { $0.transform.position = value }
    }
    public func offset3D(x: Float = 0, y: Float = 0, z: Float = 0) -> some View3D {
        ModifiedView3D(base: self) {
            $0.transform.position.x += x; $0.transform.position.y += y
            $0.transform.position.z += z
        }
    }
    public func scale3D(_ value: Float) -> some View3D {
        ModifiedView3D(base: self) { $0.transform.scale = [value, value, value] }
    }
    public func scale3D(_ value: Vector3) -> some View3D {
        ModifiedView3D(base: self) { $0.transform.scale = value }
    }
    public func rotation3D(angle: Angle3D, axis: Vector3) -> some View3D {
        ModifiedView3D(base: self) {
            $0.transform.rotation = [axis.x * angle.radians, axis.y * angle.radians,
                                     axis.z * angle.radians]
        }
    }
    public func animation3D(_ animation: SpatialAnimation = .smooth()) -> some View3D {
        ModifiedView3D(base: self) { $0.animation = animation }
    }
    public func material3D(_ material: Material3D) -> some View3D {
        ModifiedView3D(base: self) { $0.material = material }
    }
    public func shadow3D(_ style: Shadow3DStyle = Shadow3DStyle()) -> some View3D {
        ModifiedView3D(base: self) { $0.shadow = style }
    }
    public func shadow3D(
        color: Color = Color(r: 0, g: 0, b: 0), radius: Float = 16,
        offsetX: Float = 7, offsetY: Float = 11, opacity: Float = 0.32
    ) -> some View3D {
        shadow3D(Shadow3DStyle(
            color: color, radius: radius, offsetX: offsetX,
            offsetY: offsetY, opacity: opacity
        ))
    }
    public func onHover3D(_ action: @escaping (Bool) -> Void) -> some View3D {
        ModifiedView3D(base: self) { $0.onHover = action }
    }
    public func onTap3D(_ action: @escaping () -> Void) -> some View3D {
        ModifiedView3D(base: self) { $0.onTap = action }
    }
}

public struct ForEach3D<Data: RandomAccessCollection, ID: Hashable, Content: View3D>: View3D {
    public var data: Data
    public var id: KeyPath<Data.Element, ID>
    public var content: (Data.Element) -> Content

    public init(
        _ data: Data, id: KeyPath<Data.Element, ID>,
        @View3DBuilder content: @escaping (Data.Element) -> [SpatialElement]
    ) where Content == SpatialGroup3D {
        self.data = data; self.id = id
        self.content = { SpatialGroup3D(content($0)) }
    }

    public func spatialElements() -> [SpatialElement] {
        data.flatMap { content($0).spatialElements() }
    }
}

public struct SpatialGroup3D: View3D {
    var elements: [SpatialElement]
    public init(@View3DBuilder content: () -> [SpatialElement]) { elements = content() }
    init(_ elements: [SpatialElement]) { self.elements = elements }
    public func spatialElements() -> [SpatialElement] { elements }
}

struct SpatialProjectedVertex {
    var x, y, depth: Float
    var u: Float = 0
    var v: Float = 0
    /// 0 = flat color, 1 = sampled texture.
    var sampleMode: Float = 0
    var color: Color
}

private struct SpatialBatch {
    var triangles: [SpatialProjectedVertex]
    var texture: UIImage?
}

private struct SpatialProjectedObject {
    var element: SpatialElement
    var batches: [SpatialBatch]
    var shadows: [SpatialBatch]
    var triangles: [SpatialProjectedVertex] { batches.flatMap(\.triangles) }
}

public struct Scene3D: PrimitiveView {
    public var camera: Camera3D
    public var cameraControls: CameraControls3D?
    public var width: Dimension
    public var height: Dimension
    public var flexGrow: Float
    var elements: [SpatialElement]

    public init(
        camera: Camera3D = .perspective(), width: Dimension = .auto,
        height: Dimension = .auto, flexGrow: Float = 0,
        cameraControls: CameraControls3D? = nil,
        @View3DBuilder content: () -> [SpatialElement]
    ) {
        self.camera = camera; self.width = width; self.height = height
        self.flexGrow = flexGrow; self.cameraControls = cameraControls
        self.elements = content()
    }

    public var dumpDetail: String { "\(elements.count) objects" }

    public func mountPrimitive() -> any AnyViewNode {
        let leaf = LeafNode(
            kind: .scene3D, label: "Scene3D", width: width, height: height,
            flexGrow: flexGrow
        )
        configure(leaf)
        return leaf
    }

    public func reconcilePrimitive(_ node: any AnyViewNode) -> any AnyViewNode {
        guard let leaf = node as? LeafNode, leaf.kind == .scene3D else {
            return mountPrimitive()
        }
        leaf.width = width; leaf.height = height; leaf.flexGrow = flexGrow
        leaf.applyStyle(); configure(leaf)
        return leaf
    }

    private func configure(_ leaf: LeafNode) {
        let runtime = leaf.spatialRuntime ?? SpatialRuntime(nodeID: leaf.id)
        leaf.spatialRuntime = runtime
        runtime.update(camera: camera, controls: cameraControls, elements: elements)
        leaf.onClickLocal = { [weak leaf, weak runtime] x, y, _, _, mods in
            guard let leaf, let runtime else { return }
            guard runtime.controls != nil else { runtime.tap(x: x, y: y); return }
            runtime.beginCameraGesture(x: x, y: y, mods: mods)
            PointerCapture.capture(
                leaf.id,
                onMove: { [weak runtime] windowX, windowY in
                    guard let runtime else { return }
                    runtime.moveCameraGesture(
                        x: windowX - runtime.lastFrame.x,
                        y: windowY - runtime.lastFrame.y
                    )
                },
                onUp: { [weak runtime] in runtime?.endCameraGesture() }
            )
        }
        leaf.onPointerHoverLocal = { [weak runtime] x, y in runtime?.hover(x: x, y: y) }
        leaf.onHover = { [weak runtime] inside in if !inside { runtime?.leave() } }
        HoverState.register(leaf.id) { [weak leaf] inside in leaf?.onHover?(inside) }
        if cameraControls != nil {
            ScrollRouter.register(leaf.id) { [weak runtime] _, dy in runtime?.zoomCamera(by: dy) }
        } else {
            ScrollRouter.unregister(leaf.id)
        }
    }
}

final class SpatialRuntime {
    struct Motion {
        var position: Animated<Vector3>; var rotation: Animated<Vector3>; var scale: Animated<Vector3>
    }
    let nodeID: NodeID
    var camera: Camera3D = .perspective()
    var controls: CameraControls3D?
    private var configuredCamera: Camera3D?
    private var orbitYaw: Float = 0
    private var orbitPitch: Float = 0
    private var orbitDistance: Float = 1
    private var gesture: CameraGestureState?
    private var orbitVelocity = Vector3(0, 0, 0)
    private var panVelocity = Vector3(0, 0, 0)
    private var cameraStepAt: Double?
    var elements: [SpatialElement] = []
    var motion: [AnyHashable: Motion] = [:]
    private var projected: [SpatialProjectedObject] = []
    var hovered: AnyHashable?
    /// Projection emits window-space vertices because that is what DrawList
    /// consumes, while leaf input handlers deliberately receive coordinates
    /// local to their Yoga box. Keep the exact frame used for projection so
    /// picking crosses that boundary once, in one obvious place.
    var lastFrame = CanvasFrame(x: 0, y: 0, w: 0, h: 0)

    private struct CameraGestureState {
        var lastX: Float
        var lastY: Float
        var lastAt: Double
        var startX: Float
        var startY: Float
        var pan: Bool
    }

    init(nodeID: NodeID) { self.nodeID = nodeID }

    func update(
        camera: Camera3D, controls: CameraControls3D?, elements: [SpatialElement]
    ) {
        let controlsChanged = self.controls != controls
        self.controls = controls
        if configuredCamera != camera {
            configuredCamera = camera
            self.camera = camera
            adoptCameraOrbit()
        } else if controlsChanged, let controls {
            orbitDistance = min(
                controls.maximumDistance, max(controls.minimumDistance, orbitDistance)
            )
            orbitPitch = min(
                controls.maximumPitch.radians,
                max(controls.minimumPitch.radians, orbitPitch)
            )
            rebuildCamera()
        } else if controlsChanged {
            gesture = nil; cameraStepAt = nil
        }
        self.elements = elements
        var animating = false
        for e in elements {
            if var m = motion[e.id] {
                if m.position.target != e.transform.position || m.rotation.target != e.transform.rotation
                    || m.scale.target != e.transform.scale {
                    if let a = e.animation {
                        m.position.animate(to: e.transform.position, duration: a.duration, curve: a.curve)
                        m.rotation.animate(to: e.transform.rotation, duration: a.duration, curve: a.curve)
                        m.scale.animate(to: e.transform.scale, duration: a.duration, curve: a.curve)
                        animating = true
                    } else {
                        m.position.snap(to: e.transform.position); m.rotation.snap(to: e.transform.rotation)
                        m.scale.snap(to: e.transform.scale)
                    }
                    motion[e.id] = m
                }
            } else {
                motion[e.id] = Motion(position: Animated(e.transform.position),
                    rotation: Animated(e.transform.rotation), scale: Animated(e.transform.scale))
            }
        }
        if animating { installAnimation() }
    }

    private func installAnimation() {
        AnimationDriver.register(nodeID) { [weak self] in self?.step() ?? false }
    }

    private func step() -> Bool {
        let now = FrameScheduler.now()
        var active = false
        for key in Array(motion.keys) {
            guard var m = motion[key] else { continue }
            active = m.position.step(now) || active
            active = m.rotation.step(now) || active
            active = m.scale.step(now) || active
            motion[key] = m
        }
        active = stepCamera(now: now) || active
        return active
    }

    private func adoptCameraOrbit() {
        let offset = camera.position - camera.target
        orbitDistance = max(0.0001, length(offset))
        orbitYaw = atan2(offset.x, offset.z)
        orbitPitch = asin(min(1, max(-1, offset.y / orbitDistance)))
    }

    private func rebuildCamera() {
        let cp = cos(orbitPitch)
        let offset = Vector3(
            sin(orbitYaw) * cp * orbitDistance,
            sin(orbitPitch) * orbitDistance,
            cos(orbitYaw) * cp * orbitDistance
        )
        camera.position = camera.target + offset
        ViewInvalidation.markNeedsRedraw()
    }

    func beginCameraGesture(x: Float, y: Float, mods: Int32) {
        let now = FrameScheduler.now()
        gesture = CameraGestureState(
            lastX: x, lastY: y, lastAt: now, startX: x, startY: y,
            pan: KeyMods.contains(mods, KeyMods.shift)
        )
        orbitVelocity = Vector3(0, 0, 0); panVelocity = Vector3(0, 0, 0)
        cameraStepAt = nil
    }

    func moveCameraGesture(x: Float, y: Float) {
        guard let controls, var gesture else { return }
        let now = FrameScheduler.now()
        let dx = x - gesture.lastX, dy = y - gesture.lastY
        let dt = Float(max(1.0 / 240.0, now - gesture.lastAt))
        if gesture.pan {
            let forward = normalized(camera.target - camera.position)
            let right = normalized(cross(forward, [0, 1, 0]))
            let up = cross(right, forward)
            let scale = orbitDistance * controls.panSensitivity
            let delta = right * (-dx * scale) + up * (dy * scale)
            camera.target = camera.target + delta
            let measured = limited(delta * (1 / dt), to: orbitDistance * 1.5)
            panVelocity = panVelocity * 0.35 + measured * 0.65
        } else {
            let yawDelta = -dx * controls.orbitSensitivity
            let pitchDelta = -dy * controls.orbitSensitivity
            orbitYaw += yawDelta
            orbitPitch = min(
                controls.maximumPitch.radians,
                max(controls.minimumPitch.radians, orbitPitch + pitchDelta)
            )
            let measured = limited([yawDelta / dt, pitchDelta / dt, 0], to: 4)
            orbitVelocity = orbitVelocity * 0.35 + measured * 0.65
        }
        gesture.lastX = x; gesture.lastY = y; gesture.lastAt = now
        self.gesture = gesture
        rebuildCamera()
    }

    func endCameraGesture() {
        guard let gesture else { return }
        self.gesture = nil
        let moved = hypot(gesture.lastX - gesture.startX, gesture.lastY - gesture.startY)
        if moved < 4 { tap(x: gesture.startX, y: gesture.startY) }
        guard controls?.inertia == true,
              length(orbitVelocity) > 0.01 || length(panVelocity) > 0.01 else { return }
        cameraStepAt = FrameScheduler.now()
        installAnimation()
    }

    func zoomCamera(by wheelDelta: Float) {
        guard let controls else { return }
        let factor = exp(-wheelDelta * controls.zoomSensitivity)
        orbitDistance = min(
            controls.maximumDistance,
            max(controls.minimumDistance, orbitDistance * factor)
        )
        orbitVelocity = Vector3(0, 0, 0); panVelocity = Vector3(0, 0, 0)
        cameraStepAt = nil
        rebuildCamera()
    }

    private func stepCamera(now: Double) -> Bool {
        guard gesture == nil, let controls, let previous = cameraStepAt else { return false }
        let dt = Float(min(1.0 / 15.0, max(0, now - previous)))
        cameraStepAt = now
        orbitYaw += orbitVelocity.x * dt
        orbitPitch = min(
            controls.maximumPitch.radians,
            max(controls.minimumPitch.radians, orbitPitch + orbitVelocity.y * dt)
        )
        camera.target = camera.target + panVelocity * dt
        let decay = pow(controls.deceleration, dt * 60)
        orbitVelocity = orbitVelocity * decay
        panVelocity = panVelocity * decay
        rebuildCamera()
        if length(orbitVelocity) < 0.01 && length(panVelocity) < 0.01 {
            orbitVelocity = Vector3(0, 0, 0); panVelocity = Vector3(0, 0, 0)
            cameraStepAt = nil
            return false
        }
        return true
    }

    func emit(_ draw: DrawList, frame: CanvasFrame) {
        guard frame.w > 0, frame.h > 0 else { return }
        lastFrame = frame
        // A projected object can extend well beyond its Yoga box after camera
        // orbit, zoom, or hover lift. Scene3D is a viewport by definition, so
        // establish its scissor itself rather than requiring every caller to
        // remember `.clipped()`. The renderer intersects nested clips.
        draw.pushClip(x: frame.x, y: frame.y, w: frame.w, h: frame.h)
        defer { draw.popClip() }
        draw.beginSpatialScene(frame)
        projected = elements.map { e in
            let t = motion[e.id].map {
                Transform3D(position: $0.position.current, rotation: $0.rotation.current,
                            scale: $0.scale.current)
            } ?? e.transform
            return SpatialProjectedObject(
                element: e,
                batches: project(element: e, transform: t, frame: frame),
                shadows: projectShadow(element: e, transform: t, frame: frame)
            )
        }
        let shadowRadius = elements.compactMap(\.shadow?.radius).max() ?? 0
        draw.withSpatialShadowBlur(frame: frame, radius: shadowRadius) {
            for item in projected {
                for batch in item.shadows {
                    draw.spatialTriangles(batch.triangles, texture: nil)
                }
            }
        }
        for item in projected {
            for batch in item.batches {
                draw.spatialTriangles(batch.triangles, texture: batch.texture)
            }
        }
    }

    private func projectShadow(
        element: SpatialElement, transform: Transform3D, frame: CanvasFrame
    ) -> [SpatialBatch] {
        guard let style = element.shadow, style.opacity > 0 else { return [] }
        let w: Float, h: Float, z: Float
        switch element.geometry {
        case .plane(let width, let height):
            w = width; h = height; z = 0
        case .box(let size):
            w = size.x; h = size.y; z = size.z / 2
        case .ambientLight, .directionalLight:
            return []
        }
        let local: [Vector3] = [[-w/2,-h/2,z],[w/2,-h/2,z],[w/2,h/2,z],[-w/2,h/2,z]]
        let projectedCorners = local.compactMap { project(apply(transform,$0),frame:frame) }
        guard projectedCorners.count == 4 else { return [] }
        let order = [0,2,1,0,3,2]
        let uv: [(Float,Float)] = [(0,1),(1,1),(1,0),(0,0)]
        let vertices = order.map { index -> SpatialProjectedVertex in
            let p = projectedCorners[index]
            return SpatialProjectedVertex(
                x:p.x + style.offsetX,
                y:p.y + style.offsetY,
                depth:min(1,p.z + 0.0005),u:uv[index].0,v:uv[index].1,
                sampleMode:0,color:style.color.opacity(style.opacity)
            )
        }
        return [SpatialBatch(triangles:vertices,texture:nil)]
    }

    func hover(x: Float, y: Float) {
        let hit = hitID(x: x, y: y)
        guard hit != hovered else { return }
        if let old = hovered, let e = elements.first(where: { $0.id == old }) { e.onHover?(false) }
        hovered = hit
        if let hit, let e = elements.first(where: { $0.id == hit }) { e.onHover?(true) }
        ViewInvalidation.markNeedsRedraw()
    }
    func leave() { hover(x: -.greatestFiniteMagnitude, y: -.greatestFiniteMagnitude) }
    func tap(x: Float, y: Float) {
        guard let id = hitID(x: x, y: y) else { return }
        elements.first(where: { $0.id == id })?.onTap?()
    }

    private func hitID(x: Float, y: Float) -> AnyHashable? {
        let windowX = x + lastFrame.x
        let windowY = y + lastFrame.y
        var best: (AnyHashable, Float)?
        for item in projected where item.element.onHover != nil || item.element.onTap != nil {
            for i in stride(from: 0, to: item.triangles.count, by: 3) {
                let a = item.triangles[i], b = item.triangles[i+1], c = item.triangles[i+2]
                guard pointInTriangle(windowX, windowY, a, b, c) else { continue }
                let depth = min(a.depth, min(b.depth, c.depth))
                if best == nil || depth < best!.1 { best = (item.element.id, depth) }
            }
        }
        return best?.0
    }

    private func project(
        element: SpatialElement, transform: Transform3D, frame: CanvasFrame
    ) -> [SpatialBatch] {
        struct Face {
            var corners: [Vector3]
            var normal: Vector3
            var texture: UIImage?
            var color: Color
        }
        let material = element.material
        let base = material?.color ?? element.color
        let edge = material?.edgeColor ?? element.color
        let faces: [Face]
        switch element.geometry {
        case .plane(let w, let h):
            faces = [Face(corners: [[-w/2,-h/2,0],[w/2,-h/2,0],
                                    [w/2,h/2,0],[-w/2,h/2,0]],
                          normal: [0,0,1], texture: material?.frontTexture, color: base)]
        case .box(let s):
            let x=s.x/2, y=s.y/2, z=s.z/2
            faces = [
                Face(corners:[[-x,-y,z],[x,-y,z],[x,y,z],[-x,y,z]], normal:[0,0,1],
                     texture:material?.frontTexture,color:base),
                Face(corners:[[x,-y,-z],[-x,-y,-z],[-x,y,-z],[x,y,-z]], normal:[0,0,-1],texture:nil,color:edge),
                Face(corners:[[-x,-y,-z],[-x,-y,z],[-x,y,z],[-x,y,-z]], normal:[-1,0,0],texture:nil,color:edge),
                Face(corners:[[x,-y,z],[x,-y,-z],[x,y,-z],[x,y,z]], normal:[1,0,0],texture:nil,color:edge),
                Face(corners:[[-x,y,z],[x,y,z],[x,y,-z],[-x,y,-z]], normal:[0,1,0],texture:nil,color:edge),
                Face(corners:[[-x,-y,-z],[x,-y,-z],[x,-y,z],[-x,-y,z]], normal:[0,-1,0],texture:nil,color:edge),
            ]
        case .ambientLight, .directionalLight:
            return []
        }

        let order = [0,2,1,0,3,2]
        let uv: [(Float,Float)] = [(0,1),(1,1),(1,0),(0,0)]
        return faces.compactMap { face in
            let lit = litColor(face.color, normal: rotate(transform, face.normal))
            let vertices = order.compactMap { index -> SpatialProjectedVertex? in
                guard let p = project(apply(transform, face.corners[index]), frame: frame) else {
                    return nil
                }
                return SpatialProjectedVertex(
                    x: p.x, y: p.y, depth: p.z, u: uv[index].0, v: uv[index].1,
                    sampleMode: face.texture == nil ? 0 : 1, color: lit
                )
            }
            guard vertices.count == 6 else { return nil }
            // Keep one cover descriptor bound for the whole object. Edge
            // vertices disable sampling themselves, avoiding cover→white→cover
            // descriptor churn for every album in a large catalog.
            return SpatialBatch(
                triangles: vertices, texture: material?.frontTexture ?? face.texture
            )
        }
    }

    private func litColor(_ base: Color, normal: Vector3) -> Color {
        let ambientLights = elements.compactMap { e -> (Color,Float)? in
            if case .ambientLight(let intensity) = e.geometry { return (e.color,intensity) }
            return nil
        }
        let directionalLights = elements.compactMap { e -> (Vector3,Color,Float)? in
            if case .directionalLight(let direction, let intensity) = e.geometry {
                return (direction,e.color,intensity)
            }
            return nil
        }
        let ambients = ambientLights.isEmpty ? [(Color(r:1,g:1,b:1),Float(0.3))] : ambientLights
        let directionals = directionalLights.isEmpty
            ? [([-0.4,-0.7,-1] as Vector3,Color(r:1,g:1,b:1),Float(0.9))] : directionalLights
        var lr:Float=0, lg:Float=0, lb:Float=0
        for (c,i) in ambients { lr += c.r*i; lg += c.g*i; lb += c.b*i }
        let n = normalized(normal)
        for (direction,c,i) in directionals {
            let d = normalized([-direction.x,-direction.y,-direction.z])
            let amount = max(0,dot(n,d))*i
            lr += c.r*amount; lg += c.g*amount; lb += c.b*amount
        }
        return Color(r:min(1,base.r*lr),g:min(1,base.g*lg),b:min(1,base.b*lb),a:base.a)
    }

    private func apply(_ t: Transform3D, _ input: Vector3) -> Vector3 {
        var v = Vector3(input.x*t.scale.x,input.y*t.scale.y,input.z*t.scale.z)
        let cx=cos(t.rotation.x), sx=sin(t.rotation.x); v = [v.x,v.y*cx-v.z*sx,v.y*sx+v.z*cx]
        let cy=cos(t.rotation.y), sy=sin(t.rotation.y); v = [v.x*cy+v.z*sy,v.y,-v.x*sy+v.z*cy]
        let cz=cos(t.rotation.z), sz=sin(t.rotation.z); v = [v.x*cz-v.y*sz,v.x*sz+v.y*cz,v.z]
        return [v.x+t.position.x,v.y+t.position.y,v.z+t.position.z]
    }

    private func rotate(_ t: Transform3D, _ input: Vector3) -> Vector3 {
        var copy = t; copy.position = [0,0,0]; copy.scale = [1,1,1]
        return apply(copy,input)
    }

    private func project(_ p: Vector3, frame: CanvasFrame) -> Vector3? {
        let forward = normalized(camera.target - camera.position)
        let right = normalized(cross(forward, [0,1,0]))
        let up = cross(right, forward)
        let delta = p - camera.position
        let z = dot(delta, forward)
        guard z > camera.near else { return nil }
        let focal = frame.h * 0.5 / tan(camera.fieldOfView.radians * 0.5)
        return [frame.x + frame.w*0.5 + dot(delta,right)*focal/z,
                frame.y + frame.h*0.5 - dot(delta,up)*focal/z,
                min(1, max(0, (z-camera.near)/(camera.far-camera.near)))]
    }
}

private func +(a: Vector3,b: Vector3)->Vector3 { [a.x+b.x,a.y+b.y,a.z+b.z] }
private func -(a: Vector3,b: Vector3)->Vector3 { [a.x-b.x,a.y-b.y,a.z-b.z] }
private func *(a: Vector3,b: Float)->Vector3 { [a.x*b,a.y*b,a.z*b] }
private func dot(_ a: Vector3,_ b: Vector3)->Float { a.x*b.x+a.y*b.y+a.z*b.z }
private func cross(_ a: Vector3,_ b: Vector3)->Vector3 { [a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x] }
private func length(_ v: Vector3)->Float { sqrt(dot(v,v)) }
private func limited(_ v: Vector3, to maximum: Float)->Vector3 {
    let magnitude = length(v)
    return magnitude > maximum ? v * (maximum / magnitude) : v
}
private func normalized(_ v: Vector3)->Vector3 { let l=max(0.0001,sqrt(dot(v,v))); return [v.x/l,v.y/l,v.z/l] }
private func pointInTriangle(_ x:Float,_ y:Float,_ a:SpatialProjectedVertex,_ b:SpatialProjectedVertex,_ c:SpatialProjectedVertex)->Bool {
    let d1=(x-b.x)*(a.y-b.y)-(a.x-b.x)*(y-b.y)
    let d2=(x-c.x)*(b.y-c.y)-(b.x-c.x)*(y-c.y)
    let d3=(x-a.x)*(c.y-a.y)-(c.x-a.x)*(y-a.y)
    return !((d1 < 0 || d2 < 0 || d3 < 0) && (d1 > 0 || d2 > 0 || d3 > 0))
}
#endif
