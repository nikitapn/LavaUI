#include "render/svg_image.hpp"

#include <cmath>
#include <cstring>
#include <iostream>

#if defined(CANVAS_HAVE_RSVG)
#include <cairo.h>
#include <librsvg/rsvg.h>
#endif

namespace canvas {

#if defined(CANVAS_HAVE_RSVG)

bool svgAvailable() { return true; }

std::vector<uint8_t> rasterizeSvg(const std::string &path, uint32_t pixelSize,
                                  uint32_t &outWidth, uint32_t &outHeight)
{
  outWidth = 0;
  outHeight = 0;

  GError *error = nullptr;
  RsvgHandle *handle = rsvg_handle_new_from_file(path.c_str(), &error);
  if (handle == nullptr) {
    if (error != nullptr) g_error_free(error);
    return {};
  }

  // The document's intrinsic size, which an icon usually has and a diagram
  // often does not. When it has none, the caller's size is the only size there
  // is; when it has one, it still only decides the aspect ratio, because a
  // vector image drawn at its "own" size is a coincidence rather than a rule.
  double docWidth = 0.0, docHeight = 0.0;
  if (!rsvg_handle_get_intrinsic_size_in_pixels(handle, &docWidth, &docHeight) ||
      docWidth <= 0.0 || docHeight <= 0.0) {
    docWidth = docHeight = pixelSize > 0 ? static_cast<double>(pixelSize) : 64.0;
  }

  double width = docWidth;
  double height = docHeight;
  if (pixelSize > 0) {
    const double scale =
      static_cast<double>(pixelSize) / std::max(docWidth, docHeight);
    width = std::round(docWidth * scale);
    height = std::round(docHeight * scale);
  }
  if (width < 1.0) width = 1.0;
  if (height < 1.0) height = 1.0;

  cairo_surface_t *surface = cairo_image_surface_create(
    CAIRO_FORMAT_ARGB32, static_cast<int>(width), static_cast<int>(height));
  if (cairo_surface_status(surface) != CAIRO_STATUS_SUCCESS) {
    cairo_surface_destroy(surface);
    g_object_unref(handle);
    return {};
  }

  cairo_t *cr = cairo_create(surface);
  const RsvgRectangle viewport{0.0, 0.0, width, height};
  const gboolean ok = rsvg_handle_render_document(handle, cr, &viewport, &error);
  cairo_destroy(cr);
  cairo_surface_flush(surface);

  if (!ok) {
    std::cerr << "canvas: SVG render failed for '" << path << "': "
              << (error ? error->message : "?") << "\n";
    if (error != nullptr) g_error_free(error);
    cairo_surface_destroy(surface);
    g_object_unref(handle);
    return {};
  }

  const int w = cairo_image_surface_get_width(surface);
  const int h = cairo_image_surface_get_height(surface);
  const int stride = cairo_image_surface_get_stride(surface);
  const unsigned char *src = cairo_image_surface_get_data(surface);

  std::vector<uint8_t> rgba(static_cast<size_t>(w) * h * 4);
  for (int y = 0; y < h; ++y) {
    const unsigned char *row = src + static_cast<size_t>(y) * stride;
    for (int x = 0; x < w; ++x) {
      // Cairo's ARGB32 is native-endian premultiplied BGRA; everything past
      // here expects straight RGBA, the way stb hands it over. Both halves of
      // that conversion matter: skipping the un-premultiply darkens every
      // antialiased edge towards black, which on an icon is a dirty outline.
      const uint32_t pixel =
        *reinterpret_cast<const uint32_t *>(row + static_cast<size_t>(x) * 4);
      const uint8_t a = static_cast<uint8_t>((pixel >> 24) & 0xffu);
      uint8_t r = static_cast<uint8_t>((pixel >> 16) & 0xffu);
      uint8_t g = static_cast<uint8_t>((pixel >> 8) & 0xffu);
      uint8_t b = static_cast<uint8_t>(pixel & 0xffu);
      if (a != 0 && a != 255) {
        r = static_cast<uint8_t>(std::min(255, r * 255 / a));
        g = static_cast<uint8_t>(std::min(255, g * 255 / a));
        b = static_cast<uint8_t>(std::min(255, b * 255 / a));
      }
      const size_t out = (static_cast<size_t>(y) * w + x) * 4;
      rgba[out + 0] = r;
      rgba[out + 1] = g;
      rgba[out + 2] = b;
      rgba[out + 3] = a;
    }
  }

  cairo_surface_destroy(surface);
  g_object_unref(handle);
  outWidth = static_cast<uint32_t>(w);
  outHeight = static_cast<uint32_t>(h);
  return rgba;
}

#else  // !CANVAS_HAVE_RSVG

bool svgAvailable() { return false; }

std::vector<uint8_t> rasterizeSvg(const std::string &, uint32_t, uint32_t &w,
                                  uint32_t &h)
{
  w = 0;
  h = 0;
  return {};
}

#endif

}  // namespace canvas
