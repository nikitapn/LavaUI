#pragma once

#include <cstdint>
#include <cstddef>
#include <memory>
#include <string>

// C++-side convenience wrapper around Application, used internally by
// canvas_c_api.cpp. Not imported by Swift directly (see the note in
// canvas_swift's Package.swift for why: Swift's C++ interop mode is viral
// and conflicts with also needing swift-cross-ui's GtkCHelpers), but kept
// as a real class since it's still handy to build/test against from C++
// (see canvas_test in meson.build).
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

  // Renders the current retained scene. Returns false if the engine hit an
  // unrecoverable error (logged internally — exceptions never cross this
  // boundary since Swift can't catch C++ exceptions).
  bool repaint() noexcept;

  // Retained 2D rectangle scene. x/y is the top-left corner, in pixels;
  // r/g/b/a are 0-1. addRect returns an id you can later pass to
  // updateRect/removeRect.
  int addRect(float x, float y, float width, float height,
              float r, float g, float b, float a) noexcept;
  void updateRect(int id, float x, float y, float width, float height,
                   float r, float g, float b, float a) noexcept;
  void removeRect(int id) noexcept;
  void clearRects() noexcept;

  // Copies the frame repaint() just rendered (RGBA8, tightly packed,
  // width*height*4 bytes) into dst. dst must be at least dstSize bytes.
  void readPixels(uint8_t *dst, size_t dstSize) noexcept;
};
