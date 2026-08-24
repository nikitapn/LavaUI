#!/usr/bin/env bash
# Configure and build NPRPC for Lava's control plane.
#
#   scripts/build-nprpc.sh
#   scripts/build-nprpc.sh --install          # also cmake --install (needs root
#                                             # if the prefix is /usr/local)
#   PREFIX=/opt/nprpc scripts/build-nprpc.sh --install
#
# QUIC, HTTP/3, SSR, JS, tests and the SNI router stay off: the compositor
# only needs shared-memory RPC plus npidl for stub regeneration. System
# OpenSSL and Boost are enough; we do not pull BoringSSL or MsQuic.
#
# That is also why we build into .build_lava_shm rather than nprpc's
# .build_relwith_debinfo: its README points `swift test` at that directory
# and the Swift IntegrationTests need the transports we switch off here.
# Sharing one directory meant the last build to run silently decided
# whether those tests could run.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/lava.sh
source "$here/lib/lava.sh"

do_install=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      sed -n '2,14p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    --install) do_install=1; shift ;;
    *) lava_die "unknown option: $1" ;;
  esac
done

"$here/fetch-nprpc.sh"
root="$(lava_find_nprpc_root)" || lava_die "nprpc sources not found (fetch-nprpc.sh failed?)"

build="${NPRPC_BUILD_DIR:-$root/.build_lava_shm}"
if [[ $build != /* ]]; then
  build="$root/$build"
fi
prefix="${PREFIX:-/usr/local}"

jobs="$(nproc 2>/dev/null || echo 4)"
cxx="$(lava_ensure_cxx)"
cc="$(lava_cc_for_cxx "$cxx")"
lava_info "C++ compiler: $cxx"

# A previous attempt on Ubuntu 24.04 caches /usr/bin/c++ (gcc 13) and then
# every rebuild fails the same way. Wipe if that compiler cannot parse nprpc.
if [[ -f $build/CMakeCache.txt ]]; then
  cached="$(sed -n 's/^CMAKE_CXX_COMPILER:FILEPATH=//p' "$build/CMakeCache.txt" | head -1)"
  if [[ -n $cached ]] && ! lava_cxx_has_deducing_this "$cached"; then
    lava_info "nprpc was configured with $cached (too old) — reconfiguring with $cxx"
    rm -rf "$build"
  fi
fi

if [[ ! -f $build/build.ninja && ! -f $build/Makefile ]]; then
  lava_info "configuring nprpc in $build"
  cmake -G Ninja -S "$root" -B "$build" \
    -DCMAKE_C_COMPILER="$cc" \
    -DCMAKE_CXX_COMPILER="$cxx" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=ON \
    -DNPRPC_BUILD_TOOLS=ON \
    -DNPRPC_ENABLE_TCP=OFF \
    -DNPRPC_ENABLE_HTTP=OFF \
    -DNPRPC_ENABLE_HTTP3=OFF \
    -DNPRPC_ENABLE_WEBSOCKET=OFF \
    -DNPRPC_ENABLE_QUIC=OFF \
    -DNPRPC_ENABLE_SSL=OFF \
    -DNPRPC_ENABLE_SSR=OFF \
    -DNPRPC_BUILD_JS=OFF \
    -DNPRPC_BUILD_ROUTER=OFF \
    -DNPRPC_USE_BORINGSSL=OFF \
    -DNPRPC_BUILD_DEV_DOCKER=OFF \
    -DNPRPC_BUILD_TESTS=OFF
fi

lava_info "building nprpc (-j$jobs)"
cmake --build "$build" -j"$jobs"

# Swift stubs are gitignored in nprpc (nprpc_swift/.gitignore). A fresh
# clone has NPRPC.swift calling ExceptionObjectNotExist with no generated
# nprpc_base.swift. npidl is what we just built.
npidl="$build/npidl/npidl"
if [[ ! -x $npidl ]]; then
  lava_die "npidl missing at $npidl after the nprpc build"
fi
gen="$root/nprpc_swift/Sources/NPRPC/Generated"
mkdir -p "$gen"
lava_info "generating Swift NPRPC stubs → $gen"
"$npidl" --swift \
  "$root/idl/nprpc_base.npidl" \
  "$root/idl/nprpc_nameserver.npidl" \
  --output-dir "$gen"

if [[ $do_install -eq 1 ]]; then
  lava_info "installing nprpc to $prefix"
  if [[ -w $prefix ]] || [[ "$(id -u)" -eq 0 ]]; then
    cmake --install "$build"
  else
    lava_as_root cmake --install "$build"
  fi
  lava_ldconfig || true
fi

libdir="$(lava_find_nprpc_libdir "$root")" \
  || lava_die "build finished but libnprpc.so was not where we looked"
lava_info "libnprpc at $libdir"
