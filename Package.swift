// swift-tools-version: 6.0

import PackageDescription

// Post-SwiftCrossUI: C++ interop (CxxCanvas) + FBDModel. No Gtk.
let package = Package(
    name: "HelloWorld",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "HelloWorld", targets: ["HelloWorld"]),
        .library(name: "FBDModel", targets: ["FBDModel"]),
    ],
    dependencies: [
        .package(path: "canvas/canvas_swift"),
    ],
    targets: [
        .executableTarget(
            name: "HelloWorld",
            dependencies: [
                "FBDModel",
                .product(
                    name: "CxxCanvas",
                    package: "canvas_swift",
                    condition: .when(platforms: [.linux])
                ),
            ],
            swiftSettings: [
                .interoperabilityMode(.Cxx),
            ]
        ),
        .target(name: "FBDModel"),
        .testTarget(
            name: "FBDModelTests",
            dependencies: ["FBDModel"]
        ),
    ]
)
