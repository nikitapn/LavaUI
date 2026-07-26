#pragma once

#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>

class Application {
  struct Impl;
  std::unique_ptr<Impl> impl_;
public:
  // Sets up Vulkan/rendering. assetsRoot is the directory assets/shaders are
  // loaded from (previously this was inferred from argv[0]'s parent dir,
  // which doesn't make sense once this is embedded in another process).
  void init(const std::string &assetsRoot);

  // Renders the current retained scene (see add/update/removeShape below) to
  // the offscreen target. Call this whenever you want a new frame — after
  // changing the scene, or on whatever cadence you like; there's no
  // fixed-timestep loop driving it. Returns false if the engine hit an
  // unrecoverable error.
  bool repaint();

  // Retained 2D shape scene. x/y is the top-left corner, in pixels; r/g/b/a
  // are 0-1. Each add* returns an id you can later pass to
  // updateRect/removeShape (removal/clearing is shared across shape kinds
  // since the id alone disambiguates).
  int addRect(float x, float y, float width, float height,
              float r, float g, float b, float a);
  void updateRect(int id, float x, float y, float width, float height,
                   float r, float g, float b, float a);
  int addRoundedRect(float x, float y, float width, float height,
                      float r, float g, float b, float a);
  // Ports/slots: centerX/centerY/radius, not top-left+size, since circles
  // are always addressed by their center in the FBD editor this is for.
  int addCircle(float centerX, float centerY, float radius,
                float r, float g, float b, float a);
  void removeShape(int id);
  void clearShapes();

  // Retained 2D line scene (for wires). Screen-space, same pixel coordinate
  // system as the shapes above.
  int addLine(float x1, float y1, float x2, float y2,
              float r, float g, float b, float a);
  void removeLine(int id);
  void clearLines();

  // Retained 2D text labels. position is the top-left of the text baseline
  // origin TextRenderer itself expects; r/g/b are 0-1 (no alpha channel —
  // TextRenderer::renderText doesn't take one).
  int addLabel(const std::string &text, float x, float y,
               float r, float g, float b);
  void removeLabel(int id);
  void clearLabels();

  // Copies the frame repaint() just rendered (RGBA8) into dst. dst must be
  // at least width*height*4 bytes.
  void readPixels(uint8_t *dst, size_t dstSize);

  void shutdown();

  Application(int width = 1280, int height = 720);
  ~Application();
};
