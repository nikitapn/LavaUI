import Foundation

/// A quarter-turn, clockwise from the file's own orientation.
///
/// Four states rather than a free angle. The two buttons on the bar turn by 90°
/// and nothing else does, so an arbitrary angle would be a resampled picture,
/// a bounding box that grows, and a Save that could not be undone by turning
/// the other way — three costs for a feature nobody asked for.
///
/// What this does *not* do is move any pixels. That used to live here as
/// `PixelRotate`, and the decoder does it now — for the screen and for the file
/// alike, in one implementation, because the alternative is two that agree
/// until one day they do not and a photograph is saved a different way up from
/// how it was seen. See `canvas/src/render/exif.cpp` and `ImageTurn`.
public enum Rotation: Int, CaseIterable, Sendable, Equatable {
    case none = 0
    case quarter = 90
    case half = 180
    case threeQuarter = 270

    public func turnedRight() -> Rotation {
        Rotation(rawValue: (rawValue + 90) % 360) ?? .none
    }

    public func turnedLeft() -> Rotation {
        Rotation(rawValue: (rawValue + 270) % 360) ?? .none
    }

    /// Whether width and height swap under this turn.
    public var swapsAxes: Bool { self == .quarter || self == .threeQuarter }

    public func applied(to size: PixelSize) -> PixelSize {
        swapsAxes
            ? PixelSize(width: size.height, height: size.width)
            : size
    }

    /// Label for the status bar. Nothing at all when upright — a viewer that
    /// permanently says "0°" is reporting its own existence.
    public var badge: String? {
        self == .none ? nil : "\(rawValue)°"
    }
}
