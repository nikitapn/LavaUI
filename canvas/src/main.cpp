#include "pch.hpp"

#include "application.hpp"

#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"

// Headless smoke test: adds a few retained rectangles, repaints the engine
// offscreen a handful of times (no window, no GLFW), and writes the last
// frame out as a PNG, so the Vulkan/offscreen-readback/retained-scene path
// can be sanity-checked visually without going through Swift.
int main(int argc, char *argv[])
{
  const int width = 1280;
  const int height = 720;
  const int repaintCount = 5;

  std::string assetsRoot =
    std::filesystem::path(argv[0]).parent_path().string();

  std::cout << "Starting up...\n";
  Application app(width, height);

  try {
    std::cout << "Initializing...\n";
    if (auto r = app.init(assetsRoot); !r) {
      std::cerr << "init failed: " << r.error() << '\n';
      return 1;
    }

    app.addRect(100, 100, 300, 150, 0.8f, 0.2f, 0.2f, 1.0f);
    app.addRoundedRect(500, 300, 200, 200, 0.2f, 0.6f, 0.9f, 1.0f);
    app.addRect(200, 450, 400, 100, 0.3f, 0.8f, 0.3f, 0.8f);
    app.addCircle(250, 175, 20, 1.0f, 1.0f, 0.2f, 1.0f);
    app.addCircle(750, 300, 20, 1.0f, 1.0f, 0.2f, 1.0f);
    app.addLine(250, 175, 600, 400, 1.0f, 1.0f, 1.0f, 1.0f);
    app.addLabel("FBD smoke test", 100, 650, 1.0f, 1.0f, 1.0f);

    int editor = app.addTextWidget(
      100, 500, 480, 120,
      "// sample ST\nIF x > 0 THEN\n  y := 1;\nEND_IF",
      true);
    std::vector<TextHighlightRule> rules = {
      {"//[^\\n]*", 0.4f, 0.7f, 0.4f, 1.f, 10, 0},
      {"\\b(IF|THEN|ELSE|END_IF|AND|OR|NOT|TRUE|FALSE)\\b", 0.75f, 0.55f, 1.f, 1.f, 5, 0},
      {"\\b\\d+(\\.\\d+)?\\b", 0.9f, 0.7f, 0.3f, 1.f, 3, 0},
    };
    app.setTextWidgetHighlightRules(editor, rules);
    app.setTextWidgetFocused(editor, true);

    std::cout << "Repainting " << repaintCount << " times...\n";
    for (int i = 0; i < repaintCount; ++i) {
      if (!app.repaint()) {
        std::cerr << "repaint() reported failure at frame " << i << '\n';
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
