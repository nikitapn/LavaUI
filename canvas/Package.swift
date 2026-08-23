// swift-tools-version: 6.0

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
    "menu/app_menu.cpp",
    "menu/menu_import.cpp",
    "menu/notification.cpp",
    "menu/status_notifier.cpp",
    "render/blur_pass.cpp",
    "render/dmabuf_image.cpp",
    "render/imported_dmabuf.cpp",
    "render/font.cpp",
    "render/font_key.cpp",
    "render/gpu_ledger.cpp",
    "render/gpu_report.cpp",
    "render/image_atlas.cpp",
    "render/png_encode.cpp",
    "render/quad_renderer.cpp",
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

let package = Package(
    name: "CanvasSwift",
    platforms: [
        .macOS(.v13), // ignored on Linux
    ],
    products: [
        .library(name: "CxxCanvas", targets: ["CxxCanvas"]),
        .library(name: "CYoga", targets: ["CYoga"]),
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
                .define("GLM_FORCE_DEPTH_ZERO_TO_ONE"),
                .define("CANVAS_HAVE_X11", .when(platforms: [.linux])),
                .define("CANVAS_HAVE_DBUSMENU", .when(platforms: [.linux])),
            ],
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
