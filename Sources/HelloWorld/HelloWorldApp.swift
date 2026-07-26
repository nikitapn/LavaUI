import SwiftCrossUI
import DefaultBackend
import Foundation

#if canImport(SwiftBundlerRuntime)
    import SwiftBundlerRuntime
#endif

struct FileNode: Identifiable {
    let id = UUID()
    var name: String
    var children: [FileNode]?
}

let sampleFileTree: [FileNode] = [
    FileNode(
        name: "Documents",
        children: [
            FileNode(name: "Resume.pdf", children: nil),
            FileNode(
                name: "Projects",
                children: [
                    FileNode(
                        name: "HelloWorld",
                        children: [
                            FileNode(name: "HelloWorldApp.swift", children: nil),
                            FileNode(name: "TreeView.swift", children: nil),
                        ]
                    ),
                    FileNode(name: "Notes.txt", children: nil),
                ]
            ),
        ]
    ),
    FileNode(
        name: "Photos",
        children: [
            FileNode(name: "Vacation", children: []),
            FileNode(name: "Family.png", children: nil),
        ]
    ),
]

@main
@HotReloadable
struct YourApp: App {
    @State var count = 0

    var body: some Scene {
        WindowGroup("YourApp") {
            #hotReloadable {
                VStack {
                    HStack {
                        Button("-") { count -= 1 }
                        Text("Count: \(count)")
                        Button("+") { count += 1 }
                    }.padding()

                    Divider()

                    ScrollView {
                        TreeView(sampleFileTree, children: \.children) { node in
                            Text(node.name)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(width: 320, height: 300)
                    .padding()
                }
            }
        }
        .defaultSize(width: 400, height: 450)
    }
}