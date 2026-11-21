import Foundation
import LavaLSPCore
import LavaText
import LavaUI

/// The completion list as the session keeps it: everything the server
/// offered, and the part of it that still matches what has been typed.
struct CompletionSession {
    let documentID: Int
    /// Character offset where the word being completed starts.
    let anchor: Int
    let items: [CompletionItem]
    let isIncomplete: Bool
    let encoding: PositionEncoding
    /// Indices into `items`, best first.
    var shown: [Int]
    var selected = 0
}

/// Hover cards and completion: what a language server says about the code
/// under the pointer and at the caret.
extension EditorSession {
    // MARK: Hover

    /// The pointer came to rest on a character, or left the text.
    func pointerMoved(to offset: Int?) {
        hoverTarget = offset
        if let card = hoverCard, offset.map({ !card.anchor.contains($0) }) ?? true {
            hoverCard = nil
        }
        guard let offset, completion == nil, hoverCard == nil else { return }
        let owner = LanguageSessionRef(self)
        let document = active.id
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.5) {
            MainQueue.async {
                guard let session = owner.session, session.hoverTarget == offset,
                      session.active.id == document else { return }
                session.requestHover(at: offset)
            }
        }
    }

    private func requestHover(at offset: Int) {
        syncLanguageServers()
        guard let server = languageServers.ready(active.id) else { return }
        let text = active.text
        let positions = languageServers.positions(for: active.id, text: text, encoding: server.encoding)
        guard let position = positions.position(atCharacterOffset: offset) else { return }
        let owner = LanguageSessionRef(self)
        let document = active.id
        server.client.hover(uri: server.uri, at: position, timeout: 5) { result in
            MainQueue.async {
                guard let session = owner.session, session.active.id == document,
                      session.active.text == text, let target = session.hoverTarget,
                      case .success(let hover?) = result else { return }
                let lines = HoverPresentation.lines(hover)
                guard !lines.isEmpty else { return }
                // The server's range for the symbol, or the character itself.
                let anchor = hover.range.flatMap { positions.characterRange(for: $0) }
                    .flatMap { $0.isEmpty ? nil : $0 } ?? offset..<(offset + 1)
                // The pointer has moved on while the server thought.
                guard anchor.contains(target) else { return }
                session.hoverCard = EditorHoverCard(
                    anchor: anchor, lines: lines.map { EditorCardLine($0.text, isCode: $0.isCode) }
                )
            }
        }
    }

    // MARK: Completion

    /// The list as the editor draws it.
    func completionList() -> EditorCompletionList? {
        guard let completion, completion.documentID == active.id, !completion.shown.isEmpty else { return nil }
        let items = completion.shown.map { index in
            let item = completion.items[index]
            return EditorCompletionItem(
                label: item.label, detail: item.detail,
                kind: CompletionRanking.glyph(forKind: item.kind)
            )
        }
        return EditorCompletionList(anchor: completion.anchor, items: items, selected: completion.selected)
    }

    /// After every edit made through the editor. Narrows an open list, or
    /// opens one when what was just typed is the start or the middle of a
    /// name, or a member access.
    func textEdited(typedOne: Bool) {
        hoverCard = nil
        guard let prefix = controller.linePrefix(maxCharacters: 120),
              let caret = controller.caretOffset() else {
            completion = nil
            return
        }
        let word = String(prefix.reversed().prefix { TextEditingState.isWordCharacter($0) }.reversed())
        if var open = completion, open.documentID == active.id {
            guard caret - word.count == open.anchor else {
                completion = nil
                if typedOne, Self.triggers(prefix) { scheduleCompletion() }
                return
            }
            if open.isIncomplete {
                scheduleCompletion()
                return
            }
            open.shown = CompletionRanking.rank(open.items, prefix: word)
            open.selected = 0
            completion = open.shown.isEmpty ? nil : open
            return
        }
        if typedOne, Self.triggers(prefix) { scheduleCompletion() }
    }

    /// A name being typed, or the character after which a member comes.
    private static func triggers(_ prefix: String) -> Bool {
        guard let last = prefix.last else { return false }
        if TextEditingState.isWordCharacter(last) { return true }
        return last == "." || prefix.hasSuffix("->") || prefix.hasSuffix("::")
    }

    /// Ctrl+Space, or a trigger: asks once the typing pauses.
    func scheduleCompletion(immediately: Bool = false) {
        completionGeneration &+= 1
        let generation = completionGeneration
        let owner = LanguageSessionRef(self)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + (immediately ? 0 : 0.12)) {
            MainQueue.async {
                guard let session = owner.session, session.completionGeneration == generation else { return }
                session.requestCompletion(generation: generation)
            }
        }
    }

    private func requestCompletion(generation: Int) {
        syncLanguageServers()
        guard let server = languageServers.ready(active.id),
              let caret = controller.caretOffset(),
              let prefix = controller.linePrefix(maxCharacters: 120) else { return }
        let positions = languageServers.positions(for: active.id, text: active.text, encoding: server.encoding)
        guard let position = positions.position(atCharacterOffset: caret) else { return }
        let word = prefix.reversed().prefix { TextEditingState.isWordCharacter($0) }.count
        let anchor = caret - word
        let owner = LanguageSessionRef(self)
        let document = active.id
        let encoding = server.encoding
        server.client.completion(uri: server.uri, at: position, timeout: 5) { result in
            MainQueue.async {
                guard let session = owner.session, session.completionGeneration == generation,
                      session.active.id == document, case .success(let list) = result,
                      let caretNow = session.controller.caretOffset(),
                      let prefixNow = session.controller.linePrefix(maxCharacters: 120) else { return }
                // Typed past the word, or moved away, while the server worked.
                let typed = String(prefixNow.reversed().prefix { TextEditingState.isWordCharacter($0) }.reversed())
                guard caretNow - typed.count == anchor else { return }
                let shown = CompletionRanking.rank(list.items, prefix: typed)
                session.completion = shown.isEmpty ? nil : CompletionSession(
                    documentID: document, anchor: anchor, items: list.items,
                    isIncomplete: list.isIncomplete, encoding: encoding, shown: shown
                )
            }
        }
    }

    /// Keys the list takes while it is up; anything else closes the hover card
    /// and goes on to the editor.
    func editorKey(_ event: KeyEvent) -> Bool {
        hoverCard = nil
        if event.key == KeyCode.space, event.control {
            scheduleCompletion(immediately: true)
            return true
        }
        guard var open = completion, open.documentID == active.id, !open.shown.isEmpty else { return false }
        let count = open.shown.count
        switch event.key {
        case KeyCode.down: open.selected = (open.selected + 1) % count
        case KeyCode.up: open.selected = (open.selected + count - 1) % count
        case KeyCode.pageDown: open.selected = min(count - 1, open.selected + EditorCompletionList.visibleRows)
        case KeyCode.pageUp: open.selected = max(0, open.selected - EditorCompletionList.visibleRows)
        case KeyCode.enter, KeyCode.tab:
            acceptCompletion(open.selected)
            return true
        case KeyCode.escape:
            completion = nil
            return true
        case KeyCode.left, KeyCode.right, KeyCode.home, KeyCode.end:
            completion = nil
            return false
        default:
            return false
        }
        completion = open
        return true
    }

    /// A row was clicked (an index into what is shown), or the editor was
    /// clicked somewhere else (nil).
    func completionPicked(_ row: Int?) {
        guard let row else {
            completion = nil
            return
        }
        acceptCompletion(row)
    }

    private func acceptCompletion(_ row: Int) {
        guard let open = completion, open.shown.indices.contains(row),
              let caret = controller.caretOffset() else { return }
        completion = nil
        let item = open.items[open.shown[row]]
        var start = open.anchor
        var text = item.insertText ?? item.label
        if let edit = item.textEdit {
            // The server's range is for the text it was asked about; its end
            // is wherever the caret has got to since.
            let positions = languageServers.positions(for: active.id, text: active.text, encoding: open.encoding)
            if let range = positions.characterRange(for: edit.insert), range.lowerBound <= caret {
                start = range.lowerBound
            }
            text = edit.newText
        }
        var caretAt: Int?
        if item.isSnippet {
            let expanded = SnippetText.expand(text)
            text = expanded.text
            caretAt = expanded.caret
        }
        insertingCompletion = true
        controller.insert(text, replacing: start..<max(start, caret), caretAt: caretAt)
        insertingCompletion = false
    }
}
