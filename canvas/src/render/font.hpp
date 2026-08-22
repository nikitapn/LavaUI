#pragma once

// A loaded typeface: owns FreeType (rasterization) + HarfBuzz (shaping)
// state for one font file at one fixed pixel size, and is the single place
// text gets shaped. Both measure() (called from Swift, during layout) and
// whatever actually draws the glyphs (called from C++, during rendering)
// go through the same Font instance, so a measured width can never drift
// from what gets drawn — the whole reason this exists rather than shaping
// independently on each side.
//
// This also replaces something that doesn't really exist yet: today's
// TextRenderer walks codepoints one at a time via FT_Get_Char_Index /
// FT_Load_Glyph, with FT_Get_Kerning (legacy `kern` table only) as its only
// nod to spacing — no real shaping, no ligatures, no GPOS. Routing drawing
// through Font::shape() alongside Font::measure() is a render-quality
// upgrade, not just a Swift-interop convenience.
//
// Pimpl on purpose, same reasoning as canvas::Engine: keeps HarfBuzz's and
// FreeType's real headers out of anything that imports this file (Swift's
// C++ interop included) — Impl (font.cpp only) is the one place that
// #includes <hb.h> / <ft2build.h>.

// Directory-relative (not "util/result.hpp"-from-include-root) so this
// header resolves standalone via quote-include's current-file-relative
// search — same reasoning as canvas_engine.hpp, which canvas_swift's
// CxxCanvas shim depends on too.
#include "../util/result.hpp"
#include "font_key.hpp"

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace canvas {

/// Aggregate metrics for a shaped run — what a Yoga measure function needs
/// to size a Text node, before anything is drawn.
struct TextMetrics {
  float width = 0.f;
  float height = 0.f;
  /// Baseline to top/bottom of the line box — wanted for aligning runs of
  /// mixed font size on the same line (Yoga's baseline-alignment support).
  float ascent = 0.f;
  float descent = 0.f;
};

/// One glyph, already positioned relative to the run's origin (pen
/// position — cumulative advances and any GPOS/kerning adjustments already
/// baked in) — what the renderer walks to actually draw a shaped run.
struct PositionedGlyph {
  uint32_t glyphId = 0;
  /// Byte offset into the shaped string this glyph came from (HarfBuzz
  /// cluster). Without it there is no way to map a click x to a cursor
  /// position or a cursor position back to a caret x: shaping is not
  /// one-glyph-per-character, so ligatures and combining marks break any
  /// positional guess. Text editing is impossible without this field.
  uint32_t cluster = 0;
  float x = 0.f;
  float y = 0.f;
  /// Horizontal advance. Needed for the caret midpoint test; it is *not*
  /// `next.x - x`, because `x` also carries GPOS/kerning offsets.
  float advance = 0.f;
};

/// One rasterized glyph — 8-bit grayscale coverage, row-major, no padding
/// (matches the atlas texture format text_renderer.cpp already uses,
/// VK_FORMAT_R8_UNORM). Empty (width/height 0, pixels empty) for glyphs
/// with no ink, e.g. space — same thing FreeType itself returns for those,
/// just without a caller needing to know that's a FreeType-ism.
struct GlyphBitmap {
  int width = 0;
  int height = 0;
  /// Offset from the pen position to the bitmap's top-left corner.
  float bearingX = 0.f;
  float bearingY = 0.f;
  std::vector<uint8_t> pixels;
};

class Font {
  struct Impl;
  std::unique_ptr<Impl> impl_;

 public:
  Font();
  ~Font();

  // Explicit move ctor/assignment required: an out-of-line destructor
  // (needed for the pimpl idiom) suppresses the implicit move ctor, and the
  // unique_ptr member already blocks the copy ctor — without these the
  // type has no copy/move semantics and Swift's C++ interop won't import
  // it. (Same gotcha CanvasBridge and canvas::Engine already hit.)
  Font(const Font &) = delete;
  Font &operator=(const Font &) = delete;
  Font(Font &&) noexcept;
  Font &operator=(Font &&) noexcept;

  // Loads a font file at a fixed pixel size (like FT_Set_Pixel_Sizes —
  // there's no resize once loaded; load a second Font for a different
  // size). A two-phase init (default-construct, then this) rather than a
  // factory returning Result<Font>, mirroring Engine::openWindow: Swift
  // can call has_value() on the returned VoidResult, but couldn't reach
  // into a Result<Font>'s success value any more than it can call
  // VoidResult::error() today (std::expected::value() also returns a
  // reference — same "won't call, might be an interior pointer" refusal).
  // The object already exists either way; this just fills it in.
  [[nodiscard]] VoidResult load(const std::string &path, float pixelSize);

  /// The full form: a face inside a collection, a size that is already 26.6,
  /// and a hinting selection. `load` above is this one with face 0 and the
  /// renderer's default hinting, kept because most callers want a font file
  /// at a size and nothing else.
  [[nodiscard]] VoidResult loadFace(const std::string &path,
                                    uint32_t pixelSize26_6, uint32_t faceIndex,
                                    uint32_t rasterFlags);

  /// The same, from bytes the caller already has.
  ///
  /// This is the one the font registry uses, and the reason it exists is that
  /// identity is content: the registry has to hash the file to know whether it
  /// has this face already, and having read it, handing the same bytes on
  /// costs nothing where re-opening the path costs two more reads — FreeType's
  /// and HarfBuzz's. The bytes are copied and owned here, so the caller's
  /// buffer need not outlive the call.
  [[nodiscard]] VoidResult loadFaceFromMemory(const uint8_t *bytes,
                                              size_t byteCount,
                                              uint32_t pixelSize26_6,
                                              uint32_t faceIndex,
                                              uint32_t rasterFlags);

  bool isLoaded() const;

  /// How many faces the loaded file contains — 1 for a plain font, more for a
  /// `.ttc`/`.otc` collection. Valid indices are `0 … faceCount() - 1`.
  uint32_t faceCount() const;

  // Shapes `text` (HarfBuzz, full GSUB/GPOS — ligatures, kerning, the
  // works) as a single line and returns its aggregate size. This is what a
  // Yoga measure function calls from Swift when it has no width constraint
  // (YGMeasureModeUndefined) — see the overload below for wrapping.
  TextMetrics measure(const std::string &text) const;

  // Word-wraps `text` to `availWidth` and returns the wrapped block's size
  // — the width-constrained counterpart Yoga's measure callback actually
  // needs (it's invoked with an available width and a YGMeasureMode on
  // every pass). `mode` mirrors YGMeasureMode's own values exactly
  // (Undefined=0, Exactly=1, AtMost=2) rather than Font depending on
  // Yoga's header — pass the YGMeasureMode value straight through:
  //   Undefined: availWidth ignored, identical to the single-arg overload.
  //   AtMost:    wrap at availWidth; width returned is the actual longest
  //              wrapped line (<= availWidth, except a single word wider
  //              than availWidth on its own line, which can't be broken
  //              further and overflows it — same as Yoga/CSS do).
  //   Exactly:   wrap at availWidth; width returned is availWidth itself
  //              (the caller dictated it, this doesn't second-guess it),
  //              height is whatever the wrapped content needs.
  // height is lineHeight() * number of wrapped lines.
  //
  // Wraps on whitespace and explicit '\n' only — words themselves are
  // never split. Each word is shaped independently (no cross-word
  // kerning), which is the standard approach: kerning is a within-run
  // concept and real text engines don't apply it across a line-break
  // opportunity anyway.
  //
  // shape() is still single-line only (see docs/declarative-ui-plan.md's
  // open questions) — draw a wrapped block one shape() call per line,
  // split the same way this does, until shape() itself grows a
  // width/mode overload.
  TextMetrics measure(const std::string &text, float availWidth, int mode) const;

  /// Same wrap as `measure(..., AtMost)`. Stores lines on the Font until the
  /// next prepareWrap (Swift interop — no std::vector / big C arrays).
  /// Returns line count.
  int prepareWrap(const std::string &text, float availWidth);

  /// Copy line `index` from the last prepareWrap into `buf` (NUL-terminated).
  /// Returns false if index is out of range.
  bool wrapLineAt(int index, char *buf, int cap) const;

  /// Shapes `text` and retains the run until the next prepareShape().
  /// Two-phase like prepareWrap/wrapLineAt so no std::vector crosses the
  /// Swift boundary. Returns the glyph count.
  ///
  /// This is what makes Swift the single shaping site: Swift shapes once per
  /// unique (text, font), caches the run, and ships glyph ids + pen positions
  /// in the draw list. The renderer never re-shapes, so a drawn run cannot
  /// drift from the run that was measured for layout.
  int prepareShape(const std::string &text);

  /// Bulk-copy the last prepareShape() run into a caller-owned buffer.
  /// Returns the number of glyphs written (<= maxCount).
  int copyShapedGlyphs(PositionedGlyph *dst, int maxCount) const;

  // Shapes `text` and returns each glyph's pen position — the exact same
  // shaping call measure() makes, so a run's drawn width always matches
  // what measure() reported for it. This is primarily a C++-internal
  // renderer entry point (Application/TextRenderer walking the result to
  // draw), not something Swift is expected to call directly: the glyph
  // atlas/texture upload stays TextRenderer's job — this only says where
  // each glyph goes and (via rasterize()) what it looks like.
  std::vector<PositionedGlyph> shape(const std::string &text) const;

  // Rasterizes one glyph, addressed by glyph index (as returned by
  // shape() — not a Unicode codepoint: FreeType's FT_Load_Glyph wants the
  // index directly, same as HarfBuzz already resolved it to, so no
  // separate FT_Get_Char_Index lookup is needed here either). TextRenderer
  // calls this once per not-yet-cached glyph and uploads the bitmap into
  // its own atlas; Font doesn't know Vulkan exists.
  GlyphBitmap rasterize(uint32_t glyphId) const;

  float pixelSize() const;
  float lineHeight() const;
};

} // namespace canvas
