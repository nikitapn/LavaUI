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
        // C++ interop surface (no Gtk). Use from targets with
        // interoperabilityMode(.Cxx). Implementation is still libcanvas.so.
        .library(name: "CxxCanvas", targets: ["CxxCanvas"]),
        // Yoga's C API, compiled standalone by SwiftPM (no libcanvas.so)
        .library(name: "CYoga", targets: ["CYoga"]),
    ],
    targets: [
        // C++ interop: import `canvas::Engine` etc. Header-only target;
        // symbols come from libcanvas.so.
        .target(
            name: "CxxCanvas",
            dependencies: [],
            path: "Sources/CxxCanvas",
            publicHeadersPath: "include",
            cxxSettings: [
                .unsafeFlags(["-std=c++23"]),
            ],
            linkerSettings: [
                .linkedLibrary("canvas"),
                .unsafeFlags(["-L", buildPath]),
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", buildPath]),
            ]
        ),

        .target(
            name: "CYoga",
            dependencies: [],
            path: "Sources/CYoga",
            publicHeadersPath: "include",
            cxxSettings: [
                .unsafeFlags(["-std=c++20"]),
            ],
            linkerSettings: [
                .linkedLibrary("m"),
            ]
        ),
    ]
)
