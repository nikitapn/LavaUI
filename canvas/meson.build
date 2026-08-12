# The canvas engine, built for C++ consumers.
#
# Mirrors `engineSources` in Package.swift — same files, same include paths,
# same defines. If you add a source there, add it here. The two lists are
# deliberately not generated from one another: a generator would need a build
# step SwiftPM has no way to run, and the list changes rarely enough that
# keeping it in two places costs less than the machinery to keep it in one.

canvas_engine_sources = files(
  'src/application.cpp',
  'src/bridge/canvas_engine.cpp',
  'src/ipc/draw_arena.cpp',
  'src/menu/app_menu.cpp',
  'src/menu/menu_import.cpp',
  'src/menu/status_notifier.cpp',
  'src/render/blur_pass.cpp',
  'src/render/compute_physics.cpp',
  'src/render/dmabuf_image.cpp',
  'src/render/font.cpp',
  'src/render/font_key.cpp',
  'src/render/image_atlas.cpp',
  'src/render/pipeline.cpp',
  'src/render/png_encode.cpp',
  'src/render/quad_renderer.cpp',
  'src/render/shaders.cpp',
  'src/render/svg_image.cpp',
  'src/render/text_renderer.cpp',
  'src/render/texture_manager.cpp',
  'src/render/vma_impl.cpp',
  'src/render/render_device.cpp',
  'src/render/render_window.cpp',
  'src/util/cout_ext.cpp',
  'src/util/util.cpp',
  'src/window/app_window.cpp',
  'src/window/canvas_window.cpp',
  'src/window/window_platform.cpp',
)

canvas_includes = include_directories(
  'src',
  'src/bridge',
  'third-party/stb',
  'third-party/vma/include',
  'third-party/freetype/include',
)

canvas_deps = [
  dependency('vulkan'),
  # <drm_fourcc.h> only: the FourCC/modifier vocabulary an exported image is
  # described in. Nothing here talks to a DRM device.
  dependency('libdrm'),
  dependency('freetype2'),
  dependency('harfbuzz'),
  # Linked but not initialised when the engine runs headless. `glfwInit` is
  # called only under `presentCapable`, so a compositor pays the link and
  # nothing else — see `RenderDevice::init`.
  dependency('glfw3'),
  dependency('x11'),
  dependency('gio-2.0'),
  dependency('dbusmenu-glib-0.4'),
  # Icon themes ship SVG; a dock rendering one at the size it draws beats
  # unpacking a PNG chosen for a different size.
  dependency('librsvg-2.0'),
  dependency('cairo'),
  # The stack trace printed by the VR() macro when a Vulkan call fails.
  meson.get_compiler('cpp').find_library('boost_stacktrace_basic'),
  meson.get_compiler('cpp').find_library('m'),
]

canvas_defines = [
  '-DGLM_FORCE_DEPTH_ZERO_TO_ONE',
  '-DCANVAS_HAVE_X11',
  '-DCANVAS_HAVE_DBUSMENU',
  '-DCANVAS_HAVE_RSVG',
]

libcanvas = static_library(
  'canvas',
  canvas_engine_sources,
  include_directories: canvas_includes,
  dependencies: canvas_deps,
  cpp_args: canvas_defines,
)

canvas_dep = declare_dependency(
  link_with: libcanvas,
  include_directories: canvas_includes,
  dependencies: canvas_deps,
  compile_args: canvas_defines,
)
