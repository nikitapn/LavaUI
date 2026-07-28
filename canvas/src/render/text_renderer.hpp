#pragma once

#include <string>
#include <memory>

#include <vulkan/vulkan.h>

#include "util/result.hpp"
#include "util/types.hpp"

// Not canvas::TextMetrics (render/font.hpp) — that one's float
// width/height/ascent/descent for Yoga; this is TextRenderer's own
// pre-existing int w/h public contract, kept as-is so callers (e.g.
// Application::uiCommit's label sizing) don't need to change. Both are
// computed from the same canvas::Font now, just rounded differently.
struct TextMetrics {
  int w, h;
};

class Vulkan;

/// Glyph cache, not a renderer: owns the FreeType/HarfBuzz face and the
/// Vulkan atlas, and hands atlas rects to QuadRenderer. It has no pipeline of
/// its own — everything paints through the single ordered quad pass.
class TextRenderer {
  struct Impl;
  std::unique_ptr<Impl> impl_;
  
public:
  /// Does not load a font — call loadFont() after construction once the
  /// absolute path under assetsRoot is known (Application ctor runs before
  /// cwd/assetsRoot is set).
  explicit TextRenderer(Vulkan& vulkan);
  ~TextRenderer();
  
  // Non-copyable
  TextRenderer(const TextRenderer&) = delete;
  TextRenderer& operator=(const TextRenderer&) = delete;
  
  // Moveable
  TextRenderer(TextRenderer&& other) noexcept;
  TextRenderer& operator=(TextRenderer&& other) noexcept;

  /// Atlas rect + placement for one glyph, rasterizing and packing it on
  /// first use. This is all QuadRenderer needs to draw a glyph; TextRenderer
  /// keeps the atlas (expensive, content-keyed) and owns nothing else.
  struct GlyphQuad {
    vec2 uv0;      // atlas UV top-left
    vec2 uv1;      // atlas UV bottom-right
    vec2 size;     // pixel dimensions
    vec2 bearing;  // offset from pen position to the quad's top-left
  };
  bool glyphQuad(uint32_t fontId, uint32_t glyphId, GlyphQuad &out);

  /// Registers a face; returns its id (stable, idempotent) or -1. Glyph ids
  /// are face-relative, so every glyph must be looked up with the id of the
  /// font it was shaped with.
  int registerFont(const std::string &path, float pixelSize);

  /// Doubles the atlas if a glyph failed to fit. Call between frames — it
  /// replaces the image view, so re-bind via atlasView() when it returns true.
  bool growAtlasIfNeeded();
  uint32_t atlasGeneration() const;

  VkImageView atlasView() const;
  VkSampler   atlasSampler() const;

  // Main interface
  void init();
  /// Load FreeType face from an absolute (or process-cwd-relative) path.
  canvas::VoidResult loadFont(const std::string& fontPath, int fontSize);
  void cleanUp();
  
  // Utilities
  TextMetrics getTextMetrics(const std::string& text);
  float getLineHeight() const;
};

