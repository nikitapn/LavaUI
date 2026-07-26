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

  // Advances the simulation/UI by one frame and renders it. Returns false if
  // the app wants to quit (currently always true — there's no window to
  // close headlessly).
  bool tick(float deltaTime);

  // Copies the frame tick() just rendered (RGBA8) into dst. dst must be at
  // least width*height*4 bytes.
  void readPixels(uint8_t *dst, size_t dstSize);

  void shutdown();

  Application(int width = 1280, int height = 720);
  ~Application();
};
