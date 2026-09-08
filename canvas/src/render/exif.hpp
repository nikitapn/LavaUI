#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace canvas {

/// Which corner of the stored image is the visual top-left.
///
/// The EXIF numbering, unchanged, because every table written about this is in
/// it. `topLeft` is the file that needs nothing done to it, and is also what a
/// file with no tag reports — there is no third answer, and callers do not
/// have to distinguish "upright" from "silent".
enum class ExifOrientation : uint8_t {
  topLeft = 1,      ///< as stored
  topRight = 2,     ///< mirrored left-to-right
  bottomRight = 3,  ///< 180°
  bottomLeft = 4,   ///< mirrored top-to-bottom
  leftTop = 5,      ///< transposed — mirrored about the main diagonal
  rightTop = 6,     ///< 90° clockwise
  rightBottom = 7,  ///< transverse — mirrored about the anti-diagonal
  leftBottom = 8,   ///< 270° clockwise
};

/// A quarter turn asked for by a person rather than declared by a file.
///
/// Clockwise, and named as a direction rather than an angle because that is
/// what the two buttons on a viewer's bar mean. It is the same movement as
/// four of the eight orientations above and goes through the same loop; it is
/// a separate type because the two say different things — an orientation is
/// how the file is stored, a turn is what somebody pressed.
enum class ImageTurn : uint8_t {
  none = 0,
  clockwise = 1,
  half = 2,
  anticlockwise = 3,
};

/// The orientation that moves the pixels the same way, so a turn needs no
/// second implementation of anything.
ExifOrientation asOrientation(ImageTurn turn);

inline bool isIdentity(ExifOrientation o) {
  return o == ExifOrientation::topLeft;
}

inline bool isIdentity(ImageTurn t) { return t == ImageTurn::none; }

/// Whether width and height swap under it.
bool swapsAxes(ExifOrientation o);

/// The orientation declared in `bytes` — a JPEG, a PNG, or a bare TIFF/Exif
/// block, which is what both containers carry inside them.
///
/// `topLeft` for anything else: no tag, an unknown container, a truncated
/// header, a nonsense offset. These are files nobody vouched for, so every
/// failure has the same harmless answer and no caller needs an error path.
ExifOrientation readExifOrientation(const uint8_t *bytes, size_t count);

/// The same for a file, reading only its head.
///
/// A JPEG's Exif block is an APP1 segment, which the format caps at 64 KiB and
/// which conventionally sits within the first few bytes of the file; a PNG's
/// `eXIf` chunk is normally before the pixels. `kExifHeaderBytes` is generous
/// against both, and the read is one the decoder is about to do anyway.
ExifOrientation readExifOrientation(const std::string &path);

constexpr size_t kExifHeaderBytes = 128 * 1024;

/// Rewrites tightly packed RGBA8 so the image is the way up the file says it
/// is, swapping `width` and `height` when the orientation turns it.
///
/// A no-op for `topLeft`, and for a buffer that is not `width * height * 4`
/// bytes — a caller that got its own arithmetic wrong gets its pixels back
/// untouched rather than a crash.
void applyExifOrientation(std::vector<uint8_t> &pixels, uint32_t &width,
                          uint32_t &height, ExifOrientation orientation);

/// The same over a raw buffer, for the caller that has one from `stbi_load`
/// rather than a vector.
///
/// Returns a fresh buffer the caller owns, allocated with `malloc` so it can
/// be handed to `stbi_image_free` like the one it replaces. Null when there is
/// nothing to do or no memory to do it in, and the input is never freed.
uint8_t *orientedCopy(const uint8_t *pixels, int width, int height,
                      ExifOrientation orientation, int &outWidth,
                      int &outHeight);

}  // namespace canvas
