import LavaUI

struct PassFonts {
    let body: UIFont?
    let strong: UIFont?
    let caption: UIFont?
    let kicker: UIFont?
    let hero: UIFont?
    let heading: UIFont?
    let detail: UIFont?

    init(editor: Editor) {
        func face(_ name: String, _ size: Float, spacing: Float = 0) -> UIFont? {
            guard let path = BundledFont.path(name),
                  let font = UIFont(path: path, pixelSize: size, letterSpacing: spacing),
                  font.registerWithEngine(editor)
            else { return nil }
            if let base = FontStore.default {
                let paths = [base.path] + base.fallbacks.map(\.path)
                font.useFallbacks(paths.map { FontFallback(path: $0, pixelSize: size) }, into: editor)
            }
            return font
        }

        body = face("Figtree-Regular", 14)
        strong = face("Figtree-SemiBold", 14)
        caption = face("Figtree-Regular", 12)
        kicker = face("Figtree-Bold", 11, spacing: 0.1)
        hero = face("Caprasimo-Regular", 30)
        heading = face("Caprasimo-Regular", 22)
        detail = face("Caprasimo-Regular", 24)
    }
}
