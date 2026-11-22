import Foundation
import LavaAgentCore
import LavaTerminal
import LavaUI

/// Getting a message into a Claude Code session that is running, without a
/// second writer on it. Shared by the chat tab and the inline box.
///
/// A running session listens on exactly one input, its terminal, so that is
/// where the message is typed:
/// - in one of the editor's own terminal tabs: there (`terminal(running:)`);
/// - in the background: a tab the editor opens with `claude attach`, kept
///   for that session and typed into again next time;
/// - in some other terminal: nowhere — that terminal is not ours.
extension EditorSession {
    func deliver(_ text: String, toRunning live: ClaudeLiveSession, in directory: URL,
                 done: @escaping (String?) -> Void) {
        if let tab = terminal(running: live.pid) {
            Self.type(text, into: tab)
            done(nil)
            return
        }
        guard live.isBackground else {
            done("This session is running in a terminal outside LavaEditor (pid \(live.pid)), and only that terminal can talk to it.")
            return
        }
        if let tab = attachedTerminals[live.session], terminal.tabs.contains(where: { $0 === tab }), !tab.exited {
            Self.type(text, into: tab)
            done(nil)
            return
        }
        let tab = newTerminal(in: directory, typing: "claude attach \(live.attachName)")
        attachedTerminals[live.session] = tab
        Self.whenAttached(tab, deadline: Date().addingTimeInterval(15)) { ready in
            guard ready else {
                done("`claude attach \(live.attachName)` did not come up in the terminal panel.")
                return
            }
            Self.type(text, into: tab)
            done(nil)
        }
    }

    /// The session's TUI is up once it names itself in the terminal's title
    /// — before that, typing lands in the shell or in nothing.
    private static func whenAttached(_ tab: TerminalSession, deadline: Date, then: @escaping (Bool) -> Void) {
        AttachWait(tab: tab, deadline: deadline, then: then).check()
    }

    /// A bracketed paste, so a message of several lines arrives as one
    /// instead of being sent at its first newline, then Enter.
    static func type(_ text: String, into tab: TerminalSession) {
        tab.write("\u{1b}[200~" + text + "\u{1b}[201~")
        tab.write("\r")
    }

    /// The session a `claude --bg` command says it is running: the short id
    /// in its `backgrounded · <id>` line.
    static func backgroundedID(in output: String) -> String? {
        output.split(whereSeparator: \.isNewline)
            .first { $0.contains("backgrounded") }
            .flatMap { $0.split(separator: " ").last.map(String.init) }
    }

    /// Where a `--bg --resume` of `session` actually went. Claude Code
    /// continues a session under its own id only when nothing holds it; a
    /// background session that was stopped still counts as held (`claude
    /// attach` can reopen it), and then it starts a *copy* — the whole
    /// conversation under a new id, in a new file beside the old one, with
    /// the reply in it. Nil when it continued in place. Waits a few seconds
    /// for the file, which the background service writes after the command
    /// has returned. Blocking; call it off the main queue.
    static func continuation(of session: AgentSession, output: String) -> AgentSession? {
        guard let short = backgroundedID(in: output), !session.id.hasPrefix(short),
              let folder = session.file?.deletingLastPathComponent() else { return nil }
        for _ in 0..<40 {
            if let name = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?
                .first(where: { $0.hasPrefix(short) && $0.hasSuffix(".jsonl") }) {
                return AgentSession(agent: .claude, id: String(name.dropLast(6)), title: session.title,
                                    date: Date(), directory: session.directory, bytes: 0,
                                    file: folder.appendingPathComponent(name))
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return nil
    }

    /// The arguments that run one more turn of a session nothing is running,
    /// in Claude Code's background service rather than as a child of the
    /// editor: the turn outlives the editor, `claude agents` lists it while
    /// it works, and `claude attach` can watch it.
    static func backgroundResume(_ id: String, message: String) -> [String] {
        var arguments = ["--bg", "--resume", id, "--permission-mode", "auto"]
        if let model = ProcessInfo.processInfo.environment["LAVAEDITOR_CLAUDE_MODEL"], !model.isEmpty {
            arguments += ["--model", model]
        }
        return arguments + [message]
    }
}

/// Looks at a terminal's title a few times a second until the attached
/// session shows, or the deadline passes. Only touched on the main queue.
private final class AttachWait: @unchecked Sendable {
    weak var tab: TerminalSession?
    let deadline: Date
    let then: (Bool) -> Void

    init(tab: TerminalSession, deadline: Date, then: @escaping (Bool) -> Void) {
        self.tab = tab
        self.deadline = deadline
        self.then = then
    }

    func check() {
        guard let tab, !tab.exited else { then(false); return }
        if tab.title.localizedCaseInsensitiveContains("claude") {
            // A moment more for its input to take keys.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.6) { MainQueue.async { self.then(true) } }
            return
        }
        guard Date() < deadline else { then(false); return }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) { MainQueue.async { self.check() } }
    }
}
