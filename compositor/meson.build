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

protocol_xml = [
  # The shell every ordinary Wayland application speaks: toplevels, popups,
  # the negotiation behind resize and maximize.
  protocol_dir / 'stable/xdg-shell/xdg-shell.xml',
]

protocol_headers = []
foreach xml : protocol_xml
  protocol_headers += custom_target(
    xml.underscorify() + '_server_h',
    input: xml,
    output: '@BASENAME@-protocol.h',
    command: [wayland_scanner, 'server-header', '@INPUT@', '@OUTPUT@'],
  )
endforeach

# Canvas resolves its compiled shaders relative to an assets root it is told.
# A Swift client passes the SwiftPM resource bundle; a compositor has no
# bundle, so the build points it at the source tree. `LAVA_CANVAS_ASSETS` in
# the environment overrides it for an installed binary.
canvas_assets = meson.project_source_root() / 'canvas/Sources/CanvasResources'


executable(
  'compositor',
  'src/main.cpp',
  'src/canvas_surface.cpp',
  protocol_headers,
  dependencies: [
    wlroots,
    dependency('wayland-server'),
    # Keyboards arrive as evdev keycodes; xkbcommon is what turns those into
    # keysyms, and what the keymap sent to every client is built from.
    dependency('xkbcommon'),
    # libdrm supplies the FourCC/modifier vocabulary that canvas and wlroots
    # describe a shared buffer in. Vulkan arrives through canvas.
    dependency('libdrm'),
    # The renderer. Canvas draws the pixels a compositor-side surface shows,
    # and owns the Vulkan device they are exported from.
    canvas_dep,
  ],
  # wlroots guards every header behind this. It is not opt-in extra features:
  # without it `wlr/backend.h` is a hard #error, so nothing compiles at all.
  # The name is a promise about API stability across releases, not about
  # maturity — every compositor built on wlroots defines it. Per target rather
  # than project-wide because canvas neither needs nor should see it.
  cpp_args: [
    '-DWLR_USE_UNSTABLE',
    '-DLAVA_CANVAS_ASSETS="' + canvas_assets + '"',
  ],
  override_options: ['warning_level=3'],
  install: true,
)
