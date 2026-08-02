#!/usr/bin/env bash
# Compile GLSL → SPIR-V for the CanvasResources SwiftPM bundle.
#
# Checked-in .bin files under Sources/CanvasResources/shaders/ are what
# `swift build` ships; run this only after editing sources in src/shaders/.
#
# Requires: glslc (Vulkan SDK / shaderc)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/src/shaders/2d"
OUT="$ROOT/Sources/CanvasResources/shaders"

if ! command -v glslc >/dev/null 2>&1; then
  echo "error: glslc not found (install shaderc / Vulkan SDK)" >&2
  exit 1
fi

mkdir -p "$OUT"

# Basename → path under SRC (compute shaders live in a subdir).
shaders=(
  shader.vert
  shader.frag
  quad.vert
  quad.frag
  polyline.vert
  polyline.frag
  blur.vert
  blur.frag
  compute/integration.comp
  compute/collision_detect.comp
  compute/collision_resolve.comp
)

failed=0
for rel in "${shaders[@]}"; do
  in="$SRC/$rel"
  base="$(basename "$rel")"
  out="$OUT/${base}.bin"
  if [[ ! -f "$in" ]]; then
    echo "missing: $in" >&2
    failed=1
    continue
  fi
  echo "glslc  $rel  →  shaders/${base}.bin"
  glslc -mfmt=bin -o "$out" "$in"
done

if [[ "$failed" -ne 0 ]]; then
  exit 1
fi

echo "done → $OUT"
