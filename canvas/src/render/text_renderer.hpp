#pragma once

#include <string>
#include <memory>
#include <shared_mutex>

#include <vulkan/vulkan.h>

#include "util/result.hpp"
#include "util/types.hpp"

class RenderDevice;

/// Glyph cache, not a renderer: owns the FreeType/HarfBuzz face and the
/// Vulkan atlas, and hands atlas rects to QuadRenderer. It has no pipeline of
/// its own — everything paints through the single ordered quad pass.
class TextRenderer {
  struct Impl;
  std::unique_ptr<Impl> impl_;
  /// Guards the glyph cache and the atlas it packs into.
  ///
  /// Shared for the hit path, which is almost every call: several windows
  /// drawing already-cached text read `glyphMap_` and conflict over nothing.
  /// Exclusive for a miss, which rasterizes, packs and uploads.
  ///
  /// The upload stays inside the exclusive section deliberately. Releasing
  /// before it would publish a glyph whose UVs name atlas pixels the GPU has
  /// not received yet, and another window reading the map in that window draws
  /// garbage. A miss is rare; a wrong frame is not worth the microseconds.
  mutable std::shared_mutex mutex_;

public:
  /// Does not load a font — call loadFont() after construction once the
  /// absolute path under assetsRoot is known (Application ctor runs before
  /// cwd/assetsRoot is set).
  explicit TextRenderer(RenderDevice& device);
  ~TextRenderer();

  // Non-copyable
  TextRenderer(const TextRenderer&) = delete;
  TextRenderer& operator=(const TextRenderer&) = delete;

  // Not moveable either. `RenderDevice` owns the one instance through a
  // `unique_ptr` and never moves it, and a move could not be made safe: it
  // leaves `impl_` null while every other method dereferences it, so locking
  // `other.mutex_` inside one only advertises a guarantee it cannot keep.
  TextRenderer(TextRenderer&&) = delete;
  TextRenderer& operator=(TextRenderer&&) = delete;

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

  /// True if a glyph failed to pack and growAtlasIfNeeded() will replace the
  /// atlas image. Caller should wait for all in-flight frames first.
  bool atlasNeedsGrow() const;

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
};
