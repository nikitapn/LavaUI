#!/usr/bin/env bash
# Install Lava apps so LavaLauncher (and any freedesktop launcher) can find them.
#
#   packaging/install.sh              # every app in apps.conf
#   packaging/install.sh LavaTerm LavaSpotify
#   packaging/install.sh --list
#   LAVA_BIN_DIR=.build/debug packaging/install.sh
#
# For each product:
#   ~/.local/share/applications/<product>.desktop
#   ~/.local/share/icons/hicolor/scalable/apps/<icon>.svg
#   ~/.local/bin/<product>  →  binary (symlink)
#
# Default binary root is this repo's release build. Override with LAVA_BIN_DIR
# (absolute or relative to the repo) when installing a debug tree.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"
conf="$here/apps.conf"
icons_src="$here/icons"

bin_root="${LAVA_BIN_DIR:-$repo/.build/release}"
if [[ $bin_root != /* ]]; then
  bin_root="$repo/$bin_root"
fi

apps_dir="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
icons_dir="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/scalable/apps"
local_bin="${HOME}/.local/bin"

usage() {
  sed -n '2,18p' "$0" | sed 's/^# \?//'
  exit "${1:-0}"
}

# ─── Catalog ────────────────────────────────────────────────────────────────

# Read apps.conf into parallel arrays. Declared at top level so install_one can
# see them under `set -u`.
products=()
names=()
generics=()
comments=()
icons=()
categories=()
keywords=()
wmclasses=()
clients=()

load_catalog() {
  products=(); names=(); generics=(); comments=()
  icons=(); categories=(); keywords=(); wmclasses=(); clients=()
  local line product
  while IFS= read -r line || [[ -n $line ]]; do
    [[ -z $line || $line == \#* ]] && continue
    IFS='|' read -r product name generic comment icon cats keys wm client <<<"$line"
    [[ -n $product ]] || continue
    products+=("$product")
    names+=("$name")
    generics+=("$generic")
    comments+=("$comment")
    icons+=("$icon")
    categories+=("$cats")
    keywords+=("$keys")
    wmclasses+=("$wm")
    clients+=("$client")
  done <"$conf"
}

index_of() {
  local want=$1 i
  for i in "${!products[@]}"; do
    if [[ ${products[$i]} == "$want" ]]; then
      echo "$i"
      return 0
    fi
  done
  return 1
}

list_apps() {
  load_catalog
  printf '%-14s  %-12s  %s\n' PRODUCT ICON CLIENT
  local i
  for i in "${!products[@]}"; do
    printf '%-14s  %-12s  %s\n' \
      "${products[$i]}" "${icons[$i]}" \
      "$([[ ${clients[$i]} == 1 ]] && echo client || echo windowed)"
  done
}

# ─── Install one ────────────────────────────────────────────────────────────

write_desktop() {
  local path=$1 product=$2 name=$3 generic=$4 comment=$5
  local icon=$6 cats=$7 keys=$8 wm=$9 bin=${10} client=${11}

  local exec_line try_line
  try_line="TryExec=$bin"
  if [[ $client == 1 ]]; then
    exec_line="Exec=env LAVA_CLIENT=1 $bin"
  else
    exec_line="Exec=$bin"
  fi

  cat >"$path" <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=$name
GenericName=$generic
Comment=$comment
$exec_line
$try_line
Icon=$icon
Terminal=false
Categories=$cats
Keywords=$keys
StartupWMClass=$wm
StartupNotify=false
EOF
  chmod 644 "$path"
}

install_one() {
  local product=$1
  local i
  i="$(index_of "$product")" || {
    echo "unknown app: $product (see packaging/install.sh --list)" >&2
    return 1
  }

  local name=${names[$i]}
  local generic=${generics[$i]}
  local comment=${comments[$i]}
  local icon=${icons[$i]}
  local cats=${categories[$i]}
  local keys=${keywords[$i]}
  local wm=${wmclasses[$i]}
  local client=${clients[$i]}

  local bin="$bin_root/$product"
  if [[ ! -x $bin ]]; then
    # SwiftPM may nest under a triple; accept that layout too.
    local nested
    nested="$(echo "$bin_root"/../x86_64-unknown-linux-gnu/*/../"$product" \
      2>/dev/null | head -1 || true)"
    # Prefer the well-known symlink SwiftPM puts at .build/release/<product>.
    if [[ ! -x $bin && -x $repo/.build/release/$product ]]; then
      bin="$repo/.build/release/$product"
    elif [[ ! -x $bin ]]; then
      # Resolve through release symlink target if present.
      local resolved
      resolved="$(readlink -f "$repo/.build/release/$product" 2>/dev/null || true)"
      if [[ -n $resolved && -x $resolved ]]; then
        bin=$resolved
      fi
    fi
  fi
  # Canonicalise.
  if [[ -e $bin ]]; then
    bin="$(readlink -f "$bin")"
  fi
  if [[ ! -x $bin ]]; then
    echo "skip $product: no executable at $bin_root/$product" >&2
    echo "  build:  swift build -c release --product $product" >&2
    return 1
  fi

  local icon_src="$icons_src/$icon.svg"
  if [[ ! -f $icon_src ]]; then
    echo "skip $product: missing icon $icon_src" >&2
    return 1
  fi

  mkdir -p "$apps_dir" "$icons_dir" "$local_bin"

  write_desktop \
    "$apps_dir/$product.desktop" \
    "$product" "$name" "$generic" "$comment" \
    "$icon" "$cats" "$keys" "$wm" "$bin" "$client"

  cp -f "$icon_src" "$icons_dir/$icon.svg"
  chmod 644 "$icons_dir/$icon.svg"
  ln -sfn "$bin" "$local_bin/$product"

  echo "  $product"
  echo "    desktop  $apps_dir/$product.desktop"
  echo "    icon     $icons_dir/$icon.svg"
  echo "    bin      $local_bin/$product -> $bin"
}

# ─── Main ───────────────────────────────────────────────────────────────────

if [[ ${1:-} == -h || ${1:-} == --help ]]; then usage 0; fi
if [[ ${1:-} == --list ]]; then list_apps; exit 0; fi

load_catalog

targets=("$@")
if [[ ${#targets[@]} -eq 0 || ${1:-} == --all ]]; then
  targets=("${products[@]}")
fi

echo "installing into XDG dirs (bin root: $bin_root)"
failed=0
for product in "${targets[@]}"; do
  install_one "$product" || failed=$((failed + 1))
done

if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -f -t \
    "${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor" 2>/dev/null || true
fi
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "$apps_dir" 2>/dev/null || true
fi

if [[ $failed -gt 0 ]]; then
  echo "done with $failed error(s)" >&2
  exit 1
fi
echo "done."
