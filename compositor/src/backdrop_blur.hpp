#pragma once

#include <cstdint>
#include <vector>

#include "wlr.hpp"

namespace lava {

/// Read `x,y,w,h` of `buffer` as tightly packed RGBA8. Tries a CPU map,
/// then a texture readback. False if neither works.
///
/// The compositor still has to *see* the desktop behind a window — that
/// picture lives on wlroots' renderer. The frost itself is a canvas
/// `BlurPass` on the compositing Vulkan device; this is only the handover.
bool readBufferRgba(wlr_renderer *renderer, wlr_buffer *buffer, int x, int y,
                    int w, int h, std::vector<uint8_t> &out);

}  // namespace lava
