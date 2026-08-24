import LavaUI

/// The notification stack, drawn at the top right of the panel's own surface.
///
/// Not a window of its own, and that is the whole design: the panel is already
/// a full-width surface that reaches `MenuSession.openHeight` down the screen
/// with an input region it deepens whenever something is open. A toast is the
/// same problem as a dropdown — paint below the strip, take clicks while it is
/// up, hand them back when it goes — so it costs no new surface, no new
/// protocol and no second process.
///
/// What that buys is also what it costs: toasts live inside the panel's
/// surface, so they cannot be deeper than it is, cannot sit at the bottom of
/// the screen, and go with the panel if it restarts.
///
/// The stack's own rectangle is what the panel claims clicks in — `agentId`
/// below is how it finds it, and `MenuSession.toastFrame` reads the committed
/// layout rather than adding up a guess per card. That matters more than it
/// sounds: the panel's region used to be one rectangle, so a stack at the
/// right edge and a strip across the screen could only be described by their
/// union, and every click along the top of the desktop went to the panel
/// until the notification expired.
struct ToastStack: View {
    var notifications: Notifications

    /// Widest a toast gets: enough for a sentence of body text, not so much
    /// that it becomes a second panel.
    static let width: Float = 380
    /// Clear of the strip before the first card.
    static let topInset: Float = MenuSession.stripHeight + 8

    var body: some View {
        VStack(width: .pt(Self.width), padding: 0, spacing: 8) {
            ForEach(notifications.toasts) { toast in
                ToastCard(toast: toast, notifications: notifications)
            }
        }
        .agentId("notifications")
    }
}

/// One notification.
private struct ToastCard: View {
    var toast: Notifications.Toast
    var notifications: Notifications

    var body: some View {
        let theme = Theme.current
        let model = notifications
        let item = toast

        return VStack(
            padding: 0,
            spacing: 6,
            // Anywhere on the card that is not a button runs the sender's
            // default action, or dismisses when it offered none.
            onClick: { model.activate(item) },
            // The countdown stops while the pointer is here: reading a
            // notification should not be a race against it.
            onHover: { inside in model.setPaused(inside) }
        ) {
            HStack(padding: 0, alignment: .start, spacing: 10) {
                icon
                VStack(flexGrow: 1, padding: 0, spacing: 2) {
                    // The application first and dim: a toast is read by where
                    // it came from before it is read at all.
                    if !item.appName.isEmpty {
                        Text(item.appName, color: theme.textDim)
                    }
                    if !item.summary.isEmpty {
                        Text(item.summary, color: theme.textPrimary)
                    }
                    if !item.body.isEmpty {
                        Text(item.body, color: theme.textSecondary)
                            .lineLimit(6)
                    }
                }
                // An explicit close, because a click on the body may run the
                // sender's action rather than dismiss.
                HStack(
                    padding: 0, alignment: .center,
                    onClick: { model.dismiss(item) }
                ) {
                    Text("✕", color: theme.textDim)
                }
                .padding(4)
                .cornerRadius(4)
                .hoverBackground(theme.hover)
                .agentId("notification.close.\(item.id)")
            }

            if !item.actions.isEmpty {
                HStack(padding: 0, spacing: 6) {
                    Spacer()
                    ForEach(item.actions) { action in
                        HStack(
                            padding: 0, alignment: .center,
                            onClick: { model.invoke(item, action: action) }
                        ) {
                            Text(action.label, color: theme.accent)
                        }
                        .padding(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                        .cornerRadius(6)
                        .hoverBackground(theme.hover)
                        .agentId("notification.action.\(item.id).\(action.key)")
                    }
                }
            }
        }
        .padding(12)
        .background(background)
        .cornerRadius(10)
        .agentId("notification.\(item.id)")
    }

    /// Critical is the one case where the panel's own colour is wrong: "the
    /// battery is about to die" must not look like "a song changed". It is
    /// also the urgency that never expires, so the colour is what says the
    /// card is waiting for an answer.
    private var background: Color {
        toast.urgency == .critical
            ? Color(r: 0.42, g: 0.13, b: 0.15)
            : Theme.current.panel
    }

    @ViewBuilder
    private var icon: some View {
        if let image = toast.image {
            Image(image, width: .pt(32), height: .pt(32), contentMode: .fit)
        } else {
            Text(toast.fallback, color: Theme.current.textDim)
                .padding(8)
        }
    }
}
