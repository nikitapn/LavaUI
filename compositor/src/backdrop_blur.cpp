#include "backdrop_blur.hpp"

#include <algorithm>
#include <cstring>

#include <drm_fourcc.h>

namespace lava {
namespace {

void drmPixelToRgba(uint32_t format, const uint8_t *src, uint8_t *dst) {
  switch (format) {
  case DRM_FORMAT_ABGR8888:
  case DRM_FORMAT_XBGR8888:
    dst[0] = src[0];
    dst[1] = src[1];
    dst[2] = src[2];
    dst[3] = format == DRM_FORMAT_XBGR8888 ? 255 : src[3];
    break;
  case DRM_FORMAT_ARGB8888:
  case DRM_FORMAT_XRGB8888:
  default:
    dst[0] = src[2];
    dst[1] = src[1];
    dst[2] = src[0];
    dst[3] = format == DRM_FORMAT_XRGB8888 ? 255 : src[3];
    break;
  }
}

bool convertRegion(const uint8_t *src, int srcW, int srcH, int stride,
                   uint32_t format, int x, int y, int w, int h,
                   std::vector<uint8_t> &out) {
  if (src == nullptr || w < 1 || h < 1) return false;
  if (x < 0 || y < 0 || x + w > srcW || y + h > srcH) return false;
  if (stride < srcW * 4) return false;
  out.resize(static_cast<size_t>(w) * static_cast<size_t>(h) * 4);
  for (int row = 0; row < h; ++row) {
    const uint8_t *in =
        src + static_cast<size_t>(y + row) * stride + static_cast<size_t>(x) * 4;
    uint8_t *dst = out.data() + static_cast<size_t>(row) * w * 4;
    for (int col = 0; col < w; ++col) {
      drmPixelToRgba(format, in, dst);
      in += 4;
      dst += 4;
    }
  }
  return true;
}

}  // namespace

bool readBufferRgba(wlr_renderer *renderer, wlr_buffer *buffer, int x, int y,
                    int w, int h, std::vector<uint8_t> &out) {
  if (buffer == nullptr || w < 1 || h < 1) return false;
  wlr_buffer_lock(buffer);

  bool ok = false;
  void *data = nullptr;
  uint32_t format = 0;
  size_t stride = 0;
  if (wlr_buffer_begin_data_ptr_access(buffer, WLR_BUFFER_DATA_PTR_ACCESS_READ,
                                       &data, &format, &stride)) {
    ok = convertRegion(static_cast<const uint8_t *>(data), buffer->width,
                       buffer->height, static_cast<int>(stride), format, x, y,
                       w, h, out);
    wlr_buffer_end_data_ptr_access(buffer);
  }

  if (!ok && renderer != nullptr) {
    wlr_texture *texture = wlr_texture_from_buffer(renderer, buffer);
    if (texture != nullptr) {
      uint32_t readFormat = wlr_texture_preferred_read_format(texture);
      if (readFormat == 0) readFormat = DRM_FORMAT_ARGB8888;
      std::vector<uint8_t> raw(static_cast<size_t>(w) * h * 4);
      wlr_texture_read_pixels_options opts{
          .data = raw.data(),
          .format = readFormat,
          .stride = static_cast<uint32_t>(w * 4),
          .dst_x = 0,
          .dst_y = 0,
          .src_box = {x, y, w, h},
      };
      if (wlr_texture_read_pixels(texture, &opts)) {
        ok = convertRegion(raw.data(), w, h, w * 4, readFormat, 0, 0, w, h,
                           out);
      }
      wlr_texture_destroy(texture);
    }
  }

  wlr_buffer_unlock(buffer);
  return ok;
}

}  // namespace lava
