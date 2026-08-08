#include "render/font.hpp"

#include <ft2build.h>
#include FT_FREETYPE_H

#include <hb-ot.h>
#include <hb.h>

#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

namespace canvas {

struct Font::Impl {
  FT_Library ftLibrary = nullptr;
  FT_Face ftFace = nullptr;

  hb_blob_t *hbBlob = nullptr;
  hb_face_t *hbFace = nullptr;
  hb_font_t *hbFont = nullptr;

  /// The file, owned here. FreeType and HarfBuzz both point into it rather
  /// than re-reading the path, so it must outlive both — which is why
  /// `unload` clears it last.
  std::vector<uint8_t> bytes;
  FontDigest digest;

  float pixelSize = 0.f;
  float ascent = 0.f;
  float descent = 0.f;
  float lineHeight = 0.f;

  uint32_t faceCount = 0;
  /// Precomputed from `rasterFlags` once, because it is wanted per glyph.
  int32_t loadFlags = FT_LOAD_DEFAULT;

  /// Last prepareWrap result (for wrapLineAt).
  std::vector<std::string> wrapCache;

  /// Last prepareShape() run (for copyShapedGlyphs).
  std::vector<PositionedGlyph> shapeCache;

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
    // Last: everything above was reading these bytes in place.
    bytes.clear();
    bytes.shrink_to_fit();
    digest = FontDigest{};
    faceCount = 0;
    loadFlags = FT_LOAD_DEFAULT;
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
//
// When `outLines` is non-null, also records the text of each line (same
// break points as the widths) so draw can match measure.
void wrapLinesImpl(hb_font_t *font, const std::string &text, float availWidth,
                   std::vector<float> *outWidths,
                   std::vector<std::string> *outLines)
{
  const float spaceWidth = shapedWidth(font, " ");

  float currentLineWidth = 0.f;
  std::string currentLine;
  bool lineHasContent = false;

  auto endLine = [&] {
    if (outWidths) outWidths->push_back(currentLineWidth);
    if (outLines) outLines->push_back(currentLine);
    currentLineWidth = 0.f;
    currentLine.clear();
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
    const std::string word = text.substr(wordStart, pos - wordStart);
    const float wordWidth = shapedWidth(font, word);

    const float advanceIfAppended = (lineHasContent ? spaceWidth : 0.f) + wordWidth;
    if (lineHasContent && currentLineWidth + advanceIfAppended > availWidth) {
      endLine();
      currentLineWidth = wordWidth;
      currentLine = word;
      lineHasContent = true;
    } else {
      if (lineHasContent) currentLine.push_back(' ');
      currentLine += word;
      currentLineWidth += advanceIfAppended;
      lineHasContent = true;
    }
  }

  if (lineHasContent || (outWidths && outWidths->empty()) ||
      (outLines && outLines->empty())) {
    if (outWidths) outWidths->push_back(currentLineWidth);
    if (outLines) outLines->push_back(currentLine);
  }
}

std::vector<float> wrapLineWidths(hb_font_t *font, const std::string &text,
                                  float availWidth)
{
  std::vector<float> lineWidths;
  wrapLinesImpl(font, text, availWidth, &lineWidths, nullptr);
  return lineWidths;
}

/// `RasterFlags` → the `FT_LOAD_*` bits for `FT_Load_Glyph`.
///
/// Hinting only. The result is always rendered to 8-bit grayscale, because
/// that is what the atlas stores; LCD and 1-bit mono would change what a glyph
/// *is* in the atlas rather than how it was fitted, and need a format before
/// they need a flag.
int32_t freetypeLoadFlags(uint32_t rasterFlags) {
  int32_t flags = FT_LOAD_DEFAULT;
  switch (RasterFlags::hinting(rasterFlags)) {
    case FontHinting::Normal:
      flags |= FT_LOAD_TARGET_NORMAL;
      break;
    case FontHinting::None:
      flags |= FT_LOAD_NO_HINTING;
      break;
    case FontHinting::Light:
      flags |= FT_LOAD_TARGET_LIGHT;
      break;
    case FontHinting::Mono:
      // Mono *hinting* — the grid-fitting a 1-bit target implies — while
      // still rendering coverage. Sharper stems than Normal, and not the
      // same thing as a 1-bit bitmap.
      flags |= FT_LOAD_TARGET_MONO;
      break;
  }
  if (RasterFlags::forceAutohint(rasterFlags)) flags |= FT_LOAD_FORCE_AUTOHINT;
  return flags;
}

} // namespace

Font::Font() : impl_(std::make_unique<Impl>()) {}
Font::~Font() = default;
Font::Font(Font &&) noexcept = default;
Font &Font::operator=(Font &&) noexcept = default;

VoidResult Font::load(const std::string &path, float pixelSize) {
  return loadFace(path, pixelSizeTo26_6(pixelSize), 0,
                  RasterFlags::of(FontHinting::Normal));
}

VoidResult Font::loadFace(const std::string &path, uint32_t pixelSize26_6,
                          uint32_t faceIndex, uint32_t rasterFlags) {
  std::vector<uint8_t> bytes;
  if (!readFontFile(path, bytes)) {
    return fail("Font::load: failed to read font: " + path);
  }
  auto result = loadFaceFromMemory(bytes.data(), bytes.size(), pixelSize26_6,
                                   faceIndex, rasterFlags);
  // The memory form names no file, and a caller that passed a path should
  // get one back.
  if (!result) return fail(result.error() + " (" + path + ")");
  return result;
}

VoidResult Font::loadFaceFromMemory(const uint8_t *bytes, size_t byteCount,
                                    uint32_t pixelSize26_6, uint32_t faceIndex,
                                    uint32_t rasterFlags) {
  impl_->unload();

  if (bytes == nullptr || byteCount == 0) {
    return fail("Font::load: no font bytes");
  }
  if ((rasterFlags & ~RasterFlags::kKnownMask) != 0) {
    // Refused rather than masked off. An unknown bit means the caller asked
    // for something this renderer does not do, and rasterizing as though it
    // had not asked is exactly the silent wrongness the key exists to stop.
    return fail("Font::load: unknown raster flags");
  }
  if (pixelSize26_6 == 0) {
    return fail("Font::load: zero pixel size");
  }

  impl_->bytes.assign(bytes, bytes + byteCount);
  impl_->digest = sha256(impl_->bytes);
  impl_->loadFlags = freetypeLoadFlags(rasterFlags);

  FT_Error ftError = FT_Init_FreeType(&impl_->ftLibrary);
  if (ftError) {
    impl_->unload();
    return fail("Font::load: failed to initialize FreeType");
  }

  ftError = FT_New_Memory_Face(impl_->ftLibrary, impl_->bytes.data(),
                               static_cast<FT_Long>(impl_->bytes.size()),
                               static_cast<FT_Long>(faceIndex), &impl_->ftFace);
  if (ftError) {
    impl_->unload();
    return fail("Font::load: no face " + std::to_string(faceIndex) +
                " in this font");
  }
  impl_->faceCount = static_cast<uint32_t>(impl_->ftFace->num_faces);

  // `FT_Set_Char_Size` at 72 dpi rather than `FT_Set_Pixel_Sizes`, so one
  // point is one pixel and the size keeps its fractional part. The old call
  // passed `(FT_UInt)pixelSize` — an integer ppem — while HarfBuzz below was
  // scaled to the unrounded value, so a fractional size was shaped at one
  // size and rasterized at another. Whole sizes are identical either way,
  // which is why nothing ever noticed.
  FT_Set_Char_Size(impl_->ftFace, 0, static_cast<FT_F26Dot6>(pixelSize26_6), 72,
                   72);

  // The same bytes FreeType is reading, not a second read of the same path.
  // `HB_MEMORY_MODE_READONLY` because this buffer outlives the blob and is
  // not HarfBuzz's to free.
  impl_->hbBlob = hb_blob_create(
    reinterpret_cast<const char *>(impl_->bytes.data()),
    static_cast<unsigned int>(impl_->bytes.size()), HB_MEMORY_MODE_READONLY,
    nullptr, nullptr);
  if (!impl_->hbBlob || hb_blob_get_length(impl_->hbBlob) == 0) {
    impl_->unload();
    return fail("Font::load: HarfBuzz rejected the font bytes");
  }

  impl_->hbFace = hb_face_create(impl_->hbBlob, faceIndex);
  impl_->hbFont = hb_font_create(impl_->hbFace);
  hb_ot_font_set_funcs(impl_->hbFont);
  // 26.6 fixed-point, HarfBuzz's convention — and now literally the same
  // number FreeType was given, rather than a parallel computation of it.
  hb_font_set_scale(impl_->hbFont, static_cast<int>(pixelSize26_6),
                    static_cast<int>(pixelSize26_6));

  const float pixelSize = pixelSizeFrom26_6(pixelSize26_6);
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

const FontDigest &Font::contentHash() const { return impl_->digest; }

uint32_t Font::faceCount() const { return impl_->faceCount; }

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

int Font::prepareWrap(const std::string &text, float availWidth)
{
  impl_->wrapCache.clear();
  if (!impl_->isLoaded() || text.empty()) {
    impl_->wrapCache.emplace_back();
    return 1;
  }
  wrapLinesImpl(impl_->hbFont, text, availWidth, nullptr, &impl_->wrapCache);
  if (impl_->wrapCache.empty()) {
    impl_->wrapCache.emplace_back();
  }
  return static_cast<int>(impl_->wrapCache.size());
}

int Font::prepareShape(const std::string &text)
{
  impl_->shapeCache = shape(text);
  return static_cast<int>(impl_->shapeCache.size());
}

int Font::copyShapedGlyphs(PositionedGlyph *dst, int maxCount) const
{
  if (!dst || maxCount <= 0) return 0;
  const int n = static_cast<int>(impl_->shapeCache.size());
  const int copy = n < maxCount ? n : maxCount;
  std::memcpy(dst, impl_->shapeCache.data(),
              static_cast<size_t>(copy) * sizeof(PositionedGlyph));
  return copy;
}

bool Font::wrapLineAt(int index, char *buf, int cap) const
{
  if (!buf || cap <= 0) return false;
  if (index < 0 || static_cast<size_t>(index) >= impl_->wrapCache.size()) {
    return false;
  }
  const auto &line = impl_->wrapCache[static_cast<size_t>(index)];
  const int n = static_cast<int>(line.size());
  const int copy = n < cap - 1 ? n : cap - 1;
  if (copy > 0) {
    std::memcpy(buf, line.data(), static_cast<size_t>(copy));
  }
  buf[copy] = '\0';
  return true;
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
    const float advance = static_cast<float>(positions[i].x_advance) / 64.f;
    result.push_back(PositionedGlyph{
      infos[i].codepoint,
      infos[i].cluster,
      penX + static_cast<float>(positions[i].x_offset) / 64.f,
      penY - static_cast<float>(positions[i].y_offset) / 64.f,
      advance,
    });
    penX += advance;
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
  FT_Error error = FT_Load_Glyph(impl_->ftFace, glyphId, impl_->loadFlags);
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
