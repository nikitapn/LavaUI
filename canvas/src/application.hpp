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

  // Renders the current retained scene (see add/update/removeRect below) to
  // the offscreen target. Call this whenever you want a new frame — after
  // changing the scene, or on whatever cadence you like; there's no
  // fixed-timestep loop driving it. Returns false if the engine hit an
  // unrecoverable error.
  bool repaint();

  // Retained 2D rectangle scene. x/y is the top-left corner, in pixels;
  // r/g/b/a are 0-1. addRect returns an id you can later pass to
  // updateRect/removeRect.
  int addRect(float x, float y, float width, float height,
              float r, float g, float b, float a);
  void updateRect(int id, float x, float y, float width, float height,
                   float r, float g, float b, float a);
  void removeRect(int id);
  void clearRects();

  // Copies the frame repaint() just rendered (RGBA8) into dst. dst must be
  // at least width*height*4 bytes.
  void readPixels(uint8_t *dst, size_t dstSize);

  void shutdown();

  Application(int width = 1280, int height = 720);
  ~Application();
};
