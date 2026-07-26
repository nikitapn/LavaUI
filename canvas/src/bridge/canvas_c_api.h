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

// Renders the current retained scene (see canvas_add_rect etc. below).
// Call this whenever you want a new frame — after changing the scene, or
// on whatever cadence you like; there's no fixed-timestep loop driving it.
// Returns false if the engine hit an unrecoverable error.
bool canvas_repaint(CanvasContext *ctx);

// Retained 2D rectangle scene. x/y is the top-left corner, in pixels;
// r/g/b/a are 0-1. Returns an id you can later pass to
// canvas_update_rect/canvas_remove_rect (or -1 on failure).
int canvas_add_rect(
  CanvasContext *ctx,
  float x, float y, float width, float height,
  float r, float g, float b, float a);

void canvas_update_rect(
  CanvasContext *ctx, int id,
  float x, float y, float width, float height,
  float r, float g, float b, float a);

void canvas_remove_rect(CanvasContext *ctx, int id);

void canvas_clear_rects(CanvasContext *ctx);

// Copies the frame canvas_repaint() just rendered (RGBA8, tightly packed)
// into dst. dst must be at least dst_size bytes.
void canvas_read_pixels(CanvasContext *ctx, uint8_t *dst, size_t dst_size);

#ifdef __cplusplus
}
#endif
