import Foundation

/// Saturation–value square, hue strip, hex, and an optional alpha slider.
///
/// The binding is an authored sRGB `Color` — the same numbers a picker and
/// a hex field agree on. The square is HSV rather than HSL because the
/// top-right corner has to be the pure hue; HSL puts that in the middle
/// and feels like the control is fighting the hand.
///
/// ```swift
/// @State private var fill = Color(r: 0.2, g: 0.45, b: 0.8)
/// ColorPicker(color: $fill)
/// ```
public struct ColorPicker: View {
    @Binding public var color: Color
    public var showsAlpha: Bool
    public var showsHex: Bool

    /// Last saturated hue, so dragging through white does not snap the
    /// strip back to red (HSV hue is undefined at s = 0).
    @State private var lastHue: Float = 0
    @State private var hexText: String = ""

    public init(
        color: Binding<Color>,
        showsAlpha: Bool = false,
        showsHex: Bool = true
    ) {
        self._color = color
        self.showsAlpha = showsAlpha
        self.showsHex = showsHex
    }

    public var body: some View {
        let hsv = resolvedHSV
        return VStack(alignment: .start, spacing: 8) {
            HStack(alignment: .start, spacing: 8) {
                svSquare(hue: hsv.hue, saturation: hsv.saturation, value: hsv.value)
                hueStrip(hue: hsv.hue, saturation: hsv.saturation, value: hsv.value)
            }
            HStack(spacing: 8) {
                swatch
                if showsHex { hexField }
                Spacer()
            }
            if showsAlpha {
                Slider(
                    value: Binding(
                        get: { color.a },
                        set: { apply(color.opacity($0)) }
                    ),
                    in: 0...1,
                    format: { String(format: "α %.2f", $0) }
                )
            }
        }
    }

    private var resolvedHSV: (hue: Float, saturation: Float, value: Float) {
        let hsv = color.hsv
        if hsv.saturation < 0.001 {
            return (lastHue, hsv.saturation, hsv.value)
        }
        return hsv
    }

    private var swatch: some View {
        VStack(spacing: 0) { Spacer() }
            .frame(width: .pt(36), height: .pt(28))
            .background(color)
            .cornerRadius(6)
            .padding(1)
            .background(Theme.current.border)
            .cornerRadius(7)
    }

    private var hexField: some View {
        TextField(
            text: Binding(
                get: { hexText.isEmpty ? color.hex : hexText },
                set: { text in
                    hexText = text
                    if let parsed = Color(hex: text) {
                        apply(parsed)
                    }
                }
            ),
            placeholder: "#rrggbb",
            onSubmit: {
                if let parsed = Color(hex: hexText) {
                    apply(parsed)
                } else {
                    hexText = color.hex
                }
            }
        )
        .frame(width: .pt(118))
    }

    private func svSquare(hue: Float, saturation: Float, value: Float) -> some View {
        Canvas(
            label: "ColorPicker.sv",
            width: .pt(Self.squareWidth),
            height: .pt(Self.squareHeight),
            minWidth: Self.squareWidth,
            minHeight: Self.squareHeight,
            onGesture: { gesture in
                guard gesture.button == 0 else { return }
                pickSV(localX: gesture.localX, localY: gesture.localY, hue: hue)
            }
        ) { list, frame in
            paintSV(list, frame: frame, hue: hue, saturation: saturation, value: value)
        }
    }

    private func hueStrip(hue: Float, saturation: Float, value: Float) -> some View {
        Canvas(
            label: "ColorPicker.hue",
            width: .pt(Self.hueWidth),
            height: .pt(Self.squareHeight),
            minWidth: Self.hueWidth,
            minHeight: Self.squareHeight,
            onGesture: { gesture in
                guard gesture.button == 0 else { return }
                let t = min(max(gesture.localY / max(gesture.frame.h, 1), 0), 1)
                apply(
                    Color(hue: t, saturation: max(saturation, 0.001),
                          value: value, alpha: color.a),
                    hue: t
                )
            }
        ) { list, frame in
            paintHue(list, frame: frame, hue: hue)
        }
    }

    private func pickSV(localX: Float, localY: Float, hue: Float) {
        let s = min(max(localX / Self.squareWidth, 0), 1)
        let v = 1 - min(max(localY / Self.squareHeight, 0), 1)
        apply(Color(hue: hue, saturation: s, value: v, alpha: color.a), hue: hue)
    }

    /// `hue` is the strip position when the caller knows it — including
    /// when saturation is zero, where `Color.hsv.hue` is undefined.
    private func apply(_ new: Color, hue: Float? = nil) {
        if let hue {
            lastHue = hue
        } else if new.hsv.saturation >= 0.001 {
            lastHue = new.hsv.hue
        }
        color = new
        hexText = new.hex
    }

    private func paintSV(
        _ list: DrawList, frame: CanvasFrame,
        hue: Float, saturation: Float, value: Float
    ) {
        // Two plates, not a row of columns. Each gradient quad carries a
        // 1px SDF antialias so the edge is not a hard clip; two of those
        // half-coverage edges stacked (premultiplied `over`) are darker
        // than the fill they were meant to join. That was the pinstripe.
        // A white→hue ramp across and a clear→black veil down are the
        // usual HSV square and have no internal edge to seam.
        list.linearGradientRect(
            x: frame.x, y: frame.y, w: frame.w, h: frame.h,
            from: Color(r: 1, g: 1, b: 1),
            to: Color(hue: hue, saturation: 1, value: 1),
            angle: 0
        )
        list.linearGradientRect(
            x: frame.x, y: frame.y, w: frame.w, h: frame.h,
            from: Color(r: 0, g: 0, b: 0, a: 0),
            to: Color(r: 0, g: 0, b: 0, a: 1),
            angle: .pi / 2
        )
        let cx = frame.x + saturation * frame.w
        let cy = frame.y + (1 - value) * frame.h
        list.circle(cx: cx, cy: cy, radius: 7, color: .init(r: 1, g: 1, b: 1))
        list.circle(cx: cx, cy: cy, radius: 6, color: .init(r: 0, g: 0, b: 0))
        list.circle(cx: cx, cy: cy, radius: 4, color: color.opacity(1))
    }

    private func paintHue(_ list: DrawList, frame: CanvasFrame, hue: Float) {
        // Six sectors, each a two-stop ramp — exact, because a hue sector
        // is linear in authored RGB between its two primaries.
        let sectors: [Float] = [0, 1 / 6, 2 / 6, 3 / 6, 4 / 6, 5 / 6, 1]
        let h = frame.h / 6
        for i in 0..<6 {
            list.linearGradientRect(
                x: frame.x, y: frame.y + Float(i) * h,
                w: frame.w, h: h + 0.5,
                from: Color(hue: sectors[i], saturation: 1, value: 1),
                to: Color(hue: sectors[i + 1], saturation: 1, value: 1),
                angle: .pi / 2
            )
        }
        let y = frame.y + hue * frame.h
        list.rect(
            x: frame.x, y: y - 1, w: frame.w, h: 2,
            color: .init(r: 1, g: 1, b: 1)
        )
        list.rect(
            x: frame.x + 1, y: y - 0.5, w: frame.w - 2, h: 1,
            color: .init(r: 0, g: 0, b: 0)
        )
    }

    private static let squareWidth: Float = 200
    private static let squareHeight: Float = 140
    private static let hueWidth: Float = 18
}
