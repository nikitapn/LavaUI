#include "shell/layout.hpp"

#include <yoga/Yoga.h>

#include <functional>

namespace shell {
namespace {

void applyStyle(YGNodeRef node, const FlexStyle &s)
{
  YGNodeStyleSetFlexGrow(node, s.flexGrow);
  YGNodeStyleSetFlexShrink(node, s.flexShrink);
  if (s.flexBasis >= 0.f) {
    YGNodeStyleSetFlexBasis(node, s.flexBasis);
  }
  if (s.width >= 0.f) {
    YGNodeStyleSetWidth(node, s.width);
  } else {
    YGNodeStyleSetWidthAuto(node);
  }
  if (s.height >= 0.f) {
    YGNodeStyleSetHeight(node, s.height);
  } else {
    YGNodeStyleSetHeightAuto(node);
  }
  if (s.minWidth > 0.f) YGNodeStyleSetMinWidth(node, s.minWidth);
  if (s.minHeight > 0.f) YGNodeStyleSetMinHeight(node, s.minHeight);
  if (s.padding > 0.f) {
    YGNodeStyleSetPadding(node, YGEdgeAll, s.padding);
  }
}

YGNodeRef buildNode(const Node &desc)
{
  YGNodeRef node = YGNodeNew();
  applyStyle(node, desc.style);

  switch (desc.kind) {
  case Node::Kind::Row:
    YGNodeStyleSetFlexDirection(node, YGFlexDirectionRow);
    break;
  case Node::Kind::Column:
    YGNodeStyleSetFlexDirection(node, YGFlexDirectionColumn);
    break;
  case Node::Kind::Leaf:
    // Leaf: optional fixed flex basis so empty panels still take space when
    // width/height are auto and grow is set by the parent.
    break;
  }

  // Store panel kind in context pointer (small enum stored as intptr).
  YGNodeSetContext(node, reinterpret_cast<void *>(static_cast<uintptr_t>(desc.panel)));

  for (size_t i = 0; i < desc.children.size(); ++i) {
    YGNodeRef child = buildNode(desc.children[i]);
    YGNodeInsertChild(node, child, static_cast<uint32_t>(i));
  }
  return node;
}

void collectLeaves(YGNodeConstRef node, float absX, float absY,
                   std::vector<Placement> &out)
{
  const float x = absX + YGNodeLayoutGetLeft(node);
  const float y = absY + YGNodeLayoutGetTop(node);
  const float w = YGNodeLayoutGetWidth(node);
  const float h = YGNodeLayoutGetHeight(node);

  const uint32_t childCount = YGNodeGetChildCount(node);
  if (childCount == 0) {
    Placement p;
    p.panel = static_cast<PanelKind>(
      reinterpret_cast<uintptr_t>(YGNodeGetContext(node)));
    p.rect = {x, y, w, h};
    out.push_back(p);
    return;
  }

  for (uint32_t i = 0; i < childCount; ++i) {
    // YGNodeGetChild takes non-const; layout is already computed.
    collectLeaves(
      YGNodeGetChild(const_cast<YGNodeRef>(node), i), x, y, out);
  }
}

} // namespace

Node columns(PanelKind left, PanelKind center, PanelKind right,
             float leftWidth, float rightWidth)
{
  Node root;
  root.kind = Node::Kind::Row;
  root.style.width = -1.f;
  root.style.height = -1.f;

  Node L;
  L.kind = Node::Kind::Leaf;
  L.panel = left;
  L.style.width = leftWidth;
  L.style.height = -1.f;
  L.style.flexShrink = 0.f;

  Node C;
  C.kind = Node::Kind::Leaf;
  C.panel = center;
  C.style.flexGrow = 1.f;
  C.style.flexShrink = 1.f;
  C.style.minWidth = 80.f;
  C.style.height = -1.f;

  Node R;
  R.kind = Node::Kind::Leaf;
  R.panel = right;
  R.style.width = rightWidth;
  R.style.height = -1.f;
  R.style.flexShrink = 0.f;

  root.children = {std::move(L), std::move(C), std::move(R)};
  return root;
}

Node defaultWorkspace(float leftWidth, float rightWidth)
{
  return columns(PanelKind::ProjectTree, PanelKind::Diagram, PanelKind::Properties,
                 leftWidth, rightWidth);
}

std::vector<Placement> calculateLayout(const Node &root, float width, float height)
{
  YGNodeRef tree = buildNode(root);
  YGNodeStyleSetWidth(tree, width);
  YGNodeStyleSetHeight(tree, height);

  YGNodeCalculateLayout(tree, width, height, YGDirectionLTR);

  std::vector<Placement> out;
  collectLeaves(tree, 0.f, 0.f, out);

  YGNodeFreeRecursive(tree);
  return out;
}

} // namespace shell
