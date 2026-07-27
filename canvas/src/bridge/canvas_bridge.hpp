#pragma once

#include <cstdint>
#include <cstddef>
#include <memory>
#include <string>
#include <vector>

#include "render/text_widget.hpp"

class Application;

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

  // Retained 2D shape scene. x/y is the top-left corner, in pixels; r/g/b/a
  // are 0-1. Each add* returns an id you can later pass to
  // updateRect/removeShape (removal/clearing is shared across shape kinds).
  int addRect(float x, float y, float width, float height,
              float r, float g, float b, float a) noexcept;
  void updateRect(int id, float x, float y, float width, float height,
                   float r, float g, float b, float a) noexcept;
  int addRoundedRect(float x, float y, float width, float height,
                      float r, float g, float b, float a) noexcept;
  int addCircle(float centerX, float centerY, float radius,
                float r, float g, float b, float a) noexcept;
  void removeShape(int id) noexcept;
  void clearShapes() noexcept;

  // Retained 2D line scene (wires), same screen-pixel coordinate system.
  int addLine(float x1, float y1, float x2, float y2,
              float r, float g, float b, float a) noexcept;
  void removeLine(int id) noexcept;
  void clearLines() noexcept;

  // Retained 2D text labels. r/g/b are 0-1 (no alpha).
  int addLabel(const std::string &text, float x, float y,
               float r, float g, float b) noexcept;
  void removeLabel(int id) noexcept;
  void clearLabels() noexcept;

  // Text widgets (editable, optional regex highlighting).
  int addTextWidget(float x, float y, float width, float height,
                    const std::string &text, bool multiline) noexcept;
  void setTextWidgetRect(int id, float x, float y, float width, float height) noexcept;
  void setTextWidgetText(int id, const std::string &text) noexcept;
  std::string getTextWidgetText(int id) noexcept;
  bool setTextWidgetHighlightRules(int id, const std::vector<TextHighlightRule> &rules) noexcept;
  void setTextWidgetFocused(int id, bool focused) noexcept;
  bool isTextWidgetFocused(int id) noexcept;
  bool textWidgetChanged(int id) noexcept;
  void removeTextWidget(int id) noexcept;
  bool wantsAnimation() noexcept;

  // Input bridge (canvas-local pixels; GLFW-style key codes).
  void pointerMove(float x, float y) noexcept;
  void pointerButton(int button, bool pressed, float x, float y) noexcept;
  void keyEvent(int key, int action, int mods) noexcept;
  void textInput(const std::string &utf8) noexcept;

  // Copies the frame repaint() just rendered (RGBA8, tightly packed,
  // width*height*4 bytes) into dst. dst must be at least dstSize bytes.
  void readPixels(uint8_t *dst, size_t dstSize) noexcept;

  /// Direct access for windowed host / C API dual-mode (not for Swift).
  Application &rawApp() noexcept;
};
