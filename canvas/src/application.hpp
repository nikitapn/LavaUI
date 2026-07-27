#pragma once

#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

#include "render/text_widget.hpp"
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

  // ─── Text widgets (ImGui-frame editor with optional regex highlighting) ─

  /// Places a retained text field. `multiline` allows Enter to insert newlines.
  int addTextWidget(float x, float y, float width, float height,
                    const std::string &text, bool multiline);
  void setTextWidgetRect(int id, float x, float y, float width, float height);
  void setTextWidgetText(int id, const std::string &text);
  std::string getTextWidgetText(int id) const;
  bool setTextWidgetHighlightRules(int id, const std::vector<TextHighlightRule> &rules);
  void setTextWidgetFocused(int id, bool focused);
  bool isTextWidgetFocused(int id) const;
  /// True if the buffer changed since the last consume (or creation).
  bool textWidgetChanged(int id);
  void removeTextWidget(int id);

  /// True when the host should run a continuous present/readback loop
  /// (~60 Hz) — currently: any text widget has focus (caret blink, smooth
  /// selection drag). False means repaint-on-change is enough.
  bool wantsAnimation() const;

  // ─── Shell model (tree + properties, driven from Swift FBDModel) ───────
  void setProjectTree(std::vector<canvas::TreeItem> items);
  void setProperties(std::vector<canvas::PropertyItem> items);
  std::string selectedTreeId() const;
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
