#!/usr/bin/env bash
# Rebuild everything that links system libraries, after `pacman -Syu`.
#
#   scripts/after-upgrade.sh
#   scripts/after-upgrade.sh --no-release     # skip build-release and .build/release
#   scripts/after-upgrade.sh --check          # only report broken links, build nothing
#
# Order matters: nprpc first, because both the compositor and the Swift
# client products link libnprpc.so out of .build_lava_shm (nprpc_swift's
# Package.swift prefers it, as meson does).
#
# The Swift build is a full one (every source touched), not an incremental
# one. An upgrade changes system headers under the C module maps — FreeType,
# HarfBuzz, GLib, Vulkan — and SwiftPM does not always notice, which ends in
# either a stale module cache error or, worse, a build that succeeds against
# the old layout. See "Two ways the incremental build will lie to you" in
# AGENTS.md.
#
# A soname bump (poppler does it on most releases) shows up as "not found"
# in the scan before and is gone in the scan after; anything still missing
# at the end makes the script fail.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/lava.sh
source "$here/lib/lava.sh"

release=1
check_only=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      sed -n '2,20p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    --no-release) release=0; shift ;;
    --check) check_only=1; shift ;;
    *) lava_die "unknown option: $1" ;;
  esac
done

cd "$LAVA_ROOT"

meson_dirs=(build)
swift_configs=(debug)
if [[ $release -eq 1 ]]; then
  meson_dirs+=(build-release)
  [[ -d .build/release ]] && swift_configs+=(release)
fi

# Every ELF we built that a system upgrade can break: Swift executables,
# the compositor, and libnprpc itself. Prints "binary: library" per miss.
broken_links() {
  local f
  local -a files=()
  for cfg in "${swift_configs[@]}"; do
    [[ -d .build/$cfg ]] || continue
    while IFS= read -r f; do files+=("$f"); done < <(
      find ".build/$cfg/" -maxdepth 1 -type f -perm -u+x ! -name '*.*' 2>/dev/null)
  done
  for d in "${meson_dirs[@]}"; do
    [[ -x $d/compositor/compositor ]] && files+=("$d/compositor/compositor")
  done
  local root
  if root="$(lava_find_nprpc_root)"; then
    [[ -e $root/.build_lava_shm/libnprpc.so ]] && files+=("$root/.build_lava_shm/libnprpc.so")
  fi
  for f in "${files[@]}"; do
    ldd "$f" 2>/dev/null | awk -v f="$f" '/not found/ { print f ": " $1 }'
  done
}

lava_info "checking for libraries the upgrade removed"
before="$(broken_links)"
if [[ -n $before ]]; then
  printf '%s\n' "$before" | sed 's/^/  /'
else
  lava_info "nothing missing"
fi
[[ $check_only -eq 1 ]] && exit 0

lava_info "── nprpc"
"$here/build-nprpc.sh"

for d in "${meson_dirs[@]}"; do
  if [[ ! -f $d/build.ninja ]]; then
    lava_warn "$d is not a configured meson build, skipping"
    continue
  fi
  lava_info "── meson: $d"
  # ninja re-runs meson itself when meson was upgraded; this is only for
  # when that regeneration fails outright.
  if ! ninja -C "$d"; then
    lava_warn "$d failed, reconfiguring and trying once more"
    meson setup --reconfigure "$d"
    ninja -C "$d"
  fi
done

lava_info "── swift (full rebuild)"
find Sources Tests -name '*.swift' -exec touch {} +
for cfg in "${swift_configs[@]}"; do
  lava_info "swift build -c $cfg"
  swift build -c "$cfg"
done

lava_info "checking links again"
after="$(broken_links)"
if [[ -n $after ]]; then
  printf '%s\n' "$after" | sed 's/^/  /' >&2
  lava_die "still linked against libraries that are gone"
fi
lava_info "done — restart the compositor (and its clients) to run the new build"
