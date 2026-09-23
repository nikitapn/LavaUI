// Copyright (c) 2021-2025, Nikita Pennie <nikitapnn1@gmail.com>
// SPDX-License-Identifier: MIT

import DocsModel

/// What makes this LavaUI's site rather than NPRPC's. DocsModel is the NPRPC
/// site's unchanged, so fixes there carry over by copying the directory; the
/// differences are kept here and in the templates.
enum Site {
    static let name = "LavaUI"
    static let homeTitle = "LavaUI documentation"
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
