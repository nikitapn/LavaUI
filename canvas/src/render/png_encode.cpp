#include "render/png_encode.hpp"

#include <algorithm>
#include <cstring>

#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"

// Declarations only — the implementation lives in texture_manager.cpp
// next to the other stb units.
#include <stb_image_resize2.h>

namespace canvas {
namespace {

struct PngWriteCtx {
  std::vector<uint8_t> *out = nullptr;
};

void pngWriteFunc(void *context, void *data, int size) {
  auto *ctx = static_cast<PngWriteCtx *>(context);
  auto *bytes = static_cast<const uint8_t *>(data);
  ctx->out->insert(ctx->out->end(), bytes, bytes + size);
}

}  // namespace

bool encodeRgbaPng(const uint8_t *rgba, int width, int height, int stride,
                   int maxSide, std::vector<uint8_t> &outPng, int &outW,
                   int &outH) {
  if (rgba == nullptr || width < 1 || height < 1) return false;
  if (stride < width * 4) return false;

  int encW = width;
  int encH = height;
  const uint8_t *pngPixels = rgba;
  int pngStride = stride;
  std::vector<uint8_t> packed;
  std::vector<uint8_t> scaled;

  // stb wants a tight buffer when we downsample; also pack a padded source
  // so the filter does not have to carry stride through every tap.
  const bool padded = stride != width * 4;
  if (padded) {
    packed.resize(static_cast<size_t>(width) * static_cast<size_t>(height) * 4);
    for (int y = 0; y < height; ++y) {
      std::memcpy(packed.data() + static_cast<size_t>(y) * width * 4,
                  rgba + static_cast<size_t>(y) * stride,
                  static_cast<size_t>(width) * 4);
    }
    pngPixels = packed.data();
    pngStride = width * 4;
  }

  if (maxSide > 0) {
    const int longSide = std::max(width, height);
    if (longSide > maxSide) {
      encW = std::max(1, (width * maxSide + longSide / 2) / longSide);
      encH = std::max(1, (height * maxSide + longSide / 2) / longSide);
      scaled.resize(static_cast<size_t>(encW) * static_cast<size_t>(encH) * 4);
      // Same sRGB resize the image decoder uses. Averaging encoded bytes
      // (the old box filter) aliases high-contrast UI — a terminal poster
      // looked nearest-neighbour even though it was a 5×5 mean.
      unsigned char *ok = stbir_resize_uint8_srgb(
          pngPixels, width, height, pngStride, scaled.data(), encW, encH,
          encW * 4, STBIR_RGBA);
      if (ok != nullptr) {
        pngPixels = scaled.data();
        pngStride = encW * 4;
      } else {
        encW = width;
        encH = height;
      }
    }
  }

  outPng.clear();
  PngWriteCtx ctx{&outPng};
  const int ok = stbi_write_png_to_func(pngWriteFunc, &ctx, encW, encH, 4,
                                        pngPixels, pngStride);
  if (ok == 0 || outPng.empty()) return false;
  outW = encW;
  outH = encH;
  return true;
}

}  // namespace canvas
