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

  // ─── Shell model (driven from Swift FBDModel) ─────────────────────────
  void setProjectTree(std::vector<TreeItem> items);
  void setProperties(std::vector<PropertyItem> items);
  /// Currently selected tree id (empty if none).
  std::string selectedTreeId() const;

  // Incremental builders equivalent to setProjectTree/setProperties above,
  // for callers that can't construct std::vector<T> directly (Swift's C++
  // interop can call this API perfectly well, but as of this toolchain
  // can't spell `std.vector<T>` itself to build the argument — see the
  // note on Editor.swift). clear*/add*/commit* stages into Engine's own
  // buffer; commit* is what actually calls setProjectTree/setProperties.
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

  // ─── Scene (diagram geometry) ─────────────────────────────────────────
  int addRect(float x, float y, float w, float h,
              float r, float g, float b, float a = 1.f);
  void updateRect(int id, float x, float y, float w, float h,
                  float r, float g, float b, float a = 1.f);
  int addRoundedRect(float x, float y, float w, float h,
                     float r, float g, float b, float a = 1.f);
  int addCircle(float cx, float cy, float radius,
                float r, float g, float b, float a = 1.f);
  void removeShape(int id);
  void clearShapes();

  int addLine(float x1, float y1, float x2, float y2,
              float r, float g, float b, float a = 1.f);
  void removeLine(int id);
  void clearLines();

  int addLabel(const std::string &text, float x, float y,
               float r, float g, float b);
  void removeLabel(int id);
  void clearLabels();

  int addTextWidget(float x, float y, float w, float h,
                    const std::string &text, bool multiline);
  void setTextWidgetText(int id, const std::string &text);
  std::string textWidgetText(int id) const;
  bool setTextWidgetHighlightRules(int id, const std::vector<TextHighlightRule> &rules);
  /// Swift-friendly single-rule form of setTextWidgetHighlightRules (same
  /// std::vector-construction reason as the project tree/properties
  /// builders above). Replaces every existing rule on this widget with
  /// just this one — call once per pattern you want, in priority order,
  /// if you need more than one active rule at a time you'll want the
  /// batch overload from C++ instead.
  bool addTextWidgetHighlightRule(int id, const std::string &pattern,
                                  float r, float g, float b, float a,
                                  int priority);
  void setTextWidgetFocused(int id, bool focused);
  bool textWidgetChanged(int id);

  bool repaint();
  void readPixels(uint8_t *dst, size_t dstSize);

  /// Diagram panel origin in window pixels (for coordinate transforms).
  shell::Rect diagramViewport() const;

  /// Low-level access for advanced use; may be null if closed.
  Application *application();

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

} // namespace canvas
