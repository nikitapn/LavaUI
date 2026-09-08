#pragma once

#include <cstdint>
#include <string>

namespace canvas {

/// The pixels of an image file, tightly packed RGBA8, or null.
///
/// One entry point for "this path is a picture, give me its pixels", so the
/// question of *which container* is answered once. Today that is stb for
/// everything ordinary and an embedded preview for a camera raw; whatever is
/// added next, the two decode sites — the engine's own `decodeImage` and the
/// texture cache's `loadTexture` — inherit it without either being edited.
///
/// The buffer is `stbi_image_free`'s to release, whichever branch produced it.
/// Null for a file that does not exist, is not an image, or is damaged.
uint8_t *loadImageFile(const std::string &path, int &width, int &height);

}  // namespace canvas
