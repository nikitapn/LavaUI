#!/usr/bin/env bash
# Put NPRPC where meson and Package.swift look: third-party/nprpc.
#
#   scripts/fetch-nprpc.sh
#
# Prefers, in order:
#   1. NPRPC_ROOT if it already has include/nprpc/nprpc.hpp
#   2. an existing third-party/nprpc
#   3. a sibling checkout at ../nprpc (symlinked in — the development layout)
#   4. a shallow clone of https://github.com/nikitapn/nprpc.git
#
# Only the two submodules the Lava control plane needs (glaze, unordered_dense)
# are initialised. MsQuic / ngtcp2 / BoringSSL stay out: Lava talks shared
# memory, not QUIC.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/lava.sh
source "$here/lib/lava.sh"

dest="$LAVA_ROOT/third-party/nprpc"
url="${LAVA_NPRPC_URL}"
ref="${LAVA_NPRPC_REF}"

# nprpc's .gitmodules lists git@github.com:… — that is an SSH remote, not a
# requirement for a GitHub account, but it does need a deploy key. A VM has
# none. `insteadOf` on the nprpc repo is *not* inherited by the `git clone`
# that creates each submodule (separate process). Rewrite the URLs that
# `submodule init` copied into .git/config, then update.
init_lava_submodules() {
  local root=$1 sm key url
  for sm in third_party/glaze third_party/unordered_dense; do
    if [[ -d $root/$sm && ! -e $root/$sm/.git && ! -f $root/$sm/CMakeLists.txt ]]; then
      rm -rf "$root/$sm"
    fi
  done
  git -C "$root" submodule init third_party/glaze third_party/unordered_dense
  while IFS= read -r key; do
    [[ -n $key ]] || continue
    url="$(git -C "$root" config --get "$key")"
    case "$url" in
      git@github.com:*)
        git -C "$root" config "$key" "https://github.com/${url#git@github.com:}"
        ;;
      ssh://git@github.com/*)
        git -C "$root" config "$key" "https://github.com/${url#ssh://git@github.com/}"
        ;;
    esac
  done < <(git -C "$root" config --name-only --get-regexp \
    '^submodule\.third_party/(glaze|unordered_dense)\.url$' || true)
  lava_git_https -C "$root" submodule update --depth 1 \
    third_party/glaze \
    third_party/unordered_dense
}

# Already usable somewhere meson will find it.
if existing="$(lava_find_nprpc_root)"; then
  if [[ $existing == "$dest" || $existing == "$(readlink -f "$dest" 2>/dev/null || true)" ]]; then
    lava_info "nprpc already at $existing"
    init_lava_submodules "$existing"
    exit 0
  fi
  # Sibling or NPRPC_ROOT: expose it at the canonical path so meson does not
  # need an extra -Dnprpc_root= on a machine that already has the repo.
  if [[ ! -e $dest ]]; then
    mkdir -p "$(dirname "$dest")"
    ln -s "$(realpath --relative-to="$(dirname "$dest")" "$existing")" "$dest"
    lava_info "nprpc: $dest -> $existing"
  fi
  init_lava_submodules "$existing"
  exit 0
fi

# Broken leftover symlink (e.g. rsync of a tree that pointed at ../nprpc).
if [[ -L $dest && ! -e $dest ]]; then
  lava_warn "removing dangling $dest"
  rm -f "$dest"
fi

if [[ -d $dest/.git ]]; then
  lava_info "nprpc clone exists at $dest, fetching $ref"
  git -C "$dest" fetch --depth 1 origin "$ref"
  git -C "$dest" checkout FETCH_HEAD
  init_lava_submodules "$dest"
  exit 0
fi

lava_info "cloning $url ($ref) → $dest"
mkdir -p "$(dirname "$dest")"
git clone --depth 1 --branch "$ref" "$url" "$dest"
init_lava_submodules "$dest"
lava_info "nprpc ready at $dest"
