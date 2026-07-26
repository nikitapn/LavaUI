#include "pch.hpp"

#include "application.hpp"

#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"

// Headless smoke test: ticks the engine offscreen for a fixed number of
// frames (no window, no GLFW) and writes the last frame out as a PNG, so the
// Vulkan/offscreen-readback path can be sanity-checked visually without
// going through Swift. This replaces the old GLFW-windowed main loop.
int main(int argc, char *argv[])
{
  const int width = 1280;
  const int height = 720;
  const int frameCount = 120;

  std::string assetsRoot =
    std::filesystem::path(argv[0]).parent_path().string();

  std::cout << "Starting up...\n";
  Application app(width, height);

  try {
    std::cout << "Initializing...\n";
    app.init(assetsRoot);

    std::cout << "Ticking " << frameCount << " frames...\n";
    for (int i = 0; i < frameCount; ++i) {
      if (!app.tick(1.0f / 60.0f)) {
        std::cerr << "tick() reported failure at frame " << i << '\n';
        break;
      }
    }

    std::vector<uint8_t> pixels(
      static_cast<size_t>(width) * height * 4);
    app.readPixels(pixels.data(), pixels.size());

    const char *outPath = "canvas_test_output.png";
    if (stbi_write_png(outPath, width, height, 4, pixels.data(), width * 4)) {
      std::cout << "Wrote " << outPath << '\n';
    } else {
      std::cerr << "Failed to write " << outPath << '\n';
    }
  } catch (std::exception &ex) {
    std::cerr << ex.what() << '\n';
  }

  try {
    std::cout << "Shutting down...\n";
    app.shutdown();
  } catch (std::exception &ex) {
    std::cerr << ex.what() << '\n';
  }

  return 0;
}
