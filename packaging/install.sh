#!/usr/bin/env bash
# Install Lava apps so LavaLauncher (and any freedesktop launcher) can find them.
#
#   packaging/install.sh              # every app in apps.conf
#   packaging/install.sh LavaTerm LavaSpotify
#   packaging/install.sh --list
#   packaging/install.sh --no-default # do not become the default file handler
#   LAVA_BIN_DIR=.build/debug packaging/install.sh
#
# An app that declares a MimeType in apps.conf is also registered as the
# default application for every type it lists. That is the point of declaring
# them — an image viewer nothing opens images with is not installed, it is
# merely present — and it is reported line by line rather than done quietly.
# --no-default installs the entry without touching any association.
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
  # The header block, up to but not including `set -euo pipefail`. Derived
  # rather than a hard-coded line range, which is what went stale the first
  # time a line was added to it.
  sed -n '2,/^set -euo pipefail/p' "$0" | sed '$d' | sed 's/^# \?//'
  exit "${1:-0}"
}

# Whether to claim the declared MIME types. On by default; see the header.
set_default=1

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
mimetypes=()

load_catalog() {
  products=(); names=(); generics=(); comments=()
  icons=(); categories=(); keywords=(); wmclasses=(); clients=(); mimetypes=()
  local line product
  while IFS= read -r line || [[ -n $line ]]; do
    [[ -z $line || $line == \#* ]] && continue
    # `mime` is the optional tenth field; rows written before it existed
    # leave it empty, which is exactly what they mean.
    IFS='|' read -r product name generic comment icon cats keys wm client mime <<<"$line"
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
    mimetypes+=("${mime:-}")
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
  local icon=$6 cats=$7 keys=$8 wm=$9 bin=${10} client=${11} mime=${12:-}

  local exec_line try_line mime_line=""
  try_line="TryExec=$bin"
  if [[ $client == 1 ]]; then
    exec_line="Exec=env LAVA_CLIENT=1 $bin"
  else
    exec_line="Exec=$bin"
  fi
  # A handler needs somewhere for the file to go. `%F` only where a MimeType
  # was declared: an app that takes no arguments should not carry a field
  # code, and some launchers reject an Exec that has one it cannot fill.
  if [[ -n $mime ]]; then
    exec_line="$exec_line %F"
    mime_line=$'\n'"MimeType=$mime"
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
StartupNotify=false$mime_line
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
  local mime=${mimetypes[$i]}

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
    "$icon" "$cats" "$keys" "$wm" "$bin" "$client" "$mime"

  cp -f "$icon_src" "$icons_dir/$icon.svg"
  chmod 644 "$icons_dir/$icon.svg"
  ln -sfn "$bin" "$local_bin/$product"

  echo "  $product"
  echo "    desktop  $apps_dir/$product.desktop"
  echo "    icon     $icons_dir/$icon.svg"
  echo "    bin      $local_bin/$product -> $bin"

  register_defaults "$product" "$mime"
}

# Makes $product the default application for each type it declares.
#
# Per type, not once for the app: `xdg-mime default` takes a list but writes
# one mimeapps.list line each, and a type that is silently skipped is a file
# that still opens in something else — which is how "it only works for JPEG"
# happens. Reported individually so a partial result is visible rather than
# guessed at.
register_defaults() {
  local product=$1 mime=$2
  [[ -n $mime && $set_default == 1 ]] || return 0

  if ! command -v xdg-mime >/dev/null 2>&1; then
    echo "    default  skipped: xdg-mime not on PATH (install xdg-utils)" >&2
    return 0
  fi

  # No `update-desktop-database` here: the run already ends with one, and the
  # order does not matter. `xdg-mime default` writes ~/.config/mimeapps.list,
  # which is consulted ahead of the mimeinfo cache — the cache only decides who
  # *else* appears under "Open With".
  local type claimed=()
  # Trailing ';' is required by the spec and leaves an empty final field.
  local IFS=';'
  for type in $mime; do
    [[ -n $type ]] || continue
    if xdg-mime default "$product.desktop" "$type" 2>/dev/null; then
      claimed+=("$type")
    else
      echo "    default  failed for $type" >&2
    fi
  done
  unset IFS

  if [[ ${#claimed[@]} -gt 0 ]]; then
    echo "    default  ${claimed[*]}"
  fi
}

# ─── Main ───────────────────────────────────────────────────────────────────

if [[ ${1:-} == -h || ${1:-} == --help ]]; then usage 0; fi
if [[ ${1:-} == --list ]]; then list_apps; exit 0; fi

# Strip flags out of the product list before anything reads it.
args=()
for arg in "$@"; do
  case $arg in
    --no-default) set_default=0 ;;
    --set-default) set_default=1 ;;
    # Already the behaviour with no products named; kept so the spelling that
    # worked before this flag parser existed still does.
    --all) ;;
    -*) echo "unknown option: $arg" >&2; usage 1 ;;
    *) args+=("$arg") ;;
  esac
done
set -- ${args[@]+"${args[@]}"}

load_catalog

targets=("$@")
if [[ ${#targets[@]} -eq 0 ]]; then
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
