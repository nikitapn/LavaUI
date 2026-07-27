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
// Offscreen engine (readPixels into host UI). For smoke tests / legacy embed.
CanvasContext *canvas_create(
  const char *assets_root, uint32_t width, uint32_t height);

// GLFW + Vulkan present window on a background thread (same process, no IPC).
// Scene APIs below are mutex-guarded against the present loop.
CanvasContext *canvas_create_window(
  const char *assets_root, uint32_t width, uint32_t height, const char *title);

void canvas_destroy(CanvasContext *ctx);

// True while the GLFW window exists and its present loop is running.
bool canvas_window_is_open(CanvasContext *ctx);

// Place the canvas window over a Swift/Gtk layout slot (screen pixels).
// Width/height of 0 leave size unchanged; negative coords are allowed (multi-monitor).
void canvas_window_set_frame(
  CanvasContext *ctx, int x, int y, int width, int height);

// Hide during host move/resize/minimize; show again when the host settles.
// Does not destroy the window or the engine.
void canvas_window_set_visible(CanvasContext *ctx, bool visible);
bool canvas_window_is_visible(CanvasContext *ctx);

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

// ─── Text widgets ───────────────────────────────────────────────────────────

typedef struct CanvasHighlightRule {
  const char *pattern; // ECMAScript regex; not retained past the call
  float r, g, b, a;
  int priority;
  int capture_group; // 0 = whole match
} CanvasHighlightRule;

// Editable text field drawn in the ImGui/Vulkan pass. Returns id or -1.
int canvas_add_text_widget(
  CanvasContext *ctx,
  float x, float y, float width, float height,
  const char *text, bool multiline);

void canvas_set_text_widget_rect(
  CanvasContext *ctx, int id,
  float x, float y, float width, float height);

void canvas_set_text_widget_text(CanvasContext *ctx, int id, const char *text);

// Writes UTF-8 into out (NUL-terminated if cap > 0). Returns the number of
// bytes that would be written excluding NUL (like snprintf).
int canvas_get_text_widget_text(
  CanvasContext *ctx, int id, char *out, size_t cap);

// Returns false if id is invalid or any pattern failed to compile
// (successful patterns are still applied).
bool canvas_set_text_widget_highlight_rules(
  CanvasContext *ctx, int id,
  const CanvasHighlightRule *rules, int count);

void canvas_set_text_widget_focused(CanvasContext *ctx, int id, bool focused);
bool canvas_is_text_widget_focused(CanvasContext *ctx, int id);

// True if the buffer changed since the previous consume for this id.
bool canvas_text_widget_changed(CanvasContext *ctx, int id);

void canvas_remove_text_widget(CanvasContext *ctx, int id);

// True when the host should tick the canvas at display rate (~60 Hz), e.g.
// a text widget is focused and needs caret blink. When false, repaint only
// after scene/input changes.
bool canvas_wants_animation(CanvasContext *ctx);

// ─── Input bridge (canvas-local pixels; GLFW-style key codes) ───────────────

void canvas_pointer_move(CanvasContext *ctx, float x, float y);
void canvas_pointer_button(
  CanvasContext *ctx, int button, bool pressed, float x, float y);
// action: 0=release, 1=press, 2=repeat. mods: bit0=shift, bit1=ctrl, bit2=alt.
void canvas_key_event(CanvasContext *ctx, int key, int action, int mods);
void canvas_text_input(CanvasContext *ctx, const char *utf8);

// Copies the frame canvas_repaint() just rendered (RGBA8, tightly packed)
// into dst. dst must be at least dst_size bytes.
void canvas_read_pixels(CanvasContext *ctx, uint8_t *dst, size_t dst_size);

#ifdef __cplusplus
}
#endif
