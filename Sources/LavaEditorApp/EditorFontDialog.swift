import LavaUI
import Observation

@Observable
final class EditorFontDialog {
    var chooser: FontChooser?

    func present(for session: EditorSession) {
        let preferences = session.settingsFiles.effective.editor
        let choice = FontChoice(family: preferences.fontFamily, size: Int(preferences.fontSize.rounded()))
        chooser = FontChooser(selection: choice, showsStyle: false, onSelect: { [weak self, weak session] choice in
            self?.chooser = nil
            session?.setEditorFont(choice)
        }, onCancel: { [weak self] in
            self?.chooser = nil
        })
    }
}
