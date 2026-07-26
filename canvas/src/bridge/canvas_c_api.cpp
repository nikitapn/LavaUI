#include "canvas_c_api.h"
#include "canvas_bridge.hpp"

#include <iostream>

struct CanvasContext {
  CanvasBridge bridge;

  CanvasContext(const std::string &assetsRoot, uint32_t width, uint32_t height)
    : bridge(assetsRoot, width, height)
  {
  }
};

CanvasContext *canvas_create(
  const char *assets_root, uint32_t width, uint32_t height)
{
  try {
    return new CanvasContext(
      assets_root ? std::string(assets_root) : std::string(), width, height);
  } catch (const std::exception &ex) {
    std::cerr << "canvas_create: " << ex.what() << '\n';
    return nullptr;
  } catch (...) {
    std::cerr << "canvas_create: unknown exception\n";
    return nullptr;
  }
}

void canvas_destroy(CanvasContext *ctx)
{
  delete ctx;
}

bool canvas_repaint(CanvasContext *ctx)
{
  if (!ctx) return false;
  return ctx->bridge.repaint();
}

int canvas_add_rect(
  CanvasContext *ctx,
  float x, float y, float width, float height,
  float r, float g, float b, float a)
{
  if (!ctx) return -1;
  return ctx->bridge.addRect(x, y, width, height, r, g, b, a);
}

void canvas_update_rect(
  CanvasContext *ctx, int id,
  float x, float y, float width, float height,
  float r, float g, float b, float a)
{
  if (!ctx) return;
  ctx->bridge.updateRect(id, x, y, width, height, r, g, b, a);
}

int canvas_add_rounded_rect(
  CanvasContext *ctx,
  float x, float y, float width, float height,
  float r, float g, float b, float a)
{
  if (!ctx) return -1;
  return ctx->bridge.addRoundedRect(x, y, width, height, r, g, b, a);
}

int canvas_add_circle(
  CanvasContext *ctx,
  float center_x, float center_y, float radius,
  float r, float g, float b, float a)
{
  if (!ctx) return -1;
  return ctx->bridge.addCircle(center_x, center_y, radius, r, g, b, a);
}

void canvas_remove_shape(CanvasContext *ctx, int id)
{
  if (!ctx) return;
  ctx->bridge.removeShape(id);
}

void canvas_clear_shapes(CanvasContext *ctx)
{
  if (!ctx) return;
  ctx->bridge.clearShapes();
}

int canvas_add_line(
  CanvasContext *ctx,
  float x1, float y1, float x2, float y2,
  float r, float g, float b, float a)
{
  if (!ctx) return -1;
  return ctx->bridge.addLine(x1, y1, x2, y2, r, g, b, a);
}

void canvas_remove_line(CanvasContext *ctx, int id)
{
  if (!ctx) return;
  ctx->bridge.removeLine(id);
}

void canvas_clear_lines(CanvasContext *ctx)
{
  if (!ctx) return;
  ctx->bridge.clearLines();
}

int canvas_add_label(
  CanvasContext *ctx,
  const char *text, float x, float y,
  float r, float g, float b)
{
  if (!ctx) return -1;
  return ctx->bridge.addLabel(text ? std::string(text) : std::string(), x, y, r, g, b);
}

void canvas_remove_label(CanvasContext *ctx, int id)
{
  if (!ctx) return;
  ctx->bridge.removeLabel(id);
}

void canvas_clear_labels(CanvasContext *ctx)
{
  if (!ctx) return;
  ctx->bridge.clearLabels();
}

void canvas_read_pixels(CanvasContext *ctx, uint8_t *dst, size_t dst_size)
{
  if (!ctx) return;
  ctx->bridge.readPixels(dst, dst_size);
}
