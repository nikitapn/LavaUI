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

bool canvas_tick(CanvasContext *ctx, double delta_time_seconds)
{
  if (!ctx) return false;
  return ctx->bridge.tick(delta_time_seconds);
}

void canvas_read_pixels(CanvasContext *ctx, uint8_t *dst, size_t dst_size)
{
  if (!ctx) return;
  ctx->bridge.readPixels(dst, dst_size);
}
