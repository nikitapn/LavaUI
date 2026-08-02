# Prebuilt SPIR-V (checked in)

These `*.bin` files are packed by SwiftPM (`CanvasResources` target) and loaded
at runtime as `shaders/<name>.bin` under `CanvasResources.engineRoot`.

GLSL sources: `../../src/shaders/2d/`.

After editing GLSL:

```bash
./scripts/compile_shaders.sh   # from canvas/
```

Requires `glslc` (shaderc / Vulkan SDK). Consumers of LavaUI do **not** need
`glslc` — only people who change the shaders.
