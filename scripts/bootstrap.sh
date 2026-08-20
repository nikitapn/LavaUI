#!/usr/bin/env bash
# Bring a Debian or Arch machine from a git clone to a built compositor
# (and, with Swift, the shell clients).
#
#   scripts/bootstrap.sh                 # deps + nprpc + meson debug + swift
#   scripts/bootstrap.sh --release       # release compositor and clients
#   scripts/bootstrap.sh --deps-only     # just the system packages
#   scripts/bootstrap.sh --no-deps       # packages already installed
#   scripts/bootstrap.sh --no-swift      # C++ compositor only
#   scripts/bootstrap.sh --no-nprpc      # no control plane
#   scripts/bootstrap.sh --check         # scripts/check-env.sh
#
# NPRPC is cloned into third-party/nprpc (or reused from ../nprpc). Meson
# and Package.swift both look there, so a sibling checkout keeps working.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/lava.sh
source "$here/lib/lava.sh"

flavour=debug
do_deps=1
do_swift=1
do_nprpc=1
do_meson=1
do_swift_build=1
yes=0

usage() {
  sed -n '2,16p' "$0" | sed 's/^# \?//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage 0 ;;
    -y|--yes) yes=1; shift ;;
    --release|-r) flavour=release; shift ;;
    --deps-only) do_meson=0; do_swift_build=0; do_nprpc=0; do_swift=0; shift ;;
    --no-deps) do_deps=0; shift ;;
    --no-swift) do_swift=0; do_swift_build=0; shift ;;
    --no-nprpc) do_nprpc=0; shift ;;
    --meson-only) do_swift_build=0; shift ;;
    --check) exec "$here/check-env.sh" ;;
    *) lava_die "unknown option: $1 (see --help)" ;;
  esac
done

cd "$LAVA_ROOT"
lava_export_pkgconfig

if [[ $do_deps -eq 1 ]]; then
  args=()
  [[ $yes -eq 1 ]] && args+=(--yes)
  "$here/install-deps.sh" "${args[@]}"
fi

# Swift on PATH first makes meson pick /opt/swift/usr/bin/clang + ld.gold.
# Keep it off PATH until the SwiftPM step; pass g++-14 to meson by name
# rather than exporting CC/CXX, which would leak into `swift build`.
if [[ $do_swift -eq 1 ]]; then
  "$here/install-swift.sh"
fi

# --no-deps still has to produce wlroots 0.19: first-boot install-deps
# may have failed to clone into a read-only 9p tree.
if [[ $do_meson -eq 1 ]] && ! lava_have_wlroots; then
  lava_info "wlroots >= 0.19 not in pkg-config — building from source"
  "$here/build-wlroots.sh"
  lava_export_pkgconfig
fi

if [[ $do_nprpc -eq 1 ]]; then
  "$here/build-nprpc.sh"
fi

# Ubuntu splits xkbregistry out of libxkbcommon. --no-deps still has to
# pick that up or meson dies at compositor/meson.build xkbregistry.
if [[ $do_meson -eq 1 && $(lava_os) == debian ]]; then
  missing=()
  pkg-config --exists xkbregistry || missing+=(libxkbregistry-dev)
  pkg-config --exists xkbcommon || missing+=(libxkbcommon-dev)
  pkg-config --exists pixman-1 || missing+=(libpixman-1-dev)
  pkg-config --exists wayland-server || missing+=(libwayland-dev)
  pkg-config --exists libsystemd || missing+=(libsystemd-dev)
  pkg-config --exists xrandr || missing+=(libxrandr-dev)
  if [[ ${#missing[@]} -gt 0 ]]; then
    lava_info "installing compositor pkg-config deps: ${missing[*]}"
    export DEBIAN_FRONTEND=noninteractive
    lava_as_root apt-get install -y --no-install-recommends "${missing[@]}"
  fi
fi

if [[ $do_meson -eq 1 ]]; then
  if [[ $flavour == release ]]; then
    build=build-release
    meson_type=release
  else
    build=build
    meson_type=debug
  fi
  cxx="$(lava_ensure_cxx)"
  cc="$(lava_cc_for_cxx "$cxx")"
  nprpc_args=()
  if root="$(lava_find_nprpc_root)"; then
    nprpc_args+=(-Dnprpc_root="$root")
  fi
  # A failed first setup (no wlroots yet) leaves $build/ without build.ninja.
  # meson setup then refuses the directory; wipe and start over.
  # CC/CXX are per-invocation so they cannot leak into the SwiftPM step:
  # Swift always emits Clang flags, and gcc-14 rejects -target / -fblocks.
  if [[ ! -f $build/build.ninja ]]; then
    rm -rf "$build"
    CC="$cc" CXX="$cxx" meson setup "$build" --buildtype="$meson_type" "${nprpc_args[@]}"
  elif [[ ${#nprpc_args[@]} -gt 0 ]]; then
    meson configure "$build" "${nprpc_args[@]}" || true
  fi
  ninja -C "$build"
  lava_info "compositor at $build/compositor/compositor"
fi

if [[ $do_swift_build -eq 1 ]]; then
  if bin="$(lava_swift_bin)"; then
    export PATH="$(dirname "$bin"):$PATH"
  fi
  command -v swift >/dev/null || lava_die "swift not on PATH (scripts/install-swift.sh)"
  lava_use_swift_clang
  if [[ $flavour == release ]]; then
    swift build -c release
  else
    swift build
  fi
  lava_info "swift products in .build/$flavour"
fi

echo
"$here/check-env.sh" || true
lava_info "bootstrap done ($flavour)."
if [[ $do_meson -eq 1 ]]; then
  echo "  compositor: compositor/scripts/dev-run"
  echo "  session:    compositor/scripts/start-lava-compositor"
fi
