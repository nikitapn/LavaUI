#include "render/image_load.hpp"

#include <stb_image.h>

#include <vector>

#include "render/raw_preview.hpp"

namespace canvas {

uint8_t *loadImageFile(const std::string &path, int &width, int &height) {
  int channels = 0;

  // A raw file first, because stb would otherwise answer for it: a CR2 opens
  // as a TIFF as far as the first few bytes are concerned, and stb would
  // decode *something* — the wrong directory, undemosaiced, or nothing at all.
  // Asked by extension, so the cost for every ordinary photograph is a string
  // comparison.
  if (isRawPhoto(path)) {
    const std::vector<uint8_t> preview = readRawPreview(path);
    if (preview.empty()) return nullptr;
    // The camera's own JPEG, through the same decoder as any other JPEG.
    return stbi_load_from_memory(preview.data(),
                                 static_cast<int>(preview.size()), &width,
                                 &height, &channels, 4);
  }

  // stbi_load is reentrant and touches no shared state, which is what makes
  // this callable off the device thread.
  return stbi_load(path.c_str(), &width, &height, &channels, 4);
}

}  // namespace canvas
