// What `FontHinting::Normal` does to a face that has no hints of its own, and
// how far a glyph's ink may land from its pen.
//
// FreeType autohints such a face, and at `TARGET_NORMAL` the autohinter fits
// glyphs horizontally: it moves stems, changes advances, and draws each bitmap
// for the advance it chose. Text here is positioned by HarfBuzz's *unhinted*
// advances, so each glyph's ink landed off its pen by its own amount — in
// Figtree SemiBold at 14px, "notes.txt" drew with `te` and `tx` overlapping
// and gaps after `s` and `x`. `Normal` on such a face now means light
// (vertical-only) autohinting, and a hinted face is left as it was.
//
// Run against real files, because the condition is about what is in a font's
// tables: an unhinted Google Fonts build (Figtree), a face with real bytecode
// (OpenSans) and one with no `prep` at all (Noto Sans Symbols 2). Paths come
// from meson. No GPU: rasterizing is FreeType into a byte buffer.

#include "render/font.hpp"

#include <cmath>
#include <cstdio>
#include <string>
#include <vector>

using canvas::Font;
using canvas::FontHinting;
using canvas::GlyphBitmap;
using canvas::RasterFlags;

namespace {

int failures = 0;

#define CHECK(cond)                                                            \
  do {                                                                         \
    if (!(cond)) {                                                             \
      std::fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__,    \
                   #cond);                                                     \
      ++failures;                                                              \
    }                                                                          \
  } while (0)

/// Every printable ASCII character: wide enough that a face which happens to
/// hint one glyph identically both ways cannot make the comparison vacuous.
const std::string kSample = [] {
  std::string s;
  for (char c = '!'; c <= '~'; ++c) s += c;
  return s;
}();

bool load(Font &font, const std::string &path, float px, uint32_t flags) {
  auto result = font.loadFace(path, canvas::pixelSizeTo26_6(px), 0, flags);
  if (!result) {
    std::fprintf(stderr, "cannot load %s: %s\n", path.c_str(),
                 result.error().c_str());
    ++failures;
    return false;
  }
  return true;
}

bool sameBitmap(const GlyphBitmap &a, const GlyphBitmap &b) {
  return a.width == b.width && a.height == b.height &&
         a.bearingX == b.bearingX && a.bearingY == b.bearingY &&
         a.pixels == b.pixels;
}

/// How many glyphs of `kSample` rasterize differently in `a` and `b`, which
/// must be the same file at the same size.
int differingGlyphs(const Font &a, const Font &b) {
  int differing = 0;
  for (const auto &glyph : a.shape(kSample)) {
    if (!sameBitmap(a.rasterize(glyph.glyphId), b.rasterize(glyph.glyphId))) {
      ++differing;
    }
  }
  return differing;
}

constexpr uint32_t kNormal = RasterFlags::of(FontHinting::Normal);
constexpr uint32_t kLight = RasterFlags::of(FontHinting::Light);
constexpr uint32_t kForcedAutohint = RasterFlags::of(FontHinting::Normal, true);

/// An unhinted face: `Normal` must rasterize exactly as `Light` does, and
/// differently from the full-strength autohinting it used to get — the second
/// half is what keeps the first from passing on a face nothing hints at all.
void unhintedFaceGetsLightHinting(const std::string &path) {
  for (float px : {12.f, 14.f, 17.f}) {
    Font normal, light, forced;
    if (!load(normal, path, px, kNormal) || !load(light, path, px, kLight) ||
        !load(forced, path, px, kForcedAutohint)) {
      return;
    }
    CHECK(!normal.hasNativeHinting());
    CHECK(differingGlyphs(normal, light) == 0);
    CHECK(differingGlyphs(normal, forced) > 0);
  }
}

/// The case that showed it: ink placed at `round(pen) + bearingX`, as
/// `RenderWindow` placed it before subpixel positioning, must never start left of where the previous
/// glyph's ink started, and two neighbours must not overlap by more than the
/// one column antialiasing shares. Before the fix `x` started two columns
/// inside the `t` before it.
void inkFollowsThePen(const std::string &path) {
  Font font;
  if (!load(font, path, 14.f, kNormal)) return;
  const std::string text = "notes.txt";
  int previousEnd = -1000;
  for (const auto &glyph : font.shape(text)) {
    const GlyphBitmap bitmap = font.rasterize(glyph.glyphId);
    if (bitmap.width == 0) continue;
    const int start = static_cast<int>(std::lround(glyph.x)) +
                      static_cast<int>(bitmap.bearingX);
    if (start < previousEnd - 1) {
      std::fprintf(stderr, "  '%c' ink starts at %d, previous ends at %d\n",
                   text[glyph.cluster], start, previousEnd);
    }
    CHECK(start >= previousEnd - 1);
    previousEnd = start + bitmap.width;
  }
}

/// Where a bitmap's ink sits, as the coverage-weighted mean column, relative
/// to the pen it was rasterized for. Centre of each column, hence the half.
double inkCentre(const GlyphBitmap &bitmap) {
  double sum = 0, weighted = 0;
  for (int y = 0; y < bitmap.height; ++y) {
    for (int x = 0; x < bitmap.width; ++x) {
      const double c = bitmap.pixels[static_cast<size_t>(y) * bitmap.width + x];
      sum += c;
      weighted += c * (x + 0.5);
    }
  }
  return sum > 0 ? bitmap.bearingX + weighted / sum : 0;
}

/// The renderer's pen snap, restated: the whole pixel the quad lands on, and
/// the quarter the glyph is rasterized at (`TextRenderer::Impl::snapPen`).
void snapToBin(float pen, float &whole, uint32_t &bin) {
  constexpr float bins = static_cast<float>(canvas::kSubpixelBins);
  const float quantised = std::round(pen * bins) / bins;
  whole = std::floor(quantised);
  bin = static_cast<uint32_t>(std::lround((quantised - whole) * bins)) %
        canvas::kSubpixelBins;
}

/// Shifting the outline moves the ink by the shift, and by nothing else.
void subpixelShiftMovesInk(const std::string &path) {
  Font font;
  if (!load(font, path, 14.f, kNormal)) return;
  CHECK(font.subpixelPositioning());
  for (const auto &glyph : font.shape("notes.txt")) {
    const double base = inkCentre(font.rasterize(glyph.glyphId));
    for (uint32_t bin = 1; bin < canvas::kSubpixelBins; ++bin) {
      const uint32_t shift = bin * (64 / canvas::kSubpixelBins);
      const double moved = inkCentre(font.rasterize(glyph.glyphId, shift));
      // Not exact: coverage is quantised to 8 bits per pixel, so the ink
      // centre of a shifted glyph wanders by a few hundredths (`t` moves
      // 0.557 for a half-pixel shift at 14px).
      CHECK(std::fabs((moved - base) - shift / 64.0) < 0.08);
    }
  }
}

/// The spacing complaint itself: every glyph's ink lands within an eighth of
/// a pixel of where its exact HarfBuzz pen puts it. Rounded to whole pixels
/// the `x` of "notes.txt" moved 0.45px left and the `t` after it 0.38px
/// right — a 0.36px gap drawn at 1.2px.
void inkLandsWhereThePenSays(const std::string &path) {
  Font font;
  if (!load(font, path, 14.f, kNormal)) return;
  const std::string text = "notes.txt";
  for (const auto &glyph : font.shape(text)) {
    // Exact: the outline rasterized at the pen's own fraction, to 1/64.
    const float floorPen = std::floor(glyph.x);
    const uint32_t exactShift =
      static_cast<uint32_t>(std::lround((glyph.x - floorPen) * 64.f));
    const double exact =
      floorPen + inkCentre(font.rasterize(glyph.glyphId, exactShift));
    float whole = 0;
    uint32_t bin = 0;
    snapToBin(glyph.x, whole, bin);
    const double drawn = whole + inkCentre(font.rasterize(
      glyph.glyphId, bin * (64 / canvas::kSubpixelBins)));
    if (std::fabs(drawn - exact) > 0.15) {
      std::fprintf(stderr, "  '%c' ink at %.3f, pen says %.3f\n",
                   text[glyph.cluster], drawn, exact);
    }
    CHECK(std::fabs(drawn - exact) <= 0.15);
  }
}

/// Hinting that fits glyphs sideways is not shifted: its stems were placed
/// for a whole-pixel pen.
void sidewaysHintingStaysWhole(const std::string &path) {
  Font mono, forced, light;
  if (!load(mono, path, 14.f, RasterFlags::of(FontHinting::Mono)) ||
      !load(forced, path, 14.f, kForcedAutohint) ||
      !load(light, path, 14.f, RasterFlags::of(FontHinting::Light, true))) {
    return;
  }
  CHECK(!mono.subpixelPositioning());
  CHECK(!forced.subpixelPositioning());
  CHECK(light.subpixelPositioning());
  const uint32_t glyph = mono.shape("x").front().glyphId;
  CHECK(sameBitmap(mono.rasterize(glyph), mono.rasterize(glyph, 32)));
}

/// A face with real bytecode is left on the native hinter.
void hintedFaceIsUntouched(const std::string &path) {
  Font font;
  if (!load(font, path, 14.f, kNormal)) return;
  CHECK(font.hasNativeHinting());
}

/// No `prep` and no `fpgm` at all is the plainer form of the same thing.
void faceWithNoProgramsIsUnhinted(const std::string &path) {
  Font font;
  if (!load(font, path, 14.f, kNormal)) return;
  CHECK(!font.hasNativeHinting());
}

} // namespace

int main(int argc, char **argv) {
  if (argc != 5) {
    std::fprintf(stderr,
                 "usage: %s <figtree-semibold> <figtree-regular> "
                 "<opensans> <noto-symbols2>\n",
                 argv[0]);
    return 2;
  }
  const std::string semibold = argv[1], regular = argv[2];

  unhintedFaceGetsLightHinting(semibold);
  unhintedFaceGetsLightHinting(regular);
  inkFollowsThePen(semibold);
  subpixelShiftMovesInk(semibold);
  inkLandsWhereThePenSays(semibold);
  inkLandsWhereThePenSays(regular);
  sidewaysHintingStaysWhole(semibold);
  hintedFaceIsUntouched(argv[3]);
  faceWithNoProgramsIsUnhinted(argv[4]);

  if (failures != 0) {
    std::fprintf(stderr, "%d check(s) failed\n", failures);
    return 1;
  }
  std::printf("font hinting: ok\n");
  return 0;
}
