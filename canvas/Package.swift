// swift-tools-version: 6.0

import Foundation
import PackageDescription

// Canvas C++ engine compiled by SwiftPM (no prebuilt libcanvas.so).
// System deps via pkg-config systemLibrary targets. SPIR-V is packed by the
// CanvasResources target; fonts/images live on LavaUI / app targets.

let yogaSources: [String] = [
    "include/yoga/YGConfig.cpp",
    "include/yoga/YGEnums.cpp",
    "include/yoga/YGNode.cpp",
    "include/yoga/YGNodeLayout.cpp",
    "include/yoga/YGNodeStyle.cpp",
    "include/yoga/YGPixelGrid.cpp",
    "include/yoga/YGValue.cpp",
    "include/yoga/algorithm/AbsoluteLayout.cpp",
    "include/yoga/algorithm/Baseline.cpp",
    "include/yoga/algorithm/Cache.cpp",
    "include/yoga/algorithm/CalculateLayout.cpp",
    "include/yoga/algorithm/FlexLine.cpp",
    "include/yoga/algorithm/PixelGrid.cpp",
    "include/yoga/config/Config.cpp",
    "include/yoga/debug/AssertFatal.cpp",
    "include/yoga/debug/Log.cpp",
    "include/yoga/event/event.cpp",
    "include/yoga/node/LayoutResults.cpp",
    "include/yoga/node/Node.cpp",
]

let engineSources: [String] = [
    "application.cpp",
    "bridge/canvas_engine.cpp",
    "ipc/draw_arena.cpp",
    "ipc/pixel_arena.cpp",
    "menu/app_menu.cpp",
    "menu/glib_wait.cpp",
    "menu/menu_import.cpp",
    "menu/notification.cpp",
    "menu/status_notifier.cpp",
    "render/blur_pass.cpp",
    "render/dmabuf_image.cpp",
    "render/exif.cpp",
    "render/imported_dmabuf.cpp",
    "render/font.cpp",
    "render/font_key.cpp",
    "render/frame_damage.cpp",
    "render/gpu_trace.cpp",
    "render/gpu_ledger.cpp",
    "render/gpu_report.cpp",
    "render/image_atlas.cpp",
    "render/image_load.cpp",
    "render/png_encode.cpp",
    "render/quad_renderer.cpp",
    "render/raw_preview.cpp",
    "render/shaders.cpp",
    "render/svg_image.cpp",
    "render/text_renderer.cpp",
    "render/texture_manager.cpp",
    "render/vma_impl.cpp",
    "render/render_device.cpp",
    "render/render_window.cpp",
    "util/cout_ext.cpp",
    "util/util.cpp",
    "window/app_window.cpp",
    "window/canvas_window.cpp",
    "window/window_platform.cpp",
]

// ── Tracy, decided when the package is built ───────────────────────────────
//
// `LAVA_TRACY=1 swift build` compiles Tracy's client (the submodule
// third-party/tracy) in, on demand: it
// listens for the profiler but records nothing until one connects, so a
// binary left running all day does not grow a queue nobody reads.
// `LAVA_TRACY=full` records from the first instruction instead, for startup.
// Anything else, or unset, leaves Tracy out entirely — the shim in `trace/`
// is then empty functions and no thread or socket exists.
//
// The root Package.swift reads the same variable for the Swift side, so one
// environment decides both. Changing it rebuilds what it touches: SwiftPM
// re-evaluates the manifest when its environment changes.
let tracyMode = ProcessInfo.processInfo.environment["LAVA_TRACY"] ?? ""
let tracyEnabled = tracyMode == "1" || tracyMode == "on" || tracyMode == "full"
// Tracy is the submodule third-party/tracy (v0.15.0), needed by a profiling
// build only. Said here rather than as a missing-header error three hundred
// lines into the engine's compile.
if tracyEnabled {
    let client = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("third-party/tracy/public/TracyClient.cpp").path
    if !FileManager.default.fileExists(atPath: client) {
        fatalError("LAVA_TRACY needs the Tracy submodule: git submodule update --init canvas/third-party/tracy")
    }
}
// Tracy timestamps with `rdtsc` unless told otherwise, which is only right
// where every core's counter agrees. Where the kernel found they do not, it
// stops using the TSC itself and says so in its clocksource — and Tracy's
// zones then jump by the warp whenever a thread changes core. On the machine
// this was written on that was 0.83 s ("Measured 2657830998 cycles TSC warp
// between CPUs" at boot), showing up as one impossible 834 ms frame per
// capture. So: follow the kernel. `LAVA_TRACY_TIMER=tsc` or `=fallback`
// overrides; fallback is `clock_gettime`, slower per zone but always right.
//
// It takes TRACY_DISALLOW_HW_TIMER, not TRACY_TIMER_FALLBACK: the latter
// still reads rdtsc whenever CPUID calls the TSC invariant, and this CPU
// does — the counters run at a constant rate, they just do not agree.
let tracyTimer: String = {
    if let forced = ProcessInfo.processInfo.environment["LAVA_TRACY_TIMER"], !forced.isEmpty {
        return forced
    }
    let path = "/sys/devices/system/clocksource/clocksource0/current_clocksource"
    guard let source = try? String(contentsOfFile: path, encoding: .utf8) else { return "tsc" }
    return source.trimmingCharacters(in: .whitespacesAndNewlines) == "tsc" ? "tsc" : "fallback"
}()

// TRACY_ONLY_LOCALHOST: by default the client listens on every interface,
// and what it serves is the process's strings, timings and call sites.
let tracyDefines: [CXXSetting] = !tracyEnabled ? [] : [
    .define("TRACY_ENABLE"),
    .define("TRACY_ONLY_LOCALHOST"),
] + (tracyMode == "full" ? [] : [.define("TRACY_ON_DEMAND")])
  + (tracyTimer == "fallback" ? [.define("TRACY_DISALLOW_HW_TIMER")] : [])

let package = Package(
    name: "CanvasSwift",
    platforms: [
        .macOS(.v13), // ignored on Linux
    ],
    products: [
        .library(name: "CxxCanvas", targets: ["CxxCanvas"]),
        .library(name: "CYoga", targets: ["CYoga"]),
        .library(name: "CTracy", targets: ["CTracy"]),
        // SPIR-V resource bundle; path via CanvasResources.engineRoot.
        .library(name: "CanvasResources", targets: ["CanvasResources"]),
    ],
    targets: [
        // Checked-in shader bytecode only — no C++. Fonts/images belong on
        // LavaUI / app targets (user-level), not the engine package.
        .target(
            name: "CanvasResources",
            path: "Sources/CanvasResources",
            resources: [
                .copy("shaders"),
            ]
        ),

        // ── System deps (pkg-config supplies -I/-L for dependents) ─────────
        .systemLibrary(
            name: "CFreeType",
            path: "canvas_swift/Sources/CFreeType",
            pkgConfig: "freetype2",
            providers: [
                .apt(["libfreetype-dev"]),
                .brew(["freetype"]),
            ]
        ),
        .systemLibrary(
            name: "CHarfBuzz",
            path: "canvas_swift/Sources/CHarfBuzz",
            pkgConfig: "harfbuzz",
            providers: [
                .apt(["libharfbuzz-dev"]),
                .brew(["harfbuzz"]),
            ]
        ),
        .systemLibrary(
            name: "CGLFW",
            path: "canvas_swift/Sources/CGLFW",
            pkgConfig: "glfw3",
            providers: [
                .apt(["libglfw3-dev"]),
                .brew(["glfw"]),
            ]
        ),
        .systemLibrary(
            name: "CVulkan",
            path: "canvas_swift/Sources/CVulkan",
            pkgConfig: "vulkan",
            providers: [
                .apt(["libvulkan-dev"]),
                .brew(["vulkan-headers", "vulkan-loader"]),
            ]
        ),
        .systemLibrary(
            name: "CGIO",
            path: "canvas_swift/Sources/CGIO",
            pkgConfig: "gio-2.0",
            providers: [
                .apt(["libglib2.0-dev"]),
                .brew(["glib"]),
            ]
        ),
        .systemLibrary(
            name: "CDbusMenu",
            path: "canvas_swift/Sources/CDbusMenu",
            pkgConfig: "dbusmenu-glib-0.4",
            providers: [
                .apt(["libdbusmenu-glib-dev"]),
            ]
        ),
        // drm_fourcc.h only — no DRM device ioctls. Used by dmabuf export.
        .systemLibrary(
            name: "CDrm",
            path: "canvas_swift/Sources/CDrm",
            pkgConfig: "libdrm",
            providers: [
                .apt(["libdrm-dev"]),
                .brew(["libdrm"]),
            ]
        ),

        // ── Yoga (C API for LavaUI layout; symbols owned here) ─────────────
        .target(
            name: "CYoga",
            path: "canvas_swift/Sources/CYoga",
            sources: yogaSources,
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("include"),
            ],
            linkerSettings: [
                .linkedLibrary("m"),
            ]
        ),

        // ── Tracy's client, the one copy in the process ────────────────────
        // See trace/lava_trace.cpp. Always built: without LAVA_TRACY it is a
        // handful of empty functions, so nothing that calls it needs a
        // condition of its own.
        .target(
            name: "CTracy",
            path: "trace",
            sources: ["lava_trace.cpp"],
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("../third-party/tracy/public"),
            ] + tracyDefines,
            linkerSettings: [
                .linkedLibrary("dl"),
                .linkedLibrary("pthread"),
            ]
        ),

        // ── Canvas engine (Vulkan / GLFW / FreeType / HarfBuzz) ────────────
        .target(
            name: "CxxCanvas",
            dependencies: [
                "CFreeType",
                "CHarfBuzz",
                "CGLFW",
                "CVulkan",
                "CGIO",
                "CDbusMenu",
                "CDrm",
                "CTracy",
            ],
            path: "src",
            exclude: [
                // Do not exclude third-party/{stb,vma,freetype}: headerSearchPath
                // into those trees is required to compile the engine.
                "main.cpp",
                "shaders",
            ],
            sources: engineSources,
            publicHeadersPath: "swiftpm/include",
            cxxSettings: [
                .headerSearchPath("."),
                .headerSearchPath("bridge"),
                .headerSearchPath("../third-party/stb"),
                .headerSearchPath("../third-party/vma/include"),
                .headerSearchPath("../third-party/freetype/include"),
                // Tracy.hpp / TracyVulkan.hpp, whose macros are empty
                // without TRACY_ENABLE — see `tracyDefines`.
                .headerSearchPath("../third-party/tracy/public"),
                .define("GLM_FORCE_DEPTH_ZERO_TO_ONE"),
                .define("CANVAS_HAVE_X11", .when(platforms: [.linux])),
                .define("CANVAS_HAVE_DBUSMENU", .when(platforms: [.linux])),
            ] + tracyDefines,
            linkerSettings: [
                .linkedLibrary("m"),
                .linkedLibrary("X11", .when(platforms: [.linux])),
                .linkedLibrary("boost_stacktrace_basic", .when(platforms: [.linux])),
            ]
        ),
    ],
    // C++23 draft name still used by PackageDescription on this toolchain.
    cxxLanguageStandard: .gnucxx2b
)
