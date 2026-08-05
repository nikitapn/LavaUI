// swift-tools-version: 6.0

import Foundation
import PackageDescription

// ── Optional control plane (NPRPC) ────────────────────────────────────────
//
// The compositor's control plane — naming fonts and textures, attaching a
// window to a client's draw arena — is RPC-shaped, and NPRPC does a
// shared-memory round trip in ~7 µs. But `nprpc_swift` builds with
// `.unsafeFlags`, which SwiftPM permits only for path dependencies, and which
// propagate to anything depending on it. So it is wired in here rather than
// under LavaUI: LavaUI must stay free of unsafe flags to remain usable as a
// GitHub dependency (see canvas/Package.swift), and the control plane belongs
// above the UI framework anyway.
//
// Detected rather than required, because HelloWorld itself does not need it.
// Without nprpc checked out, everything still builds; `ArenaDemo` simply
// falls back to agreeing on ids out of band, which is what it did before this
// existed.
let nprpcPath = ProcessInfo.processInfo.environment["NPRPC_SWIFT_PATH"]
    ?? URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("nprpc/nprpc_swift")
        .path
let haveNprpc = FileManager.default.fileExists(atPath: nprpcPath + "/Package.swift")

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
        .executable(name: "ArenaDemo", targets: ["ArenaDemo"]),
        .library(name: "LavaUI", targets: ["LavaUI"]),
        .library(name: "LavaText", targets: ["LavaText"]),
        .library(name: "LavaMenu", targets: ["LavaMenu"]),
        .library(name: "TraceLoomCore", targets: ["TraceLoomCore"]),
        .library(name: "SpotifyCore", targets: ["SpotifyCore"]),
        .library(name: "FBDModel", targets: ["FBDModel"]),
    ],
    dependencies: [
        .package(path: "canvas"),
    ] + (haveNprpc ? [Package.Dependency.package(path: nprpcPath)] : []),
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

        // One renderer process, one app process, one shared-memory draw arena.
        // Both halves in one binary (`ArenaDemo host` / `ArenaDemo produce`)
        // so the two sides cannot drift out of sync while the wire format is
        // still moving. The producer links the engine but never opens a
        // device: shaping is CPU-only, which is the property that makes this
        // split possible at all.
        .executableTarget(
            name: "ArenaDemo",
            dependencies: ["LavaUI"]
                + (haveNprpc
                    ? [Target.Dependency("LavaIDL"), Target.Dependency("LavaClient")]
                    : []),
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
            // `LAVA_CLIENT=1` runs the same demo under the compositor. Optional
            // for the same reason the control plane is: without nprpc checked
            // out this builds and runs as an ordinary windowed app.
            ] + (haveNprpc ? [Target.Dependency("LavaClient")] : []),
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
    ] + (haveNprpc ? [
        // Generated NPRPC stubs for idl/lava.npidl. A module of its own so
        // callers `import LavaIDL` explicitly and regeneration never touches
        // hand-written code — the same split nscalc uses.
        //
        // Regenerate with: scripts/gen_stubs.sh
        Target.target(
            name: "LavaIDL",
            dependencies: [.product(name: "NPRPC", package: "nprpc_swift")],
            swiftSettings: [.interoperabilityMode(.Cxx)]
        ),
        // The app half of the control plane: what any LavaUI app needs to run
        // as a client of the compositor rather than as its own window.
        //
        // Above LavaUI rather than inside it, because NPRPC's `.unsafeFlags`
        // propagate to every dependent and SwiftPM permits them only for path
        // dependencies — a LavaUI that linked this could not be used as a
        // GitHub dependency. Being a client is also genuinely a layer above a
        // UI framework.
        Target.target(
            name: "LavaClient",
            dependencies: [
                "LavaUI", "LavaIDL",
                .product(name: "NPRPC", package: "nprpc_swift"),
            ],
            swiftSettings: [.interoperabilityMode(.Cxx)]
        ),
    ] : []),
    // Same C++23 as canvas_swift so interop headers parse consistently.
    // C++23 draft name still used by PackageDescription on this toolchain.
    cxxLanguageStandard: .gnucxx2b
)

