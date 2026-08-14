import Foundation
import LavaUI
#if LAVA_HAS_CLIENT
import LavaClient
#endif

/// Selects the process that hosts a LavaUI app from the runtime environment.
///
/// This stays above LavaUI so the framework does not acquire NPRPC or a
/// compositor dependency merely to support application entry points.
public enum LavaHost {
    public static var isClient: Bool {
        ProcessInfo.processInfo.environment["LAVA_CLIENT"] == "1"
    }

    /// Opens through the compositor when `LAVA_CLIENT=1`; otherwise opens a
    /// local window. Client-side chrome is the default, while
    /// `LAVA_FRAME=server` requests compositor chrome.
    public static func open(
        title: String,
        assetsRoot: String? = nil,
        width: Float = 1280,
        height: Float = 800
    ) -> Editor? {
        guard isClient else {
            return LavaApp.open(
                title: title, assetsRoot: assetsRoot,
                width: width, height: height
            )
        }

        #if LAVA_HAS_CLIENT
        let serverFrame =
            ProcessInfo.processInfo.environment["LAVA_FRAME"] == "server"
        return LavaClient.open(
            title: title, width: width, height: height,
            frame: serverFrame ? .server : .client
        )
        #else
        FileHandle.standardError.write(
            Data("LAVA_CLIENT=1 requires the LavaClient product\n".utf8)
        )
        return nil
        #endif
    }

    /// Runs the editor through the same host selected by `open`.
    public static func run<V: View>(
        editor: Editor,
        menu: (() -> MenuBar)? = nil,
        onRawKey: ((InputEvent) -> Bool)? = nil,
        makeRoot: @escaping () -> V
    ) {
        #if LAVA_HAS_CLIENT
        if isClient {
            LavaClient.run(
                editor: editor, menu: menu,
                onRawKey: onRawKey, makeRoot: makeRoot
            )
        }
        #endif

        LavaApp.run(
            editor: editor, menu: menu,
            onRawKey: onRawKey, makeRoot: makeRoot
        )
    }

    /// States the smallest size at which the app's layout remains usable.
    /// Applies through GLFW locally or through the compositor in client mode.
    public static func setMinimumSize(
        editor: Editor, width: Float, height: Float
    ) {
        #if LAVA_HAS_CLIENT
        if isClient {
            LavaClient.setMinimumSize(width: width, height: height)
            return
        }
        #endif

        editor.setMinimumSize(width: width, height: height)
    }
}
