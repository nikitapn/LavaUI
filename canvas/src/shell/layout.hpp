#pragma once

// Yoga-backed layout for the app chrome (tree | diagram | properties).
//
// Swift (or C++) can later push a Node tree; for now Application builds
// defaultWorkspace() and reads Placement rects each frame.

#include <cstdint>
#include <vector>

namespace shell {

enum class PanelKind : uint8_t {
  ProjectTree = 0,
  Diagram = 1,
  Properties = 2,
  Log = 3,
};

struct FlexStyle {
  float flexGrow = 0.f;
  float flexShrink = 1.f;
  float flexBasis = -1.f; // <0 = auto
  float minWidth = 0.f;
  float minHeight = 0.f;
  float width = -1.f;  // <0 = auto
  float height = -1.f; // <0 = auto
  float padding = 0.f;
};

struct Node {
  enum class Kind { Leaf, Row, Column } kind = Kind::Leaf;
  PanelKind panel = PanelKind::Diagram;
  FlexStyle style{};
  std::vector<Node> children;
};

struct Rect {
  float x = 0, y = 0, w = 0, h = 0;
};

struct Placement {
  PanelKind panel = PanelKind::Diagram;
  Rect rect{};
};

/// Default 3-column workspace: fixed left/right, flex-grow diagram.
Node defaultWorkspace(float leftWidth = 220.f, float rightWidth = 260.f);

/// Three-column row with explicit panel kinds and fixed side widths.
Node columns(PanelKind left, PanelKind center, PanelKind right,
             float leftWidth, float rightWidth);

/// Run Yoga and return absolute pixel rects for every leaf panel.
std::vector<Placement> calculateLayout(const Node &root, float width, float height);

} // namespace shell
