#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

/// What makes two loaded faces the same face.
///
/// The old answer was the file path and a `float` size, and both halves of
/// that were wrong in ways that only show up once there is more than one
/// process drawing text.
///
/// A **path is not an identity**. It is too coarse — a font installed at
/// `/usr/share/fonts/TTF/DejaVuSans.ttf` and the identical bytes shipped in an
/// app's resource bundle are one face wearing two names, and keying on the
/// name rasterizes and atlases it twice. It is also too *fine*, in the
/// direction that actually corrupts: a path is a mutable reference. Rebuild a
/// client and `.build/…/fonts/OpenSans-Regular.ttf` is a different file with
/// the same name, but a compositor that outlives the build — and the
/// compositor is the session — keeps serving the face it loaded hours ago.
/// Content-addressing fixes both at once, and is the only key that stays true
/// when the bytes move or change underneath it.
///
/// A **`float` size is not comparable**. The old registry compared sizes with
/// `==`, so two computations of "sixteen pixels" that differ in the last bit
/// were two faces. Sizes are quantised to 26.6 fixed point here — FreeType's
/// and HarfBuzz's own convention — so the key holds exactly the number that
/// reaches the rasterizer, and nothing finer.
namespace canvas {

/// SHA-256 of a font file's bytes.
///
/// Cryptographic rather than a cheap 64-bit mix, because a collision here does
/// not cost a cache miss — it silently draws one typeface's glyphs from
/// another's outlines, which is the kind of bug that gets attributed to
/// anything except the hash.
struct FontDigest {
  std::array<uint8_t, 32> bytes{};

  bool operator==(const FontDigest &) const = default;

  /// Lowercase hex, for logs. Full length: a truncated digest in a log is a
  /// digest you cannot compare against anything.
  std::string hex() const;

  /// Empty digest — what an unhashed or failed load carries.
  bool empty() const;
};

FontDigest sha256(const uint8_t *data, size_t size);

inline FontDigest sha256(const std::vector<uint8_t> &data) {
  return sha256(data.data(), data.size());
}

/// Reads `path` whole into `out`. False if it cannot be opened, cannot be
/// read, or is empty — a zero-byte font is not a font.
///
/// Here rather than in `Font` because both sides of content addressing need
/// it: the registry reads the file to hash it, and hands the same bytes on.
bool readFontFile(const std::string &path, std::vector<uint8_t> &out);

/// The digest of the file at `path`, remembered per file for this process.
///
/// Content addressing costs a pass over every byte, and the same bytes get
/// asked about more than once: a face wanted at two sizes is two keys over one
/// file, and every client that opens re-registers the faces the last one
/// already did. A terminal asking for a 12 MiB Nerd Font and a 19 MiB CJK
/// fallback paid ~100 ms of SHA-256 for answers this process had computed
/// before.
///
/// The memo is keyed on what the filesystem says the file *is* — device,
/// inode, size, mtime — so a font replaced under a running session hashes
/// again and gets a new identity, which is the property content addressing
/// exists for. A path alone would not: `/usr/share/fonts/…` is stable across
/// exactly the update that changes the bytes.
///
/// `out` is filled only on a miss, when the file had to be read anyway; a hit
/// answers from four numbers and touches no font bytes at all. Callers that
/// need the bytes regardless must check `out` and read it themselves — which
/// is the point, since the common caller finds the key already registered and
/// never needs them.
bool fontFileDigest(const std::string &path, FontDigest &outDigest,
                    std::vector<uint8_t> &out);

/// How a glyph is hinted on its way to the atlas.
///
/// Hinting only. The atlas is 8-bit grayscale coverage (`VK_FORMAT_R8_UNORM`),
/// and the modes left out — LCD subpixel, 1-bit mono — change what a glyph
/// *is* in the atlas rather than how it was fitted to the pixel grid, so they
/// need a format and a shader before they need a key. The bits above are
/// reserved for them.
enum class FontHinting : uint32_t {
  /// FreeType's default: the font's own bytecode where it has any.
  Normal = 0,
  /// Unhinted. Outlines land where the outline says, which keeps shapes
  /// faithful and stems blurry — what most people mean by "macOS-like".
  None = 1,
  /// Light: vertical fitting only. The usual Linux desktop preference, and
  /// the one that leaves horizontal metrics closest to the unhinted advance.
  Light = 2,
  /// Full monochrome-style hinting, still rendered to grayscale.
  Mono = 3,
};

/// Packed hinting selection plus flags. Bits 0-3 are the `FontHinting`; bit 4
/// forces FreeType's autohinter over the font's own bytecode; the rest are
/// reserved and must be zero, so an older renderer can reject a key it does
/// not understand rather than quietly rasterize it wrong.
struct RasterFlags {
  static constexpr uint32_t kHintingMask = 0x0000000f;
  static constexpr uint32_t kForceAutohint = 0x00000010;
  static constexpr uint32_t kKnownMask = kHintingMask | kForceAutohint;

  static constexpr uint32_t of(FontHinting hinting, bool forceAutohint = false) {
    return static_cast<uint32_t>(hinting) |
           (forceAutohint ? kForceAutohint : 0u);
  }

  static constexpr FontHinting hinting(uint32_t flags) {
    return static_cast<FontHinting>(flags & kHintingMask);
  }

  static constexpr bool forceAutohint(uint32_t flags) {
    return (flags & kForceAutohint) != 0;
  }
};

/// Pixels → 26.6 fixed point, which is the unit FreeType and HarfBuzz both
/// size in. Rounds rather than truncates: the old code cast a float to an
/// integer ppem, so 17.9px rasterized at 17 while HarfBuzz shaped at 17.9.
constexpr uint32_t pixelSizeTo26_6(float pixels) {
  return static_cast<uint32_t>(pixels * 64.f + 0.5f);
}

constexpr float pixelSizeFrom26_6(uint32_t fixed) {
  return static_cast<float>(fixed) / 64.f;
}

/// Everything that makes a rasterized face what it is.
struct FontKey {
  /// The bytes, not the name they were read under.
  FontDigest contentHash;
  /// Which face inside a collection (`.ttc`/`.otc`). 0 for a plain font file.
  uint32_t faceIndex = 0;
  /// 26.6 fixed point, never a float.
  uint32_t pixelSize26_6 = 0;
  /// Variable-font axis settings, hashed the same way the file is.
  ///
  /// Reserved: nothing sets axes yet, so this is the digest of an empty axis
  /// list on every key today. It is in the struct rather than waiting for the
  /// feature because adding a field to a key later means every entry cached
  /// under the old shape is wrong in a way nothing detects — the one class of
  /// bug this whole type exists to prevent.
  FontDigest variationsHash;
  /// `RasterFlags`.
  uint32_t rasterFlags = 0;

  bool operator==(const FontKey &) const = default;
};

}  // namespace canvas
