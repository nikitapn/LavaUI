# Shared helpers for scripts/ under the LavaUI repo. Sourced, not executed.
# shellcheck shell=bash

if [[ -n "${LAVA_LIB_LOADED:-}" ]]; then
  return 0
fi
LAVA_LIB_LOADED=1

LAVA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LAVA_NPRPC_URL="${LAVA_NPRPC_URL:-https://github.com/nikitapn/nprpc.git}"
LAVA_NPRPC_REF="${LAVA_NPRPC_REF:-main}"
LAVA_WLROOTS_VERSION="${LAVA_WLROOTS_VERSION:-0.19.3}"
LAVA_SWIFT_VERSION="${LAVA_SWIFT_VERSION:-6.3.3}"

# ── logging ────────────────────────────────────────────────────────────────

lava_info() { printf 'lava: %s\n' "$*"; }
lava_warn() { printf 'lava: warning: %s\n' "$*" >&2; }
lava_die()  { printf 'lava: %s\n' "$*" >&2; exit 1; }

# ── distro ─────────────────────────────────────────────────────────────────

# debian | arch | unknown
lava_os() {
  if [[ -n "${LAVA_OS:-}" ]]; then
    printf '%s\n' "$LAVA_OS"
    return
  fi
  local id=""
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    id="$(. /etc/os-release && printf '%s\n' "${ID:-}")"
  fi
  case "$id" in
    debian|ubuntu|linuxmint|pop|raspbian|kali) printf 'debian\n' ;;
    arch|manjaro|endeavouros|garuda|artix)     printf 'arch\n' ;;
    *)
      if command -v apt-get >/dev/null 2>&1; then
        printf 'debian\n'
      elif command -v pacman >/dev/null 2>&1; then
        printf 'arch\n'
      else
        printf 'unknown\n'
      fi
      ;;
  esac
}

lava_as_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    lava_die "need root to run: $*"
  fi
}

# systemd units and some sudoers configs put /usr/sbin off PATH. Debian
# installs ldconfig there, so a bare `ldconfig` is a "command not found"
# even when we are root.
lava_ldconfig() {
  local bin
  for bin in /usr/sbin/ldconfig /sbin/ldconfig ldconfig; do
    if command -v "$bin" >/dev/null 2>&1 || [[ -x $bin ]]; then
      lava_as_root "$bin" "$@"
      return 0
    fi
  done
  lava_warn "ldconfig not found; you may need to set LD_LIBRARY_PATH for /usr/local/lib"
}

# nprpc's npidl uses C++23 explicit object parameters (`this Self&`).
# GCC 13 (Ubuntu 24.04's default `g++`) does not parse that; 14+ does.
lava_cxx_has_deducing_this() {
  local cxx=$1
  command -v "$cxx" >/dev/null 2>&1 || return 1
  echo 'struct S { auto f(this S& self) { return 0; } }; int main(){ S s; return s.f(); }' \
    | "$cxx" -std=c++23 -x c++ - -o /dev/null >/dev/null 2>&1
}

# Prints the compiler to use for nprpc / meson. Installs g++-14 on Debian
# family when the default one is too old (the Ubuntu 24.04 VM case).
lava_ensure_cxx() {
  local c
  for c in ${CXX:-} g++-14 clang++-18 clang++ c++ g++; do
    [[ -n $c ]] || continue
    if lava_cxx_has_deducing_this "$c"; then
      command -v "$c"
      return 0
    fi
  done
  if [[ $(lava_os) == debian ]]; then
    lava_info "default C++ compiler cannot parse C++23 'this Self&' — installing g++-14"
    export DEBIAN_FRONTEND=noninteractive
    lava_as_root apt-get install -y --no-install-recommends g++-14 gcc-14
    if lava_cxx_has_deducing_this g++-14; then
      command -v g++-14
      return 0
    fi
  fi
  lava_die "need g++-14 or clang 17+ (nprpc uses C++23 explicit object parameters). Ubuntu 24.04: apt install g++-14"
}

# Matching C compiler for a C++ driver (g++-14 → gcc-14).
lava_cc_for_cxx() {
  local cxx=$1 base
  base="$(basename "$cxx")"
  case "$base" in
    g++-*) command -v "gcc-${base#g++-}" 2>/dev/null || command -v gcc ;;
    clang++-*) command -v "clang-${base#clang++-}" 2>/dev/null || command -v clang ;;
    clang++) command -v clang ;;
    *) command -v gcc || command -v cc ;;
  esac
}

# SwiftPM always passes Clang flags (-target, -fblocks) to C/C++ compiles.
# gcc-14 — what meson and nprpc need — rejects those. Point CC/CXX at the
# clang sitting next to `swift` so a leftover gcc from the meson step cannot
# leak into `swift build` (CPulse, Yoga, nprpc_bridge all die the same way).
lava_use_swift_clang() {
  local bin dir clang cxx
  bin="$(lava_swift_bin || true)"
  if [[ -n $bin ]]; then
    dir="$(dirname "$bin")"
    if [[ -x $dir/clang ]]; then
      export CC="$dir/clang"
      if [[ -x $dir/clang++ ]]; then
        export CXX="$dir/clang++"
      else
        export CXX="$dir/clang"
      fi
      lava_info "SwiftPM C/C++ compiler: $CC"
      return 0
    fi
  fi
  if clang="$(command -v clang 2>/dev/null)"; then
    export CC="$clang"
    cxx="$(command -v clang++ 2>/dev/null || true)"
    export CXX="${cxx:-$clang}"
    lava_info "SwiftPM C/C++ compiler: $CC"
    return 0
  fi
  unset CC CXX
  lava_warn "no clang next to swift; SwiftPM C/C++ compile will fail if CC is gcc"
}

# ── pkg-config search path (picks up a /usr/local wlroots / nprpc) ─────────

lava_export_pkgconfig() {
  # Always prepend: a source-built wlroots lands here, and the directory
  # may not exist until after scripts/build-wlroots.sh.
  local extras=() d
  for d in \
    /usr/local/lib/pkgconfig \
    /usr/local/lib64/pkgconfig \
    /usr/local/lib/x86_64-linux-gnu/pkgconfig \
    /usr/local/lib/aarch64-linux-gnu/pkgconfig
  do
    extras+=("$d")
  done
  local joined
  joined="$(IFS=:; echo "${extras[*]}")"
  export PKG_CONFIG_PATH="${joined}${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
}

# GitHub SSH remotes (nprpc's .gitmodules) fail in a VM / CI with no deploy
# key. insteadOf on the superproject's *local* config is not inherited by the
# `git clone` that creates a submodule — the child only sees env and -c.
# GIT_CONFIG_* is inherited. Call this just around submodule fetches.
lava_git_https() {
  # GIT_CONFIG_COUNT may already be set by an outer git; append if so.
  local n="${GIT_CONFIG_COUNT:-0}"
  export GIT_CONFIG_COUNT=$((n + 1))
  export GIT_CONFIG_KEY_${n}="url.https://github.com/.insteadOf"
  export GIT_CONFIG_VALUE_${n}="git@github.com:"
  git "$@"
}

# ── nprpc locations ────────────────────────────────────────────────────────
# Same order meson and Package.swift use: explicit env, third-party clone,
# then a sibling checkout at ../nprpc.

lava_nprpc_candidates() {
  local out=()
  if [[ -n "${NPRPC_ROOT:-}" ]]; then
    out+=("$NPRPC_ROOT")
  fi
  out+=("$LAVA_ROOT/third-party/nprpc")
  out+=("$(dirname "$LAVA_ROOT")/nprpc")
  printf '%s\n' "${out[@]}"
}

lava_find_nprpc_root() {
  # Iterate an array, not a pipe: the caller returns on the first hit, and
  # a leftover printf would then SIGPIPE under `set -o pipefail`.
  local p
  local -a candidates=()
  if [[ -n ${NPRPC_ROOT:-} ]]; then
    candidates+=("$NPRPC_ROOT")
  fi
  candidates+=("$LAVA_ROOT/third-party/nprpc")
  candidates+=("$(dirname "$LAVA_ROOT")/nprpc")
  for p in "${candidates[@]}"; do
    if [[ -f $p/include/nprpc/nprpc.hpp ]]; then
      printf '%s\n' "$p"
      return 0
    fi
  done
  return 1
}

# Directory that actually contains libnprpc.so, or empty.
lava_find_nprpc_libdir() {
  local root="${1:-}"
  [[ -n $root ]] || root="$(lava_find_nprpc_root || true)"
  [[ -n $root ]] || return 1
  local d
  for d in \
    "$root/.build_lava_shm" \
    "$root/.build_relwith_debinfo" \
    "$root/.build_release" \
    "$root/.build" \
    "$root/lib" \
    "$root/lib64" \
    "$root/lib/x86_64-linux-gnu" \
    "$root/lib/aarch64-linux-gnu"
  do
    if [[ -e $d/libnprpc.so || -e $d/libnprpc.so.1 ]]; then
      printf '%s\n' "$d"
      return 0
    fi
  done
  return 1
}

lava_find_npidl() {
  local root libdir
  if [[ -n "${NPIDL:-}" && -x $NPIDL ]]; then
    printf '%s\n' "$NPIDL"
    return 0
  fi
  root="$(lava_find_nprpc_root || true)"
  [[ -n $root ]] || return 1
  local c
  for c in \
    "$root/.build_lava_shm/npidl/npidl" \
    "$root/.build_relwith_debinfo/npidl/npidl" \
    "$root/.build_release/npidl/npidl" \
    "$root/.build/npidl/npidl" \
    "$root/bin/npidl"
  do
    if [[ -x $c ]]; then
      printf '%s\n' "$c"
      return 0
    fi
  done
  return 1
}

# ── package lists ──────────────────────────────────────────────────────────

# Read packaging/deps/$1.txt into the named array (required) and optional array.
# Strips comments and blank lines. Optional lines start with '?'.
lava_read_packages() {
  local file="$LAVA_ROOT/packaging/deps/$1"
  local -n _req=$2
  local -n _opt=$3
  _req=()
  _opt=()
  [[ -f $file ]] || lava_die "missing package list: $file"
  local line
  while IFS= read -r line || [[ -n $line ]]; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z $line ]] && continue
    if [[ $line == \?* ]]; then
      _opt+=("${line#?}")
    else
      _req+=("$line")
    fi
  done <"$file"
}

# ── wlroots ────────────────────────────────────────────────────────────────

lava_have_wlroots() {
  lava_export_pkgconfig
  pkg-config --exists 'wlroots-0.19 >= 0.19.0' 2>/dev/null \
    || pkg-config --exists 'wlroots >= 0.19.0' 2>/dev/null
}

# ── swift ──────────────────────────────────────────────────────────────────

lava_swift_bin() {
  if [[ -n "${LAVA_SWIFT:-}" && -x $LAVA_SWIFT ]]; then
    printf '%s\n' "$LAVA_SWIFT"
    return 0
  fi
  # cloud-init / systemd run with set -u and no HOME. Expanding $HOME in the
  # candidate list would abort before we ever look at /opt/swift.
  local c
  local candidates=()
  if c="$(command -v swift 2>/dev/null)"; then
    candidates+=("$c")
  fi
  candidates+=(/opt/swift/usr/bin/swift)
  if [[ -n ${HOME:-} ]]; then
    candidates+=("$HOME/.local/opt/swift/usr/bin/swift")
  fi
  for c in "${candidates[@]}"; do
    if [[ -n $c && -x $c ]]; then
      printf '%s\n' "$c"
      return 0
    fi
  done
  return 1
}

# Prints major.minor.patch (best effort) or empty.
lava_swift_version() {
  local bin
  bin="$(lava_swift_bin || true)"
  [[ -n $bin ]] || return 1
  "$bin" --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1
}

# 0 if installed Swift is at least $1 (e.g. 6.3).
lava_swift_at_least() {
  local have want=$1
  have="$(lava_swift_version || true)"
  [[ -n $have ]] || return 1
  printf '%s\n%s\n' "$want" "$have" | sort -C -V
}
