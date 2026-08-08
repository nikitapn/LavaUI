#include "decoration.hpp"

namespace lava {
namespace {

using canvas::DrawCommand;
using enum canvas::DrawCommandKind;

// RGBA8 little-endian — R in the low byte, so these read as 0xAABBGGRR.
constexpr uint32_t kBarFocused   = 0xff2e2a28u;
constexpr uint32_t kBarUnfocused = 0xff262322u;
constexpr uint32_t kTitle        = 0xffd8d4d0u;
constexpr uint32_t kTitleDim     = 0xff8a8785u;
constexpr uint32_t kGlyph        = 0xffc8c4c0u;
constexpr uint32_t kCloseHover   = 0xff4436d0u;  // a red, not a tint
constexpr uint32_t kButtonHover  = 0xff4a4442u;

/// Buttons are square, inset from the strip's edges.
constexpr float kButtonSize = 28.f;
constexpr float kButtonGap  = 2.f;
constexpr float kEdgePad    = 4.f;
constexpr float kTitlePad   = 12.f;

}  // namespace

bool Decoration::loadFont(const std::string &path, float pixelSize) {
  fontLoaded_ = font_.load(path, pixelSize).has_value();
  return fontLoaded_;
}

float Decoration::buttonCenterX(uint32_t width, int fromRight) {
  const float slot = kButtonSize + kButtonGap;
  return static_cast<float>(width) - kEdgePad - slot * fromRight -
         kButtonSize * 0.5f;
}

DecorationHit Decoration::hitTest(float x, float y, uint32_t width) {
  if (y < 0.f || y > static_cast<float>(kHeight)) return DecorationHit::Bar;
  // Right to left, in the order they are drawn.
  const std::pair<DecorationHit, int> buttons[] = {
      {DecorationHit::Close, 0},
      {DecorationHit::Maximize, 1},
  };
  for (const auto &[hit, slot] : buttons) {
    const float cx = buttonCenterX(width, slot);
    if (x >= cx - kButtonSize * 0.5f && x <= cx + kButtonSize * 0.5f) {
      return hit;
    }
  }
  return DecorationHit::Bar;
}

void Decoration::build(const std::string &title, uint32_t width,
                       DecorationHit hovered, bool focused) {
  commands_.clear();
  glyphs_.clear();

  const float w = static_cast<float>(width);
  const float h = static_cast<float>(kHeight);

  commands_.push_back({.kind = static_cast<uint32_t>(Rect),
                       .x = 0, .y = 0, .w = w, .h = h,
                       .color = focused ? kBarFocused : kBarUnfocused});

  // Title, shaped here. The compositor is the only process that knows a
  // window's title *and* has the atlas, so this is the one piece of text it
  // draws for itself rather than replaying from a client.
  if (fontLoaded_ && !title.empty()) {
    const auto shaped = font_.shape(title);
    // Vertically centred on the strip using the run's own metrics, so a
    // different size or face does not need this number changed.
    const canvas::TextMetrics metrics = font_.measure(title);
    const float baseline = (h + metrics.ascent - metrics.descent) * 0.5f;
    const float first = kTitlePad;
    // Stop before the buttons rather than drawing under them.
    const float limit = buttonCenterX(width, 1) - kButtonSize;
    for (const auto &g : shaped) {
      const float x = first + g.x;
      if (x > limit) break;
      glyphs_.push_back({.glyphId = g.glyphId,
                         .fontId  = fontId_,
                         .x       = x,
                         .y       = baseline + g.y});
    }
    if (!glyphs_.empty()) {
      // `param` is the first glyph index and `w` the count — the convention
      // every Text command follows, so the renderer never re-shapes.
      commands_.push_back({.kind  = static_cast<uint32_t>(Text),
                           .w     = static_cast<float>(glyphs_.size()),
                           .color = focused ? kTitle : kTitleDim,
                           .param = 0});
    }
  }

  // Buttons, right to left. Drawn as glyphs of their own would need a symbol
  // face and an atlas entry per state; two lines and a square are cheaper and
  // read the same at this size.
  const float cy = h * 0.5f;

  const float closeX = buttonCenterX(width, 0);
  if (hovered == DecorationHit::Close) {
    commands_.push_back({.kind = static_cast<uint32_t>(RoundedRect),
                         .x = closeX - kButtonSize * 0.5f,
                         .y = cy - kButtonSize * 0.5f,
                         .w = kButtonSize, .h = kButtonSize,
                         .color = kCloseHover, .aux = 6.f});
  }
  const float arm = 4.5f;
  commands_.push_back({.kind = static_cast<uint32_t>(Line),
                       .x = closeX - arm, .y = cy - arm,
                       .w = closeX + arm, .h = cy + arm, .color = kGlyph});
  commands_.push_back({.kind = static_cast<uint32_t>(Line),
                       .x = closeX - arm, .y = cy + arm,
                       .w = closeX + arm, .h = cy - arm, .color = kGlyph});

  const float maxX = buttonCenterX(width, 1);
  if (hovered == DecorationHit::Maximize) {
    commands_.push_back({.kind = static_cast<uint32_t>(RoundedRect),
                         .x = maxX - kButtonSize * 0.5f,
                         .y = cy - kButtonSize * 0.5f,
                         .w = kButtonSize, .h = kButtonSize,
                         .color = kButtonHover, .aux = 6.f});
  }
  // An outline, drawn as four lines: a filled rect would need a second one
  // punched out of it, and there is no such command.
  const float box = 4.5f;
  const float corners[4][4] = {
      {maxX - box, cy - box, maxX + box, cy - box},
      {maxX + box, cy - box, maxX + box, cy + box},
      {maxX + box, cy + box, maxX - box, cy + box},
      {maxX - box, cy + box, maxX - box, cy - box},
  };
  for (const auto &c : corners) {
    commands_.push_back({.kind = static_cast<uint32_t>(Line),
                         .x = c[0], .y = c[1], .w = c[2], .h = c[3],
                         .color = kGlyph});
  }
}

}  // namespace lava
