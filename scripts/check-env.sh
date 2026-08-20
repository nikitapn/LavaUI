#!/usr/bin/env bash
# Print what a Lava build would find on this machine. Exit 1 if a required
# piece is missing (compiler, meson, wlroots, the canvas pkg-config deps).
# NPRPC and Swift are reported but do not fail the check: windowed LavaUI
# builds without either, and the compositor builds without the control plane.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/lava.sh
source "$here/lib/lava.sh"

lava_export_pkgconfig

fail=0
warn=0

have() {
  local label=$1
  shift
  if "$@" >/dev/null 2>&1; then
    printf '  ok    %s\n' "$label"
    return 0
  fi
  printf '  MISS  %s\n' "$label"
  fail=$((fail + 1))
  return 1
}

soft() {
  local label=$1
  shift
  if "$@" >/dev/null 2>&1; then
    printf '  ok    %s\n' "$label"
    return 0
  fi
  printf '  ----  %s\n' "$label"
  warn=$((warn + 1))
  return 1
}

pkg() {
  local name=$1
  if pkg-config --exists "$name" 2>/dev/null; then
    printf '%s %s' "$name" "$(pkg-config --modversion "$name" 2>/dev/null || echo '?')"
    return 0
  fi
  return 1
}

echo "Lava environment  ($LAVA_ROOT, $(lava_os))"
echo

echo "toolchain"
have "c++ ($(command -v c++ 2>/dev/null || echo missing))" command -v c++
if cxx="$(command -v "${CXX:-g++-14}" 2>/dev/null || command -v c++)"; then
  if lava_cxx_has_deducing_this "$cxx"; then
    have "C++23 this Self& ($cxx)" true
  else
    have "C++23 this Self& ($cxx is too old; need g++-14)" false
  fi
fi
have "meson ($(meson --version 2>/dev/null || echo missing))" command -v meson
have "ninja ($(ninja --version 2>/dev/null || echo missing))" command -v ninja
have "cmake ($(cmake --version 2>/dev/null | head -1 || echo missing))" command -v cmake
have "pkg-config" command -v pkg-config
have "git" command -v git
if bin="$(lava_swift_bin)"; then
  soft "swift $(lava_swift_version) ($bin)" true
  if ! lava_swift_at_least 6.3; then
    printf '        (need 6.3+ for nprpc_swift / LavaClient)\n'
  fi
else
  soft "swift 6.3+  (scripts/install-swift.sh)" false
fi
echo

echo "canvas (pkg-config)"
for name in vulkan freetype2 harfbuzz glfw3 x11 gio-2.0 dbusmenu-glib-0.4 \
            librsvg-2.0 cairo libdrm; do
  if ver="$(pkg "$name")"; then
    have "$ver" true
  else
    have "$name" false
  fi
done
if [[ -e /usr/lib/libboost_stacktrace_basic.so \
   || -e /usr/lib64/libboost_stacktrace_basic.so \
   || -e /usr/local/lib/libboost_stacktrace_basic.so ]]; then
  have "libboost_stacktrace_basic" true
else
  have "libboost_stacktrace_basic" false
fi
echo

echo "compositor"
if lava_have_wlroots; then
  have "wlroots $(pkg-config --modversion wlroots-0.19 2>/dev/null \
    || pkg-config --modversion wlroots)" true
else
  have "wlroots >= 0.19  (scripts/build-wlroots.sh)" false
fi
for name in wayland-server xkbcommon xkbregistry pixman-1 libsystemd; do
  if ver="$(pkg "$name")"; then
    have "$ver" true
  else
    have "$name" false
  fi
done
echo

echo "nprpc (optional — control plane)"
if root="$(lava_find_nprpc_root)"; then
  soft "sources $root" true
  if libdir="$(lava_find_nprpc_libdir "$root")"; then
    soft "libnprpc $libdir" true
  else
    soft "libnprpc.so  (scripts/build-nprpc.sh)" false
  fi
  if npidl="$(lava_find_npidl)"; then
    soft "npidl $npidl" true
  else
    soft "npidl" false
  fi
else
  soft "sources  (scripts/fetch-nprpc.sh or a ../nprpc checkout)" false
fi
echo

if [[ $fail -gt 0 ]]; then
  echo "missing $fail required item(s). Run scripts/install-deps.sh" >&2
  exit 1
fi
if [[ $warn -gt 0 ]]; then
  echo "ready for a windowed / no-control-plane build. $warn optional item(s) unset."
else
  echo "ready."
fi
