// Reading the one EXIF tag that changes what a decoder must return.
//
// A photograph off a phone is almost never stored the way up it is meant to be
// seen. The sensor reads out the same way whichever way the body is held, and
// the camera records how it was held as a number rather than by moving 24
// million pixels. A decoder that ignores that number returns a picture on its
// side — which is not a missing feature, it is the wrong pixels, and it is why
// this is applied here rather than left to each caller to remember.
//
// Only the orientation tag is read. Everything else in EXIF — the camera, the
// lens, the date, the coordinates — is information *about* the picture, and
// belongs wherever it is going to be shown, not in the decode path.

#include "render/exif.hpp"

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>

namespace canvas {

namespace {

uint16_t u16(const uint8_t *p, bool big) {
  return big ? static_cast<uint16_t>(uint16_t(p[0]) << 8 | p[1])
             : static_cast<uint16_t>(uint16_t(p[1]) << 8 | p[0]);
}

uint32_t u32(const uint8_t *p, bool big) {
  return big ? (uint32_t(p[0]) << 24 | uint32_t(p[1]) << 16 |
                uint32_t(p[2]) << 8 | uint32_t(p[3]))
             : (uint32_t(p[3]) << 24 | uint32_t(p[2]) << 16 |
                uint32_t(p[1]) << 8 | uint32_t(p[0]));
}

/// Walks the TIFF block at `base` and answers with tag 0x0112 from IFD0.
///
/// Bounds are checked against `count` at every step and never against the
/// lengths the file states, which is the whole discipline here: an offset in
/// this format is a number a stranger wrote.
ExifOrientation orientationInTiff(const uint8_t *b, size_t count, size_t base) {
  if (base + 8 > count) return ExifOrientation::topLeft;
  const uint8_t *tiff = b + base;

  bool big;
  if (tiff[0] == 0x49 && tiff[1] == 0x49) {
    big = false;  // "II" — Intel, little-endian
  } else if (tiff[0] == 0x4D && tiff[1] == 0x4D) {
    big = true;  // "MM" — Motorola, big-endian
  } else {
    return ExifOrientation::topLeft;
  }
  // 42, in whichever order the two bytes above just declared. The format's own
  // self-check, and the only thing separating a real block from a coincidence.
  if (u16(tiff + 2, big) != 42) return ExifOrientation::topLeft;

  // Offsets are counted from the start of the TIFF header, not the file.
  const uint32_t ifdOffset = u32(tiff + 4, big);
  if (ifdOffset < 8) return ExifOrientation::topLeft;  // inside the header
  const size_t ifdAt = base + ifdOffset;
  if (ifdAt + 2 > count || ifdAt < base) return ExifOrientation::topLeft;

  const uint8_t *ifd = b + ifdAt;
  // Entries are 12 bytes each. The count is clamped to what is actually here
  // rather than trusted, so a header cut short by a partial read — or by a
  // file that lies — is walked as far as it goes instead of refused.
  const size_t declared = u16(ifd, big);
  const size_t room = (count - (ifdAt + 2)) / 12;
  const size_t entries = std::min(declared, room);

  for (size_t i = 0; i < entries; ++i) {
    const uint8_t *entry = ifd + 2 + i * 12;
    if (u16(entry, big) != 0x0112) continue;  // Orientation

    const uint16_t type = u16(entry + 2, big);
    if (u32(entry + 4, big) != 1) return ExifOrientation::topLeft;
    // The value sits in the last four bytes of the entry when it fits, which
    // one number always does. SHORT is what the specification says; LONG is
    // written by enough encoders to be worth accepting.
    uint32_t value;
    if (type == 3) {
      value = u16(entry + 8, big);
    } else if (type == 4) {
      value = u32(entry + 8, big);
    } else {
      return ExifOrientation::topLeft;
    }
    if (value >= 1 && value <= 8) {
      return static_cast<ExifOrientation>(value);
    }
    return ExifOrientation::topLeft;
  }
  return ExifOrientation::topLeft;
}

/// Offset of the TIFF header inside a JPEG's Exif APP1 segment, or 0.
///
/// Zero doubles as "not found" because a JPEG starts with its own two-byte
/// marker, so a TIFF header can never legitimately be at offset 0.
size_t exifBlockInJpeg(const uint8_t *b, size_t count) {
  if (count < 4 || b[0] != 0xFF || b[1] != 0xD8) return 0;  // no SOI

  size_t i = 2;
  while (i + 4 <= count) {
    if (b[i] != 0xFF) return 0;  // not a marker where one has to be
    const uint8_t marker = b[i + 1];

    if (marker == 0xFF) {  // fill byte: any number may precede a marker
      ++i;
      continue;
    }
    // Standalone markers carry no length.
    if (marker == 0xD8 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
      i += 2;
      continue;
    }
    // Entropy-coded data, or the end. Whatever metadata there was is behind us.
    if (marker == 0xDA || marker == 0xD9) return 0;

    const size_t length = size_t(b[i + 2]) << 8 | b[i + 3];
    if (length < 2) return 0;  // the length counts its own two bytes

    // Checked before the segment is skipped rather than after, so an Exif
    // block that a partial read cut short is still parsed as far as it goes.
    static const uint8_t kExif[6] = {'E', 'x', 'i', 'f', 0, 0};
    const size_t payload = i + 4;
    if (marker == 0xE1 && payload + sizeof(kExif) <= count &&
        std::memcmp(b + payload, kExif, sizeof(kExif)) == 0) {
      return payload + sizeof(kExif);
    }
    i += 2 + length;
  }
  return 0;
}

/// Offset of the TIFF header inside a PNG `eXIf` chunk, or 0.
///
/// Only what is in front of the pixels: `eXIf` is allowed after `IDAT` too,
/// and finding it there would mean reading a whole file to answer a question
/// about its header. A file that puts it there is read as unoriented.
size_t exifBlockInPng(const uint8_t *b, size_t count) {
  static const uint8_t kSignature[8] = {0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n'};
  if (count < sizeof(kSignature) + 8 ||
      std::memcmp(b, kSignature, sizeof(kSignature)) != 0) {
    return 0;
  }

  size_t i = sizeof(kSignature);
  while (i + 8 <= count) {
    const uint32_t length = u32(b + i, true);
    const uint8_t *type = b + i + 4;
    if (std::memcmp(type, "eXIf", 4) == 0) return i + 8;
    if (std::memcmp(type, "IDAT", 4) == 0) return 0;
    // Chunk lengths are capped at 2^31-1 by the format; anything above that is
    // a file trying to walk us off the end.
    if (length > 0x7FFFFFFFu) return 0;
    i += 12 + size_t(length);  // length + type + data + CRC
  }
  return 0;
}

/// One destination pixel at a time, so the *writes* are sequential.
///
/// The reads stride by a row for anything that turns, and cache badly whatever
/// order this is written in; making the writes linear is the half worth having.
/// The same reasoning, and the same loop, as `PixelRotate.rotate` on the Swift
/// side — which is where a turn the *user* asked for still happens.
void gather(const uint8_t *src, int w, int h, ExifOrientation o, uint8_t *dst) {
  const bool swap = swapsAxes(o);
  const int outW = swap ? h : w;
  const int outH = swap ? w : h;

  for (int y = 0; y < outH; ++y) {
    uint8_t *row = dst + static_cast<size_t>(y) * outW * 4;
    for (int x = 0; x < outW; ++x) {
      int sx = x;
      int sy = y;
      switch (o) {
        case ExifOrientation::topLeft:     sx = x;         sy = y;         break;
        case ExifOrientation::topRight:    sx = w - 1 - x; sy = y;         break;
        case ExifOrientation::bottomRight: sx = w - 1 - x; sy = h - 1 - y; break;
        case ExifOrientation::bottomLeft:  sx = x;         sy = h - 1 - y; break;
        case ExifOrientation::leftTop:     sx = y;         sy = x;         break;
        case ExifOrientation::rightTop:    sx = y;         sy = h - 1 - x; break;
        case ExifOrientation::rightBottom: sx = w - 1 - y; sy = h - 1 - x; break;
        case ExifOrientation::leftBottom:  sx = w - 1 - y; sy = x;         break;
      }
      std::memcpy(row + static_cast<size_t>(x) * 4,
                  src + (static_cast<size_t>(sy) * w + sx) * 4, 4);
    }
  }
}

}  // namespace

bool swapsAxes(ExifOrientation o) {
  switch (o) {
    case ExifOrientation::leftTop:
    case ExifOrientation::rightTop:
    case ExifOrientation::rightBottom:
    case ExifOrientation::leftBottom:
      return true;
    default:
      return false;
  }
}

ExifOrientation readExifOrientation(const uint8_t *bytes, size_t count) {
  if (bytes == nullptr || count == 0) return ExifOrientation::topLeft;
  if (const size_t tiff = exifBlockInJpeg(bytes, count)) {
    return orientationInTiff(bytes, count, tiff);
  }
  if (const size_t tiff = exifBlockInPng(bytes, count)) {
    return orientationInTiff(bytes, count, tiff);
  }
  // A bare TIFF/Exif block: what both containers hold, what a TIFF file starts
  // with, and what a caller with the segment already in hand passes. The magic
  // check inside is what makes this safe to try on anything.
  return orientationInTiff(bytes, count, 0);
}

ExifOrientation readExifOrientation(const std::string &path) {
  std::FILE *file = std::fopen(path.c_str(), "rb");
  if (file == nullptr) return ExifOrientation::topLeft;
  std::vector<uint8_t> head(kExifHeaderBytes);
  const size_t got = std::fread(head.data(), 1, head.size(), file);
  std::fclose(file);
  return readExifOrientation(head.data(), got);
}

void applyExifOrientation(std::vector<uint8_t> &pixels, uint32_t &width,
                          uint32_t &height, ExifOrientation orientation) {
  if (isIdentity(orientation) || width == 0 || height == 0) return;
  const size_t expected =
      static_cast<size_t>(width) * static_cast<size_t>(height) * 4;
  if (pixels.size() != expected) return;

  std::vector<uint8_t> turned(expected);
  gather(pixels.data(), static_cast<int>(width), static_cast<int>(height),
         orientation, turned.data());
  pixels = std::move(turned);
  if (swapsAxes(orientation)) std::swap(width, height);
}

uint8_t *orientedCopy(const uint8_t *pixels, int width, int height,
                      ExifOrientation orientation, int &outWidth,
                      int &outHeight) {
  if (pixels == nullptr || isIdentity(orientation) || width <= 0 ||
      height <= 0) {
    return nullptr;
  }
  const size_t bytes =
      static_cast<size_t>(width) * static_cast<size_t>(height) * 4;
  auto *turned = static_cast<uint8_t *>(std::malloc(bytes));
  if (turned == nullptr) return nullptr;

  gather(pixels, width, height, orientation, turned);
  outWidth = swapsAxes(orientation) ? height : width;
  outHeight = swapsAxes(orientation) ? width : height;
  return turned;
}

}  // namespace canvas
