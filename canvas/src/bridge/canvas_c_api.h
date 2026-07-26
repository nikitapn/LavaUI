#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct CanvasContext CanvasContext;

// assetsRoot: directory assets/shaders are loaded from. Returns NULL on
// failure (logged to stderr).
CanvasContext *canvas_create(
  const char *assets_root, uint32_t width, uint32_t height);

void canvas_destroy(CanvasContext *ctx);

// Advances and renders one frame. Returns false if the engine hit an
// unrecoverable error.
bool canvas_tick(CanvasContext *ctx, double delta_time_seconds);

// Copies the frame canvas_tick() just rendered (RGBA8, tightly packed) into
// dst. dst must be at least dst_size bytes.
void canvas_read_pixels(CanvasContext *ctx, uint8_t *dst, size_t dst_size);

#ifdef __cplusplus
}
#endif
