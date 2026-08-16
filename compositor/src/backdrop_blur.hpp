#pragma once

#include <cstdint>
#include <vector>

#include "wlr.hpp"

namespace lava {

/// Read `x,y,w,h` of `buffer` as tightly packed RGBA8. Tries a CPU map,
/// then a texture readback. False if neither works.
///
/// Fallback only. The compositor still has to *see* the desktop behind a
/// window, and that picture lives on wlroots' renderer. The usual path
/// imports the capture as a dma-buf on the canvas device (`ImportedDmabuf`)
/// and never copies pixels; this is what runs when the buffer has no
/// dma-buf or the modifier will not import.
bool readBufferRgba(wlr_renderer *renderer, wlr_buffer *buffer, int x, int y,
                    int w, int h, std::vector<uint8_t> &out);

}  // namespace lava
