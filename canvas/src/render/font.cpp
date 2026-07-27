#include "render/font.hpp"

#include <ft2build.h>
#include FT_FREETYPE_H

#include <hb-ot.h>
#include <hb.h>

#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <cstring>

namespace canvas {

struct Font::Impl {
  FT_Library ftLibrary = nullptr;
  FT_Face ftFace = nullptr;

  hb_blob_t *hbBlob = nullptr;
  hb_face_t *hbFace = nullptr;
  hb_font_t *hbFont = nullptr;

  float pixelSize = 0.f;
  float ascent = 0.f;
  float descent = 0.f;
  float lineHeight = 0.f;

  ~Impl() { unload(); }

  bool isLoaded() const { return hbFont != nullptr && ftFace != nullptr; }

  void unload() {
    if (hbFont) {
      hb_font_destroy(hbFont);
      hbFont = nullptr;
    }
    if (hbFace) {
      hb_face_destroy(hbFace);
      hbFace = nullptr;
    }
    if (hbBlob) {
      hb_blob_destroy(hbBlob);
      hbBlob = nullptr;
    }
    if (ftFace) {
      FT_Done_Face(ftFace);
      ftFace = nullptr;
    }
    if (ftLibrary) {
      FT_Done_FreeType(ftLibrary);
      ftLibrary = nullptr;
    }
  }
};

namespace {

// Shapes `text` against `font`, returning a buffer the caller must destroy.
// Shared by measure() and shape() so they can never disagree about what
// shaping produces — same buffer setup, same hb_shape() call, every time.
hb_buffer_t *shapeText(hb_font_t *font, const std::string &text) {
  hb_buffer_t *buffer = hb_buffer_create();
  hb_buffer_add_utf8(
    buffer, text.c_str(), static_cast<int>(text.size()), 0, static_cast<int>(text.size()));
  hb_buffer_guess_segment_properties(buffer);
  hb_shape(font, buffer, nullptr, 0);
  return buffer;
}

// Shapes `text` and sums its glyph advances — the width-only fast path
// wrapLineWidths() needs per word, without paying for a PositionedGlyph
// vector it isn't going to use.
float shapedWidth(hb_font_t *font, const std::string &text) {
  hb_buffer_t *buffer = shapeText(font, text);
  unsigned int glyphCount = 0;
  hb_glyph_position_t *positions = hb_buffer_get_glyph_positions(buffer, &glyphCount);
  float width = 0.f;
  for (unsigned int i = 0; i < glyphCount; ++i) {
    width += static_cast<float>(positions[i].x_advance) / 64.f;
  }
  hb_buffer_destroy(buffer);
  return width;
}

// Greedy word-wrap: packs whitespace-separated words onto lines no wider
// than availWidth, breaking early on explicit '\n'. Words are never split —
// a single word wider than availWidth still gets its own (overflowing)
// line, same as Yoga/CSS. Each word is shaped independently (no cross-word
// kerning — standard for line-breaking; kerning isn't a thing across a
// break opportunity in real text engines either). Always returns at least
// one (possibly zero-width) line.
std::vector<float> wrapLineWidths(hb_font_t *font, const std::string &text, float availWidth) {
  std::vector<float> lineWidths;
  const float spaceWidth = shapedWidth(font, " ");

  float currentLineWidth = 0.f;
  bool lineHasContent = false;

  auto endLine = [&] {
    lineWidths.push_back(currentLineWidth);
    currentLineWidth = 0.f;
    lineHasContent = false;
  };

  size_t pos = 0;
  while (pos < text.size()) {
    if (text[pos] == '\n') {
      endLine();
      ++pos;
      continue;
    }
    if (std::isspace(static_cast<unsigned char>(text[pos]))) {
      ++pos;
      continue;
    }

    size_t wordStart = pos;
    while (pos < text.size() && !std::isspace(static_cast<unsigned char>(text[pos]))) {
      ++pos;
    }
    const float wordWidth = shapedWidth(font, text.substr(wordStart, pos - wordStart));

    const float advanceIfAppended = (lineHasContent ? spaceWidth : 0.f) + wordWidth;
    if (lineHasContent && currentLineWidth + advanceIfAppended > availWidth) {
      endLine();
      currentLineWidth = wordWidth;
      lineHasContent = true;
    } else {
      currentLineWidth += advanceIfAppended;
      lineHasContent = true;
    }
  }

  if (lineHasContent || lineWidths.empty()) {
    lineWidths.push_back(currentLineWidth);
  }

  return lineWidths;
}

} // namespace

Font::Font() : impl_(std::make_unique<Impl>()) {}
Font::~Font() = default;
Font::Font(Font &&) noexcept = default;
Font &Font::operator=(Font &&) noexcept = default;

VoidResult Font::load(const std::string &path, float pixelSize) {
  impl_->unload();

  FT_Error ftError = FT_Init_FreeType(&impl_->ftLibrary);
  if (ftError) {
    return fail("Font::load: failed to initialize FreeType");
  }

  ftError = FT_New_Face(impl_->ftLibrary, path.c_str(), 0, &impl_->ftFace);
  if (ftError) {
    impl_->unload();
    return fail("Font::load: failed to load font: " + path);
  }

  FT_Set_Pixel_Sizes(impl_->ftFace, 0, static_cast<FT_UInt>(pixelSize));

  // Independent load from the same file, not a shared buffer with
  // FreeType — simpler lifetime bookkeeping than reusing one blob for
  // both, at the cost of reading a (small) font file from disk twice, once
  // at load time only.
  impl_->hbBlob = hb_blob_create_from_file(path.c_str());
  if (!impl_->hbBlob || hb_blob_get_length(impl_->hbBlob) == 0) {
    impl_->unload();
    return fail("Font::load: HarfBuzz failed to read font: " + path);
  }

  impl_->hbFace = hb_face_create(impl_->hbBlob, 0);
  impl_->hbFont = hb_font_create(impl_->hbFace);
  hb_ot_font_set_funcs(impl_->hbFont);
  // 26.6 fixed-point, HarfBuzz's convention (matches FreeType's).
  const int scale = static_cast<int>(pixelSize * 64.f);
  hb_font_set_scale(impl_->hbFont, scale, scale);

  impl_->pixelSize = pixelSize;
  impl_->ascent = static_cast<float>(impl_->ftFace->size->metrics.ascender) / 64.f;
  impl_->descent = static_cast<float>(-impl_->ftFace->size->metrics.descender) / 64.f;
  impl_->lineHeight =
    static_cast<float>(
      impl_->ftFace->size->metrics.ascender - impl_->ftFace->size->metrics.descender)
    / 64.f;

  return ok();
}

bool Font::isLoaded() const { return impl_->isLoaded(); }

// Both measure() and shape() assume single-line input — callers doing
// multi-line layout are expected to split on '\n' themselves and call once
// per line, same as the existing (naive) TextRenderer does today.

TextMetrics Font::measure(const std::string &text) const {
  if (!impl_->isLoaded() || text.empty()) {
    return TextMetrics{0.f, impl_->lineHeight, impl_->ascent, impl_->descent};
  }

  hb_buffer_t *buffer = shapeText(impl_->hbFont, text);
  unsigned int glyphCount = 0;
  hb_glyph_position_t *positions = hb_buffer_get_glyph_positions(buffer, &glyphCount);

  float width = 0.f;
  for (unsigned int i = 0; i < glyphCount; ++i) {
    width += static_cast<float>(positions[i].x_advance) / 64.f;
  }

  hb_buffer_destroy(buffer);

  return TextMetrics{width, impl_->lineHeight, impl_->ascent, impl_->descent};
}

TextMetrics Font::measure(const std::string &text, float availWidth, int mode) const {
  constexpr int kUndefined = 0;
  constexpr int kExactly = 1;
  // kAtMost = 2, the only remaining value — checked implicitly below.

  if (mode == kUndefined) {
    return measure(text);
  }

  if (!impl_->isLoaded() || text.empty()) {
    return TextMetrics{
      mode == kExactly ? availWidth : 0.f, impl_->lineHeight, impl_->ascent, impl_->descent};
  }

  std::vector<float> lineWidths = wrapLineWidths(impl_->hbFont, text, availWidth);

  float width = availWidth;
  if (mode != kExactly) {
    width = 0.f;
    for (float lineWidth : lineWidths) {
      width = std::max(width, lineWidth);
    }
  }

  return TextMetrics{
    width,
    impl_->lineHeight * static_cast<float>(lineWidths.size()),
    impl_->ascent,
    impl_->descent,
  };
}

std::vector<PositionedGlyph> Font::shape(const std::string &text) const {
  std::vector<PositionedGlyph> result;
  if (!impl_->isLoaded() || text.empty()) {
    return result;
  }

  hb_buffer_t *buffer = shapeText(impl_->hbFont, text);
  unsigned int glyphCount = 0;
  hb_glyph_info_t *infos = hb_buffer_get_glyph_infos(buffer, &glyphCount);
  hb_glyph_position_t *positions = hb_buffer_get_glyph_positions(buffer, &glyphCount);

  result.reserve(glyphCount);
  float penX = 0.f;
  float penY = 0.f;
  for (unsigned int i = 0; i < glyphCount; ++i) {
    // infos[i].codepoint is a glyph index post-shaping, not a Unicode
    // codepoint (HarfBuzz repurposes the field) — exactly what FreeType's
    // FT_Load_Glyph wants, and what lets a ligature (several codepoints,
    // one glyph) come through correctly instead of the old per-codepoint
    // FT_Get_Char_Index walk.
    result.push_back(PositionedGlyph{
      infos[i].codepoint,
      penX + static_cast<float>(positions[i].x_offset) / 64.f,
      penY - static_cast<float>(positions[i].y_offset) / 64.f,
    });
    penX += static_cast<float>(positions[i].x_advance) / 64.f;
    penY += static_cast<float>(positions[i].y_advance) / 64.f;
  }

  hb_buffer_destroy(buffer);
  return result;
}

GlyphBitmap Font::rasterize(uint32_t glyphId) const {
  GlyphBitmap result;
  if (!impl_->isLoaded()) {
    return result;
  }

  // Unlike the old FT_Get_Char_Index(codepoint) + FT_Load_Glyph two-step,
  // glyphId is already a glyph index (HarfBuzz resolved it during
  // shaping), so this loads it directly — the step that lets a ligature's
  // single substituted glyph rasterize correctly instead of only ever
  // being reachable by codepoint.
  FT_Error error = FT_Load_Glyph(impl_->ftFace, glyphId, FT_LOAD_DEFAULT);
  if (error) {
    return result;
  }
  error = FT_Render_Glyph(impl_->ftFace->glyph, FT_RENDER_MODE_NORMAL);
  if (error) {
    return result;
  }

  FT_GlyphSlot slot = impl_->ftFace->glyph;
  const FT_Bitmap &bitmap = slot->bitmap;

  result.width = static_cast<int>(bitmap.width);
  result.height = static_cast<int>(bitmap.rows);
  result.bearingX = static_cast<float>(slot->bitmap_left);
  result.bearingY = static_cast<float>(slot->bitmap_top);

  if (bitmap.width > 0 && bitmap.rows > 0) {
    // FreeType rows may be padded (bitmap.pitch != width) — copy row by
    // row rather than assuming a tightly packed buffer.
    result.pixels.resize(static_cast<size_t>(bitmap.width) * bitmap.rows);
    for (unsigned int row = 0; row < bitmap.rows; ++row) {
      std::memcpy(
        result.pixels.data() + static_cast<size_t>(row) * bitmap.width,
        bitmap.buffer + static_cast<size_t>(row) * std::abs(bitmap.pitch),
        bitmap.width);
    }
  }

  return result;
}

float Font::pixelSize() const { return impl_->pixelSize; }
float Font::lineHeight() const { return impl_->lineHeight; }

} // namespace canvas
