#pragma once

// Declarative UI widget tree (Swift → C++).
//
// Swift builds a description (HStack/VStack/Text/…); C++ owns the runtime:
// Yoga layout, TextRenderer draw, hit-test, and a small event queue that
// Swift drains into Widget.onClick handlers.
//
// Hot update: re-commit a new root any time Swift state changes (full tree
// swap). Source-level Swift hot reload is a later step (plugin dylib).

#include "shell/layout.hpp"

#include <cstdint>
#include <functional>
#include <optional>
#include <string>
#include <vector>

namespace shell {

enum class WidgetKind : uint8_t {
  Row = 0,
  Column = 1,
  Text = 2,
  Spacer = 3,
  DiagramHost = 4,
};

struct WidgetDesc {
  int id = 0; // >0 → hit-testable / event target
  WidgetKind kind = WidgetKind::Text;
  std::string text;
  float r = 0.90f, g = 0.90f, b = 0.90f, a = 1.f;
  FlexStyle style{};
  bool clickable = false;
  std::vector<WidgetDesc> children;
};

enum class UIEventKind : uint8_t {
  Click = 0,
};

struct UIEvent {
  int widgetId = 0;
  UIEventKind kind = UIEventKind::Click;
};

/// Flattened layout result for one node (containers included for hit bounds).
struct LaidOutWidget {
  int id = 0;
  WidgetKind kind = WidgetKind::Text;
  Rect rect{};
  std::string text;
  float r = 0.9f, g = 0.9f, b = 0.9f, a = 1.f;
  bool clickable = false;
};

/// Measure callback: fill outW/outH for a text string (used by Yoga measure).
using MeasureTextFn = std::function<void(const std::string &text, float &outW, float &outH)>;

class WidgetTree {
 public:
  void clear();
  void setRoot(WidgetDesc root);
  bool hasRoot() const { return hasRoot_; }

  /// Run Yoga; fills laidOut_ and diagramHost_.
  void layout(float width, float height, const MeasureTextFn &measure);

  const std::vector<LaidOutWidget> &nodes() const { return laidOut_; }
  std::optional<Rect> diagramHostRect() const { return diagramHost_; }

  /// Top-most clickable widget containing (x,y), or -1.
  int hitTest(float x, float y) const;

  void enqueueClick(int widgetId);
  bool pollEvent(UIEvent &out);

 private:
  WidgetDesc root_{};
  bool hasRoot_ = false;
  std::vector<LaidOutWidget> laidOut_;
  std::optional<Rect> diagramHost_;
  std::vector<UIEvent> events_;
};

/// Stack-based builder used by the Swift interop free functions.
class WidgetBuilder {
 public:
  void reset();
  void begin(WidgetKind kind, int id, float flexGrow, float flexShrink,
             float width, float height, float padding);
  void text(int id, const char *text, float r, float g, float b, bool clickable);
  void end();
  /// Take ownership of the built tree (must have exactly one root).
  WidgetDesc takeRoot();
  bool hasRoot() const { return !stack_.empty() || rootBuilt_; }

 private:
  std::vector<WidgetDesc> stack_;
  WidgetDesc root_{};
  bool rootBuilt_ = false;
};

} // namespace shell
