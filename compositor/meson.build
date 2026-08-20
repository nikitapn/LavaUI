wlroots = dependency('wlroots-0.19', version: '>=0.19.0', required: false)
if not wlroots.found()
  wlroots = dependency('wlroots', version: '>=0.19.0')
endif

# Wayland protocols are XML, not headers. `wayland-scanner` turns each one into
# the C the compositor side needs, and wlroots' own headers include the result
# by name — `wlr_xdg_shell.h` will not compile without `xdg-shell-protocol.h`
# existing. Generated into the build tree rather than committed so the versions
# always match the installed wayland-protocols.
wayland_protocols = dependency('wayland-protocols')
protocol_dir = wayland_protocols.get_variable(pkgconfig: 'pkgdatadir')
wayland_scanner = find_program(
  dependency('wayland-scanner', native: true).get_variable(
    pkgconfig: 'wayland_scanner'),
  native: true,
)

# Headers only for protocols we bind through wlroots (xdg-shell). Full
# private-code is only needed for protocols we implement ourselves.
protocol_headers = []
protocol_sources = []

foreach xml : [
  # The shell every ordinary Wayland application speaks: toplevels, popups,
  # the negotiation behind resize and maximize.
  protocol_dir / 'stable/xdg-shell/xdg-shell.xml',
  # Pointer grabs and raw motion. Xwayland uses these to implement the X11
  # grabs that games rely on for an unbounded first-person camera.
  protocol_dir / 'unstable/pointer-constraints/pointer-constraints-unstable-v1.xml',
  protocol_dir / 'unstable/relative-pointer/relative-pointer-unstable-v1.xml',
]
  protocol_headers += custom_target(
    xml.underscorify() + '_server_h',
    input: xml,
    output: '@BASENAME@-protocol.h',
    command: [wayland_scanner, 'server-header', '@INPUT@', '@OUTPUT@'],
  )
endforeach

# KDE AppMenu: clients point a wl_surface at a com.canonical.dbusmenu
# object on the session bus. How Dolphin (etc.) export a global menu on
# pure Wayland without an X11 window id. Checked into protocols/ rather
# than wayland-protocols — it is a KDE extension, not a standard one.
appmenu_xml = meson.current_source_dir() / 'protocols/appmenu.xml'
protocol_headers += custom_target(
  'appmenu_server_h',
  input: appmenu_xml,
  output: 'appmenu-protocol.h',
  command: [wayland_scanner, 'server-header', '@INPUT@', '@OUTPUT@'],
)
protocol_sources += custom_target(
  'appmenu_private_c',
  input: appmenu_xml,
  output: 'appmenu-protocol.c',
  command: [wayland_scanner, 'private-code', '@INPUT@', '@OUTPUT@'],
)

# Canvas resolves its compiled shaders relative to an assets root it is told.
# A Swift client passes the SwiftPM resource bundle; a compositor has no
# bundle, so the build points it at the source tree. `LAVA_CANVAS_ASSETS` in
# the environment overrides it for an installed binary.
canvas_assets = meson.project_source_root() / 'canvas/Sources/CanvasResources'

# The face the compositor draws window titles in. Same files LavaUI clients
# use, so its own text does not look like a different desktop.
lava_ui_fonts = meson.project_source_root() / 'Sources/LavaUI/Resources/fonts'

# ── Control plane (NPRPC) ───────────────────────────────────────────────────
#
# Detected rather than required, the same way `Package.swift` treats it and for
# the same reason: a clone without nprpc should still build a compositor. What
# it loses is the control plane — no input, no surfaces asked for by clients —
# which is exactly the part that needs the other repo.
#
# Found by path rather than pkg-config: nprpc does not install a .pc the
# compositor can use, and the Swift package's one is ${pcfiledir}-relative.
# Search order matches scripts/lib/lava.sh and Package.swift:
#   -Dnprpc_root=…, then third-party/nprpc, then ../nprpc, then libnprpc
#   on the default linker path (a cmake --install).
nprpc_opt = get_option('nprpc_root')
nprpc_candidates = []
if nprpc_opt != ''
  nprpc_candidates += nprpc_opt
endif
nprpc_candidates += meson.project_source_root() / 'third-party/nprpc'
nprpc_candidates += meson.project_source_root() / '../nprpc'

fs = import('fs')
nprpc_root = ''
foreach c : nprpc_candidates
  if nprpc_root == '' and fs.exists(c / 'include/nprpc/nprpc.hpp')
    nprpc_root = c
  endif
endforeach

nprpc_dep = dependency('', required: false)
lava_idl_sources = []
cpp = meson.get_compiler('cpp')

if nprpc_root != ''
  nprpc_lib_dirs = []
  foreach d : [
    nprpc_root / '.build_relwith_debinfo',
    nprpc_root / '.build_release',
    nprpc_root / '.build',
    nprpc_root / 'lib',
    nprpc_root / 'lib64',
    nprpc_root / 'lib/x86_64-linux-gnu',
    nprpc_root / 'lib/aarch64-linux-gnu',
  ]
    if fs.exists(d)
      nprpc_lib_dirs += d
    endif
  endforeach
  nprpc_lib = cpp.find_library('nprpc', dirs: nprpc_lib_dirs, required: false)
  if nprpc_lib.found()
    nprpc_rpath = nprpc_root
    foreach d : nprpc_lib_dirs
      if fs.exists(d / 'libnprpc.so') or fs.exists(d / 'libnprpc.so.1')
        nprpc_rpath = d
        break
      endif
    endforeach
    nprpc_dep = declare_dependency(
      dependencies: [nprpc_lib],
      # `-isystem` rather than `include_directories()` for two reasons: nprpc
      # often lives outside this source tree, and meson refuses to form an
      # absolute include path to anywhere it does not own; and system headers
      # are exempt from our warning level, which is at 3 and would otherwise
      # report another project's headers at us on every build.
      compile_args: ['-DLAVA_HAVE_NPRPC', '-isystem' + nprpc_root / 'include'],
      # In-tree builds put libnprpc.so next to the CMake cache, which is not
      # on the loader's search list. A cmake --install to /usr/local does not
      # need this, but an extra rpath is harmless.
      link_args: ['-Wl,-rpath,' + nprpc_rpath],
    )
    # Generated by scripts/gen_stubs.sh and checked in, so this builds without
    # npidl on the path.
    lava_idl_sources = ['src/gen/lava.cpp', 'src/control_plane.cpp']
    message('control plane: enabled (nprpc at ' + nprpc_root + ')')
  else
    warning('control plane: nprpc at ' + nprpc_root \
      + ' has no libnprpc.so — run scripts/build-nprpc.sh')
  endif
else
  nprpc_lib = cpp.find_library('nprpc', required: false)
  if nprpc_lib.found()
    nprpc_dep = declare_dependency(
      dependencies: [nprpc_lib],
      compile_args: ['-DLAVA_HAVE_NPRPC'],
    )
    lava_idl_sources = ['src/gen/lava.cpp', 'src/control_plane.cpp']
    message('control plane: enabled (system libnprpc)')
  else
    message('control plane: disabled (no nprpc; scripts/fetch-nprpc.sh)')
  endif
endif


executable(
  'compositor',
  'src/main.cpp',
  'src/appmenu.cpp',
  'src/backdrop_blur.cpp',
  'src/background.cpp',
  'src/canvas_surface.cpp',
  'src/clipboard.cpp',
  'src/config.cpp',
  'src/decoration.cpp',
  'src/frame_probe.cpp',
  'src/shell.cpp',
  'src/screenshot_portal.cpp',
  'src/window_memory.cpp',
  'src/focus_history.cpp',
  lava_idl_sources,
  protocol_headers,
  protocol_sources,
  dependencies: [
    wlroots,
    dependency('wayland-server'),
    # Keyboards arrive as evdev keycodes; xkbcommon is what turns those into
    # keysyms, and what the keymap sent to every client is built from.
    dependency('xkbcommon'),
    # The catalogue of layouts a settings app offers to choose from. Ships
    # with xkbcommon and answers where the rules files actually are, which
    # differs between distributions.
    dependency('xkbregistry'),
    # libdrm supplies the FourCC/modifier vocabulary that canvas and wlroots
    # describe a shared buffer in. Vulkan arrives through canvas.
    dependency('libdrm'),
    # Regions. wlroots puts pixman on the include path already, but linking it
    # is ours to declare — the wallpaper marks itself opaque so the scene can
    # skip drawing the desktop underneath it.
    dependency('pixman-1'),
    # The renderer. Canvas draws the pixels a compositor-side surface shows,
    # and owns the Vulkan device they are exported from.
    canvas_dep,
    nprpc_dep,
    # Session-bus Screenshot portal (Flameshot). sd-bus is what logind
    # already pulled in through wlroots; we talk to it directly so the
    # capture stays on the compositor thread.
    dependency('libsystemd'),
  ],
  # wlroots guards every header behind this. It is not opt-in extra features:
  # without it `wlr/backend.h` is a hard #error, so nothing compiles at all.
  # The name is a promise about API stability across releases, not about
  # maturity — every compositor built on wlroots defines it. Per target rather
  # than project-wide because canvas neither needs nor should see it.
  cpp_args: [
    '-DWLR_USE_UNSTABLE',
    '-DLAVA_CANVAS_ASSETS="' + canvas_assets + '"',
    '-DLAVA_UI_FONTS="' + lava_ui_fonts + '"',
  ],
  override_options: ['warning_level=3'],
  install: true,
)

# Headless: the focus MRU is a vector of ids and needs no compositor.
focus_history_test = executable(
  'focus_history_test',
  ['tests/focus_history_test.cpp', 'src/focus_history.cpp'],
  include_directories: include_directories('src'),
  build_by_default: false,
)
test('focus history', focus_history_test)
