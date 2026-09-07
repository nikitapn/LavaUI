import Foundation

/// A quarter-turn, clockwise from the file's own orientation.
///
/// Four states rather than a free angle. The two buttons on the bar turn by 90°
/// and nothing else does, so an arbitrary angle would be a resampled picture,
/// a bounding box that grows, and a Save that could not be undone by turning
/// the other way — three costs for a feature nobody asked for.
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

/// Turning RGBA8 pixels, on the CPU.
///
/// Here rather than in the app for the usual reason this repo splits `*Core`
/// out: it is the part with an off-by-one in it, and it can be checked on a
/// 2×3 buffer with no GPU, no window, and no file.
public enum PixelRotate {
    /// `pixels` is tightly packed RGBA8, `width * height * 4` bytes.
    /// Returns the turned buffer and its new dimensions, or nil if the input
    /// does not describe the image it claims to.
    public static func rotate(
        pixels: [UInt8], width: Int, height: Int, by rotation: Rotation
    ) -> (pixels: [UInt8], width: Int, height: Int)? {
        guard width > 0, height > 0,
              pixels.count == width * height * 4
        else { return nil }
        guard rotation != .none else { return (pixels, width, height) }

        let outW = rotation.swapsAxes ? height : width
        let outH = rotation.swapsAxes ? width : height

        var out = [UInt8](repeating: 0, count: pixels.count)
        pixels.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                guard let s = src.baseAddress, let d = dst.baseAddress else { return }
                // Written as a per-destination-pixel gather rather than a
                // scatter, so the *writes* are sequential. The reads stride
                // by a row for the quarter turns and cache badly either way;
                // making the writes linear is the half worth having, and it
                // is the difference between ~40 ms and ~200 ms on a 24MP
                // photograph.
                for y in 0..<outH {
                    let dstRow = y * outW * 4
                    for x in 0..<outW {
                        let (sx, sy): (Int, Int)
                        switch rotation {
                        case .none:
                            (sx, sy) = (x, y)
                        case .quarter:
                            // Clockwise: destination column x came from source
                            // row x counted from the bottom.
                            (sx, sy) = (y, height - 1 - x)
                        case .half:
                            (sx, sy) = (width - 1 - x, height - 1 - y)
                        case .threeQuarter:
                            (sx, sy) = (width - 1 - y, x)
                        }
                        let si = (sy * width + sx) * 4
                        let di = dstRow + x * 4
                        d[di] = s[si]
                        d[di + 1] = s[si + 1]
                        d[di + 2] = s[si + 2]
                        d[di + 3] = s[si + 3]
                    }
                }
            }
        }
        return (out, outW, outH)
    }

    /// Whether any pixel is not fully opaque.
    ///
    /// Asked before saving: JPEG has no alpha channel, so an image that uses
    /// one must not be written as a JPEG whatever its extension says, or the
    /// transparent parts come back black.
    public static func hasTransparency(pixels: [UInt8]) -> Bool {
        var i = 3
        while i < pixels.count {
            if pixels[i] != 255 { return true }
            i += 4
        }
        return false
    }
}
