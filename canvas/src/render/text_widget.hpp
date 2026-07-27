#pragma once

#include <cstdint>
#include <string>
#include <vector>

#include "text_highlight_rule.hpp"

struct ImDrawList;
struct ImFont;

/// In-canvas multiline text field: stb_textedit for editing, ImDrawList for
/// painting (including per-run regex colors). Lives in the ImGui frame so it
/// shares the same Vulkan pass as the debug UI.
class CanvasTextWidget {
 public:
  float x = 0.f, y = 0.f, w = 120.f, h = 40.f;
  bool multiline = true;
  bool focused = false;
  /// Set when the buffer changes via typing/paste; cleared by consumeChanged().
  bool changed = false;

  CanvasTextWidget();
  ~CanvasTextWidget();

  CanvasTextWidget(const CanvasTextWidget&) = delete;
  CanvasTextWidget& operator=(const CanvasTextWidget&) = delete;
  CanvasTextWidget(CanvasTextWidget&&) noexcept;
  CanvasTextWidget& operator=(CanvasTextWidget&&) noexcept;

  void setText(std::string text);
  const std::string& text() const { return text_; }

  /// Compiles rules; skips any pattern that fails to compile. Returns false
  /// if at least one pattern failed (successful ones are still applied).
  bool setHighlightRules(const std::vector<TextHighlightRule>& rules);

  void rehighlight();

  bool hitTest(float mx, float my) const;

  /// Coordinates are canvas-local (top-left origin, y-down), same as shapes.
  void onMouseDown(float mx, float my);
  void onMouseDrag(float mx, float my);
  void onMouseUp(float mx, float my);

  /// `key` uses GLFW-style codes (see util/key_codes.hpp). `action` is
  /// ACTION_PRESS / ACTION_RELEASE / ACTION_REPEAT. `mods`: bit0=shift,
  /// bit1=ctrl, bit2=alt (matching GLFW).
  void onKey(int key, int action, int mods);
  void onTextInput(const char* utf8);

  bool consumeChanged() {
    bool c = changed;
    changed = false;
    return c;
  }

  /// Call once per frame inside ImGui::NewFrame()…ImGui::Render().
  void draw(ImDrawList* drawList, ImFont* font, float fontSize, float deltaTime);

  // --- used by stb_textedit adapters in text_widget.cpp ---
  std::string& mutableText() { return text_; }
  const std::string& mutableText() const { return text_; }
  float lineHeight() const { return line_height_; }
  float charWidthAt(int index) const;
  void notifyBufferChanged();

 private:
  std::string text_;
  // Opaque STB_TexteditState — heap-allocated so the header stays free of
  // stb macros / the large undo struct.
  struct EditState;
  EditState* edit_ = nullptr;

  struct CompiledRule {
    std::string pattern;
    void* regex = nullptr; // std::regex*, owned
    uint32_t color = 0xffffffff;
    int priority = 0;
    int capture_group = 0;
  };
  std::vector<CompiledRule> rules_;

  struct StyleRun {
    int start = 0;
    int end = 0;
    uint32_t color = 0xffffffff;
  };
  std::vector<StyleRun> runs_;

  ImFont* font_ = nullptr;
  float font_size_ = 16.f;
  float line_height_ = 18.f;
  float pad_ = 4.f;
  float scroll_x_ = 0.f;
  float scroll_y_ = 0.f;
  float caret_blink_ = 0.f;
  bool mouse_down_ = false;

  void ensureCaretVisible();
  void clearRules();
  float contentX() const { return x + pad_ - scroll_x_; }
  float contentY() const { return y + pad_ - scroll_y_; }
};
