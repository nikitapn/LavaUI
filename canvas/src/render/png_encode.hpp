#pragma once

#include <cstdint>
#include <vector>

namespace canvas {

/// Encodes tightly-or-strided 8-bit RGBA into a PNG.
///
/// `maxSide` > 0 downsamples so the longer encoded edge fits, the same
/// contract `RenderWindow::capturePng` and `CaptureSurface` already have.
/// The resize is `stbir` in linear light — a box filter in sRGB of a
/// terminal poster looked like nearest-neighbour.
/// `outW`/`outH` receive the encoded size. False if the source is empty or
/// stb refuses to write.
bool encodeRgbaPng(const uint8_t *rgba, int width, int height, int stride,
                   int maxSide, std::vector<uint8_t> &outPng, int &outW,
                   int &outH);

/// The same, as a baseline JPEG at `quality` (1-100).
///
/// Exists for one caller: saving a photograph an image viewer rotated. PNG
/// would be correct and unusable — a 24-megapixel photograph re-encoded
/// losslessly is well over a hundred megabytes, written over a six-megabyte
/// JPEG, and nobody asked for that when they clicked a rotate arrow.
///
/// Alpha is dropped, because JPEG has none. The caller is expected to have
/// checked that the source had none either; this composites nothing and
/// simply ignores the fourth channel.
bool encodeRgbaJpeg(const uint8_t *rgba, int width, int height, int stride,
                    int quality, std::vector<uint8_t> &outJpeg);

}  // namespace canvas
