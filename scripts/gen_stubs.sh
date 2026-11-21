#!/usr/bin/env bash
# Regenerate C++ and Swift declarations for idl/*.npidl.
#
# Runs npidl on the host — no Docker. The compiler comes out of nprpc's CMake
# build; point NPIDL at another one to switch flavours:
#
#   NPIDL=/path/to/npidl scripts/gen_stubs.sh
#
# The RPC output is gitignored, and this is what produces it: a fresh checkout
# has no Sources/LavaIDL and no compositor/src/gen until this has run.
# `scripts/bootstrap.sh` runs it in the right place; run it by hand after every
# edit to an IDL file.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/lava.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/lava.sh"

if [[ -z "${NPIDL:-}" ]]; then
  NPIDL="$(lava_find_npidl || true)"
fi

if [[ ! -x "${NPIDL:-}" ]]; then
  echo "npidl not found. Build nprpc (scripts/build-nprpc.sh) or set NPIDL=" >&2
  echo "Looked in third-party/nprpc and ../nprpc." >&2
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

# The file index (indexer/) is a second interface in its own module,
# `lava.index`. Its Swift stubs land beside the compositor's in LavaIDL, which
# is where a client already looks; the C++ ones are the daemon's own.
echo "npidl --swift  →  Sources/LavaIDL (index)"
"$NPIDL" --swift --output-dir "$ROOT/Sources/LavaIDL" "$ROOT/idl/index.npidl"
mkdir -p "$ROOT/indexer/src/gen"
echo "npidl --cpp    →  indexer/src/gen"
"$NPIDL" --cpp --output-dir "$ROOT/indexer/src/gen" "$ROOT/idl/index.npidl"

# The draw-list enums are committed so canvas and LavaUI build without NPRPC.
# Stage them first so an older npidl cannot replace them with RPC stubs.
drawlist_tmp="$(mktemp -d)"
trap 'rm -rf -- "$drawlist_tmp"' EXIT
"$NPIDL" --cpp --swift --output-dir "$drawlist_tmp" "$ROOT/idl/drawlist.npidl"
if [[ -e "$drawlist_tmp/drawlist.cpp" ]]; then
  echo "drawlist.npidl requires an npidl with enum-only output support. Set NPIDL to an updated compiler." >&2
  exit 1
fi
mkdir -p "$ROOT/canvas/src/render/gen" "$ROOT/Sources/LavaUI/Generated"
echo "npidl --cpp    →  canvas/src/render/gen (drawlist)"
cp "$drawlist_tmp/drawlist.hpp" "$ROOT/canvas/src/render/gen/"
echo "npidl --swift  →  Sources/LavaUI/Generated (drawlist)"
cp "$drawlist_tmp/drawlist.swift" "$ROOT/Sources/LavaUI/Generated/"

echo "done"
