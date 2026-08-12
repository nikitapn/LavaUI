#pragma once

#include <cstdint>
#include <vector>

namespace canvas {

/// Encodes tightly-or-strided 8-bit RGBA into a PNG.
///
/// `maxSide` > 0 box-filters so the longer encoded edge fits, the same
/// contract `RenderWindow::capturePng` and `CaptureSurface` already have.
/// `outW`/`outH` receive the encoded size. False if the source is empty or
/// stb refuses to write.
bool encodeRgbaPng(const uint8_t *rgba, int width, int height, int stride,
                   int maxSide, std::vector<uint8_t> &outPng, int &outW,
                   int &outH);

}  // namespace canvas
