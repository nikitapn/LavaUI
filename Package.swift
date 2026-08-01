// swift-tools-version: 6.0

import PackageDescription

// Post-SwiftCrossUI: C++ interop (CxxCanvas) + FBDModel. No Gtk.
// LavaUI = declarative View DSL + Yoga + draw list + engine bridge.
let package = Package(
    name: "HelloWorld",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "HelloWorld", targets: ["HelloWorld"]),
        .executable(name: "TraceLoom", targets: ["TraceLoomApp"]),
        .executable(name: "Spotify", targets: ["SpotifyApp"]),
        .library(name: "LavaUI", targets: ["LavaUI"]),
        .library(name: "LavaText", targets: ["LavaText"]),
        .library(name: "LavaMenu", targets: ["LavaMenu"]),
        .library(name: "TraceLoomCore", targets: ["TraceLoomCore"]),
        .library(name: "SpotifyCore", targets: ["SpotifyCore"]),
        .library(name: "FBDModel", targets: ["FBDModel"]),
    ],
    dependencies: [
        .package(path: "canvas/canvas_swift"),
    ],
    targets: [
        // Declarative UI library (View DSL, Yoga layout, fonts, draw list, Editor).
        // Pure text-editing logic: no C++ interop, no Vulkan, no Foundation
        // beyond String. Kept a separate target so "testable headlessly" is
        // enforced by the build graph rather than by discipline.
        .target(name: "LavaText"),
        // Application menu IR + DSL. No Yoga, no Vulkan, no C++ — same
        // headless-test rule as LavaText (see docs/native-menus.md).
        .target(name: "LavaMenu"),
        .target(name: "TraceLoomCore"),
        // Spotify Web API + cover download. No LavaUI — same headless rule as
        // TraceLoomCore so catalog/auth can be tested without a window.
        .target(name: "SpotifyCore"),
        // Throwaway modifier spike; delete once the design is chosen. We keep for now. 01/08/2026
        .executableTarget(
            name: "ModifierSpike",
            dependencies: ["LavaUI"],
            swiftSettings: [
                .interoperabilityMode(.Cxx),
                .unsafeFlags(["-Xcc", "-std=c++23"]),
            ]
        ),

        .target(
            name: "LavaUI",
            dependencies: [
                "LavaText",
                "LavaMenu",
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
        .executableTarget(
            name: "HelloWorld",
            dependencies: [
                "LavaUI",
                "FBDModel",
            ],
            swiftSettings: [
                // App only needs interop if LavaUI's public API re-exports C++
                // types into app code. Keep C++ mode so #if canImport(CxxCanvas)
                // paths in HelloWorld still see the module on Linux.
                .interoperabilityMode(.Cxx),
                .unsafeFlags(["-Xcc", "-std=c++23"]),
            ]
        ),
        .executableTarget(
            name: "TraceLoomApp",
            dependencies: [
                "LavaUI",
                "TraceLoomCore",
            ],
            swiftSettings: [
                .interoperabilityMode(.Cxx),
                .unsafeFlags(["-Xcc", "-std=c++23"]),
            ]
        ),
        .executableTarget(
            name: "SpotifyApp",
            dependencies: [
                "LavaUI",
                "SpotifyCore",
            ],
            swiftSettings: [
                .interoperabilityMode(.Cxx),
                .unsafeFlags(["-Xcc", "-std=c++23"]),
            ]
        ),
        .target(name: "FBDModel"),
        .testTarget(
            name: "LavaTextTests",
            dependencies: ["LavaText"]
        ),
        .testTarget(
            name: "LavaMenuTests",
            dependencies: ["LavaMenu"]
        ),
        .testTarget(
            name: "FBDModelTests",
            dependencies: ["FBDModel"]
        ),
        .testTarget(
            name: "TraceLoomCoreTests",
            dependencies: ["TraceLoomCore"]
        ),
    ]
)
