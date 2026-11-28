import LavaProjectCore
import LavaUI

typealias FindFileChord = EditorKeyChord<FindFileMode>

func makeFindFileChord() -> FindFileChord {
    FindFileChord(
        prefix: .init(KeyCode.x, modifiers: KeyMods.control),
        bindings: [
            .init(KeyCode.f, modifiers: KeyMods.control): .directory,
            .init(KeyCode.f): .project,
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
        let stroke = FindFileChord.Stroke(key, modifiers: Int32(event.y) & modifierMask)
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
        case .action(let mode):
            showFindFile(mode)
        }
        LavaApp.suppressRawKeyText()
        return true
    }
}
