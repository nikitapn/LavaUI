#!/usr/bin/env bash
# Exercise libsecret on a private bus and keyring, never the desktop's real one.
set -euo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
for command in cc pkg-config dbus-run-session gnome-keyring-daemon; do
  command -v "$command" >/dev/null || { echo "Test requires $command" >&2; exit 1; }
done
keyring_test_root="$(mktemp -d /tmp/lavapass-keyring.XXXXXX)"
trap 'rm -rf -- "$keyring_test_root"' EXIT
cc -Wall -Wextra -Werror -I "$repo_root/Sources/CLavaPass/include" \
  "$repo_root/Tests/CLavaPassTests/keyring.c" "$repo_root/Sources/CLavaPass/lava_pass.c" \
  $(pkg-config --cflags --libs libsecret-1) -o "$keyring_test_root/probe"
mkdir -p "$keyring_test_root/config" "$keyring_test_root/data" "$keyring_test_root/control"
XDG_CONFIG_HOME="$keyring_test_root/config" XDG_DATA_HOME="$keyring_test_root/data" \
  GNOME_KEYRING_CONTROL="$keyring_test_root/control" \
  dbus-run-session -- sh -c '
    printf %s public-test-keyring-password |
      gnome-keyring-daemon --unlock --components=secrets --control-directory="$1/control" >"$1/daemon.log" 2>&1
    "$1/probe"
  ' sh "$keyring_test_root"
