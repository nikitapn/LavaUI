#pragma once

#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

#include "render/draw_command.hpp"
#include "util/result.hpp"

class Application {
  struct Impl;
  std::unique_ptr<Impl> impl_;
public:
  // Sets up Vulkan/rendering. assetsRoot is the directory that contains the
  // `assets/` and `shaders/` folders (e.g. canvas/.build.Debug). Prefer
  // absolute paths; do not rely on process cwd.
  // Offscreen path (readPixels / smoke tests).
  [[nodiscard]] canvas::VoidResult init(const std::string &assetsRoot);

  // Opens a GLFW window and presents via swapchain (no readback on the hot
  // path). Input is delivered through GLFW callbacks into the engine.
  [[nodiscard]] canvas::VoidResult initWithWindow(
    const std::string &assetsRoot, const std::string &title);

  bool windowShouldClose() const;

  /// Place the GLFW window over a layout slot (screen coordinates, pixels).
  /// Size changes rebuild the Vulkan framebuffer on the next ensure/repaint.
  void setWindowFrame(int x, int y, int width, int height);

  /// Show or hide the GLFW window (does not destroy it).
  void setWindowVisible(bool visible);

  /// True while minimized. A live GLFW query, not a cached flag — WM
  /// minimize/restore doesn't route through `setWindowVisible`, so caching
  /// would need its own callback wiring to stay correct.
  bool isIconified() const;

  // Renders the current retained scene. Offscreen: to the readback target.
  // Windowed: blit to swapchain and present. Returns false on error.
  bool repaint();

  /// Immediate draw list from Swift (copied). See Engine::submitDrawList.
  void submitDrawList(const canvas::DrawCommand *cmds, size_t cmdCount,
                      const canvas::GlyphInstance *glyphs, size_t glyphCount,
                      const canvas::MeshVertex *meshVerts, size_t meshVertCount);
  bool pollInputEvent(canvas::InputEvent &out);

  /// Current swapchain / framebuffer size in pixels (after last ensure).
  void framebufferSize(float &outW, float &outH) const;

  /// Whole-window camera: layout stays in window pixels; renderer zooms/pans.
  /// `zoom` must be > 0 (clamped to 1 if not). Pan is in layout pixels.
  void setViewTransform(float zoom, float panX, float panY);

  /// Load the face TextRenderer uses for draw-list text. Swift is the only
  /// caller (FontStore); Application does not pick a default path.
  [[nodiscard]] canvas::VoidResult loadFont(const std::string &path, float pixelSize);
  int registerFont(const std::string &path, float pixelSize);

  /// System clipboard (GLFW-backed; empty when headless).
  std::string clipboardText() const;
  void setClipboardText(const std::string &text);

  /// Load a PNG/JPEG (stb) for draw-list `Image` commands. Returns texture id
  /// (>0) or -1. Idempotent per absolute path (refcounted in TextureManager).
  int loadTexture(const std::string &path);
  /// Pixel size of a loaded texture; returns false if id unknown.
  bool textureSize(uint32_t textureId, float &outW, float &outH) const;

  // ─── Input bridge (canvas-local coords, GLFW-style key codes) ───────────

  void pointerMove(float x, float y);
  void pointerButton(int button, bool pressed, float x, float y);
  void keyEvent(int key, int action, int mods);
  void textInput(const std::string &utf8);
  /// Synthetic wheel/trackpad delta; same coalescing queue as hardware scroll.
  void scroll(float dx, float dy);

  // Copies the frame repaint() just rendered (RGBA8) into dst. dst must be
  // at least width*height*4 bytes.
  void readPixels(uint8_t *dst, size_t dstSize);

  /// GPU→CPU capture of the resolve target (works windowed). See Vulkan::captureFrame.
  void captureFrame(uint8_t *dst, size_t dstSize);

  /// Capture resolve as PNG (optional crop + optional max-side downsample).
  /// `w`/`h` <= 0 → full frame. `maxSide` ≤ 0 → no downsample.
  bool capturePng(std::vector<uint8_t> &outPng, int x, int y, int w, int h,
                  int maxSide = 0, int *outW = nullptr, int *outH = nullptr);

  /// Same as capturePng, base64-encoded (empty string on failure).
  std::string capturePngBase64(int x, int y, int w, int h, int maxSide = 0,
                               int *outW = nullptr, int *outH = nullptr);

  void shutdown();

  Application(int width = 1280, int height = 720);
  ~Application();
};
