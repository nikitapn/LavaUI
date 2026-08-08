#!/usr/bin/env bash
# Regenerate NPRPC stubs for idl/*.npidl.
#
# Runs npidl on the host — no Docker. The compiler comes out of nprpc's CMake
# build; point NPIDL at another one to switch flavours:
#
#   NPIDL=/path/to/npidl scripts/gen_stubs.sh
#
# Generated files are checked in, so a clone without nprpc still builds
# everything except the control plane itself.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NPRPC_ROOT="${NPRPC_ROOT:-$(cd "$ROOT/.." && pwd)/nprpc}"
NPIDL="${NPIDL:-$NPRPC_ROOT/.build_relwith_debinfo/npidl/npidl}"

if [[ ! -x "$NPIDL" ]]; then
  echo "npidl not found at $NPIDL" >&2
  echo "Build nprpc first, or set NPIDL=/path/to/npidl." >&2
  exit 1
fi

mkdir -p "$ROOT/Sources/LavaIDL"
echo "npidl --swift  →  Sources/LavaIDL"
"$NPIDL" --swift --output-dir "$ROOT/Sources/LavaIDL" "$ROOT/idl/lava.npidl"

# The compositor is C++ and serves the same interface the Swift clients call.
# One IDL, two languages, generated from one command so they cannot drift.
mkdir -p "$ROOT/compositor/src/gen"
echo "npidl --cpp    →  compositor/src/gen"
"$NPIDL" --cpp --output-dir "$ROOT/compositor/src/gen" "$ROOT/idl/lava.npidl"

echo "done"
