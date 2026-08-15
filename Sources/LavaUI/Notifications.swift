import Foundation
import Observation

/// Desktop notifications, from the panel's side: what is on screen right now,
/// and what a click on it does.
///
/// The Swift half of canvas's `NotificationHost`, and the same shape as
/// `StatusNotifierTray` — poll on the frame loop, rebuild when the revision
/// moves, forward the user's decisions back out. Everything that speaks D-Bus
/// stays on the C++ side; everything that decides what a toast looks like
/// stays above this.
@Observable
public final class Notifications {
    /// One live notification, with its icon already a texture.
    /// Not `Equatable`: `UIImage` is a texture handle, and comparing two
    /// toasts is never how a panel decides to redraw — `revision` is.
    public struct Toast: Identifiable {
        /// The protocol's id — what `ActionInvoked` and `NotificationClosed`
        /// speak in, and what a replacement reuses.
        public var id: UInt32
        public var appName: String
        public var summary: String
        public var body: String
        public var image: UIImage?
        /// First letter of the application's name, for when there is no icon.
        public var fallback: String
        public var urgency: Urgency
        /// Buttons, in the order the sender gave them. The conventional
        /// `default` action is not here — it is what clicking the body does.
        public var actions: [Action]
        /// True when this one waits for the user rather than a clock.
        public var isSticky: Bool
        /// Whether the sender offered a `default` action — what a click on the
        /// body invokes. Without one, that click just dismisses.
        public var hasDefaultAction: Bool

        public struct Action: Equatable, Identifiable {
            public var key: String
            public var label: String
            public var id: String { key }
        }
    }

    public enum Urgency: UInt8, Equatable {
        case low = 0
        case normal = 1
        case critical = 2
    }

    private let editor: Editor
    private var revision: UInt64 = 0
    /// Texture per notification id, so a poll that changed nothing does not
    /// re-upload an icon that is already resident.
    private var imageKeys: [UInt32: String] = [:]

    /// Whether this panel is the session's notification daemon. False when
    /// something else already owns the name — dunst, or the desktop this is
    /// nested inside — in which case that daemon draws them and this shows
    /// nothing.
    public private(set) var isServing = false
    public private(set) var toasts: [Toast] = []

    public init(editor: Editor) {
        self.editor = editor
        isServing = editor.notificationsStart()
        FileHandle.standardError.write(Data(
            (isServing
                ? "LavaUI: serving desktop notifications\n"
                : "LavaUI: notifications served elsewhere; not showing any\n"
            ).utf8
        ))
    }

    /// Pumps the bus, retires what expired, and rebuilds when either changed.
    @discardableResult
    public func poll() -> Bool {
        guard isServing else { return false }
        editor.notificationsPoll()
        let current = editor.notificationsRevision
        guard current != revision else { return false }
        revision = current
        rebuild()
        return true
    }

    /// A click on the body: the `default` action if the sender offered one,
    /// and otherwise just gone.
    public func activate(_ toast: Toast) {
        if toast.hasDefaultAction {
            editor.notificationInvokeAction(toast.id, key: "default")
        } else {
            editor.notificationDismiss(toast.id)
        }
    }

    public func invoke(_ toast: Toast, action: Toast.Action) {
        editor.notificationInvokeAction(toast.id, key: action.key)
    }

    public func dismiss(_ toast: Toast) {
        editor.notificationDismiss(toast.id)
    }

    public func dismissAll() {
        editor.notificationDismissAll()
    }

    /// Stops every countdown while the pointer is over the stack. A
    /// notification that vanishes mid-sentence is one the user has to guess at.
    public func setPaused(_ paused: Bool) {
        guard isServing else { return }
        editor.notificationsSetPaused(paused)
    }

    private func rebuild() {
        let count = editor.notificationsCount
        var next: [Toast] = []
        next.reserveCapacity(count)
        var live = Set<UInt32>()

        for index in 0..<count {
            let info = editor.notification(index)
            live.insert(info.id)

            var actions: [Toast.Action] = []
            for slot in 0..<info.actionCount {
                let key = editor.notificationActionKey(index, action: slot)
                // `default` is the click-the-body action by convention, and
                // drawing it as a button as well would offer the same thing
                // twice.
                guard key != "default" else { continue }
                actions.append(Toast.Action(
                    key: key,
                    label: editor.notificationActionLabel(index, action: slot)
                ))
            }
            let hasDefault = (0..<info.actionCount).contains {
                editor.notificationActionKey(index, action: $0) == "default"
            }

            let label = info.summary.isEmpty ? info.appName : info.summary
            next.append(Toast(
                id: info.id,
                appName: info.appName,
                summary: info.summary,
                body: info.body,
                image: resolveImage(info),
                fallback: Self.initial(of: info.appName.isEmpty ? label : info.appName),
                urgency: Urgency(rawValue: info.urgency) ?? .normal,
                actions: actions,
                isSticky: info.remainingMs == 0,
                hasDefaultAction: hasDefault
            ))
        }

        imageKeys = imageKeys.filter { live.contains($0.key) }
        toasts = next
    }

    private func resolveImage(_ info: NotificationInfo) -> UIImage? {
        if info.iconWidth > 0, info.iconHeight > 0,
           info.iconRgba.count >= info.iconWidth * info.iconHeight * 4
        {
            let key = "notify:\(info.id):\(info.iconWidth)x\(info.iconHeight)"
            imageKeys[info.id] = key
            return editor.uploadImage(
                key: key, path: key, pixels: info.iconRgba,
                width: UInt32(info.iconWidth), height: UInt32(info.iconHeight)
            )
        }
        if !info.iconPath.isEmpty {
            return ImageStore.load(path: info.iconPath, into: editor)
        }
        return nil
    }

    private static func initial(of name: String) -> String {
        guard let c = name.unicodeScalars.first,
              CharacterSet.alphanumerics.contains(c)
        else { return "•" }
        return String(c).uppercased()
    }
}
