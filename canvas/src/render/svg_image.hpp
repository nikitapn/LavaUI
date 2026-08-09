#pragma once

// SVG rasterization, for icons.
//
// Optional at build time (CANVAS_HAVE_RSVG). Stubbed when unavailable, in
// which case an `.svg` path decodes to nothing and whoever asked falls back to
// whatever it draws for an icon it could not load.
//
// Separate from the stb path next door because it is a different kind of
// operation. stb decodes an image that has a size; an SVG *has no size* — it
// has a shape, and a size is something the caller chooses. That difference is
// the whole reason a dock wants this: an icon theme's 48-pixel PNG is a
// compromise between the sizes it might be drawn at, and an SVG rendered at
// the size actually wanted is simply right.

#include <cstdint>
#include <string>
#include <vector>

namespace canvas {

/// Renders `path` into RGBA8 at `pixelSize` on the longer edge.
///
/// Straight (non-premultiplied) alpha, top-left origin — the same form
/// `stbi_load` produces, so everything downstream cannot tell which decoder
/// ran. Empty on any failure, including a build without librsvg.
///
/// `pixelSize` of 0 asks for the document's own size, which for an icon is
/// usually the nominal one its theme filed it under.
std::vector<uint8_t> rasterizeSvg(const std::string &path, uint32_t pixelSize,
                                  uint32_t &outWidth, uint32_t &outHeight);

/// Whether this build can rasterize SVG at all.
bool svgAvailable();

}  // namespace canvas
