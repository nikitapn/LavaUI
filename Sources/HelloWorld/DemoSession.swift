import Foundation
import LavaUI
import Observation

/// Chrome the demo's menubar and its own header both drive.
///
/// Same join as TraceLoom's `TraceLoomSession`: menu actions are built in
/// `LavaApp.run(menu:)`, outside the view tree, so they cannot capture `@State`
/// — those wrappers are value copies. An `@Observable` class is what both sides
/// can hold.
///
/// Deliberately only the *shared* state. The demo's list, editors, sliders and
/// canvases stay `@State` on `DemoExample`, because nothing outside the view
/// touches them and moving them here would trade working code for churn.
///
/// `lightTheme` earns its place by having been a bug: the menu wrote
/// `Theme.current` directly while the header's `[ Theme: Dark ]` label read a
/// separate `@State`, so toggling the theme from the menu changed the colours
/// and left the label saying the opposite.
@Observable
final class DemoSession {
    var showSidebar = true
    var showInspector = true
    var showBanner = true
    var lightTheme = false

    /// Applies `lightTheme` to the global theme. The single writer, so the
    /// label and the colours cannot disagree again.
    func setTheme(light: Bool) {
        lightTheme = light
        Theme.current = light ? .light : .dark
    }

    func toggleTheme() {
        setTheme(light: !lightTheme)
    }

    /// Everything the menu can put back, for when a demo session has been
    /// clicked into a corner.
    func resetChrome() {
        showSidebar = true
        showInspector = true
        showBanner = true
        setTheme(light: false)
    }
}
