#pragma once

// C++-first public API for the editor engine. Prefer this over the C API
// when calling from C++ or Swift C++ interop. The C API in canvas_c_api.h
// is a thin wrapper for targets that still need plain C.

// Directory-relative (not "shell/layout.hpp"-from-include-root) so this
// header resolves standalone via quote-include's current-file-relative
// search, without needing an extra -I search path — canvas_swift's
// CxxCanvas shim includes this file directly and SwiftPM's header search
// path setting refuses paths outside the package root.
#include "../shell/layout.hpp"
#include "../shell/model.hpp"
#include "../util/result.hpp"
#include "../render/text_highlight_rule.hpp"
#include "../render/draw_command.hpp"

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

class Application;

namespace canvas {

/// Owns the windowed (or offscreen) Application and optional present thread.
class Engine {
 public:
  Engine();
  ~Engine();

  Engine(const Engine &) = delete;
  Engine &operator=(const Engine &) = delete;
  Engine(Engine &&) noexcept;
  Engine &operator=(Engine &&) noexcept;

  /// Single GLFW+Vulkan window with ImGui shell + continuous present.
  [[nodiscard]] VoidResult openWindow(const std::string &assetsRoot,
                                      uint32_t width, uint32_t height,
                                      const std::string &title);

  /// Headless offscreen (tests / PNG smoke).
  [[nodiscard]] VoidResult openOffscreen(const std::string &assetsRoot,
                                         uint32_t width, uint32_t height);

  void close();
  bool isOpen() const;

  void setWindowFrame(int x, int y, int width, int height);
  void setWindowVisible(bool visible);
  bool isWindowVisible() const;

  void clearProjectTreeBuilder();
  void addTreeItem(const std::string &id, const std::string &label,
                   int depth, bool selected);
  void commitProjectTree();

  void clearPropertiesBuilder();
  void addPropertyItem(const std::string &key, const std::string &value);
  void commitProperties();

  void setWorkspaceLayout(shell::Node root);
  void setWorkspaceColumns(shell::PanelKind left, shell::PanelKind center,
                           shell::PanelKind right,
                           float leftWidth, float rightWidth);

  // ─── Declarative UI (Swift tree → Yoga + TextRenderer) ────────────────
  void uiReset();
  void uiBegin(int kind, int id, float flexGrow, float flexShrink,
               float width, float height, float padding);
  void uiText(int id, const char *text, float r, float g, float b, bool clickable);
  void uiEnd();
  void uiCommit();
  /// Returns false if queue empty. kind: 0 = Click.
  bool uiPollEvent(int &outWidgetId, int &outKind);

  bool repaint();
  void readPixels(uint8_t *dst, size_t dstSize);

  /// Replace the retained immediate draw list (copied under the engine mutex).
  /// Text commands carry `param` = first glyph index and `w` = glyph count
  /// into `glyphs`. Swift shapes; the renderer only looks up atlas entries.
  void submitDrawList(const DrawCommand *cmds, size_t cmdCount,
                      const GlyphInstance *glyphs, size_t glyphCount);

  /// Pop one raw input event (mouse). Returns false if empty.
  bool pollInputEvent(InputEvent &out);

  /// Diagram panel origin in window pixels (for coordinate transforms).
  shell::Rect diagramViewport() const;

  /// Tell the engine where the diagram host lives (window pixels).
  void setDiagramViewport(float x, float y, float w, float h);

  /// Load TextRenderer face for draw-list text. Called from Swift FontStore
  /// after open — C++ does not choose a default path.
  [[nodiscard]] VoidResult loadFont(const std::string &path, float pixelSize);

  /// Registers a face for draw-list glyph lookup and returns its id, or -1.
  /// Idempotent per (path, pixelSize). Swift stamps this id into every
  /// GlyphInstance so the renderer resolves ids against the right face.
  int registerFont(const std::string &path, float pixelSize);

  /// Low-level access for advanced use; may be null if closed.
  Application *application();

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

} // namespace canvas
