// lavactl — the compositor, from a shell script.
//
// Everything the desktop does to a window it does over the control plane, and
// until now every caller of that was a GUI client. A link handler is not: it
// runs, asks one question, acts on the answer and exits, and it has to do all
// of that before the browser it is about to launch would have finished
// starting anyway.
//
// Deliberately thin. It owns no policy beyond `focus-app`, which exists
// because the alternative was three round trips from `sh` and a race in
// between; everything else is one RPC with its arguments parsed.

#if canImport(LavaIDL)
import Foundation
import LavaClient
import LavaIDL

let usage = """
usage: lavactl <command>

  windows                  every window: id, workspace, focused, app id, title
  workspace                the workspace on screen right now
  activate <id>            restore, raise and focus a window by surface id
  keyboard                 the keyboard config the compositor is serving
  focus-app <app-id>       activate this application's window on the current
                           workspace; prints its id, exits 1 if it has none

Exit codes: 0 done, 1 nothing matched, 2 bad usage, 3 no compositor.
"""

func die(_ message: String, _ code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { die(usage, 2) }

guard LavaClient.connectControlPlane() else {
    // `connectControlPlane` has already said which sessions are running, which
    // is the useful half of the answer when there is more than one.
    die("lavactl: no compositor on this session", 3)
}

/// The window list, or an exit — every command here needs it or needs nothing.
func snapshot() -> (workspace: UInt32, windows: [WindowInfo]) {
    guard let list = LavaClient.currentWindowList() else {
        die("lavactl: the compositor did not answer with a window list", 3)
    }
    return (list.0, list.1)
}

switch command {
case "windows":
    let (_, windows) = snapshot()
    for w in windows {
        // Tab-separated and id-first, because the consumer is `cut` or `awk`.
        print("\(w.surfaceId)\t\(w.workspace)\t\(w.focused ? "focused" : "-")"
            + "\t\(w.minimized ? "minimized" : "-")\t\(w.appId)\t\(w.title)")
    }

case "workspace":
    print(snapshot().workspace)

case "keyboard":
    // What the compositor believes, which is not always what lava.conf says:
    // the file is parsed once at startup, so a disagreement between the two
    // localises a bug to the load path rather than the settings app.
    do {
        let k = try DesktopSettings.keyboard()
        print("layout\t\(k.layout)")
        print("variant\t\(k.variant)")
        print("options\t\(k.options)")
        print("model\t\(k.model)")
        print("rules\t\(k.rules)")
        print("repeat-rate\t\(k.repeatRate)")
        print("repeat-delay\t\(k.repeatDelay)")
        print("mod-key\t\(k.modKey)")
    } catch {
        die("lavactl: GetKeyboard failed: \(error)", 3)
    }

case "activate":
    guard args.count == 2, let id = UInt32(args[1]) else {
        die("usage: lavactl activate <surface-id>", 2)
    }
    LavaClient.activateWindow(id)

case "focus-app":
    guard args.count == 2 else { die("usage: lavactl focus-app <app-id>", 2) }
    let appId = args[1]
    let (workspace, windows) = snapshot()
    let here = windows.filter { $0.appId == appId && $0.workspace == workspace }
    // Focused, then any window still on screen, then a minimized one — in the
    // compositor's own order, which is front to back, so with two of them the
    // one last used wins. Minimized still counts: `ActivateWindow` restores,
    // and a browser minimized on this workspace is one that is running here.
    guard let target = here.first(where: \.focused)
        ?? here.first(where: { !$0.minimized })
        ?? here.first
    else {
        exit(1)
    }
    LavaClient.activateWindow(target.surfaceId)
    print(target.surfaceId)

case "-h", "--help", "help":
    print(usage)

default:
    die(usage, 2)
}

#else

import Foundation
FileHandle.standardError.write(
    Data("lavactl: built without NPRPC; there is no control plane to talk to\n".utf8)
)
exit(3)

#endif
