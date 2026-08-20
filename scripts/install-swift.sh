#!/usr/bin/env bash
# Install a Swift 6.3+ toolchain if this machine does not already have one.
#
#   scripts/install-swift.sh
#   LAVA_SWIFT_VERSION=6.3.3 scripts/install-swift.sh
#
# Order:
#   1. an existing `swift` on PATH that is already 6.3+
#   2. Arch: the extra/swift-language (or swift) package
#   3. official Ubuntu 24.04 tarball from swift.org, dropped in /opt/swift
#      (root) or ~/.local/opt/swift (user)
#
# The Ubuntu tarball is what Debian 13 and Arch both run: Swift does not
# publish a Debian or Arch build, and 24.04's glibc is new enough for both.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/lava.sh
source "$here/lib/lava.sh"

if lava_swift_at_least 6.3; then
  lava_info "swift $(lava_swift_version) already usable ($(lava_swift_bin))"
  exit 0
fi

os="$(lava_os)"
if [[ $os == arch ]]; then
  for pkg in swift-language swift; do
    if lava_as_root pacman --noconfirm --needed -S "$pkg"; then
      if lava_swift_at_least 6.3; then
        lava_info "swift $(lava_swift_version) from $pkg"
        exit 0
      fi
      lava_warn "$pkg installed but is older than 6.3 — using the official tarball"
      break
    fi
  done
fi

ver="$LAVA_SWIFT_VERSION"
arch="$(uname -m)"
case "$arch" in
  x86_64)  swift_arch="" ;;
  aarch64) swift_arch="-aarch64" ;;
  *) lava_die "no official Swift tarball for $arch" ;;
esac

# https://www.swift.org/install/linux/
name="swift-${ver}-RELEASE-ubuntu24.04${swift_arch}"
url="https://download.swift.org/swift-${ver}-release/ubuntu2404${swift_arch}/swift-${ver}-RELEASE/${name}.tar.gz"

if [[ "$(id -u)" -eq 0 ]]; then
  prefix=/opt
else
  prefix="${HOME:?HOME is unset; cannot install Swift as a non-root user}/.local/opt"
fi
mkdir -p "$prefix"
stamp="$prefix/$name"
if [[ ! -x $stamp/usr/bin/swift ]]; then
  lava_info "downloading Swift $ver ($name)"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  curl --fail --location --progress-bar "$url" -o "$tmp/swift.tar.gz"
  tar -C "$tmp" -xzf "$tmp/swift.tar.gz"
  rm -rf "$stamp"
  mkdir -p "$prefix"
  mv "$tmp/$name" "$stamp"
fi

link="$prefix/swift"
rm -f "$link"
ln -sfn "$name" "$link"

if [[ "$(id -u)" -eq 0 ]]; then
  ln -sfn "$link/usr/bin/swift" /usr/local/bin/swift
  ln -sfn "$link/usr/bin/swiftc" /usr/local/bin/swiftc
else
  mkdir -p "${HOME}/.local/bin"
  ln -sfn "$link/usr/bin/swift" "${HOME}/.local/bin/swift"
  ln -sfn "$link/usr/bin/swiftc" "${HOME}/.local/bin/swiftc"
  lava_info "add ${HOME}/.local/bin to PATH if swift is not found in this shell"
fi

export PATH="$link/usr/bin:$PATH"
if ! lava_swift_at_least 6.3; then
  lava_die "swift still not usable after install"
fi
lava_info "swift $(lava_swift_version) at $link/usr/bin/swift"
