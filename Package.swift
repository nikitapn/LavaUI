// swift-tools-version: 6.0

import PackageDescription

// Post-SwiftCrossUI: C++ interop (CxxCanvas) + FBDModel. No Gtk.
let package = Package(
    name: "HelloWorld",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "HelloWorld", targets: ["HelloWorld"]),
        // Throwaway Phase 0 spikes (docs/declarative-ui-plan.md) — delete after Phase 1.
        .executable(name: "Phase0Spikes", targets: ["Phase0Spikes"]),
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
                .product(
                    name: "CYoga",
                    package: "canvas_swift",
                    condition: .when(platforms: [.linux])
                ),
            ],
            swiftSettings: [
                .interoperabilityMode(.Cxx),
                // Must match CxxCanvas's own -std=c++23 (canvas_engine.hpp
                // uses std::expected/VoidResult) or ClangImporter parses it
                // under an older default C++ standard and chokes on
                // std::unexpected.
                .unsafeFlags(["-Xcc", "-std=c++23"]),
            ]
        ),
        // Phase 0 prep: parameter packs, Yoga measure, Font::measure.
        .executableTarget(
            name: "Phase0Spikes",
            dependencies: [
                .product(
                    name: "CxxCanvas",
                    package: "canvas_swift",
                    condition: .when(platforms: [.linux])
                ),
                .product(
                    name: "CYoga",
                    package: "canvas_swift",
                    condition: .when(platforms: [.linux])
                ),
            ],
            swiftSettings: [
                .interoperabilityMode(.Cxx),
                .unsafeFlags(["-Xcc", "-std=c++23"]),
                // C++ interop modules sometimes force script mode; keep @main.
                .unsafeFlags(["-parse-as-library"]),
            ]
        ),
        .target(name: "FBDModel"),
        .testTarget(
            name: "FBDModelTests",
            dependencies: ["FBDModel"]
        ),
    ]
)
