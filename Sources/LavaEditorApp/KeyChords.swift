import LavaProjectCore
import LavaUI

enum EditorChordAction: Equatable {
    case findFile(FindFileMode)
    case toggleInlineBlame
}

typealias AppKeyChord = EditorKeyChord<EditorChordAction>

func makeFindFileChord() -> AppKeyChord {
    AppKeyChord(
        prefix: .init(KeyCode.x, modifiers: KeyMods.control),
        bindings: [
            .init(KeyCode.f, modifiers: KeyMods.control): .findFile(.directory),
            .init(KeyCode.f): .findFile(.project),
            .init(KeyCode.b): .toggleInlineBlame,
        ],
        cancelKeys: [.init(KeyCode.escape), .init(KeyCode.g, modifiers: KeyMods.control)]
    )
}

extension EditorSession {
    func handleKeyChord(_ event: InputEvent) -> Bool {
        guard !FocusManager.takesKeysBeforeShortcuts else {
            findFile.resetChord()
            return false
        }
        guard event.x > 0 else { return false }
        let key = event.button
        let modifierMask = KeyMods.control | KeyMods.shift | KeyMods.alt | KeyMods.superKey
        let stroke = AppKeyChord.Stroke(key, modifiers: Int32(event.y) & modifierMask)
        let result = findFile.chord.press(
            stroke, prefixAvailable: !FocusManager.hasTextSelection,
            isRepeat: event.x > 1, isModifier: (KeyCode.leftShift...KeyCode.rightSuper).contains(key)
        )
        if findFile.chordPending != findFile.chord.isPending {
            findFile.chordPending = findFile.chord.isPending
        }
        switch result {
        case .pass:
            return false
        case .prefix, .cancel:
            break
        case .undefined(let stroke):
            let name = KeyShortcut(stroke.key, []).label.lowercased()
            let mods = [(KeyMods.control, "C-"), (KeyMods.alt, "M-"),
                        (KeyMods.shift, "S-"), (KeyMods.superKey, "Super-")]
            let label = mods.filter { stroke.modifiers & $0.0 != 0 }.map { $0.1 }.joined() + name
            notice = "C-x \(label) is undefined"
        case .action(.findFile(let mode)):
            showFindFile(mode)
        case .action(.toggleInlineBlame):
            toggleInlineBlame()
        }
        LavaApp.suppressRawKeyText()
        return true
    }
}
