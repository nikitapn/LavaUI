// swift-tools-version: 5.10

import PackageDescription

var dependencies: [Package.Dependency] = [
    .package(
        url: "https://github.com/moreSwift/swift-cross-ui",
        .upToNextMinor(from: "0.7.0")
    ),
    .package(
        url: "https://github.com/stackotter/swift-image-formats",
        .upToNextMinor(from: "0.5.0")
    ),
    .package(path: "canvas/canvas_swift"),
]
var targetDependencies: [Target.Dependency] = [
    .product(name: "SwiftCrossUI", package: "swift-cross-ui"),
    .product(name: "DefaultBackend", package: "swift-cross-ui"),
    .product(name: "ImageFormats", package: "swift-image-formats"),
    .product(
        name: "Gtk",
        package: "swift-cross-ui",
        condition: .when(platforms: [.linux])
    ),
    .product(
        name: "GtkBackend",
        package: "swift-cross-ui",
        condition: .when(platforms: [.linux])
    ),
    .product(
        name: "CanvasKit",
        package: "canvas_swift",
        condition: .when(platforms: [.linux])
    ),
]

// The Swift Bundler runtime (used for hot reloading) requires Swift >=6.0.
#if compiler(>=6.0)
    dependencies.append(
        .package(
            url: "https://github.com/moreSwift/swift-bundler",
            revision: "496c0638dc2c6750c7873832a08c36c74631aed4"
        )
    )
    targetDependencies.append(
        .product(
            name: "SwiftBundlerRuntime",
            package: "swift-bundler",
            condition: .when(platforms: [.macOS, .linux])
        )
    )
#endif

let package = Package(
    name: "HelloWorld",
    platforms: [.macOS(.v10_15), .iOS(.v13), .tvOS(.v13), .macCatalyst(.v13)],
    dependencies: dependencies,
    targets: [
        .executableTarget(
            name: "HelloWorld",
            dependencies: targetDependencies
        ),
        // The FBD graph model (blocks/slots/wires) — pure Swift, no
        // dependency on SwiftCrossUI/CanvasKit/anything else, so it's
        // testable and reusable on its own.
        .target(
            name: "FBDModel"
        ),
        .testTarget(
            name: "FBDModelTests",
            dependencies: ["FBDModel"]
        ),
    ]
)
