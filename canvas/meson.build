project('2d', 'cpp',
  version: '0.1.0',
  default_options: [
    'cpp_std=c++23',
    'default_library=static',
    'buildtype=debug',
  ],
)

fs = import('fs')
cpp = meson.get_compiler('cpp')

# Historically libc++ was forced under clang (see common_cpp_args/
# common_link_args below) to match an older CMake setup. That's now actively
# harmful: canvas_lib is also what Swift's C++ interop links against
# (canvas_swift/Sources/CxxCanvas), and Swift's Linux toolchain is built
# against libstdc++ — its own interop shim (libcxxstdlibshim.h) doesn't even
# parse under -stdlib=libc++. Since this system's libstdc++ (gcc 16) already
# has full C++23 support (<expected> included), there's no remaining reason
# to diverge from the platform default here.

# ——— System dependencies ———
vulkan_dep   = dependency('vulkan')
freetype_dep = dependency('freetype2')
harfbuzz_dep = dependency('harfbuzz')
glfw_dep     = dependency('glfw3')
# Optional: X11 native hints so the canvas can skip the taskbar/dock.
x11_dep     = dependency('x11', required: false)

# ——— Shaders (compiled to <builddir>/shaders/) ———
subdir('shaders')

# ——— Assets (copied flat into <builddir>/assets/) ———
asset_sources = [
  'assets/images/football-157930_640.png',
  'assets/images/football-157930.svg_64.png',
  'assets/images/football-157930.svg_128.png',
  'assets/fonts/OpenSans-Regular.ttf',
  'assets/fonts/LiberationSerif-Regular.ttf',
  # Media/geometric symbols (▶ ⏸) for PulseMeter; Symbols *2* has the glyphs.
  'assets/fonts/NotoSansSymbols2-Regular.ttf',
]

copy_assets = custom_target('copy_assets',
  input: asset_sources,
  output: 'assets_copied.stamp',
  # python3 receives: <dest_dir> <input0> ... <inputN> <stamp>
  # sys.argv[1]    = dest dir
  # sys.argv[2:-1] = source files
  # sys.argv[-1]   = stamp file to touch
  command: [
    find_program('python3'), '-c',
    'import shutil,sys,pathlib;d=pathlib.Path(sys.argv[1]);d.mkdir(parents=True,exist_ok=True);[shutil.copy2(f,d) for f in sys.argv[2:-1]];pathlib.Path(sys.argv[-1]).touch()',
    '@OUTDIR@/assets',
    '@INPUT@',
    '@OUTPUT@',
  ],
  build_by_default: true,
)

# ——— Engine sources (everything except main.cpp) ———
# Shared between the embeddable `canvas` library and the headless smoke-test
# executable below, so the executable actually exercises the same artifact
# Swift links against rather than a separately-compiled copy.
engine_sources = [
  'src/application.cpp',
  'src/render/vulkan.cpp',
  'src/render/vma_impl.cpp',
  'src/render/pipeline.cpp',
  'src/render/shaders.cpp',
  'src/render/texture_manager.cpp',
  'src/render/compute_physics.cpp',
  'src/render/text_renderer.cpp',
  'src/render/font.cpp',
  'src/render/quad_renderer.cpp',
  'src/render/blur_pass.cpp',
  'src/window/canvas_window.cpp',
  'src/window/window_platform.cpp',
  'src/util/util.cpp',
  'src/util/cout_ext.cpp',
  'src/bridge/canvas_bridge.cpp',
  'src/bridge/canvas_engine.cpp',
]

main_inc = include_directories(
  'src',
  'src/bridge',
  'third-party/entt/single_include',
  'third-party/imgui',
  'third-party/imgui/backends',
  'third-party/freetype/include',
  'third-party/stb',
  'third-party/taskflow',
  'third-party/yoga',
  'third-party/vma',
)

common_cpp_args = ['-DGLM_FORCE_DEPTH_ZERO_TO_ONE']
if x11_dep.found()
  common_cpp_args += ['-DCANVAS_HAVE_X11']
endif
common_link_args = []

# ——— Yoga (flexbox layout for app chrome) ———
yoga_inc = include_directories('third-party/yoga')
yoga_sources = [
  'third-party/yoga/yoga/YGConfig.cpp',
  'third-party/yoga/yoga/YGEnums.cpp',
  'third-party/yoga/yoga/YGNode.cpp',
  'third-party/yoga/yoga/YGNodeLayout.cpp',
  'third-party/yoga/yoga/YGNodeStyle.cpp',
  'third-party/yoga/yoga/YGPixelGrid.cpp',
  'third-party/yoga/yoga/YGValue.cpp',
  'third-party/yoga/yoga/algorithm/AbsoluteLayout.cpp',
  'third-party/yoga/yoga/algorithm/Baseline.cpp',
  'third-party/yoga/yoga/algorithm/Cache.cpp',
  'third-party/yoga/yoga/algorithm/CalculateLayout.cpp',
  'third-party/yoga/yoga/algorithm/FlexLine.cpp',
  'third-party/yoga/yoga/algorithm/PixelGrid.cpp',
  'third-party/yoga/yoga/config/Config.cpp',
  'third-party/yoga/yoga/debug/AssertFatal.cpp',
  'third-party/yoga/yoga/debug/Log.cpp',
  'third-party/yoga/yoga/event/event.cpp',
  'third-party/yoga/yoga/node/LayoutResults.cpp',
  'third-party/yoga/yoga/node/Node.cpp',
]
yoga_lib = static_library('yoga',
  sources: yoga_sources,
  include_directories: yoga_inc,
  cpp_args: common_cpp_args,
  link_args: common_link_args,
)
yoga_dep = declare_dependency(
  link_with: yoga_lib,
  include_directories: yoga_inc,
)

canvas_deps = [vulkan_dep, freetype_dep, harfbuzz_dep, glfw_dep, yoga_dep]
if x11_dep.found()
  canvas_deps += [x11_dep]
endif

# ——— Embeddable library ———
# This is what Swift (or anything else) links against. canvas_bridge.hpp/.cpp
# is the only public surface — Vulkan/engine internals never leave this lib.
canvas_lib = shared_library('canvas',
  sources: engine_sources,
  include_directories: main_inc,
  dependencies: canvas_deps,
  cpp_args: common_cpp_args,
  link_args: common_link_args,
  install: true,
)

canvas_dep = declare_dependency(
  link_with: canvas_lib,
  include_directories: include_directories('src/bridge'),
)

install_headers('src/bridge/canvas_bridge.hpp')

# ——— Headless smoke-test executable ———
# No window, no GLFW: ticks the engine offscreen and writes a PNG. Exercises
# canvas_lib itself (not a separate compile of engine_sources).
exe = executable('2d',
  sources: ['src/main.cpp'],
  include_directories: main_inc,
  dependencies: [canvas_dep],
  cpp_args: common_cpp_args,
  link_args: common_link_args,
)
