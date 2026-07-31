import Foundation
import LavaUI

#if canImport(CxxCanvas)

/// Runs the LavaUI widget playground (`DemoExample`).
@main
struct HelloWorldApp {
    static func main() {
        guard let editor = LavaApp.open(title: "LavaUI · DemoExample") else {
            exit(1)
        }

        let brandImage = ImageStore.loadAsset(
            named: "football-157930.svg_64.png",
            assetsRoot: LavaApp.resolveAssetsRoot(),
            into: editor
        )
        if brandImage == nil {
            FileHandle.standardError.write(Data("warning: brand image failed to load\n".utf8))
        }

        LavaApp.run(editor: editor) {
            DemoExample(brandImage: brandImage)
        }
    }
}

#else

@main
struct HelloWorldApp {
    static func main() {
        FileHandle.standardError.write(
            Data("HelloWorld: LavaUI requires Linux + libcanvas (CxxCanvas).\n".utf8)
        )
        exit(1)
    }
}

#endif
