#pragma once

#include <cstdint>
#include <cstddef>
#include <memory>
#include <string>

// Swift-facing surface for the canvas engine. Deliberately hides every
// engine/Vulkan type behind the pimpl — the only types that cross this
// boundary (std::string, uint32_t, double, bool, uint8_t*, size_t) are all
// trivially importable by Swift's C++ interop, so nothing here needs
// forward declarations the way a bridge exposing real engine types would.
class CanvasBridge {
  struct Impl;
  std::unique_ptr<Impl> impl_;

 public:
  // assetsRoot: directory assets/shaders are loaded from.
  CanvasBridge(const std::string &assetsRoot, uint32_t width, uint32_t height);

  // Explicit move ctor/assignment required: an out-of-line destructor
  // (needed for the pimpl idiom) suppresses the implicit move ctor, and the
  // unique_ptr member already blocks the copy ctor — without these the type
  // has no copy/move semantics and Swift's C++ interop won't import it.
  // (Discovered via a standalone spike before writing this for real.)
  CanvasBridge(CanvasBridge &&) noexcept;
  CanvasBridge &operator=(CanvasBridge &&) noexcept;
  ~CanvasBridge();

  // Advances and renders one frame. Returns false if the engine hit an
  // unrecoverable error (logged internally — exceptions never cross this
  // boundary since Swift can't catch C++ exceptions).
  bool tick(double deltaTimeSeconds) noexcept;

  // Copies the frame tick() just rendered (RGBA8, tightly packed,
  // width*height*4 bytes) into dst. dst must be at least dstSize bytes.
  void readPixels(uint8_t *dst, size_t dstSize) noexcept;
};
