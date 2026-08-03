// swift-tools-version: 6.0

import PackageDescription

// Post-SwiftCrossUI: C++ interop (CxxCanvas) + FBDModel. No Gtk.
// LavaUI = declarative View DSL + Yoga + draw list + engine bridge.
// Canvas engine is built by SwiftPM via the `canvas` package (CxxCanvas).
let package = Package(
    name: "HelloWorld",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "HelloWorld", targets: ["HelloWorld"]),
        .executable(name: "TraceLoom", targets: ["TraceLoomApp"]),
        .executable(name: "Spotify", targets: ["SpotifyApp"]),
        .executable(name: "LavaBench", targets: ["LavaBench"]),
        .executable(name: "TwoWindows", targets: ["TwoWindows"]),
        .library(name: "LavaUI", targets: ["LavaUI"]),
        .library(name: "LavaText", targets: ["LavaText"]),
        .library(name: "LavaMenu", targets: ["LavaMenu"]),
        .library(name: "TraceLoomCore", targets: ["TraceLoomCore"]),
        .library(name: "SpotifyCore", targets: ["SpotifyCore"]),
        .library(name: "FBDModel", targets: ["FBDModel"]),
    ],
    dependencies: [
        .package(path: "canvas"),
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
        // Two windows, one process, one GPU. The smallest program that proves
        // the device/window split: both surfaces render from one loop and
        // share the font atlas and texture cache.
        .executableTarget(
            name: "TwoWindows",
            dependencies: ["LavaUI"],
            swiftSettings: [
                .interoperabilityMode(.Cxx),
            ]
        ),

        // Throwaway modifier spike; delete once the design is chosen. We keep for now. 01/08/2026
        .executableTarget(
            name: "ModifierSpike",
            dependencies: ["LavaUI"],
            swiftSettings: [
                .interoperabilityMode(.Cxx),
            ]
        ),

        .target(
            name: "LavaUI",
            dependencies: [
                "LavaText",
                "LavaMenu",
                .product(
                    name: "CxxCanvas",
                    package: "canvas",
                    condition: .when(platforms: [.linux])
                ),
                .product(
                    name: "CYoga",
                    package: "canvas",
                    condition: .when(platforms: [.linux])
                ),
                .product(
                    name: "CanvasResources",
                    package: "canvas",
                    condition: .when(platforms: [.linux])
                ),
            ],
            resources: [
                // Default UI + symbol fonts. App images live on app targets.
                .copy("Resources/fonts"),
            ],
            swiftSettings: [
                // C++ interop with CxxCanvas. Package cxxLanguageStandard
                // (.gnucxx23) must match canvas headers (std::expected).
                // No unsafeFlags — those block LavaUI as a GitHub dependency.
                .interoperabilityMode(.Cxx),
            ]
        ),
        .executableTarget(
            name: "HelloWorld",
            dependencies: [
                "LavaUI",
                "FBDModel",
            ],
            resources: [
                // Demo brand art (not framework assets).
                .process("Resources"),
            ],
            swiftSettings: [
                // App only needs interop if LavaUI's public API re-exports C++
                // types into app code. Keep C++ mode so #if canImport(CxxCanvas)
                // paths in HelloWorld still see the module on Linux.
                .interoperabilityMode(.Cxx),
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
            ]
        ),
        .target(name: "FBDModel"),
        // Performance suite. Not a test target: it opens a window (text
        // measurement needs the engine) and it must run `-c release` to mean
        // anything, neither of which belongs in `swift test`.
        // See docs/performance.md.
        .executableTarget(
            name: "LavaBench",
            dependencies: [
                "LavaUI",
                "LavaText",
                "TraceLoomCore",
            ],
            swiftSettings: [
                .interoperabilityMode(.Cxx),
            ]
        ),
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
        // The one exception to the headless rule above. Multi-window routing
        // — which window an invalidation, a focus change or a visibility set
        // belongs to — is pure Swift, but it *is* `ViewInvalidation` and
        // `FocusManager`, so it cannot be lifted into a window-free target
        // without dragging the framework with it. Linking LavaUI links the
        // engine; these tests must never open a window, load a font or touch
        // an `Editor`, and there is nothing here that would.
        .testTarget(
            name: "LavaUITests",
            dependencies: ["LavaUI"],
            swiftSettings: [.interoperabilityMode(.Cxx)]
        ),
    ],
    // Same C++23 as canvas_swift so interop headers parse consistently.
    // C++23 draft name still used by PackageDescription on this toolchain.
    cxxLanguageStandard: .gnucxx2b
)

