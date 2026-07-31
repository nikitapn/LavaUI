import Foundation
import LavaUI

#if canImport(CxxCanvas)

/// Runs TraceLoom, a pattern-driven log timeline product built with LavaUI.
@main
struct TraceLoomApp {
    static func main() {
        guard let editor = LavaApp.open(title: "TraceLoom · Log Timeline Studio") else {
            exit(1)
        }
        LavaApp.run(editor: editor) { TraceLoom() }
    }
}

#else

@main
struct TraceLoomApp {
    static func main() {
        FileHandle.standardError.write(
            Data("TraceLoom: LavaUI requires Linux + libcanvas (CxxCanvas).\n".utf8)
        )
        exit(1)
    }
}

#endif
