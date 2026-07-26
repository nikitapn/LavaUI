// swift-tools-version: 6.0

import Foundation
import PackageDescription

// Resolve the canvas repo root from this manifest's own location (parent of
// canvas_swift), rather than hardcoding a path — same reasoning as
// nprpc_swift's Package.swift.
let canvasRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .path

// Which Meson build directory (under canvasRoot) to link libcanvas against.
// Override e.g. `CANVAS_BUILD_DIR=.build.Release swift build`.
let canvasBuildDir = ProcessInfo.processInfo.environment["CANVAS_BUILD_DIR"] ?? ".build.Debug"
let buildPath = "\(canvasRoot)/\(canvasBuildDir)"

let package = Package(
    name: "CanvasSwift",
    platforms: [
        .macOS(.v13)  // For Linux, this is ignored.
    ],
    products: [
        .library(
            name: "CanvasKit",
            targets: ["CanvasKit"])
    ],
    targets: [
        // Plain C bridge module — exposes canvas_c_api.h to Swift as an
        // ordinary C module (no C++, no Swift C++-interop mode). That's
        // deliberate: a Swift C++-interop-enabled module can't be imported
        // from a target that also needs swift-cross-ui's GtkCHelpers (a
        // plain C module with constructs, like uninitialized `const`
        // globals, that are legal C but not legal C++ — Clang parses all C
        // imports as C++ once interop mode is on for a target). Going
        // through a plain `extern "C"` API here avoids that fight entirely.
        // Header-only: the actual implementation (canvas_c_api.cpp,
        // canvas_bridge.cpp) is compiled by Meson into libcanvas.so, not by
        // SwiftPM.
        .target(
            name: "CCanvas",
            dependencies: [],
            path: "Sources/CCanvas",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedLibrary("canvas"),
                .unsafeFlags(["-L", buildPath]),
                // NOTE: must be absolute paths, not $ORIGIN-relative. The
                // Swift toolchain injects its own rpath entry ahead of ours,
                // and once the dynamic linker misses on that entry it
                // silently skips any subsequent $ORIGIN-relative rpath
                // entries instead of continuing to search them. (Same
                // gotcha already hit and documented in nprpc_swift.)
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", buildPath]),
            ]
        ),

        // Swift-facing wrapper.
        .target(
            name: "CanvasKit",
            dependencies: ["CCanvas"],
            path: "Sources/CanvasKit"
        ),
    ]
)
