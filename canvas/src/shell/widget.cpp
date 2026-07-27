#include "shell/widget.hpp"

#include <yoga/Yoga.h>

#include <algorithm>
#include <memory>

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

struct MeasureCtx {
  const WidgetDesc *desc = nullptr;
  MeasureTextFn measure;
};

YGSize textMeasure(YGNodeConstRef node, float /*width*/,
                   YGMeasureMode /*widthMode*/, float /*height*/,
                   YGMeasureMode /*heightMode*/)
{
  auto *ctx = static_cast<MeasureCtx *>(YGNodeGetContext(node));
  float w = 8.f, h = 18.f;
  if (ctx && ctx->desc && ctx->measure) {
    ctx->measure(ctx->desc->text, w, h);
  } else if (ctx && ctx->desc) {
    // Fallback: ~8px per code unit, 18px line height.
    w = std::max(8.f, static_cast<float>(ctx->desc->text.size()) * 8.f);
    h = 18.f;
  }
  // Padding for click target.
  return YGSize{w + 8.f, h + 6.f};
}

struct BuildCtx {
  MeasureTextFn measure;
  std::vector<std::unique_ptr<MeasureCtx>> measureCtxs;
};

YGNodeRef buildYG(const WidgetDesc &desc, BuildCtx &bctx)
{
  YGNodeRef node = YGNodeNew();
  applyStyle(node, desc.style);

  switch (desc.kind) {
  case WidgetKind::Row:
    YGNodeStyleSetFlexDirection(node, YGFlexDirectionRow);
    YGNodeStyleSetAlignItems(node, YGAlignStretch);
    break;
  case WidgetKind::Column:
    YGNodeStyleSetFlexDirection(node, YGFlexDirectionColumn);
    YGNodeStyleSetAlignItems(node, YGAlignStretch);
    break;
  case WidgetKind::Spacer:
    if (desc.style.flexGrow <= 0.f) {
      YGNodeStyleSetFlexGrow(node, 1.f);
    }
    break;
  case WidgetKind::DiagramHost:
    if (desc.style.flexGrow <= 0.f) {
      YGNodeStyleSetFlexGrow(node, 1.f);
    }
    YGNodeStyleSetFlexShrink(node, 1.f);
    if (desc.style.minWidth <= 0.f) {
      YGNodeStyleSetMinWidth(node, 80.f);
    }
    break;
  case WidgetKind::Text: {
    // Intrinsic size from font metrics when width/height not fixed.
    if (desc.style.width < 0.f || desc.style.height < 0.f) {
      auto mctx = std::make_unique<MeasureCtx>();
      mctx->desc = &desc;
      mctx->measure = bctx.measure;
      YGNodeSetMeasureFunc(node, textMeasure);
      YGNodeSetContext(node, mctx.get());
      bctx.measureCtxs.push_back(std::move(mctx));
    }
    break;
  }
  }

  // Keep widget id in context when no measure ctx (measure owns context).
  if (desc.kind != WidgetKind::Text ||
      (desc.style.width >= 0.f && desc.style.height >= 0.f)) {
    YGNodeSetContext(node, reinterpret_cast<void *>(
                             static_cast<intptr_t>(desc.id)));
  }

  for (size_t i = 0; i < desc.children.size(); ++i) {
    YGNodeRef child = buildYG(desc.children[i], bctx);
    YGNodeInsertChild(node, child, static_cast<uint32_t>(i));
  }
  return node;
}

void collect(YGNodeConstRef node, const WidgetDesc &desc,
             float absX, float absY,
             std::vector<LaidOutWidget> &out,
             std::optional<Rect> &diagramHost)
{
  const float x = absX + YGNodeLayoutGetLeft(node);
  const float y = absY + YGNodeLayoutGetTop(node);
  const float w = YGNodeLayoutGetWidth(node);
  const float h = YGNodeLayoutGetHeight(node);

  LaidOutWidget lw;
  lw.id = desc.id;
  lw.kind = desc.kind;
  lw.rect = {x, y, w, h};
  lw.text = desc.text;
  lw.r = desc.r;
  lw.g = desc.g;
  lw.b = desc.b;
  lw.a = desc.a;
  lw.clickable = desc.clickable && desc.id > 0;
  out.push_back(lw);

  if (desc.kind == WidgetKind::DiagramHost) {
    diagramHost = lw.rect;
  }

  const uint32_t n = YGNodeGetChildCount(node);
  for (uint32_t i = 0; i < n && i < desc.children.size(); ++i) {
    collect(YGNodeGetChild(const_cast<YGNodeRef>(node), i),
            desc.children[i], x, y, out, diagramHost);
  }
}

} // namespace

// ─── WidgetTree ─────────────────────────────────────────────────────────────

void WidgetTree::clear()
{
  hasRoot_ = false;
  root_ = {};
  laidOut_.clear();
  diagramHost_.reset();
  events_.clear();
}

void WidgetTree::setRoot(WidgetDesc root)
{
  root_ = std::move(root);
  hasRoot_ = true;
  laidOut_.clear();
  diagramHost_.reset();
  // Keep pending events — clicks that fired mid-rebuild still matter.
}

void WidgetTree::layout(float width, float height, const MeasureTextFn &measure)
{
  laidOut_.clear();
  diagramHost_.reset();
  if (!hasRoot_ || width <= 0.f || height <= 0.f) return;

  BuildCtx bctx;
  bctx.measure = measure;
  YGNodeRef tree = buildYG(root_, bctx);
  YGNodeStyleSetWidth(tree, width);
  YGNodeStyleSetHeight(tree, height);
  YGNodeCalculateLayout(tree, width, height, YGDirectionLTR);

  collect(tree, root_, 0.f, 0.f, laidOut_, diagramHost_);
  YGNodeFreeRecursive(tree);
}

int WidgetTree::hitTest(float x, float y) const
{
  // Walk reverse paint order (later = front).
  for (auto it = laidOut_.rbegin(); it != laidOut_.rend(); ++it) {
    if (!it->clickable) continue;
    const auto &r = it->rect;
    if (x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h) {
      return it->id;
    }
  }
  return -1;
}

void WidgetTree::enqueueClick(int widgetId)
{
  if (widgetId <= 0) return;
  events_.push_back(UIEvent{widgetId, UIEventKind::Click});
}

bool WidgetTree::pollEvent(UIEvent &out)
{
  if (events_.empty()) return false;
  out = events_.front();
  events_.erase(events_.begin());
  return true;
}

// ─── WidgetBuilder ──────────────────────────────────────────────────────────

void WidgetBuilder::reset()
{
  stack_.clear();
  root_ = {};
  rootBuilt_ = false;
}

void WidgetBuilder::begin(WidgetKind kind, int id, float flexGrow,
                          float flexShrink, float width, float height,
                          float padding)
{
  WidgetDesc n;
  n.id = id;
  n.kind = kind;
  n.style.flexGrow = flexGrow;
  n.style.flexShrink = flexShrink;
  n.style.width = width;
  n.style.height = height;
  n.style.padding = padding;
  stack_.push_back(std::move(n));
}

void WidgetBuilder::text(int id, const char *text, float r, float g, float b,
                         bool clickable)
{
  WidgetDesc n;
  n.id = id;
  n.kind = WidgetKind::Text;
  n.text = text ? text : "";
  n.r = r;
  n.g = g;
  n.b = b;
  n.clickable = clickable;
  n.style.flexShrink = 0.f;
  if (stack_.empty()) {
    root_ = std::move(n);
    rootBuilt_ = true;
    return;
  }
  stack_.back().children.push_back(std::move(n));
}

void WidgetBuilder::end()
{
  if (stack_.empty()) return;
  WidgetDesc finished = std::move(stack_.back());
  stack_.pop_back();
  if (stack_.empty()) {
    root_ = std::move(finished);
    rootBuilt_ = true;
  } else {
    stack_.back().children.push_back(std::move(finished));
  }
}

WidgetDesc WidgetBuilder::takeRoot()
{
  // Auto-close unclosed begins so a partial tree still works.
  while (!stack_.empty()) {
    end();
  }
  rootBuilt_ = false;
  return std::move(root_);
}

} // namespace shell
