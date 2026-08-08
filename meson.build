project(
  'lava',
  'cpp',
  version: '0.1.0',
  # Level 1 because this tree is not warning-clean at 3 and the compositor,
  # which is, raises its own per target. A global level everything has to meet
  # is a level nobody looks at.
  default_options: ['cpp_std=c++23', 'warning_level=1', 'werror=false'],
)

# Why meson builds canvas at all, when SwiftPM already does.
#
# Canvas has two consumers with nothing in common. Clients are Swift and reach
# it through C++ interop, which only SwiftPM knows how to drive. The compositor
# is C++ linked against wlroots, and dragging SwiftPM into that link is a much
# worse trade than compiling the same sources twice.
#
# So the engine is described once here and once in canvas/Package.swift, and
# both build the same source list from the same tree. Two peers, no
# cross-linking. `canvas/meson.build` names the reason each side needs what it
# needs, so the lists can be kept in step by reading them.
subdir('canvas')
subdir('compositor')
