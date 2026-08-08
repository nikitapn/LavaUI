// swift-tools-version: 6.0

import PackageDescription

// Canvas C++ engine compiled by SwiftPM (no prebuilt libcanvas.so).
// System deps via pkg-config systemLibrary targets. SPIR-V is packed by the
// CanvasResources target; fonts/images live on LavaUI / app targets.

let yogaSources: [String] = [
    "third-party/yoga/yoga/YGConfig.cpp",
    "third-party/yoga/yoga/YGEnums.cpp",
    "third-party/yoga/yoga/YGNode.cpp",
    "third-party/yoga/yoga/YGNodeLayout.cpp",
    "third-party/yoga/yoga/YGNodeStyle.cpp",
    "third-party/yoga/yoga/YGPixelGrid.cpp",
    "third-party/yoga/yoga/YGValue.cpp",
    "third-party/yoga/yoga/algorithm/AbsoluteLayout.cpp",
    "third-party/yoga/yoga/algorithm/Baseline.cpp",
    "third-party/yoga/yoga/algorithm/Cache.cpp",
    "third-party/yoga/yoga/algorithm/CalculateLayout.cpp",
    "third-party/yoga/yoga/algorithm/FlexLine.cpp",
    "third-party/yoga/yoga/algorithm/PixelGrid.cpp",
    "third-party/yoga/yoga/config/Config.cpp",
    "third-party/yoga/yoga/debug/AssertFatal.cpp",
    "third-party/yoga/yoga/debug/Log.cpp",
    "third-party/yoga/yoga/event/event.cpp",
    "third-party/yoga/yoga/node/LayoutResults.cpp",
    "third-party/yoga/yoga/node/Node.cpp",
]

let engineSources: [String] = [
    "src/application.cpp",
    "src/bridge/canvas_engine.cpp",
    "src/ipc/draw_arena.cpp",
    "src/menu/app_menu.cpp",
    "src/render/blur_pass.cpp",
    "src/render/compute_physics.cpp",
    "src/render/dmabuf_image.cpp",
    "src/render/font.cpp",
    "src/render/font_key.cpp",
    "src/render/image_atlas.cpp",
    "src/render/pipeline.cpp",
    "src/render/quad_renderer.cpp",
    "src/render/shaders.cpp",
    "src/render/text_renderer.cpp",
    "src/render/texture_manager.cpp",
    "src/render/vma_impl.cpp",
    "src/render/render_device.cpp",
    "src/render/render_window.cpp",
    "src/util/cout_ext.cpp",
    "src/util/util.cpp",
    "src/window/app_window.cpp",
    "src/window/canvas_window.cpp",
    "src/window/window_platform.cpp",
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
            path: ".",
            exclude: [
                // Keep SPM from scanning the rest of the monorepo tree.
                "canvas_swift",
                "Package.swift",
                "scripts",
                "Sources",
                "src",
                "third-party/freetype",
                "third-party/stb",
                "third-party/vma",
                "third-party/yoga/tests",
                "third-party/yoga/website",
                "third-party/yoga/javascript",
                "third-party/yoga/java",
                "third-party/yoga/lib",
                "third-party/yoga/gentest",
            ],
            sources: yogaSources,
            publicHeadersPath: "canvas_swift/Sources/CYoga/include",
            cxxSettings: [
                .headerSearchPath("third-party/yoga"),
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
            path: ".",
            exclude: [
                // Do not exclude third-party/{stb,vma,freetype}: headerSearchPath
                // into those trees is required to compile the engine.
                "canvas_swift",
                "Package.swift",
                "scripts",
                "Sources",
                "src/main.cpp",
                "src/camel.py",
                "src/shaders",
                "third-party/yoga",
            ],
            sources: engineSources,
            publicHeadersPath: "canvas_swift/Sources/CxxCanvas/include",
            cxxSettings: [
                .headerSearchPath("src"),
                .headerSearchPath("src/bridge"),
                .headerSearchPath("third-party/stb"),
                .headerSearchPath("third-party/vma/include"),
                .headerSearchPath("third-party/freetype/include"),
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
