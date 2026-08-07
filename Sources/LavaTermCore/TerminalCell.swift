/// One character cell in the terminal grid.
public struct TerminalCell: Equatable, Sendable {
    public var scalar: Unicode.Scalar
    public var fg: TerminalColor
    public var bg: TerminalColor
    public var bold: Bool
    public var inverse: Bool
    public var underline: Bool

    public static let empty = TerminalCell(
        scalar: " ",
        fg: .defaultForeground,
        bg: .defaultBackground,
        bold: false,
        inverse: false,
        underline: false
    )

    public init(
        scalar: Unicode.Scalar,
        fg: TerminalColor = .defaultForeground,
        bg: TerminalColor = .defaultBackground,
        bold: Bool = false,
        inverse: Bool = false,
        underline: Bool = false
    ) {
        self.scalar = scalar
        self.fg = fg
        self.bg = bg
        self.bold = bold
        self.inverse = inverse
        self.underline = underline
    }

    public var displayFg: TerminalColor { inverse ? bg : fg }
    public var displayBg: TerminalColor { inverse ? fg : bg }
}

/// Terminal colour: default or a palette index (0…255, xterm cube/greyscale).
public enum TerminalColor: Equatable, Sendable, Hashable {
    case `default`
    case index(UInt8)
    case rgb(UInt8, UInt8, UInt8)

    public static let defaultForeground = TerminalColor.default
    public static let defaultBackground = TerminalColor.default
}
