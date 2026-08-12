#include "render/png_encode.hpp"

#include <algorithm>
#include <cstring>

#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"

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
      for (int dy = 0; dy < encH; ++dy) {
        const int y0 = dy * height / encH;
        const int y1 = std::max(y0 + 1, (dy + 1) * height / encH);
        for (int dx = 0; dx < encW; ++dx) {
          const int x0 = dx * width / encW;
          const int x1 = std::max(x0 + 1, (dx + 1) * width / encW);
          uint32_t sum[4] = {0, 0, 0, 0};
          uint32_t count = 0;
          for (int sy = y0; sy < y1; ++sy) {
            const uint8_t *row =
                pngPixels + (static_cast<size_t>(sy) * width + x0) * 4;
            for (int sx = x0; sx < x1; ++sx) {
              sum[0] += row[0];
              sum[1] += row[1];
              sum[2] += row[2];
              sum[3] += row[3];
              row += 4;
              ++count;
            }
          }
          uint8_t *out =
              scaled.data() + (static_cast<size_t>(dy) * encW + dx) * 4;
          if (count == 0) {
            out[0] = out[1] = out[2] = out[3] = 0;
          } else {
            out[0] = static_cast<uint8_t>(sum[0] / count);
            out[1] = static_cast<uint8_t>(sum[1] / count);
            out[2] = static_cast<uint8_t>(sum[2] / count);
            out[3] = static_cast<uint8_t>(sum[3] / count);
          }
        }
      }
      pngPixels = scaled.data();
      pngStride = encW * 4;
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
