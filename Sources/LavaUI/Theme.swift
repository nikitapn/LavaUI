import Foundation

/// How a focused text field draws its attention ring.
///
/// The pipeline has no true stroke primitive — rounded rings use a filled
/// outer plate with the field fill punched back on top (same trick overlays
/// use for borders). Hard rectangles use four edge plates.
public enum FocusRingStyle: Equatable, Sendable {
    /// No focus chrome (caret only).
    case none
    /// Legacy: accent bars on the top and bottom edges only.
    case underline
    /// Full axis-aligned box (four edges).
    case rectangle
    /// Full outline honouring the field's corner radius (default).
    case rounded
}

/// Semantic styling tokens.
///
/// The point of naming tokens by *role* rather than by appearance is that a
/// view says `.accent`, not `Color(r: 0.7, ...)`, so a theme swap does not
/// require touching a single view. `Color.primary` and friends already read
/// this way at call sites; they now resolve through here instead of being
/// frozen constants.
public struct Theme: Equatable, Sendable {
    // MARK: Text
    public var textPrimary: Color
    public var textSecondary: Color
    public var textMuted: Color
    public var textDim: Color
    /// Emphasis for headings and focus rings.
    public var accent: Color
    /// Current selection in a list — deliberately distinct from `accent`.
    public var selected: Color

    // MARK: Surfaces
    /// Window background, behind everything.
    public var background: Color
    /// Side panels and other raised chrome.
    public var panel: Color
    /// Inset surfaces: text fields, wells.
    public var inset: Color
    /// The diagram canvas.
    public var canvas: Color
    /// Row highlight under the pointer.
    public var hover: Color
    /// Text selection highlight.
    public var selectionFill: Color

    // MARK: Borders and metrics
    public var border: Color
    public var borderWidth: Float
    /// Default corner radius for panels and controls. 0 gives hard corners.
    public var cornerRadius: Float
    /// Inner padding for controls such as text fields.
    public var controlPadding: Float
    /// Default distance between adjacent views in a stack when its spacing is `nil`.
    public var stackSpacing: Float
    public var caretWidth: Float
    /// Shape of the focused-field chrome. Defaults to a full rounded outline.
    public var focusRingStyle: FocusRingStyle
    /// Stroke thickness for the focus ring (also used by `.underline`).
    public var focusRingWidth: Float
    /// Focus ring colour. `nil` uses `accent`.
    public var focusRingColor: Color?

    public init(
        textPrimary: Color, textSecondary: Color, textMuted: Color, textDim: Color,
        accent: Color, selected: Color,
        background: Color, panel: Color, inset: Color, canvas: Color,
        hover: Color, selectionFill: Color,
        border: Color, borderWidth: Float = 1,
        cornerRadius: Float = 4, controlPadding: Float = 4, stackSpacing: Float = 8,
        caretWidth: Float = 1.5,
        focusRingStyle: FocusRingStyle = .rounded,
        focusRingWidth: Float = 1.5,
        focusRingColor: Color? = nil
    ) {
        self.textPrimary = textPrimary
        self.textSecondary = textSecondary
        self.textMuted = textMuted
        self.textDim = textDim
        self.accent = accent
        self.selected = selected
        self.background = background
        self.panel = panel
        self.inset = inset
        self.canvas = canvas
        self.hover = hover
        self.selectionFill = selectionFill
        self.border = border
        self.borderWidth = borderWidth
        self.cornerRadius = cornerRadius
        self.controlPadding = controlPadding
        self.stackSpacing = stackSpacing
        self.caretWidth = caretWidth
        self.focusRingStyle = focusRingStyle
        self.focusRingWidth = focusRingWidth
        self.focusRingColor = focusRingColor
    }

    /// The palette this app shipped with, kept as-is so the theme migration
    /// changes nothing visually until someone chooses a different one.
    public static let dark = Theme(
        textPrimary: Color(r: 0.90, g: 0.90, b: 0.90),
        textSecondary: Color(r: 0.55, g: 0.55, b: 0.60),
        textMuted: Color(r: 0.50, g: 0.60, b: 0.50),
        textDim: Color(r: 0.45, g: 0.55, b: 0.50),
        accent: Color(r: 0.70, g: 0.75, b: 0.90),
        selected: Color(r: 1.0, g: 0.85, b: 0.40),
        background: Color(r: 0.10, g: 0.11, b: 0.13),
        panel: Color(r: 0.14, g: 0.15, b: 0.18),
        inset: Color(r: 0.10, g: 0.11, b: 0.14),
        canvas: Color(r: 0.12, g: 0.13, b: 0.16),
        hover: Color(r: 0.25, g: 0.27, b: 0.33),
        selectionFill: Color(r: 0.25, g: 0.40, b: 0.65),
        border: Color(r: 0.28, g: 0.30, b: 0.35)
    )

    public static let light = Theme(
        textPrimary: Color(r: 0.12, g: 0.13, b: 0.16),
        textSecondary: Color(r: 0.40, g: 0.42, b: 0.46),
        textMuted: Color(r: 0.45, g: 0.50, b: 0.45),
        textDim: Color(r: 0.55, g: 0.58, b: 0.55),
        accent: Color(r: 0.20, g: 0.35, b: 0.70),
        selected: Color(r: 0.75, g: 0.50, b: 0.05),
        background: Color(r: 0.93, g: 0.96, b: 0.97),
        panel: Color(r: 0.92, g: 0.93, b: 0.94),
        inset: Color(r: 1.00, g: 1.00, b: 1.00),
        canvas: Color(r: 0.88, g: 0.89, b: 0.91),
        hover: Color(r: 0.24, g: 0.68, b: 0.91),
        selectionFill: Color(r: 0.65, g: 0.78, b: 0.95),
        border: Color(r: 0.75, g: 0.76, b: 0.80)
    )

    /// Deep indigo with a cyan/magenta pair, for surfaces that sit over a
    /// desktop rather than filling a window.
    ///
    /// The greys exist to disappear behind content, which is right for an
    /// editor and wrong for a launcher: there the surface is most of what is
    /// on screen, and neutral grey over a photograph reads as a smudge rather
    /// than as a thing. This is still dark and still low-chroma enough to put
    /// a wall of app icons on, but it has a hue, so what is behind it is
    /// clearly behind *something*.
    ///
    /// `selected` and `accent` are far apart on the wheel on purpose — the two
    /// mean different things (where you are, versus what is important) and a
    /// palette that makes them cousins loses that distinction exactly when a
    /// keyboard-driven grid needs it most.
    public static let nebula = Theme(
        textPrimary: Color(r: 0.94, g: 0.94, b: 0.98),
        textSecondary: Color(r: 0.68, g: 0.66, b: 0.82),
        textMuted: Color(r: 0.58, g: 0.56, b: 0.74),
        textDim: Color(r: 0.50, g: 0.48, b: 0.66),
        accent: Color(r: 0.36, g: 0.86, b: 0.92),
        selected: Color(r: 1.00, g: 0.45, b: 0.72),
        background: Color(r: 0.06, g: 0.05, b: 0.12),
        panel: Color(r: 0.11, g: 0.10, b: 0.20),
        inset: Color(r: 0.08, g: 0.07, b: 0.16),
        canvas: Color(r: 0.09, g: 0.08, b: 0.18),
        hover: Color(r: 0.22, g: 0.20, b: 0.38),
        selectionFill: Color(r: 0.42, g: 0.24, b: 0.62),
        border: Color(r: 0.32, g: 0.28, b: 0.52)
    )

    /// Warm charcoal with copper light, the night-side counterpart to `paper`.
    ///
    /// Dark's greys are cool on purpose — they sit behind code and disappear.
    /// Ember is the same darkness with the colour temperature flipped, so a
    /// desktop that wants firelight rather than a monitor in a basement has
    /// somewhere to go that is still a dark theme.
    public static let ember = Theme(
        textPrimary: Color(r: 0.96, g: 0.92, b: 0.86),
        textSecondary: Color(r: 0.70, g: 0.58, b: 0.46),
        textMuted: Color(r: 0.62, g: 0.50, b: 0.38),
        textDim: Color(r: 0.52, g: 0.42, b: 0.32),
        accent: Color(r: 0.94, g: 0.62, b: 0.32),
        selected: Color(r: 1.00, g: 0.78, b: 0.36),
        background: Color(r: 0.11, g: 0.07, b: 0.05),
        panel: Color(r: 0.17, g: 0.11, b: 0.08),
        inset: Color(r: 0.10, g: 0.07, b: 0.05),
        canvas: Color(r: 0.13, g: 0.09, b: 0.06),
        hover: Color(r: 0.36, g: 0.22, b: 0.14),
        selectionFill: Color(r: 0.52, g: 0.26, b: 0.12),
        border: Color(r: 0.42, g: 0.28, b: 0.18)
    )

    /// Deep forest. Green enough to be a choice, quiet enough to put a
    /// wall of icons on — the same job nebula does in indigo.
    public static let moss = Theme(
        textPrimary: Color(r: 0.90, g: 0.94, b: 0.88),
        textSecondary: Color(r: 0.58, g: 0.68, b: 0.56),
        textMuted: Color(r: 0.50, g: 0.62, b: 0.50),
        textDim: Color(r: 0.42, g: 0.52, b: 0.42),
        accent: Color(r: 0.62, g: 0.86, b: 0.56),
        selected: Color(r: 0.90, g: 0.82, b: 0.38),
        background: Color(r: 0.07, g: 0.10, b: 0.08),
        panel: Color(r: 0.11, g: 0.15, b: 0.12),
        inset: Color(r: 0.08, g: 0.11, b: 0.09),
        canvas: Color(r: 0.09, g: 0.13, b: 0.10),
        hover: Color(r: 0.18, g: 0.28, b: 0.20),
        selectionFill: Color(r: 0.16, g: 0.38, b: 0.24),
        border: Color(r: 0.24, g: 0.36, b: 0.26)
    )

    /// Warm paper. `light` is a cool daylight grey; this is the same
    /// brightness with the yellow left in, so a page reads as a page
    /// rather than as a window.
    public static let paper = Theme(
        textPrimary: Color(r: 0.18, g: 0.14, b: 0.10),
        textSecondary: Color(r: 0.46, g: 0.40, b: 0.32),
        textMuted: Color(r: 0.52, g: 0.46, b: 0.38),
        textDim: Color(r: 0.58, g: 0.54, b: 0.46),
        accent: Color(r: 0.62, g: 0.32, b: 0.12),
        selected: Color(r: 0.52, g: 0.22, b: 0.08),
        background: Color(r: 0.97, g: 0.95, b: 0.90),
        panel: Color(r: 0.94, g: 0.91, b: 0.85),
        inset: Color(r: 1.00, g: 0.99, b: 0.96),
        canvas: Color(r: 0.92, g: 0.89, b: 0.82),
        hover: Color(r: 0.88, g: 0.74, b: 0.50),
        selectionFill: Color(r: 0.90, g: 0.78, b: 0.56),
        border: Color(r: 0.78, g: 0.72, b: 0.62)
    )

    /// Near-black with a hard white, for a desktop that wants contrast
    /// rather than atmosphere. The accent keeps a drop of blue so links
    /// and focus rings do not disappear into the grey.
    public static let graphite = Theme(
        textPrimary: Color(r: 0.96, g: 0.96, b: 0.97),
        textSecondary: Color(r: 0.62, g: 0.62, b: 0.64),
        textMuted: Color(r: 0.54, g: 0.54, b: 0.56),
        textDim: Color(r: 0.46, g: 0.46, b: 0.48),
        accent: Color(r: 0.70, g: 0.82, b: 1.00),
        selected: Color(r: 1.00, g: 0.88, b: 0.40),
        background: Color(r: 0.05, g: 0.05, b: 0.06),
        panel: Color(r: 0.11, g: 0.11, b: 0.12),
        inset: Color(r: 0.07, g: 0.07, b: 0.08),
        canvas: Color(r: 0.08, g: 0.08, b: 0.09),
        hover: Color(r: 0.28, g: 0.28, b: 0.32),
        selectionFill: Color(r: 0.20, g: 0.32, b: 0.52),
        border: Color(r: 0.32, g: 0.32, b: 0.36)
    )

    /// A built-in palette the desktop can push by name.
    ///
    /// `name` is what `lava.conf` and the control plane carry; `title` and
    /// `summary` are what Settings shows. Keep this list in step with
    /// `canonicalThemeName` in the compositor — an unknown name is dark.
    public struct BuiltIn: Equatable, Sendable {
        public var name: String
        public var title: String
        public var summary: String
        public var theme: Theme
    }

    /// Palettes the system theme understands, in the order Settings lists them.
    public static var builtIns: [BuiltIn] {
        [
            BuiltIn(name: "dark", title: "Dark", summary: "cool grey", theme: .dark),
            BuiltIn(name: "light", title: "Light", summary: "daylight", theme: .light),
            BuiltIn(name: "nebula", title: "Nebula", summary: "indigo", theme: .nebula),
            BuiltIn(name: "ember", title: "Ember", summary: "warm charcoal", theme: .ember),
            BuiltIn(name: "moss", title: "Moss", summary: "forest", theme: .moss),
            BuiltIn(name: "paper", title: "Paper", summary: "cream", theme: .paper),
            BuiltIn(name: "graphite", title: "Graphite", summary: "high contrast", theme: .graphite),
        ]
    }

    /// App-wide default theme. `Environment.current.theme` falls through to
    /// this wherever no `.theme(_:)` override is in scope, so setting it still
    /// reaches everything that never opted out — but a subtree wearing
    /// `.theme(_:)` no longer has to go through here at all.
    nonisolated(unsafe) public static var current: Theme = .dark {
        didSet {
            if current != oldValue { ViewInvalidation.markDirty() }
        }
    }

    /// The names the compositor's system theme understands.
    public static func named(_ name: String) -> Theme? {
        builtIns.first { $0.name == name }?.theme
    }

    /// Called after a compositor system-theme push is applied to `current`.
    /// Apps that paint their own paper (a terminal, a player) can retint
    /// here. Nil is the usual case — `Theme.current` already rebuilt the
    /// tree.
    nonisolated(unsafe) public static var onSystemUpdate: ((Theme) -> Void)?
}

extension Color {
    // Resolved through the environment's theme, so these stay valid names at
    // call sites while becoming swappable — globally via `Theme.current`, or
    // per subtree via `.theme(_:)`.
    public static var primary: Color { Environment.current.theme.textPrimary }
    public static var secondary: Color { Environment.current.theme.textSecondary }
    public static var accent: Color { Environment.current.theme.accent }
    public static var selected: Color { Environment.current.theme.selected }
    public static var muted: Color { Environment.current.theme.textMuted }
    public static var dim: Color { Environment.current.theme.textDim }
}

/// What a window paints behind its content, before anything in the tree.
///
/// Its own type rather than a `Theme` field because it is not a colour choice,
/// it is a statement about the *window*: whether the surface underneath the UI
/// is opaque, translucent, or absent.
///
/// A windowed app never touches this — `.theme` is what every one of them has
/// always drawn. A compositor surface is composited by somebody else rather
/// than pasted onto a swapchain, so it can be any of the three, and `.none` is
/// what a rounded corner or a drop shadow needs: both depend on the parts
/// nothing was drawn over staying empty rather than becoming black.
public enum WindowBackdrop: Sendable {
    /// The theme's opaque background. The default, and the only thing a
    /// windowed app should want.
    case theme
    /// A specific colour, which may be translucent.
    case color(Color)
    /// Nothing at all — the surface stays as the frame was cleared.
    case none
    /// Frost the desktop behind the window, then this translucent tint.
    ///
    /// Only the compositor can see what is under the window, so this is a
    /// no-op in a windowed app (the tint still paints). `radius` 0 is
    /// `.color(tint)`. An opaque tint hides the frost completely — the
    /// useful alphas are well below 1; see `docs/colour-and-blending.md`.
    case blur(radius: Float, tint: Color)

    nonisolated(unsafe) public static var current: WindowBackdrop = .theme

    /// Frosted glass with a dark wash that still lets the desktop through.
    public static func blur(radius: Float) -> WindowBackdrop {
        .blur(
            radius: radius,
            tint: Color(r: 0.08, g: 0.07, b: 0.10, a: 0.42)
        )
    }

    /// The colour to fill the window with, or nil to fill nothing.
    public var fill: Color? {
        switch self {
        case .theme: return Theme.current.background
        case .color(let c): return c
        case .none: return nil
        case .blur(_, let tint): return tint
        }
    }

    /// Layout pixels the compositor should frost behind this window. 0 = off.
    public var compositorBlurRadius: Float {
        switch self {
        case .blur(let radius, _): return max(0, radius)
        default: return 0
        }
    }
}
