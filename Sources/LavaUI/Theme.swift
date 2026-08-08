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
        background: Color(r: 0.96, g: 0.96, b: 0.97),
        panel: Color(r: 0.92, g: 0.92, b: 0.94),
        inset: Color(r: 1.00, g: 1.00, b: 1.00),
        canvas: Color(r: 0.88, g: 0.89, b: 0.91),
        hover: Color(r: 0.85, g: 0.86, b: 0.89),
        selectionFill: Color(r: 0.65, g: 0.78, b: 0.95),
        border: Color(r: 0.75, g: 0.76, b: 0.80)
    )

    /// App-wide default theme. `Environment.current.theme` falls through to
    /// this wherever no `.theme(_:)` override is in scope, so setting it still
    /// reaches everything that never opted out — but a subtree wearing
    /// `.theme(_:)` no longer has to go through here at all.
    nonisolated(unsafe) public static var current: Theme = .dark {
        didSet {
            if current != oldValue { ViewInvalidation.markDirty() }
        }
    }
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

    nonisolated(unsafe) public static var current: WindowBackdrop = .theme

    /// The colour to fill the window with, or nil to fill nothing.
    public var fill: Color? {
        switch self {
        case .theme: return Theme.current.background
        case .color(let c): return c
        case .none: return nil
        }
    }
}
