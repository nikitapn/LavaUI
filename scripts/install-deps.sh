#!/usr/bin/env bash
# Install the system packages LavaUI, the compositor and NPRPC need.
#
#   scripts/install-deps.sh              # detect Debian/Arch, install
#   scripts/install-deps.sh --yes        # no apt/pacman prompts
#   scripts/install-deps.sh --list       # print the lists and exit
#   scripts/install-deps.sh --vm-host    # also qemu + xorriso (for scripts/vm-*)
#   scripts/install-deps.sh --no-wlroots # skip a from-source wlroots 0.19
#
# Does not install Swift — that is scripts/install-swift.sh, because the
# toolchain is not a distro package on Debian and is optional if you only
# want the C++ compositor.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/lava.sh
source "$here/lib/lava.sh"

yes=0
list_only=0
vm_host=0
do_wlroots=1

usage() {
  sed -n '2,14p' "$0" | sed 's/^# \?//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage 0 ;;
    -y|--yes) yes=1; shift ;;
    --list) list_only=1; shift ;;
    --vm-host) vm_host=1; shift ;;
    --no-wlroots) do_wlroots=0; shift ;;
    *) lava_die "unknown option: $1 (see --help)" ;;
  esac
done

os="$(lava_os)"
if [[ $os == unknown ]]; then
  lava_die "unsupported distro (need Debian/Ubuntu or Arch)"
fi

req=(); opt=()
case "$os" in
  debian) lava_read_packages debian.txt req opt ;;
  arch)   lava_read_packages arch.txt req opt ;;
esac

if [[ $list_only -eq 1 ]]; then
  echo "# $os required"
  printf '%s\n' "${req[@]}"
  echo "# $os optional"
  printf '%s\n' "${opt[@]}"
  exit 0
fi

install_debian() {
  export DEBIAN_FRONTEND=noninteractive
  local apt=(apt-get)
  [[ $yes -eq 1 ]] && apt=(apt-get -y)
  lava_as_root "${apt[@]}" update
  lava_as_root "${apt[@]}" install --no-install-recommends "${req[@]}"
  local p
  for p in "${opt[@]}"; do
    if lava_as_root "${apt[@]}" install --no-install-recommends "$p"; then
      lava_info "optional package $p installed"
    else
      lava_warn "optional package $p not available (will build wlroots if needed)"
    fi
  done
  lava_export_pkgconfig
  if [[ $do_wlroots -eq 1 ]] && ! lava_have_wlroots; then
    extra=(); _ignore=()
    lava_read_packages debian-wlroots-build.txt extra _ignore
    if [[ ${#extra[@]} -gt 0 ]]; then
      lava_as_root "${apt[@]}" install --no-install-recommends "${extra[@]}" || \
        lava_warn "some wlroots build deps missing; source build may fail"
    fi
  fi
  if [[ $vm_host -eq 1 ]]; then
    lava_as_root "${apt[@]}" install --no-install-recommends \
      qemu-system-x86 qemu-utils xorriso
  fi
}

install_arch() {
  local pac=(pacman)
  if [[ $yes -eq 1 ]]; then
    pac=(pacman --noconfirm --needed)
  else
    pac=(pacman --needed)
  fi
  lava_as_root "${pac[@]}" -Sy
  lava_as_root "${pac[@]}" -S "${req[@]}"
  local p
  for p in "${opt[@]}"; do
    lava_as_root "${pac[@]}" -S "$p" && lava_info "optional package $p installed" \
      || lava_warn "optional package $p not available"
  done
  if [[ $vm_host -eq 1 ]]; then
    lava_as_root "${pac[@]}" -S qemu-system-x86 qemu-img xorriso
  fi
}

lava_info "installing $os packages"
case "$os" in
  debian) install_debian ;;
  arch)   install_arch ;;
esac

lava_export_pkgconfig

if [[ $do_wlroots -eq 1 ]] && ! lava_have_wlroots; then
  lava_info "wlroots >= 0.19 not in pkg-config — building $LAVA_WLROOTS_VERSION from source"
  "$here/build-wlroots.sh"
elif lava_have_wlroots; then
  lava_info "wlroots $(pkg-config --modversion wlroots-0.19 2>/dev/null \
    || pkg-config --modversion wlroots) ready"
fi

lava_info "system packages installed"
