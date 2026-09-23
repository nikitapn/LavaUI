// Copyright (c) 2021-2025, Nikita Pennie <nikitapnn1@gmail.com>
// SPDX-License-Identifier: MIT

import Foundation

/// A long-form page written as HTML rather than Markdown, because it carries
/// diagrams and a layout of its own: `articles/<slug>.html`, a fragment the
/// layout wraps like any other page.
struct Article: Sendable {
    let slug: String
    /// The text of its `<h1>`.
    let title: String
    /// The text of its `.standfirst` paragraph, for the home page.
    let summary: String?
    let html: String
}

/// The articles directory, read once, or on every request while templates
/// are being reloaded — so an edit shows up the same way a template's does.
final class ArticleStore: @unchecked Sendable {
    private let directory: String
    private let reload: Bool
    private let lock = NSLock()
    private var cached: [Article]

    init(directory: String, reload: Bool) {
        self.directory = directory
        self.reload = reload
        self.cached = Self.load(directory)
    }

    var all: [Article] {
        lock.lock()
        defer { lock.unlock() }
        if reload { cached = Self.load(directory) }
        return cached
    }

    func article(slug: String) -> Article? { all.first { $0.slug == slug } }

    private static func load(_ directory: String) -> [Article] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return files.filter { $0.hasSuffix(".html") }.sorted().compactMap { file in
            guard let html = try? String(contentsOfFile: directory + "/" + file, encoding: .utf8)
            else { return nil }
            let slug = String(file.dropLast(5))
            // A comment may well mention the very tags looked for below.
            let body = html.replacingOccurrences(of: "(?s)<!--.*?-->", with: "",
                                                 options: .regularExpression)
            return Article(slug: slug,
                           title: text(of: "<h1", closedBy: "</h1>", in: body) ?? slug,
                           summary: text(of: "class=\"standfirst\"", closedBy: "</p>", in: body),
                           html: html)
        }
    }

    /// The text inside the first element whose opening tag contains `marker`,
    /// up to `closing`, tags stripped. The element must not nest its own kind.
    private static func text(of marker: String, closedBy closing: String, in html: String) -> String? {
        guard let start = html.range(of: marker),
              let open = html[start.upperBound...].firstIndex(of: ">"),
              let close = html[open...].range(of: closing)
        else { return nil }
        let inner = html[html.index(after: open)..<close.lowerBound]
        let stripped = inner.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
