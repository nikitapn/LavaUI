import Foundation

/// Streaming ANSI / VT100 parser. Feeds printable characters and control
/// sequences into a `TerminalScreen`.
///
/// Incomplete on purpose: enough for interactive shells and full-screen tools
/// (tmux, less, vim) — SGR, CUP, scroll regions, DEC private modes, and a
/// correct ECMA-48 escape state machine so sequences like `ESC ( B` (charset
/// designate) are consumed whole rather than leaving a stray `B` on screen.
/// Everything else is acknowledged and ignored.
public final class AnsiParser: @unchecked Sendable {
    public enum Output: Equatable, Sendable {
        case print(Unicode.Scalar)
        case bell
        case backspace
        case tab
        case lineFeed
        case carriageReturn
        case cursorUp(Int)
        case cursorDown(Int)
        case cursorForward(Int)
        case cursorBack(Int)
        case cursorPosition(row: Int, col: Int)
        case eraseDisplay(Int)
        case eraseLine(Int)
        case setGraphics([Int])
        case scrollUp(Int)
        case scrollDown(Int)
        case saveCursor
        case restoreCursor
        case setScrollRegion(top: Int, bottom: Int)
        case deleteChars(Int)
        case insertChars(Int)
        case eraseChars(Int)
        case deleteLines(Int)
        case insertLines(Int)
        /// DEC private modes: `CSI ? … h` / `CSI ? … l`. Modes are the
        /// integers between the `?` and the final — one sequence can set several.
        case privateModes(modes: [Int], set: Bool)
        case ignore
    }

    private enum State {
        case ground
        /// Byte immediately after ESC.
        case escape
        /// ESC + one or more intermediate bytes (0x20…0x2F). The next final
        /// (0x30…0x7E) ends the sequence — charset designates live here:
        /// `ESC ( B`, `ESC ) 0`, `ESC * B`, …
        case escapeIntermediate
        case csi
        case osc
        /// OSC saw ESC; next byte is `\` (ST) or something else.
        case oscEsc
        /// DCS / SOS / PM / APC: ignore until BEL or ST. Without this, the
        /// payload of an ignored string sequence prints as garbage.
        case stringIgnored
        case stringIgnoredEsc
    }

    private var state: State = .ground
    private var csiParams = ""
    private var csiPrivate = false
    private var oscBuffer = ""

    public init() {}

    public func reset() {
        state = .ground
        csiParams = ""
        csiPrivate = false
        oscBuffer = ""
    }

    /// Parse a chunk of bytes from the PTY (UTF-8). Invalid sequences become U+FFFD.
    public func feed(_ data: Data) -> [Output] {
        var out: [Output] = []
        var i = data.startIndex
        while i < data.endIndex {
            // Multi-byte UTF-8 only in ground: control sequences are byte-oriented.
            if state == .ground {
                let byte = data[i]
                if byte < 0x80 {
                    out.append(contentsOf: consumeGround(Unicode.Scalar(byte)))
                    i = data.index(after: i)
                    continue
                }
                if let (scalar, next) = decodeUTF8(data, from: i) {
                    out.append(contentsOf: consumeGround(scalar))
                    i = next
                } else {
                    out.append(.print(Unicode.Scalar(0xFFFD)!))
                    i = data.index(after: i)
                }
                continue
            }

            let byte = data[i]
            i = data.index(after: i)
            out.append(contentsOf: consumeControl(Unicode.Scalar(byte)))
        }
        return out
    }

    // MARK: - State machine

    private func consumeGround(_ s: Unicode.Scalar) -> [Output] {
        switch s.value {
        case 0x07: return [.bell]
        case 0x08: return [.backspace]
        case 0x09: return [.tab]
        case 0x0A, 0x0B, 0x0C: return [.lineFeed]
        case 0x0D: return [.carriageReturn]
        case 0x1B:
            state = .escape
            return []
        case 0x00...0x1F, 0x7F:
            return []  // other C0 ignored
        default:
            return [.print(s)]
        }
    }

    private func consumeControl(_ s: Unicode.Scalar) -> [Output] {
        switch state {
        case .ground:
            return consumeGround(s)

        case .escape:
            return consumeEscape(s)

        case .escapeIntermediate:
            let v = s.value
            // More intermediates.
            if v >= 0x20 && v <= 0x2F {
                return []
            }
            // Final byte — charset designates, double-height lines, etc.
            // We do not implement any of them; consuming the final is the fix
            // so `ESC ( B` does not leave a printable `B` on the screen.
            if v >= 0x30 && v <= 0x7E {
                state = .ground
                return [.ignore]
            }
            // CAN / SUB / unexpected: cancel and resync.
            state = .ground
            return consumeGround(s)

        case .csi:
            let v = s.value
            if csiParams.isEmpty && (v == 0x3F || v == 0x3E || v == 0x3C || v == 0x3D) {
                csiPrivate = true
                csiParams.append(Character(s))
                return []
            }
            if (v >= 0x30 && v <= 0x3F) || v == 0x3B {
                csiParams.append(Character(s))
                return []
            }
            // Intermediate bytes
            if v >= 0x20 && v <= 0x2F {
                csiParams.append(Character(s))
                return []
            }
            // Final byte
            state = .ground
            return [parseCSI(final: Character(s))]

        case .osc:
            if s.value == 0x07 {
                state = .ground
                oscBuffer = ""
                return [.ignore]
            }
            if s.value == 0x1B {
                state = .oscEsc
                return []
            }
            if oscBuffer.count < 4096 {
                oscBuffer.append(Character(s))
            }
            return []

        case .oscEsc:
            // ST is ESC \ — anything else after ESC ends OSC too (resync).
            state = .ground
            oscBuffer = ""
            return [.ignore]

        case .stringIgnored:
            if s.value == 0x07 {
                state = .ground
                return [.ignore]
            }
            if s.value == 0x1B {
                state = .stringIgnoredEsc
                return []
            }
            return []

        case .stringIgnoredEsc:
            state = .ground
            return [.ignore]
        }
    }

    private func consumeEscape(_ s: Unicode.Scalar) -> [Output] {
        let v = s.value
        switch v {
        case 0x5B:  // [
            state = .csi
            csiParams = ""
            csiPrivate = false
            return []
        case 0x5D:  // ]
            state = .osc
            oscBuffer = ""
            return []
        // DCS / SOS / PM / APC — ignore the string body until BEL or ST.
        case 0x50, 0x58, 0x5E, 0x5F:  // P X ^ _
            state = .stringIgnored
            return []
        // Intermediate: charset designation, etc. (`ESC ( B`).
        case 0x20...0x2F:
            state = .escapeIntermediate
            return []
        // Finals we care about (no intermediates).
        case 0x37:  // 7
            state = .ground
            return [.saveCursor]
        case 0x38:  // 8
            state = .ground
            return [.restoreCursor]
        case 0x44:  // D index
            state = .ground
            return [.lineFeed]
        case 0x4D:  // M reverse index
            state = .ground
            return [.scrollDown(1)]
        case 0x45:  // E next line
            state = .ground
            return [.carriageReturn, .lineFeed]
        case 0x3D, 0x3E:  // DECKPAM / DECKPNM — keypad mode; keys still work
            state = .ground
            return [.ignore]
        case 0x63:  // RIS full reset
            state = .ground
            return [.ignore]
        default:
            // Unknown single-byte ESC final: swallow it, do not print it.
            if v >= 0x30 && v <= 0x7E {
                state = .ground
                return [.ignore]
            }
            // C0 inside ESC: cancel.
            state = .ground
            return consumeGround(s)
        }
    }

    private func parseCSI(final: Character) -> Output {
        // Strip private-mode marker for params
        var raw = csiParams
        if csiPrivate, let first = raw.first, "?><=".contains(first) {
            raw = String(raw.dropFirst())
        }
        let parts = raw.split(separator: ";", omittingEmptySubsequences: false)
            .map { Int($0) ?? 0 }

        func p(_ i: Int, default d: Int = 1) -> Int {
            if i < parts.count {
                let v = parts[i]
                return v == 0 ? d : v
            }
            return d
        }

        // DEC private modes. Without these, full-screen tools (tmux, less,
        // vim, htop) cannot enter the alternate screen or hide the cursor —
        // they draw on top of the shell's scrollback and look broken.
        if csiPrivate {
            switch final {
            case "h":
                return .privateModes(modes: parts.isEmpty ? [0] : parts, set: true)
            case "l":
                return .privateModes(modes: parts.isEmpty ? [0] : parts, set: false)
            default:
                return .ignore
            }
        }

        switch final {
        case "A": return .cursorUp(p(0))
        case "B": return .cursorDown(p(0))
        case "C": return .cursorForward(p(0))
        case "D": return .cursorBack(p(0))
        case "H", "f":
            return .cursorPosition(row: p(0), col: p(1))
        case "J": return .eraseDisplay(parts.first ?? 0)
        case "K": return .eraseLine(parts.first ?? 0)
        case "m":
            // Empty CSI m is reset
            let list = raw.isEmpty ? [0] : parts
            return .setGraphics(list)
        case "S": return .scrollUp(p(0))
        case "T": return .scrollDown(p(0))
        case "r":
            let top = parts.isEmpty ? 1 : max(1, parts[0] == 0 ? 1 : parts[0])
            let bottom = parts.count > 1 ? max(top, parts[1]) : 0
            return .setScrollRegion(top: top, bottom: bottom)
        case "P": return .deleteChars(p(0))
        case "@": return .insertChars(p(0))
        case "X": return .eraseChars(p(0))
        case "M": return .deleteLines(p(0))
        case "L": return .insertLines(p(0))
        case "s": return .saveCursor
        case "u": return .restoreCursor
        case "G":
            // Cursor Horizontal Absolute
            return .cursorPosition(row: 0, col: p(0))  // row 0 = keep
        case "d":
            // Vertical Absolute
            return .cursorPosition(row: p(0), col: 0)
        default:
            return .ignore
        }
    }

    // MARK: - UTF-8

    private func decodeUTF8(_ data: Data, from start: Data.Index) -> (Unicode.Scalar, Data.Index)? {
        let b0 = data[start]
        let len: Int
        let mask: UInt8
        switch b0 {
        case 0xC0...0xDF: len = 2; mask = 0x1F
        case 0xE0...0xEF: len = 3; mask = 0x0F
        case 0xF0...0xF7: len = 4; mask = 0x07
        default: return nil
        }
        var i = start
        var value = UInt32(b0 & mask)
        for _ in 1..<len {
            i = data.index(after: i)
            guard i < data.endIndex else { return nil }
            let b = data[i]
            guard (b & 0xC0) == 0x80 else { return nil }
            value = (value << 6) | UInt32(b & 0x3F)
        }
        guard let scalar = Unicode.Scalar(value) else { return nil }
        return (scalar, data.index(after: i))
    }
}
