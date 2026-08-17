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
// Detected rather than required, because windowed LavaUI apps do not need it.
let nprpcPath = ProcessInfo.processInfo.environment["NPRPC_SWIFT_PATH"]
    ?? URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("nprpc/nprpc_swift")
        .path
let haveNprpc = FileManager.default.fileExists(atPath: nprpcPath + "/Package.swift")

let interopCxx: [SwiftSetting] = [.interoperabilityMode(.Cxx)]

var packageDependencies: [Package.Dependency] = [
    .package(path: "canvas"),
]
if haveNprpc {
    packageDependencies.append(.package(path: nprpcPath))
}

var products: [Product] = [
    .executable(name: "HelloWorld", targets: ["HelloWorld"]),
    .executable(name: "TraceLoom", targets: ["TraceLoomApp"]),
    .executable(name: "LavaSpotify", targets: ["SpotifyApp"]),
    .executable(name: "LavaWeather", targets: ["WeatherApp"]),
    .executable(name: "LavaTerm", targets: ["LavaTermApp"]),
    .executable(name: "LavaBench", targets: ["LavaBench"]),
    .executable(name: "TwoWindows", targets: ["TwoWindows"]),
    .executable(name: "LavaSurface", targets: ["LavaSurface"]),
    .executable(name: "LavaTaskbar", targets: ["LavaTaskbar"]),
    .executable(name: "LavaDock", targets: ["LavaDock"]),
    .executable(name: "LavaSettings", targets: ["LavaSettings"]),
    .executable(name: "LavaDebug", targets: ["LavaDebug"]),
    .executable(name: "LavaLauncher", targets: ["LavaLauncher"]),
    .executable(name: "LavaSwitcher", targets: ["LavaSwitcher"]),
    .library(name: "LavaUI", targets: ["LavaUI"]),
    .library(name: "LavaHost", targets: ["LavaHost"]),
    .library(name: "LavaText", targets: ["LavaText"]),
    .library(name: "LavaMenu", targets: ["LavaMenu"]),
    .library(name: "LavaShell", targets: ["LavaShell"]),
    .library(name: "TraceLoomCore", targets: ["TraceLoomCore"]),
    .library(name: "SpotifyCore", targets: ["SpotifyCore"]),
    .library(name: "LavaTermCore", targets: ["LavaTermCore"]),
    .library(name: "WeatherCore", targets: ["WeatherCore"]),
    .library(name: "FBDModel", targets: ["FBDModel"]),
]

var targets: [Target] = [
    // Pure text-editing logic: no C++ interop, no Vulkan.
    .target(name: "LavaText"),
    // Application menu IR + DSL. Headless-testable.
    .target(name: "LavaMenu"),
    // What a desktop shell needs to know about the machine it is a shell for:
    // which applications are installed, and which picture belongs to each.
    // Pure Foundation — no engine, no control plane — so it is testable
    // without either. See Sources/LavaShell/DesktopEntry.swift.
    .target(name: "LavaShell"),
    // libpulse client for the panel volume applet (PulseAudio / PipeWire-Pulse).
    .target(
        name: "CPulse",
        path: "Sources/CPulse",
        publicHeadersPath: "include",
        linkerSettings: [
            .linkedLibrary("pulse", .when(platforms: [.linux])),
        ]
    ),
    .target(name: "TraceLoomCore"),
    .target(name: "SpotifyCore"),
    .target(name: "LavaTermCore"),
    .target(name: "WeatherCore"),
    .target(name: "FBDModel"),

    .executableTarget(
        name: "TwoWindows",
        dependencies: ["LavaUI"],
        swiftSettings: interopCxx
    ),
    // A LavaUI app with no window and no GPU, drawn by the wlroots compositor
    // and driven by input it forwards. See Sources/LavaSurface/main.swift.
    .executableTarget(
        name: "LavaSurface",
        dependencies: ["LavaUI"]
            + (haveNprpc ? [Target.Dependency("LavaClient")] : []),
        swiftSettings: interopCxx
    ),
    // The desktop's top panel, as an ordinary LavaUI client — the shell built
    // out of the same client API an app uses. See Sources/LavaTaskbar.
    .executableTarget(
        name: "LavaTaskbar",
        dependencies: ["LavaUI", "CPulse"]
            + (haveNprpc ? [Target.Dependency("LavaClient"),
                            Target.Dependency("LavaIDL")] : []),
        resources: [
            .process("Resources"),
        ],
        swiftSettings: interopCxx
    ),
    // The dock: what is open on this workspace, as icons. The other half of a
    // shell, and the first client that needed the window list.
    .executableTarget(
        name: "LavaDock",
        dependencies: ["LavaUI", "LavaShell"]
            + (haveNprpc ? [Target.Dependency("LavaClient"),
                            Target.Dependency("LavaIDL")] : []),
        swiftSettings: interopCxx
    ),
    // The application launcher: everything installed, as a wall of icons.
    .executableTarget(
        name: "LavaLauncher",
        dependencies: ["LavaUI", "LavaShell"]
            + (haveNprpc ? [Target.Dependency("LavaClient"),
                            Target.Dependency("LavaIDL")] : []),
        swiftSettings: interopCxx
    ),
    // Ctrl+Tab / Mod+Tab: live window posters in a Scene3D shelf.
    .executableTarget(
        name: "LavaSwitcher",
        dependencies: ["LavaUI", "LavaShell"]
            + (haveNprpc ? [Target.Dependency("LavaClient"),
                            Target.Dependency("LavaIDL")] : []),
        swiftSettings: interopCxx
    ),
    // The desktop's settings, and the first client that changes the desktop
    // rather than asking it questions. See Sources/LavaSettings/main.swift.
    .executableTarget(
        name: "LavaSettings",
        dependencies: ["LavaUI"]
            + (haveNprpc ? [Target.Dependency("LavaClient"),
                            Target.Dependency("LavaIDL")] : []),
        swiftSettings: interopCxx
    ),
    // Where the compositor's VRAM went: the GPU report, as a window and as
    // `--once` text. See Sources/LavaDebug/main.swift.
    .executableTarget(
        name: "LavaDebug",
        dependencies: ["LavaUI"]
            + (haveNprpc ? [Target.Dependency("LavaClient"),
                            Target.Dependency("LavaIDL")] : []),
        swiftSettings: interopCxx
    ),
    .executableTarget(
        name: "ModifierSpike",
        dependencies: ["LavaUI"],
        swiftSettings: interopCxx
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
            .copy("Resources/fonts"),
        ],
        swiftSettings: interopCxx
    ),
    // Runtime host selection stays above LavaUI so NPRPC remains optional.
    .target(
        name: "LavaHost",
        dependencies: ["LavaUI"]
            + (haveNprpc ? [Target.Dependency("LavaClient")] : []),
        swiftSettings: interopCxx + (haveNprpc ? [.define("LAVA_HAS_CLIENT")] : [])
    ),
    .executableTarget(
        name: "HelloWorld",
        dependencies: [
            "LavaUI",
            "LavaHost",
            "FBDModel",
        ],
        resources: [
            .process("Resources"),
        ],
        swiftSettings: interopCxx
    ),
    .executableTarget(
        name: "TraceLoomApp",
        dependencies: ["LavaUI", "LavaHost", "TraceLoomCore"],
        swiftSettings: interopCxx
    ),
    .executableTarget(
        name: "SpotifyApp",
        dependencies: [
            "LavaUI",
            "LavaHost",
            "SpotifyCore"
        ],
        swiftSettings: interopCxx
    ),
    .executableTarget(
        name: "LavaTermApp",
        dependencies: ["LavaUI", "LavaHost", "LavaTermCore"],
        swiftSettings: interopCxx,
        linkerSettings: [
            .linkedLibrary("util", .when(platforms: [.linux])),
        ]
    ),
    .executableTarget(
        name: "WeatherApp",
        dependencies: ["LavaUI", "LavaHost", "WeatherCore"],
        swiftSettings: interopCxx
    ),
    .executableTarget(
        name: "LavaBench",
        dependencies: ["LavaUI", "LavaText", "TraceLoomCore"],
        swiftSettings: interopCxx
    ),
    .testTarget(name: "LavaTextTests", dependencies: ["LavaText"]),
    .testTarget(name: "LavaMenuTests", dependencies: ["LavaMenu"]),
    .testTarget(name: "LavaShellTests", dependencies: ["LavaShell"]),
    .testTarget(name: "FBDModelTests", dependencies: ["FBDModel"]),
    .testTarget(name: "TraceLoomCoreTests", dependencies: ["TraceLoomCore"]),
    .testTarget(
        name: "LavaUITests",
        dependencies: ["LavaUI"],
        swiftSettings: interopCxx
    ),
    .testTarget(name: "LavaTermCoreTests", dependencies: ["LavaTermCore"]),
    .testTarget(name: "WeatherCoreTests", dependencies: ["WeatherCore"]),
]

if haveNprpc {
    targets.append(contentsOf: [
        Target.target(
            name: "LavaIDL",
            dependencies: [.product(name: "NPRPC", package: "nprpc_swift")],
            swiftSettings: interopCxx
        ),
        Target.target(
            name: "LavaClient",
            dependencies: [
                "LavaUI", "LavaIDL",
                .product(name: "NPRPC", package: "nprpc_swift"),
            ],
            swiftSettings: interopCxx
        ),
    ])
}

// Post-SwiftCrossUI: C++ interop (CxxCanvas) + FBDModel. No Gtk.
// LavaUI = declarative View DSL + Yoga + draw list + engine bridge.
// Canvas engine is built by SwiftPM via the `canvas` package (CxxCanvas).
let package = Package(
    name: "HelloWorld",
    platforms: [.macOS(.v13)],
    products: products,
    dependencies: packageDependencies,
    targets: targets,
    // Same C++23 as canvas_swift so interop headers parse consistently.
    cxxLanguageStandard: .gnucxx2b
)
