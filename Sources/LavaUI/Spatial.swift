import Foundation

/// A point, direction or per-axis scale in a `Scene3D`'s world.
///
/// +x is right, +y up and +z toward the default camera, which sits on the
/// +z axis looking at the origin. Writable as an array literal: `[0, 1, 0]`.
public struct Vector3: Equatable, Sendable, Animatable,
    ExpressibleByArrayLiteral
{
    /// The x component.
    public var x: Float
    /// The y component.
    public var y: Float
    /// The z component.
    public var z: Float

    /// Creates a vector; missing components are zero.
    public init(_ x: Float = 0, _ y: Float = 0, _ z: Float = 0) {
        self.x = x; self.y = y; self.z = z
    }

    /// Creates a vector from up to three literals, `[x, y, z]`; missing ones are zero.
    public init(arrayLiteral elements: Float...) {
        self.init(
            elements.indices.contains(0) ? elements[0] : 0,
            elements.indices.contains(1) ? elements[1] : 0,
            elements.indices.contains(2) ? elements[2] : 0
        )
    }

    /// Interpolates each component linearly.
    public static func interpolate(_ from: Vector3, _ to: Vector3, _ t: Float) -> Vector3 {
        Vector3(
            Float.interpolate(from.x, to.x, t),
            Float.interpolate(from.y, to.y, t),
            Float.interpolate(from.z, to.z, t)
        )
    }
}

/// An angle, stored in radians.
public struct Angle3D: Equatable, Sendable {
    /// The angle in radians.
    public var radians: Float
    /// No rotation.
    public static let zero = Angle3D(radians: 0)
    /// An angle given in radians.
    public static func radians(_ value: Float) -> Angle3D { Angle3D(radians: value) }
    /// An angle given in degrees.
    public static func degrees(_ value: Float) -> Angle3D {
        Angle3D(radians: value * .pi / 180)
    }
}

/// Where an object sits in the world, how it is turned and how big it is.
///
/// Applied to the object's own geometry as scale, then rotation about x, y
/// and z in that order, then translation.
public struct Transform3D: Equatable, Sendable {
    /// Translation, in world units.
    public var position: Vector3
    /// Rotation about the x, y and z axes, in radians, applied in that order.
    public var rotation: Vector3
    /// Scale along each axis; `[1, 1, 1]` is the object's own size.
    public var scale: Vector3

    /// Creates a transform. The default leaves the object as it is.
    public init(
        position: Vector3 = Vector3(0, 0, 0),
        rotation: Vector3 = Vector3(0, 0, 0),
        scale: Vector3 = [1, 1, 1]
    ) {
        self.position = position; self.rotation = rotation; self.scale = scale
    }
}

/// A perspective camera: where it is, what it looks at, and how wide it sees.
public struct Camera3D: Equatable, Sendable {
    /// Where the camera is, in world units.
    public var position: Vector3
    /// The point the camera looks at; also what orbit controls turn around.
    public var target: Vector3
    /// Vertical field of view.
    public var fieldOfView: Angle3D
    /// Distance to the near clipping plane. Anything closer is not drawn.
    public var near: Float
    /// Distance to the far clipping plane. Anything farther is not drawn.
    public var far: Float

    /// A camera on the +z axis looking at the origin, with a 42° field of view.
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

/// How a `Scene3D`'s camera follows the pointer: drag to orbit, Shift-drag to
/// pan, wheel to zoom.
public struct CameraControls3D: Equatable, Sendable {
    /// Radians of orbit per pixel dragged.
    public var orbitSensitivity: Float
    /// Pan distance per pixel dragged, as a fraction of the distance to the target.
    public var panSensitivity: Float
    /// How strongly one wheel notch zooms. The distance is multiplied by
    /// `exp(-notches × zoomSensitivity)`.
    public var zoomSensitivity: Float
    /// Closest the camera may zoom to its target.
    public var minimumDistance: Float
    /// Farthest the camera may zoom from its target.
    public var maximumDistance: Float
    /// Lowest the camera may orbit, looking up at the target.
    public var minimumPitch: Angle3D
    /// Highest the camera may orbit, looking down at the target.
    public var maximumPitch: Angle3D
    /// Whether a released drag keeps the camera moving and slowing down.
    public var inertia: Bool
    /// Fraction of drag velocity retained per 60 Hz frame.
    public var deceleration: Float

    /// Creates controls. Values are clamped into sense: sensitivities to zero or
    /// more, the maximum distance to at least the minimum, the pitch limits into
    /// order and the deceleration into 0–0.999.
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

    /// Orbit controls with the default sensitivities and the given distance limits.
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

/// How a 3D object moves to a new transform.
///
/// Attach with `.animation3D(_:)`. Without one, a changed transform takes
/// effect in the next frame.
public struct SpatialAnimation: Equatable, Sendable {
    /// How long the move takes, in seconds.
    public var duration: Double
    /// How progress maps onto time.
    public var curve: AnimationCurve
    /// When false, world x jumps to the new pose and only y/z, rotation,
    /// and scale interpolate. A bookshelf can keep the focused cover
    /// planted at the camera centre instead of sliding the whole shelf.
    public var animatesPosition: Bool

    /// Creates an animation.
    public init(
        duration: Double = 0.22, curve: AnimationCurve = .easeOut,
        animatesPosition: Bool = true
    ) {
        self.duration = duration
        self.curve = curve
        self.animatesPosition = animatesPosition
    }

    /// Position.x jumps; lift, turn, and scale still ease.
    public func snappingPosition() -> SpatialAnimation {
        var copy = self
        copy.animatesPosition = false
        return copy
    }

    /// An eased transition of `duration` seconds.
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

/// How a 3D object's faces are coloured.
public struct Material3D: Sendable {
    /// Colour of the front face.
    public var color: Color
    /// Picture drawn on the front face (+z), or `nil` for the flat `color`.
    public var frontTexture: UIImage?
    /// Colour of the other faces of a box: its edges, sides and back.
    public var edgeColor: Color

    /// Creates a material. `edgeColor` defaults to `color`.
    public init(
        color: Color = Color(r: 1, g: 1, b: 1),
        texture: UIImage? = nil,
        edgeColor: Color? = nil
    ) {
        self.color = color
        self.frontTexture = texture
        self.edgeColor = edgeColor ?? color
    }

    /// A cover picture on the front with dark edges, for album and poster cards.
    public static func albumCover(
        front: UIImage, edgeColor: Color = Color(r: 0.12, g: 0.12, b: 0.14)
    ) -> Material3D {
        Material3D(texture: front, edgeColor: edgeColor)
    }
}

/// A soft shadow under a 3D object, drawn on the screen rather than cast in
/// the world.
public struct Shadow3DStyle: Equatable, Sendable {
    /// Colour of the shadow.
    public var color: Color
    /// Blur radius of the shadow, in pixels.
    public var radius: Float
    /// Horizontal offset of the shadow from the object, in pixels.
    public var offsetX: Float
    /// Vertical offset of the shadow from the object, in pixels. Positive is down.
    public var offsetY: Float
    /// Opacity of the shadow, 0–1.
    public var opacity: Float

    /// Creates a shadow style. The opacity is clamped to 0–1.
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

/// A mirror image of a 3D object in a horizontal floor, fading with distance.
public struct Reflection3DStyle: Equatable, Sendable {
    /// Horizontal world-space plane across which geometry is mirrored.
    public var planeY: Float
    /// Opacity of the reflection where it meets the plane, 0–1.
    public var opacity: Float
    /// Distance from the plane, in world units, over which the reflection fades out.
    public var fadeDistance: Float
    /// Blur applied to the reflection, in pixels.
    public var blurRadius: Float

    /// Creates a reflection style.
    public init(
        planeY: Float = -0.75, opacity: Float = 0.3,
        fadeDistance: Float = 1.6, blurRadius: Float = 1.5
    ) {
        self.planeY = planeY
        self.opacity = min(1, max(0, opacity))
        self.fadeDistance = max(0.01, fadeDistance)
        self.blurRadius = max(0, blurRadius)
    }
}

/// A position in a 3D catalog layout, as `CatalogLayout3D` and
/// `BookshelfLayout3D` compute it.
public struct CatalogPose3D: Equatable, Sendable {
    /// The transform for the item.
    public var transform: Transform3D

    /// Creates a pose.
    public init(transform: Transform3D = Transform3D()) {
        self.transform = transform
    }
}

/// A reusable album/poster shelf that adds depth and fans neighboring items
/// around a focused cover while keeping the unfocused catalog in one row.
public struct CatalogLayout3D: Equatable, Sendable {
    /// Distance between neighbouring items' centres, in world units.
    public var spacing: Float
    /// How far the focused item comes forward, toward the camera.
    public var focusDepth: Float
    /// How far the focused item rises.
    public var focusLift: Float
    /// Scale of the focused item.
    public var focusScale: Float
    /// Extra distance neighbours move aside to make room for the focused item.
    public var neighborSpread: Float
    /// How far each further neighbour steps back, up to four steps.
    public var neighborDepthStep: Float
    /// How much the neighbours turn toward the focused item.
    public var fanAngle: Angle3D

    /// Creates a layout. Negative spacing and steps are clamped to zero.
    public init(
        spacing: Float = 1.6,
        focusDepth: Float = 0.55,
        focusLift: Float = 0.08,
        focusScale: Float = 1.12,
        neighborSpread: Float = 0.28,
        neighborDepthStep: Float = 0.08,
        fanAngle: Angle3D = .degrees(10)
    ) {
        self.spacing = max(0, spacing)
        self.focusDepth = focusDepth
        self.focusLift = focusLift
        self.focusScale = max(0.01, focusScale)
        self.neighborSpread = max(0, neighborSpread)
        self.neighborDepthStep = max(0, neighborDepthStep)
        self.fanAngle = fanAngle
    }

    /// A shelf with the default spread and depth, tuned for album covers.
    public static func focusedShelf(
        spacing: Float = 1.6,
        focusDepth: Float = 0.55,
        focusLift: Float = 0.08,
        focusScale: Float = 1.12,
        fanAngle: Angle3D = .degrees(10)
    ) -> CatalogLayout3D {
        CatalogLayout3D(
            spacing: spacing, focusDepth: focusDepth,
            focusLift: focusLift, focusScale: focusScale, fanAngle: fanAngle
        )
    }

    /// The pose of item `index` of `itemCount`, with `focusedIndex` focused, or no
    /// item focused when it is `nil`. The row is centred on x = 0.
    public func pose(
        at index: Int, itemCount: Int, focusedIndex: Int?
    ) -> CatalogPose3D {
        let count = max(0, itemCount)
        let centered = Float(index) - Float(max(0, count - 1)) * 0.5
        var transform = Transform3D(position: [centered * spacing, 0, 0])
        guard let focusedIndex, focusedIndex >= 0, focusedIndex < count else {
            return CatalogPose3D(transform: transform)
        }
        let distance = index - focusedIndex
        if distance == 0 {
            transform.position.z = focusDepth
            transform.position.y = focusLift
            transform.scale = [focusScale, focusScale, focusScale]
        } else {
            let side: Float = distance < 0 ? -1 : 1
            transform.position.x += side * neighborSpread
            transform.position.z = -Float(min(abs(distance), 4)) * neighborDepthStep
            // Neighbors turn gently toward the focused cover.
            transform.rotation.y = -side * fanAngle.radians
        }
        return CatalogPose3D(transform: transform)
    }

    /// Conservative orbit radius that keeps the camera outside this shelf.
    public func recommendedMinimumCameraDistance(
        itemCount: Int, itemWidth: Float, itemHeight: Float,
        clearance: Float = 2
    ) -> Float {
        let halfWidth = Float(max(0, itemCount - 1)) * spacing * 0.5
            + max(0, itemWidth) * focusScale * 0.5 + neighborSpread
        let halfHeight = max(0, itemHeight) * focusScale * 0.5
        let depth = abs(focusDepth) + neighborDepthStep * 4
        return sqrt(halfWidth * halfWidth + halfHeight * halfHeight + depth * depth)
            + max(0, clearance)
    }
}

/// Two stacks of books around a face-on cover: neighbours stand on the
/// shelf at a steep yaw so a sliver of their front is still readable, and
/// the focused item turns to face the camera.
///
/// Index 0 is the left of the *list*, not of the screen. The focused card
/// sits at x = 0; everything before it packs into the left stack, everything
/// after into the right. An empty stack is just an empty stack.
public struct BookshelfLayout3D: Equatable, Sendable {
    /// World x of the first book in a stack, measured from the focused card.
    public var stackOrigin: Float
    /// How tightly later books pack along x. Small on purpose: a stack, not a row.
    public var stackPitch: Float
    /// How far each further book steps back.
    public var stackRecede: Float
    /// Yaw of a book in the stack. Large enough to read as a spine-on-shelf
    /// pose; small enough that the cover is still visible.
    public var bookAngle: Angle3D
    /// How far the focused item comes forward, toward the camera.
    public var focusDepth: Float
    /// How far the focused item rises.
    public var focusLift: Float
    /// Scale of the focused item.
    public var focusScale: Float

    /// Creates a layout.
    public init(
        stackOrigin: Float = 1.05,
        stackPitch: Float = 0.16,
        stackRecede: Float = 0.07,
        bookAngle: Angle3D = .degrees(62),
        focusDepth: Float = 0.55,
        focusLift: Float = 0.06,
        focusScale: Float = 1.06
    ) {
        self.stackOrigin = max(0.01, stackOrigin)
        self.stackPitch = max(0, stackPitch)
        self.stackRecede = max(0, stackRecede)
        self.bookAngle = bookAngle
        self.focusDepth = focusDepth
        self.focusLift = focusLift
        self.focusScale = max(0.01, focusScale)
    }

    /// Bookshelf stacks with the default depth and focus.
    public static func bookStacks(
        stackOrigin: Float = 1.05,
        stackPitch: Float = 0.16,
        bookAngle: Angle3D = .degrees(62)
    ) -> BookshelfLayout3D {
        BookshelfLayout3D(
            stackOrigin: stackOrigin, stackPitch: stackPitch, bookAngle: bookAngle
        )
    }

    /// The pose of item `index` of `itemCount`, with `focusedIndex` at x = 0 and
    /// facing the camera. `itemHeight` stands the books on a shelf at y = 0;
    /// pass 0 to centre them on y = 0 instead.
    public func pose(
        at index: Int, itemCount: Int, focusedIndex: Int?,
        itemHeight: Float = 0
    ) -> CatalogPose3D {
        let focus = focusedIndex ?? 0
        let restY = max(0, itemHeight) * 0.5
        var transform = Transform3D(position: [0, restY, 0])
        let distance = index - focus
        if distance == 0 {
            transform.position.y = restY + focusLift
            transform.position.z = focusDepth
            transform.scale = [focusScale, focusScale, focusScale]
            return CatalogPose3D(transform: transform)
        }
        let side: Float = distance < 0 ? -1 : 1
        let rank = abs(distance)
        // First book sits at `stackOrigin`; the rest pack behind it.
        transform.position.x = side * (stackOrigin + Float(rank - 1) * stackPitch)
        transform.position.z = -Float(rank - 1) * stackRecede
        // Right stack: +yaw turns the cover toward −X (the focus). Left
        // stack is the mirror. The cover stays a bit visible; the edge
        // reads as a book on a shelf.
        transform.rotation.y = side * bookAngle.radians
        return CatalogPose3D(transform: transform)
    }

    /// A camera distance that keeps the camera outside the stacks, for
    /// `CameraControls3D.minimumDistance`.
    public func recommendedMinimumCameraDistance(
        itemCount: Int, itemWidth: Float, itemHeight: Float,
        clearance: Float = 2.2
    ) -> Float {
        let maxRank = Float(max(0, itemCount - 1))
        let halfWidth = stackOrigin + maxRank * stackPitch
            + max(0, itemWidth) * focusScale * 0.5
        let halfHeight = max(0, itemHeight) * focusScale + focusLift
        let depth = abs(focusDepth) + maxRank * stackRecede
        return sqrt(halfWidth * halfWidth + halfHeight * halfHeight + depth * depth)
            + max(0, clearance)
    }
}

/// Content of a `Scene3D`: objects, lights and groups of them.
///
/// Unlike `View`, a 3D view has no body and no state of its own. It flattens
/// into `SpatialElement`s the scene draws, and the `…3D` modifiers set their
/// transform, material and behaviour.
public protocol View3D {
    /// The objects this view contributes, with its modifiers applied.
    func spatialElements() -> [SpatialElement]
}

/// Builds the content of a `Scene3D`, `ForEach3D` or `SpatialGroup3D` from
/// 3D views, with `if`, `if`/`else` and `for` supported.
@resultBuilder
public enum View3DBuilder {
    /// Flattens one 3D view into its elements.
    public static func buildExpression<V: View3D>(_ value: V) -> [SpatialElement] {
        value.spatialElements()
    }
    /// Joins the elements of each statement, in order.
    public static func buildBlock(_ components: [SpatialElement]...) -> [SpatialElement] {
        components.flatMap { $0 }
    }
    /// An `if` without `else`: its elements, or none.
    public static func buildOptional(_ component: [SpatialElement]?) -> [SpatialElement] {
        component ?? []
    }
    /// The `if` branch of an `if`/`else`.
    public static func buildEither(first: [SpatialElement]) -> [SpatialElement] { first }
    /// The `else` branch of an `if`/`else`.
    public static func buildEither(second: [SpatialElement]) -> [SpatialElement] { second }
    /// A `for` loop: every iteration's elements, in order.
    public static func buildArray(_ components: [[SpatialElement]]) -> [SpatialElement] {
        components.flatMap { $0 }
    }
}

/// One drawable object or light, with everything the modifiers have set on it.
/// Built by `Plane3D`, `Box3D` and the light views; not constructed directly.
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
    var reflection: Reflection3DStyle?
    var transform = Transform3D()
    var animation: SpatialAnimation?
    var onHover: ((Bool) -> Void)?
    var onTap: (() -> Void)?

    public func spatialElements() -> [SpatialElement] { [self] }
}

/// Light that reaches every face equally, whatever way it points.
///
/// A scene with no ambient light gets one at intensity 0.3, and one with no
/// directional light gets a default `DirectionalLight3D`.
public struct AmbientLight3D: View3D {
    private var element: SpatialElement
    /// Creates an ambient light. `intensity` below zero is treated as zero.
    public init(color: Color = Color(r: 1, g: 1, b: 1), intensity: Float = 0.3) {
        element = SpatialElement(
            id: AnyHashable("lavaui.ambient-light"),
            geometry: .ambientLight(intensity: max(0, intensity)), color: color
        )
    }
    public func spatialElements() -> [SpatialElement] { [element] }
}

/// Light arriving from one direction, like the sun: faces turned toward it are brighter.
public struct DirectionalLight3D: View3D {
    private var element: SpatialElement
    /// Creates a directional light.
    /// - Parameters:
    /// - direction: The way the light travels, from the light toward the scene.
    /// - color: The light's colour.
    /// - intensity: The light's strength; below zero is treated as zero.
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

/// A flat rectangle in the x–y plane, facing +z.
public struct Plane3D: View3D {
    private var element: SpatialElement
    /// Creates a plane. `id` identifies the object across rebuilds, which is what
    /// lets it animate between transforms and report hover and taps. Sizes are
    /// in world units.
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

/// A box. With a `Material3D`, the front face (+z) shows its picture and the
/// other faces its edge colour; without one, every face is `color`.
public struct Box3D: View3D {
    private var element: SpatialElement
    /// Creates a box. `id` identifies the object across rebuilds, which is what
    /// lets it animate between transforms and report hover and taps. Sizes are
    /// in world units; the default is a thin card.
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
    /// Replaces the transform.
    public func transform3D(_ value: Transform3D) -> some View3D {
        ModifiedView3D(base: self) { $0.transform = value }
    }
    /// Places the object at item `index` of a focused shelf. See `CatalogLayout3D.pose(at:itemCount:focusedIndex:)`.
    public func catalog3D(
        index: Int, itemCount: Int, focusedIndex: Int?,
        layout: CatalogLayout3D = .focusedShelf()
    ) -> some View3D {
        transform3D(layout.pose(
            at: index, itemCount: itemCount, focusedIndex: focusedIndex
        ).transform)
    }
    /// Places the object at item `index` of a bookshelf. See `BookshelfLayout3D.pose(at:itemCount:focusedIndex:itemHeight:)`.
    public func catalog3D(
        index: Int, itemCount: Int, focusedIndex: Int?,
        itemHeight: Float = 0,
        layout: BookshelfLayout3D
    ) -> some View3D {
        transform3D(layout.pose(
            at: index, itemCount: itemCount, focusedIndex: focusedIndex,
            itemHeight: itemHeight
        ).transform)
    }
    /// Replaces the position.
    public func position(_ value: Vector3) -> some View3D {
        ModifiedView3D(base: self) { $0.transform.position = value }
    }
    /// Moves the object by the given amounts, in world units, from where it is.
    public func offset3D(x: Float = 0, y: Float = 0, z: Float = 0) -> some View3D {
        ModifiedView3D(base: self) {
            $0.transform.position.x += x; $0.transform.position.y += y
            $0.transform.position.z += z
        }
    }
    /// Scales the object uniformly.
    public func scale3D(_ value: Float) -> some View3D {
        ModifiedView3D(base: self) { $0.transform.scale = [value, value, value] }
    }
    /// Scales the object by a different amount along each axis.
    public func scale3D(_ value: Vector3) -> some View3D {
        ModifiedView3D(base: self) { $0.transform.scale = value }
    }
    /// Replaces the rotation with `angle` about `axis`.
    ///
    /// Stored as Euler angles (`axis × angle`), which is exact for a rotation
    /// about one of the coordinate axes — `[0, 1, 0]` and the like — and an
    /// approximation for any other axis.
    public func rotation3D(angle: Angle3D, axis: Vector3) -> some View3D {
        ModifiedView3D(base: self) {
            $0.transform.rotation = [axis.x * angle.radians, axis.y * angle.radians,
                                     axis.z * angle.radians]
        }
    }
    /// Animates changes to the object's transform. See `SpatialAnimation`.
    public func animation3D(_ animation: SpatialAnimation = .smooth()) -> some View3D {
        ModifiedView3D(base: self) { $0.animation = animation }
    }
    /// Sets how the object's faces are coloured.
    public func material3D(_ material: Material3D) -> some View3D {
        ModifiedView3D(base: self) { $0.material = material }
    }
    /// Draws a soft shadow under the object.
    public func shadow3D(_ style: Shadow3DStyle = Shadow3DStyle()) -> some View3D {
        ModifiedView3D(base: self) { $0.shadow = style }
    }
    /// Draws a soft shadow under the object. See `Shadow3DStyle`.
    public func shadow3D(
        color: Color = Color(r: 0, g: 0, b: 0), radius: Float = 16,
        offsetX: Float = 7, offsetY: Float = 11, opacity: Float = 0.32
    ) -> some View3D {
        shadow3D(Shadow3DStyle(
            color: color, radius: radius, offsetX: offsetX,
            offsetY: offsetY, opacity: opacity
        ))
    }
    /// Mirrors the object in a horizontal floor.
    public func reflection3D(
        _ style: Reflection3DStyle = Reflection3DStyle()
    ) -> some View3D {
        ModifiedView3D(base: self) { $0.reflection = style }
    }
    /// Mirrors the object in a horizontal floor. See `Reflection3DStyle`.
    public func reflection3D(
        planeY: Float = -0.75, opacity: Float = 0.3,
        fadeDistance: Float = 1.6, blurRadius: Float = 1.5
    ) -> some View3D {
        reflection3D(Reflection3DStyle(
            planeY: planeY, opacity: opacity,
            fadeDistance: fadeDistance, blurRadius: blurRadius
        ))
    }
    /// Calls `action` with `true` when the pointer moves onto the object and
    /// `false` when it leaves.
    public func onHover3D(_ action: @escaping (Bool) -> Void) -> some View3D {
        ModifiedView3D(base: self) { $0.onHover = action }
    }
    /// Calls `action` when the object is clicked. With camera controls on, a drag
    /// of four pixels or more orbits instead and does not count as a click.
    public func onTap3D(_ action: @escaping () -> Void) -> some View3D {
        ModifiedView3D(base: self) { $0.onTap = action }
    }
}

/// One group of 3D views per element of a collection.
public struct ForEach3D<Data: RandomAccessCollection, ID: Hashable, Content: View3D>: View3D {
    /// The elements, one group each.
    public var data: Data
    /// The key path identifying each element.
    public var id: KeyPath<Data.Element, ID>
    /// Builds the group for one element.
    public var content: (Data.Element) -> Content

    /// Builds one group of 3D views per element of `data`.
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

/// Several 3D views treated as one, so a modifier applies to all of them.
public struct SpatialGroup3D: View3D {
    var elements: [SpatialElement]
    /// Groups the views in `content`.
    public init(@View3DBuilder content: () -> [SpatialElement]) { elements = content() }
    init(_ elements: [SpatialElement]) { self.elements = elements }
    public func spatialElements() -> [SpatialElement] { elements }
}

struct SpatialProjectedVertex {
    var x, y, depth: Float
    /// Camera-space Z the projection divided by. 1 keeps affine mapping
    /// (face-on cards); a tilted cover needs the real value.
    var w: Float = 1
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
    var reflections: [SpatialBatch]
    var triangles: [SpatialProjectedVertex] { batches.flatMap(\.triangles) }
}

/// A viewport onto 3D content: cards, boxes and lights, drawn with depth,
/// perspective and simple lighting, and optionally orbited with the pointer.
///
/// Objects are identified by the ids given to `Plane3D` and `Box3D`, so a
/// rebuild with new transforms moves them rather than replacing them, and
/// `.animation3D(_:)` eases the move.
public struct Scene3D: PrimitiveView {
    /// The camera the scene is seen through. With `cameraControls`, the pointer moves it.
    public var camera: Camera3D
    /// How the pointer orbits, pans and zooms the camera, or `nil` for a fixed camera.
    public var cameraControls: CameraControls3D?
    /// Width of the viewport.
    public var width: Dimension
    /// Height of the viewport.
    public var height: Dimension
    /// Share of the parent's leftover main-axis space the viewport takes.
    public var flexGrow: Float
    var elements: [SpatialElement]

    /// Creates a scene. Every parameter matches the property of the same name.
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
        leaf.onClickLocal = { [weak leaf, weak runtime] x, y, _, _, mods, _ in
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
                        if a.animatesPosition {
                            m.position.animate(
                                to: e.transform.position,
                                duration: a.duration, curve: a.curve
                            )
                        } else {
                            // Plant x now so a shelf reflow cannot drag the
                            // focused card across the screen with the stacks.
                            let planted = Vector3(
                                e.transform.position.x,
                                m.position.current.y,
                                m.position.current.z
                            )
                            m.position.snap(to: planted)
                            m.position.animate(
                                to: e.transform.position,
                                duration: a.duration, curve: a.curve
                            )
                        }
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
        if let controls {
            orbitDistance = min(
                controls.maximumDistance, max(controls.minimumDistance, orbitDistance)
            )
            orbitPitch = min(
                controls.maximumPitch.radians,
                max(controls.minimumPitch.radians, orbitPitch)
            )
            rebuildCamera()
        }
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
                shadows: projectShadow(element: e, transform: t, frame: frame),
                reflections: e.reflection.map {
                    project(
                        element: e, transform: t, frame: frame, reflection: $0
                    )
                } ?? []
            )
        }
        let shadowRadius = elements.compactMap(\.shadow?.radius).max() ?? 0
        draw.withSpatialBlur(frame: frame, radius: shadowRadius) {
            for item in projected {
                for batch in item.shadows {
                    draw.spatialTriangles(batch.triangles, texture: nil)
                }
            }
        }
        let reflectionRadius = elements.compactMap(\.reflection?.blurRadius).max() ?? 0
        draw.withSpatialBlur(frame: frame, radius: reflectionRadius) {
            for item in projected {
                for batch in item.reflections {
                    draw.spatialTriangles(batch.triangles, texture: batch.texture)
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
                depth:min(1,p.depth + 0.0005),
                w:p.viewZ,
                u:uv[index].0,v:uv[index].1,
                sampleMode:0,color:style.color.opacity(style.opacity)
            )
        }
        return [SpatialBatch(triangles:vertices,texture:nil)]
    }

    func hover(x: Float, y: Float) { adopt(hit: hitID(x: x, y: y)) }

    /// The pointer is no longer over the scene at all.
    ///
    /// Not expressed as a hover at some impossibly distant point. "Nowhere" is
    /// not a position, and the one that used to stand in for it — negative
    /// `greatestFiniteMagnitude` — overflows the edge products in
    /// `pointInTriangle` to infinities that all share a sign, which is exactly
    /// the answer "inside". So leaving the scene picked an element instead of
    /// clearing one, and it stayed picked, because nothing was coming to
    /// correct it: the pointer was somewhere else entirely by then.
    func leave() { adopt(hit: nil) }

    private func adopt(hit: AnyHashable?) {
        guard hit != hovered else { return }
        if let old = hovered, let e = elements.first(where: { $0.id == old }) { e.onHover?(false) }
        hovered = hit
        if let hit, let e = elements.first(where: { $0.id == hit }) { e.onHover?(true) }
        ViewInvalidation.markNeedsRedraw()
    }
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
        element: SpatialElement, transform: Transform3D, frame: CanvasFrame,
        reflection: Reflection3DStyle? = nil
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
            var normal = rotate(transform, face.normal)
            if reflection != nil { normal.y = -normal.y }
            let lit = litColor(face.color, normal: normal)
            let vertices = order.compactMap { index -> SpatialProjectedVertex? in
                var world = apply(transform, face.corners[index])
                var color = lit
                if let reflection {
                    world.y = 2 * reflection.planeY - world.y
                    let distance = max(0, reflection.planeY - world.y)
                    let fade = max(0, 1 - distance / reflection.fadeDistance)
                    color = color.opacity(reflection.opacity * fade)
                }
                guard let p = project(world, frame: frame) else {
                    return nil
                }
                return SpatialProjectedVertex(
                    x: p.x, y: p.y, depth: p.depth, w: p.viewZ,
                    u: uv[index].0, v: uv[index].1,
                    sampleMode: face.texture == nil ? 0 : 1, color: color
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
        // Light adds up as light does, which means linear components — a
        // light colour is as much a colour as the surface it falls on, so it
        // is decoded too. Multiplying authored components instead makes a
        // face at half illumination land at 0.5^2.4 of full rather than 0.5,
        // and reads as shading far heavier than any light asked for.
        var lr:Float=0, lg:Float=0, lb:Float=0
        for (c,i) in ambients {
            let l = c.linear
            lr += l.r*i; lg += l.g*i; lb += l.b*i
        }
        let n = normalized(normal)
        for (direction,c,i) in directionals {
            let d = normalized([-direction.x,-direction.y,-direction.z])
            let amount = max(0,dot(n,d))*i
            let l = c.linear
            lr += l.r*amount; lg += l.g*amount; lb += l.b*amount
        }
        // Back to authored sRGB before it goes anywhere: the vertex format is
        // 8-bit sRGB and nothing downstream re-encodes, so handing it linear
        // components would arrive dark *and* spend those 8 bits on the
        // highlights instead of the shadows. `fromLinear` clamps, which is
        // where an overshooting sum of lights ends up.
        let lit = base.linear
        return Color.fromLinear(
            Color(r: lit.r*lr, g: lit.g*lg, b: lit.b*lb, a: base.a)
        )
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

    private struct Projected {
        var x, y, depth, viewZ: Float
    }

    private func project(_ p: Vector3, frame: CanvasFrame) -> Projected? {
        let forward = normalized(camera.target - camera.position)
        let right = normalized(cross(forward, [0,1,0]))
        let up = cross(right, forward)
        let delta = p - camera.position
        let viewZ = dot(delta, forward)
        guard viewZ > camera.near else { return nil }
        let focal = frame.h * 0.5 / tan(camera.fieldOfView.radians * 0.5)
        return Projected(
            x: frame.x + frame.w * 0.5 + dot(delta, right) * focal / viewZ,
            y: frame.y + frame.h * 0.5 - dot(delta, up) * focal / viewZ,
            depth: min(1, max(0, (viewZ - camera.near) / (camera.far - camera.near))),
            viewZ: viewZ
        )
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
