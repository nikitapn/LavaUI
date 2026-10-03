import Foundation
import LavaClient
import LavaIDL
import LavaUI
import Observation

// The lock screen.
//
//   the compositor locks          (idle, Mod+L, logind, suspend)
//     →  black curtain over every output, input taken from every window
//     →  this process, started with LAVA_LOCK_TOKEN
//     →  CreateLockSurface(token)  — refused without it
//     →  SubscribeLock: a password one way, LockState the other
//     →  `unlocked`: the compositor destroys the surface, and the input
//        stream ending is what ends this process
//
// **This process cannot unlock anything.** It draws a field and reports what
// was typed into it; the compositor checks the password with PAM and decides.
// If this crashes the session stays locked behind the curtain and the
// compositor starts another one.

/// What the screen shows. The password itself is not observed: the field
/// draws its length, and that is all the view ever reads of it.
@Observable
final class LockModel {
    var status: LockStatus = .locked
    var failures: UInt32 = 0
    var user = ""
    var time = ""
    var date = ""
    /// How many characters are in the field.
    var typed = 0
    /// What PAM said, and the keyboard as the compositor reads it. See
    /// `LockState`.
    var message = ""
    var capsLock = false
    var numLock = true
    var layout = ""

    /// Enter was pressed while the last attempt was still being checked.
    /// Submitted when that one comes back refused, rather than dropped:
    /// retyping during PAM's delay is exactly what a person does.
    @ObservationIgnored private var submitWhenAnswered = false

    /// UTF-8 bytes rather than a `String`, so it can be zeroed. A `String`
    /// is immutable storage that is freed whenever ARC decides and never
    /// cleared; this buffer is cleared the moment it is sent.
    @ObservationIgnored private var password: [UInt8] = []
    /// Where each typed character ends in `password`, so Backspace removes a
    /// character and not a byte of one.
    @ObservationIgnored private var boundaries: [Int] = []

    var checking: Bool { status == .checking }

    /// GLFW's codes for the two keys `KeyCode` does not name.
    private static let keypadEnter: Int32 = 335
    private static let keyU: Int32 = 85

    /// Typing is accepted while a check runs. It used to be swallowed, and
    /// the delay PAM puts on a wrong password is exactly when people retype:
    /// the first characters of the next attempt vanished, so it was refused
    /// too, and each refusal counted towards `pam_faillock` locking the
    /// account.
    func type(_ character: Character) -> Bool {
        // Control characters are keys, not text; Enter and friends arrive
        // through `key` as well.
        guard let scalar = character.unicodeScalars.first, scalar.value >= 0x20,
              scalar.value != 0x7f
        else { return false }
        password.append(contentsOf: Array(String(character).utf8))
        boundaries.append(password.count)
        typed = boundaries.count
        // Typing again is answering the last refusal; its message has done
        // its job.
        if status == .rejected { status = .locked }
        return true
    }

    func key(_ event: KeyEvent) -> Bool {
        switch event.key {
        case KeyCode.backspace:
            guard !boundaries.isEmpty else { return true }
            if event.control {
                clear()
            } else {
                boundaries.removeLast()
                let keep = boundaries.last ?? 0
                for index in keep..<password.count { password[index] = 0 }
                password.removeSubrange(keep...)
                typed = boundaries.count
            }
            return true
        case KeyCode.escape:
            clear()
            submitWhenAnswered = false
            return true
        case KeyCode.enter, Self.keypadEnter:
            submit()
            return true
        default:
            // Ctrl+U, the terminal's "clear the line", because that is what
            // people reach for at a password prompt.
            if event.control, event.key == Self.keyU {
                clear()
                return true
            }
            return false
        }
    }

    func submit() {
        guard !password.isEmpty else { return }
        guard !checking else {
            submitWhenAnswered = true
            return
        }
        LavaClient.submitPassword(String(decoding: password, as: UTF8.self))
        clear()
        // Shown at once rather than when the compositor says so: the round
        // trip is short, but the field emptying with nothing else happening
        // reads as the password being thrown away.
        status = .checking
    }

    func apply(_ state: LockState) {
        // The compositor's `checking` for an attempt this screen already shows
        // as checking changes nothing; anything else is news.
        status = state.status
        failures = state.failures
        user = state.user
        message = state.message
        capsLock = state.capsLock
        numLock = state.numLock
        layout = state.layout
        if status == .rejected, submitWhenAnswered {
            submitWhenAnswered = false
            submit()
        }
    }

    func clear() {
        for index in password.indices { password[index] = 0 }
        password.removeAll()
        boundaries.removeAll()
        typed = 0
    }

    func tick() {
        let now = Date()
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm"
        let day = DateFormatter()
        day.dateFormat = "EEEE, d MMMM"
        let newTime = clock.string(from: now)
        let newDate = day.string(from: now)
        // Only on change: an observed write is a frame, and a lock screen that
        // redrew every second would keep the GPU awake all night.
        if newTime != time { time = newTime }
        if newDate != date { date = newDate }
    }
}

enum Palette {
    static let behind = Color(r: 0.035, g: 0.04, b: 0.06)
    static let glow = Color(r: 0.09, g: 0.1, b: 0.16)
    static let text = Color(r: 0.93, g: 0.94, b: 0.97)
    static let dim = Color(r: 0.62, g: 0.65, b: 0.72)
    static let field = Color(r: 1, g: 1, b: 1, a: 0.08)
    static let fieldEdge = Color(r: 1, g: 1, b: 1, a: 0.16)
    static let wrong = Color(r: 0.96, g: 0.45, b: 0.45)
    static let warn = Color(r: 0.95, g: 0.78, b: 0.42)
}

struct Fonts {
    let clock: UIFont?
    let date: UIFont?
    let body: UIFont?
}

struct LockView: View {
    let model: LockModel
    let fonts: Fonts

    /// The one keyboard target: there is nothing else on this screen to type
    /// into, and a lock screen that waited for a click first would be one
    /// that ignored the first characters of every password.
    private let keyTarget = NodeID.generate()

    var body: some View {
        FocusManager.setDefault(
            keyTarget,
            onKey: { [model] event in model.key(event) },
            onChar: { [model] character in model.type(character) }
        )

        return VStack(flexGrow: 1, alignment: .center, spacing: 10) {
            Spacer()
            Text(model.time, color: Palette.text, font: fonts.clock)
            Text(model.date, color: Palette.dim, font: fonts.date)
            Spacer().frame(height: .pt(48))
            Text(model.user, color: Palette.text, font: fonts.body)
            PasswordField(model: model)
            Text(statusLine, color: statusColor, font: fonts.body)
            // PAM's own words — `pam_faillock`'s "the account is locked" is
            // why a right password is refused, and nothing else would say so.
            if !model.message.isEmpty {
                Text(model.message, color: Palette.wrong)
            }
            Text(keyboardLine, color: Palette.warn)
            Spacer()
            Text(
                "Type your password and press Enter",
                color: Palette.dim
            )
            .padding(.bottom, 32)
        }
        .background(Gradient(from: Palette.glow, to: Palette.behind))
    }

    private var statusLine: String {
        switch model.status {
        case .checking: return "Checking…"
        case .rejected:
            return model.failures > 1
                ? "Wrong password (\(model.failures) attempts)"
                : "Wrong password"
        case .unlocked: return "Unlocked"
        case .locked: return " "
        }
    }

    /// What the keyboard will type that the dots cannot show.
    private var keyboardLine: String {
        var parts: [String] = []
        if model.capsLock { parts.append("Caps Lock is on") }
        if !model.numLock { parts.append("Num Lock is off") }
        if !model.layout.isEmpty { parts.append(model.layout) }
        return parts.isEmpty ? " " : parts.joined(separator: "  ·  ")
    }

    private var statusColor: Color {
        model.status == .rejected ? Palette.wrong : Palette.dim
    }
}

/// Dots, one per character typed, in a plate the width of a password. Never
/// the characters: there is nothing here that could show them even by
/// accident, because the view only ever reads the count.
///
/// Drawn rather than typeset — the UI face has no large dot, and a glyph the
/// face lacks comes out as a box.
struct PasswordField: View {
    let model: LockModel

    static let width: Float = 340
    static let height: Float = 52
    static let dot: Float = 10
    static let gap: Float = 8

    var body: some View {
        // Read here so the field rebuilds when they change: paint is not
        // observed.
        let typed = model.typed
        let dim = model.checking
        return Canvas(
            label: "password",
            width: .pt(Self.width),
            height: .pt(Self.height),
            paint: { list, frame in
                list.roundedRect(
                    x: frame.x, y: frame.y, w: frame.w, h: frame.h,
                    color: Palette.field, radius: 12
                )
                // As many as fit; a longer password still shows a full row,
                // which says "a lot" as well as forty dots would.
                let fits = Int((frame.w - 32 + Self.gap) / (Self.dot + Self.gap))
                let count = min(typed, fits)
                guard count > 0 else { return }
                let row = Float(count) * Self.dot + Float(count - 1) * Self.gap
                var x = frame.x + (frame.w - row) / 2
                let y = frame.y + (frame.h - Self.dot) / 2
                for _ in 0..<count {
                    list.roundedRect(
                        x: x, y: y, w: Self.dot, h: Self.dot,
                        color: dim ? Palette.dim : Palette.text,
                        radius: Self.dot / 2
                    )
                    x += Self.dot + Self.gap
                }
            }
        )
        .border(Palette.fieldEdge)
        .cornerRadius(12)
    }
}

// ─── Bring-up ───────────────────────────────────────────────────────────────

// Opaque: the curtain behind this is black, and the desktop behind that is
// exactly what must not show through.
WindowBackdrop.current = .theme

guard let editor = LavaClient.openLockSurface() else {
    FileHandle.standardError.write(
        Data("LavaLock: not started by the compositor for a lock\n".utf8)
    )
    exit(1)
}

/// Loaded at a size and registered, because a client stamps glyph ids that
/// the compositor resolves against the face registered under that id.
func face(_ pixelSize: Float) -> UIFont? {
    guard let font = UIFont.loadUI(assetsRoot: LavaResources.root, pixelSize: pixelSize),
          font.registerWithEngine(editor)
    else { return nil }
    return font
}

let fonts = Fonts(clock: face(96), date: face(24), body: face(20))
// Touched only from the frame loop; the closures that reach it hop there
// first. Same arrangement as the panel's clock.
nonisolated(unsafe) let model = LockModel()
model.tick()

LavaClient.onLockState { state in model.apply(state) }

Thread.detachNewThread {
    while true {
        MainQueue.async { model.tick() }
        Thread.sleep(forTimeInterval: 1.0)
    }
}

LavaClient.run(editor: editor) { LockView(model: model, fonts: fonts) }
