// Copyright (c) 2021-2025, Nikita Pennie <nikitapnn1@gmail.com>
// SPDX-License-Identifier: MIT

import DocsModel
import Foundation

/// What makes this LavaUI's site rather than NPRPC's. DocsModel is the NPRPC
/// site's unchanged, so fixes there carry over by copying the directory; the
/// differences are kept here and in the templates.
enum Site {
    static let name = "LavaUI"
    /// The words someone looking for this would type, rather than its name —
    /// "LavaUI documentation" only matched people who already knew it.
    static let homeTitle = "LavaUI — SwiftUI-style UI framework for Linux, drawn with Vulkan"
    static let homeDescription =
        "A declarative UI framework in Swift for Linux: SwiftUI-style views, Yoga layout, "
        + "HarfBuzz text and a Vulkan renderer — and a Wayland desktop built with it."
    /// Where the site is served, for canonical links, the sitemap and link
    /// previews. `DOCS_BASE_URL` overrides it (a staging host, a local run).
    static let defaultBaseURL = "https://lavaui.nikitapn.com"
    /// The link-preview picture, relative to the static root.
    static let previewImage = "/desktop.jpg"
    /// Guides link to notes the site does not carry (`issues.md`,
    /// `../AGENTS.md`); those go to the repository instead of a 404.
    static let repository = "https://github.com/nikitapn/LavaUI/blob/main/"

    /// The Swift modules an app imports, in the order someone learning the
    /// framework meets them.
    static let modules: [(name: String, summary: String)] = [
        ("LavaUI", "Views, state, layout, drawing, input and the app loop."),
        ("LavaHost", "Opens an app as a window or as a compositor client, chosen at run time."),
        ("LavaClient", "Runs an app as a client of the Lava compositor, with no GPU of its own."),
        ("LavaText", "Text editing without a GPU: cursors, selection, undo, search, wrapping."),
        ("LavaMenu", "Application menus as data, for whatever draws them."),
    ]

    static let languageSummaries: [String: String] = [
        "idl": "The compositor's control plane: fonts, images, surfaces, present and input.",
    ]

    /// Guides in reading order; the rest follow alphabetically.
    static let guideOrder = ["getting-started", "api", "install", "swiftui-parity"]

    static func title(of language: Language) -> String {
        language.id == "idl" ? "Control plane" : language.title
    }

    static func stats(_ index: DocsIndex, lang: Language, namespace: String) -> (Int, Int) {
        let prefix = namespace + lang.separator
        let all = index.symbols.values.filter {
            $0.lang == lang.id && ($0.qualified == namespace || $0.qualified.hasPrefix(prefix))
        }
        return (all.count, all.filter { !$0.doc.isEmpty }.count)
    }

    /// Rendered HTML as one line of plain text for a meta description:
    /// tags gone, the entities the renderers emit decoded, whitespace
    /// collapsed, and cut at a word near `limit` characters — about what a
    /// results page shows before it truncates on its own.
    static func plainText(_ html: String, limit: Int = 160) -> String? {
        // Blocks end in a space, inline tags in nothing: `<code>@State</code>,`
        // is "@State," — a space for every tag reads "@State ,".
        var text = html.replacingOccurrences(
            of: "</(p|li|h[1-6]|div|td|th|pre|blockquote)>|<br\\s*/?>", with: " ",
            options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, char) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"),
                               ("&#x27;", "'"), ("&nbsp;", " "), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: char)
        }
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        guard text.count > limit else { return text }
        let cut = text.prefix(limit)
        // A whole sentence if one ends in the back half; otherwise a word
        // boundary and an ellipsis to say the text goes on.
        if let end = cut.lastIndex(where: { ".!?".contains($0) }),
           cut.distance(from: cut.startIndex, to: end) >= limit / 2 {
            return String(cut[...end])
        }
        let word = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return word.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:—-")) + "…"
    }

    /// A guide's first paragraph, which is where every guide says what it is.
    static func firstParagraph(_ html: String) -> String? {
        guard let r = html.range(of: "(?s)<p>.*?</p>", options: .regularExpression) else {
            return nil
        }
        return plainText(String(html[r]))
    }

    /// Relative `href`s and `src`s left in a guide after DocsModel rewrote
    /// the ones between guides point at files in the repository.
    static func linkOutside(_ html: String, from file: String) -> String {
        let dir = file.split(separator: "/").dropLast().map(String.init)
        var out = ""
        var rest = Substring(html)
        while let r = rest.range(of: #"(href|src)=""#, options: .regularExpression) {
            out += rest[..<r.upperBound]
            rest = rest[r.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { break }
            let target = String(rest[..<end])
            rest = rest[end...]
            let external = target.isEmpty || target.hasPrefix("/") || target.hasPrefix("#")
                || target.contains(":")
            guard !external else {
                out += target
                continue
            }
            var parts = dir
            for part in target.split(separator: "/", omittingEmptySubsequences: false) {
                if part == ".." { _ = parts.popLast() } else if part != "." { parts.append(String(part)) }
            }
            out += repository + parts.joined(separator: "/")
        }
        out += rest
        return out
    }
}
