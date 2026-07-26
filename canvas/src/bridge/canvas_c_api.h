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

// Retained 2D shape scene. x/y is the top-left corner, in pixels; r/g/b/a
// are 0-1. Each canvas_add_* returns an id you can later pass to
// canvas_update_rect/canvas_remove_shape (or -1 on failure). Removal and
// clearing are shared across shape kinds since the id alone disambiguates.
int canvas_add_rect(
  CanvasContext *ctx,
  float x, float y, float width, float height,
  float r, float g, float b, float a);

void canvas_update_rect(
  CanvasContext *ctx, int id,
  float x, float y, float width, float height,
  float r, float g, float b, float a);

int canvas_add_rounded_rect(
  CanvasContext *ctx,
  float x, float y, float width, float height,
  float r, float g, float b, float a);

// centerX/centerY/radius, not top-left+size.
int canvas_add_circle(
  CanvasContext *ctx,
  float center_x, float center_y, float radius,
  float r, float g, float b, float a);

void canvas_remove_shape(CanvasContext *ctx, int id);

void canvas_clear_shapes(CanvasContext *ctx);

// Retained 2D line scene (wires), same screen-pixel coordinate system as
// the shapes above.
int canvas_add_line(
  CanvasContext *ctx,
  float x1, float y1, float x2, float y2,
  float r, float g, float b, float a);

void canvas_remove_line(CanvasContext *ctx, int id);

void canvas_clear_lines(CanvasContext *ctx);

// Retained 2D text labels. r/g/b are 0-1 (no alpha channel).
int canvas_add_label(
  CanvasContext *ctx,
  const char *text, float x, float y,
  float r, float g, float b);

void canvas_remove_label(CanvasContext *ctx, int id);

void canvas_clear_labels(CanvasContext *ctx);

// Copies the frame canvas_repaint() just rendered (RGBA8, tightly packed)
// into dst. dst must be at least dst_size bytes.
void canvas_read_pixels(CanvasContext *ctx, uint8_t *dst, size_t dst_size);

#ifdef __cplusplus
}
#endif
