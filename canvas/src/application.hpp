#pragma once

#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

#include "render/text_widget.hpp"
#include "render/draw_command.hpp"
#include "shell/layout.hpp"
#include "shell/model.hpp"
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

  // Renders the current retained scene. Offscreen: to the readback target.
  // Windowed: blit to swapchain and present. Returns false on error.
  bool repaint();

  /// Diagram panel rect in window pixels (from Yoga layout).
  shell::Rect diagramViewport() const;

  /// Replace the Yoga workspace tree (e.g. columns from Swift).
  void setWorkspaceLayout(shell::Node root);
  /// Convenience: three columns with fixed side widths.
  void setWorkspaceColumns(shell::PanelKind left, shell::PanelKind center,
                           shell::PanelKind right,
                           float leftWidth, float rightWidth);

  // ─── Declarative UI tree (SwiftUI-style, Yoga + TextRenderer) ───────────
  // Builder: uiReset → uiBegin/uiText… → uiEnd → uiCommit.
  // Kind: 0=Row, 1=Column, 2=Text (use uiText), 3=Spacer, 4=DiagramHost.
  // width/height < 0 means auto. Events: uiPollEvent → widgetId + kind (0=Click).
  void uiReset();
  void uiBegin(int kind, int id, float flexGrow, float flexShrink,
               float width, float height, float padding);
  void uiText(int id, const char *text, float r, float g, float b, bool clickable);
  void uiEnd();
  void uiCommit();
  bool uiPollEvent(int &outWidgetId, int &outKind);

  /// Immediate draw list from Swift (copied). See Engine::submitDrawList.
  void submitDrawList(const canvas::DrawCommand *cmds, size_t cmdCount,
                      const uint8_t *stringBlob, size_t blobSize,
                      const uint32_t *stringOffsets, size_t stringCount);
  bool pollInputEvent(canvas::InputEvent &out);
  void setDiagramViewport(float x, float y, float w, float h);

  /// Load the face TextRenderer uses for draw-list text. Swift is the only
  /// caller (FontStore); Application does not pick a default path.
  [[nodiscard]] canvas::VoidResult loadFont(const std::string &path, float pixelSize);

  // ─── Input bridge (canvas-local coords, GLFW-style key codes) ───────────

  void pointerMove(float x, float y);
  void pointerButton(int button, bool pressed, float x, float y);
  void keyEvent(int key, int action, int mods);
  void textInput(const std::string &utf8);

  // Copies the frame repaint() just rendered (RGBA8) into dst. dst must be
  // at least width*height*4 bytes.
  void readPixels(uint8_t *dst, size_t dstSize);

  void shutdown();

  Application(int width = 1280, int height = 720);
  ~Application();
};
