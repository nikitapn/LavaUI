// Copyright (c) 2021-2025, Nikita Pennie <nikitapnn1@gmail.com>
// SPDX-License-Identifier: MIT

import DocsModel
import Foundation
import NPRPC
import NPRPCWeb

/// Holds the index built from api.json and rebuilds it when the file
/// changes, so `scripts/docs-api.sh` shows up on the next request without a
/// restart.
public final class DocsStore: @unchecked Sendable {
    private let path: String
    private let lock = NSLock()
    private var index: DocsIndex
    private var loadedAt: Date?

    public init(path: String) throws {
        self.path = path
        self.index = DocsIndex(try ApiFile.load(from: path))
        self.loadedAt = Self.modified(path)
    }

    public var current: DocsIndex {
        lock.lock()
        defer { lock.unlock() }
        let modified = Self.modified(path)
        if let modified, modified != loadedAt {
            // A half-written or broken file keeps the last good index.
            do {
                index = DocsIndex(try ApiFile.load(from: path))
                loadedAt = modified
            } catch {
                FileHandle.standardError.write(Data("docs: keeping previous api.json: \(error)\n".utf8))
            }
        }
        return index
    }

    private static func modified(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }
}

public struct DocsSite: Sendable {
    public static let dropdownResults = 12
    public static let pageResults = 100

    private let store: DocsStore
    private let library: TemplateLibrary
    private let articles: ArticleStore
    /// Scheme and host the site is reached at, no trailing slash.
    private let baseURL: String

    public init(store: DocsStore, templateDirectory: String, articleDirectory: String,
                hotReload: Bool = false, baseURL: String? = nil) throws {
        self.store = store
        var base = baseURL ?? Site.defaultBaseURL
        while base.hasSuffix("/") { base.removeLast() }
        self.baseURL = base
        self.library = try TemplateLibrary(directory: templateDirectory, hotReload: hotReload)
        self.articles = ArticleStore(directory: articleDirectory, reload: hotReload)
    }

    public var articleNames: [String] { articles.all.map(\.slug) }

    public var templateNames: [String] { library.templateNames }

    /// Render one request, or decline it so NPRPC serves static files.
    public func handle(_ request: PageRequest) -> PageResponse? {
        guard request.method == "GET" || request.method == "HEAD" else { return nil }
        let index = store.current
        // htmx navigation swaps #content, so it needs the page body alone. A
        // history restore wants the whole document back.
        let fragment = request.headers["hx-request"] == "true"
            && request.headers["hx-history-restore-request"] != "true"

        let parts = request.path.split(separator: "/").map {
            String($0).removingPercentEncoding ?? String($0)
        }
        // Every page names itself by the path it was asked for, without the
        // query: a search's `?q=` is the only query the site has, and search
        // pages are not indexed anyway.
        // One spelling per page: `/api/swift/` and `/api/swift` both answer,
        // and two canonical URLs for one page is what canonical is there to
        // prevent.
        var path = request.path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }

        switch parts.first {
        case nil:
            let view = HomeView(
                modules: moduleCards(index),
                articles: articles.all.map { ArticleCard(title: $0.title, summary: $0.summary,
                                                         url: "/article/" + $0.slug) },
                guides: guideNav(index))
            return page("home", view, title: Site.homeTitle, index: index, fragment: fragment,
                        path: path, meta: PageMeta(description: Site.homeDescription))

        // Served here rather than from the static root so their URLs come
        // from the same base as the canonical links.
        case "robots.txt" where parts.count == 1:
            return robots()
        case "sitemap.xml" where parts.count == 1:
            return sitemap(index)

        case "api":
            guard parts.count >= 2, let language = Language.named(parts[1]) else {
                return notFound(index: index, fragment: fragment)
            }
            if parts.count == 2 {
                let description = Site.languageSummaries[language.id]
                    ?? "API reference for \(Site.title(of: language)) in LavaUI."
                return page("lang", LangView(language: language, index: index),
                            title: "\(Site.title(of: language)) API", index: index, fragment: fragment,
                            path: path, meta: PageMeta(description: description))
            }
            let components = Array(parts.dropFirst(2))
            guard let p = index.page(lang: language.id, components: components) else {
                // A module (Swift) or namespace (IDL) with no declaration of
                // its own name lists what is in it.
                let view = LangView(language: language, index: index,
                                    namespace: components.joined(separator: language.separator))
                guard !view.namespaces.isEmpty else { return notFound(index: index, fragment: fragment) }
                let module = Site.modules.first { $0.name == view.title }?.summary
                let description = module.map { "\(view.title): \($0)" }
                    ?? "API reference for \(view.title): \(view.symbols) declarations."
                // "LavaUI · LavaUI" says nothing; "LavaUI module" says what the page is.
                let kind = language.id == "swift" && !view.title.contains(language.separator)
                    ? "module" : "API"
                return page("lang", view, title: "\(view.title) \(kind)", index: index,
                            fragment: fragment, path: path, meta: PageMeta(description: description))
            }
            let view = SymbolPageView(page: p, index: index)
            let name = p.components.joined(separator: language.separator)
            return page("symbol", view, title: "\(name) — \(Site.title(of: language))",
                        index: index, fragment: fragment, path: path, meta: symbolMeta(p, name: name, index: index))

        case "guide":
            guard parts.count == 2, let guide = index.guide(slug: parts[1]) else {
                return notFound(index: index, fragment: fragment)
            }
            let html = Site.linkOutside(guide.html, from: guide.file)
            return page("guide", GuideView(title: guide.title, html: html, file: guide.file,
                                           source: Site.repository + guide.file),
                        title: guide.title, index: index, fragment: fragment,
                        path: path, meta: PageMeta(description: Site.firstParagraph(guide.html)))

        case "article":
            guard parts.count == 2, let article = articles.article(slug: parts[1]) else {
                return notFound(index: index, fragment: fragment)
            }
            return page("article", ArticleView(html: article.html), title: article.title,
                        index: index, fragment: fragment, path: path,
                        meta: PageMeta(description: article.summary.flatMap { Site.plainText($0) }))

        case "search":
            let query = request.queryItems["q"] ?? ""
            // The header box asks for a short list to drop down; a submitted
            // search (or no JavaScript) gets a full results page.
            if request.headers["hx-target"] == "search-results" {
                let view = SearchView(query: query, index: index, limit: Self.dropdownResults)
                return render("partials/search_results", view)
            }
            let view = SearchView(query: query, index: index, limit: Self.pageResults)
            return page("search", view, title: "Search: \(query)", index: index,
                        fragment: fragment, path: path, meta: PageMeta(indexable: false),
                        query: query)

        default:
            // Assets (/style.css, /vendor/htmx.min.js) go to the static root.
            if parts.last?.contains(".") == true { return nil }
            return notFound(index: index, fragment: fragment)
        }
    }

    // MARK: - Rendering

    private func guideNav(_ index: DocsIndex) -> [NavItem] {
        // Where a newcomer starts, in reading order; the rest alphabetical.
        let rank = Dictionary(uniqueKeysWithValues: Site.guideOrder.enumerated().map { ($1, $0) })
        let ordered = index.guides.sorted {
            let a = rank[$0.slug] ?? Int.max, b = rank[$1.slug] ?? Int.max
            return a != b ? a < b : $0.title < $1.title
        }
        return ordered.map { NavItem(title: $0.title, url: "/guide/" + $0.slug) }
    }

    /// The API sidebar: the Swift modules an app imports, then every other
    /// language with anything in it.
    private func apiNav(_ index: DocsIndex) -> [NavItem] {
        moduleCards(index).map { NavItem(title: $0.title, url: $0.url) }
    }

    private func moduleCards(_ index: DocsIndex) -> [ModuleCard] {
        var cards: [ModuleCard] = []
        if let swift = Language.named("swift") {
            // A module is the first component; anything deeper is a stray
            // member npdoc could not place, listed on its module's page.
            let present = Set(index.topLevelPages(lang: swift.id).compactMap {
                $0.namespace.components(separatedBy: swift.separator).first
            })
            let modules = Site.modules.map(\.name).filter(present.contains)
                + present.subtracting(Site.modules.map(\.name)).sorted()
            for module in modules {
                let (symbols, documented) = Site.stats(index, lang: swift, namespace: module)
                cards.append(ModuleCard(
                    title: module, url: "/api/swift/" + module,
                    summary: Site.modules.first { $0.name == module }?.summary,
                    symbols: symbols, documented: documented))
            }
        }
        for lang in Language.all where lang.id != "swift" {
            let (symbols, documented) = index.stats(lang: lang.id)
            guard symbols > 0 else { continue }
            cards.append(ModuleCard(title: Site.title(of: lang), url: "/api/" + lang.id,
                                    summary: Site.languageSummaries[lang.id],
                                    symbols: symbols, documented: documented))
        }
        return cards
    }

    /// A declaration's page: its first summary for the snippet, and indexed
    /// only if something on it is documented. An undocumented page is a
    /// signature and nothing else, and hundreds of those are what makes a
    /// search engine think less of the whole site.
    private func symbolMeta(_ page: Page, name: String, index: DocsIndex) -> PageMeta {
        let symbols = page.symbolIds.compactMap { index.symbols[$0] }
        let summary = symbols.lazy.map(\.summary_html).first { !$0.isEmpty }
        return PageMeta(
            description: summary.flatMap { Site.plainText("\(name) — " + $0) },
            indexable: symbols.contains { !$0.doc.isEmpty })
    }

    private func robots() -> PageResponse {
        // /search is a page per query, all of them near-empty.
        let text = "User-agent: *\nDisallow: /search\n\nSitemap: \(baseURL)/sitemap.xml\n"
        return PageResponse(status: 200, headers: ["content-type": "text/plain; charset=utf-8"],
                            body: Array(text.utf8))
    }

    /// Every page worth indexing: home, guides, articles, the API overviews
    /// and each documented declaration. No `lastmod` — nothing here knows
    /// when a page's source last changed, and a wrong date is worse than none.
    private func sitemap(_ index: DocsIndex) -> PageResponse {
        var paths = ["/"]
        paths += guideNav(index).map(\.url)
        paths += articles.all.map { "/article/" + $0.slug }
        paths += moduleCards(index).map(\.url)
        paths += index.pages.values
            .filter { $0.symbolIds.contains { !(index.symbols[$0]?.doc.isEmpty ?? true) } }
            .map(index.pageURL)
            .sorted()
        var xml = #"<?xml version="1.0" encoding="UTF-8"?>"# + "\n"
            + #"<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">"# + "\n"
        for path in paths {
            xml += "  <url><loc>\(escape(baseURL + path))</loc></url>\n"
        }
        xml += "</urlset>\n"
        return PageResponse(status: 200, headers: ["content-type": "application/xml; charset=utf-8"],
                            body: Array(xml.utf8))
    }

    private func page(_ template: String, _ view: Any, title: String, index: DocsIndex,
                      fragment: Bool, path: String?, meta: PageMeta, query: String = "",
                      status: Int = 200) -> PageResponse {
        guard let content = library.render(view, withTemplate: template) else {
            return templateMissing(template)
        }
        let fullTitle = title == Site.homeTitle ? title : "\(title) · \(Site.name)"
        if fragment {
            // htmx takes the document title from a <title> in the swapped
            // content.
            return PageResponse(html: "<title>\(escape(fullTitle))</title>\n" + content, status: status)
        }
        let layout = LayoutView(
            title: fullTitle, content: content, meta: meta,
            canonical: path.map { baseURL + $0 }, image: baseURL + Site.previewImage,
            brand: Site.name, modules: apiNav(index),
            articles: articles.all.map { NavItem(title: $0.title, url: "/article/" + $0.slug) },
            guides: guideNav(index), query: query)
        guard let html = library.render(layout, withTemplate: "layout") else {
            return templateMissing("layout")
        }
        return PageResponse(html: html, status: status)
    }

    private func render(_ template: String, _ view: Any) -> PageResponse {
        guard let html = library.render(view, withTemplate: template) else {
            return templateMissing(template)
        }
        return PageResponse(html: html)
    }

    private func notFound(index: DocsIndex, fragment: Bool) -> PageResponse {
        page("not_found", NavItem(title: "", url: ""), title: "Not found", index: index,
             fragment: fragment, path: nil, meta: PageMeta(indexable: false), status: 404)
    }

    private func templateMissing(_ name: String) -> PageResponse {
        PageResponse(html: "<h1>500</h1><p>Template '\(escape(name))' is missing.</p>", status: 500)
    }

    private func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
