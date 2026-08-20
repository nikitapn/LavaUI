#!/usr/bin/env bash
# Build wlroots 0.19 from source into /usr/local. Used when the distro still
# ships 0.17/0.18 (Debian 13, Ubuntu 24.04). Arch has wlroots0.19 and skips
# this. Override the tag with LAVA_WLROOTS_VERSION.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/lava.sh
source "$here/lib/lava.sh"

lava_export_pkgconfig
if lava_have_wlroots; then
  lava_info "wlroots >= 0.19 already present, nothing to build"
  exit 0
fi

# --no-deps / a VM restart skips install-deps. Pull the wrap-build extras
# here so a missing libxml2 does not fail meson after the wayland wrap.
if [[ $(lava_os) == debian ]]; then
  extra=(); _ignore=()
  lava_read_packages debian-wlroots-build.txt extra _ignore
  if [[ ${#extra[@]} -gt 0 ]]; then
    export DEBIAN_FRONTEND=noninteractive
    lava_as_root apt-get install -y --no-install-recommends "${extra[@]}"
  fi
fi

tag="$LAVA_WLROOTS_VERSION"
url="https://gitlab.freedesktop.org/wlroots/wlroots.git"
# The VM 9p-mounts the repo read-only at first boot. Cloning into
# $LAVA_ROOT/third-party/wlroots then fails, install-deps exits, and
# bootstrap --no-deps never retries. Prefer a writable cache.
src="${LAVA_WLROOTS_SRC:-}"
if [[ -z $src ]]; then
  if mkdir -p "$LAVA_ROOT/third-party" 2>/dev/null && [[ -w $LAVA_ROOT/third-party ]]; then
    src="$LAVA_ROOT/third-party/wlroots"
  else
    src="/var/tmp/lava-wlroots-$tag"
  fi
fi

if [[ ! -d $src/.git ]]; then
  lava_info "cloning wlroots $tag → $src"
  mkdir -p "$(dirname "$src")"
  git clone --depth 1 --branch "$tag" "$url" "$src"
fi

build="$src/build"
# Debian/Ubuntu meson defaults to wrap-mode=nodownload. wlroots 0.19 wants
# wayland-protocols newer than Noble's 1.34 and would wrap-fetch it; without
# this, setup dies at meson.build:96 with "Automatic wrap-based subproject
# downloading is disabled". A failed setup leaves $build/ without build.ninja.
if [[ ! -f $build/build.ninja ]]; then
  rm -rf "$build"
  meson setup "$build" "$src" \
    --prefix=/usr/local \
    --buildtype=release \
    --wrap-mode=default \
    -Dexamples=false
fi
ninja -C "$build"
lava_as_root ninja -C "$build" install
if [[ -d /etc/ld.so.conf.d ]]; then
  echo /usr/local/lib | lava_as_root tee /etc/ld.so.conf.d/lava-local.conf >/dev/null
  echo /usr/local/lib64 | lava_as_root tee -a /etc/ld.so.conf.d/lava-local.conf >/dev/null
  lava_ldconfig
fi

lava_export_pkgconfig
if ! lava_have_wlroots; then
  lava_die "wlroots installed but pkg-config still cannot see wlroots-0.19. Set PKG_CONFIG_PATH to /usr/local/lib/pkgconfig"
fi
lava_info "wlroots $(pkg-config --modversion wlroots-0.19 2>/dev/null || pkg-config --modversion wlroots) installed to /usr/local"
