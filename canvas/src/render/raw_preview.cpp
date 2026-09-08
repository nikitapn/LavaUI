// Finding the picture inside a negative.
//
// A camera raw file is not an image. It is the sensor's readings behind a
// colour filter array — one channel per pixel, no white balance, no tone
// curve, no demosaic — plus everything the camera knew at the moment of the
// exposure. Turning that into something to look at is a series of decisions,
// and the camera has already made all of them once: every raw container
// carries the JPEG its own processor produced, the frame that appeared on the
// screen on the back of the body.
//
// So this does not develop anything. It finds that JPEG and hands it to the
// same decoder every other photograph goes through. What it costs is
// resolution the camera chose not to embed — the preview is often smaller than
// the sensor, 2256x1504 out of 4272x2848 on the body this was written against
// — and what it buys is that a folder of raws opens as fast as a folder of
// JPEGs, with the colours the photographer saw, and with no decoder in the
// tree that has to know what a Bayer pattern is.
//
// The containers are TIFF: an ordered chain of directories, each describing
// one image in the file, with offsets counted from the start. CR2, NEF, ARW
// and DNG all work this way and differ only in which directory holds what,
// which is why nothing here is Canon-specific.

#include "render/raw_preview.hpp"

#include <algorithm>
#include <cctype>
#include <cstdio>
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

/// The scalar in an entry, when it is one and it fits in the entry itself.
///
/// A TIFF entry holds its value inline when the value is four bytes or fewer,
/// and an offset to it otherwise. One SHORT or one LONG always fits, and a
/// preview's offset and length are always one of each — an entry with a count
/// of anything else is a different tag than the one being looked for, and is
/// refused rather than followed.
bool scalarAt(const uint8_t *entry, bool big, uint32_t &out) {
  const uint16_t type = u16(entry + 2, big);
  if (u32(entry + 4, big) != 1) return false;
  if (type == 3) {
    out = u16(entry + 8, big);
    return true;
  }
  if (type == 4) {
    out = u32(entry + 8, big);
    return true;
  }
  return false;
}

/// Directories still to read, and the ones already read.
///
/// A chain is a list of offsets a file states, so it can name a directory
/// twice, name itself, or name a hundred — all of which are cycles or bombs
/// rather than pictures. Bounded on both counts, and the bound is small
/// because no real container is deep: a CR2 has four directories, a DNG with
/// two sub-directories has six.
constexpr size_t kMaxDirectories = 32;

struct Walk {
  const uint8_t *b = nullptr;
  size_t count = 0;
  bool big = false;
  uint64_t fileSize = 0;
  std::vector<size_t> pending;
  std::vector<size_t> seen;
  std::vector<PreviewSpan> found;

  void schedule(size_t at) {
    if (at < 8 || at + 2 > count) return;  // inside the header, or past the end
    if (seen.size() + pending.size() >= kMaxDirectories) return;
    if (std::find(seen.begin(), seen.end(), at) != seen.end()) return;
    if (std::find(pending.begin(), pending.end(), at) != pending.end()) return;
    pending.push_back(at);
  }

  /// Remembers a span, having checked it is inside the file it claims to be
  /// in. Zero-length and absurd lengths go here to die, not to the reader.
  void offer(uint64_t offset, uint64_t length) {
    if (length == 0 || offset == 0) return;
    if (offset > fileSize || length > fileSize - offset) return;
    found.push_back(PreviewSpan{offset, length});
  }
};

/// Reads one directory: its previews, and wherever else it points.
void readDirectory(Walk &walk, size_t at) {
  walk.seen.push_back(at);
  const uint8_t *ifd = walk.b + at;

  // Clamped to what was actually read rather than trusted. A head-only buffer
  // and a file that lies are the same situation from in here, and both are
  // walked as far as they go instead of refused.
  const size_t declared = u16(ifd, walk.big);
  const size_t room = (walk.count - (at + 2)) / 12;
  const size_t entries = std::min(declared, room);

  // A strip pair and a JPEG-interchange pair are two ways of saying the same
  // thing, and a directory may use either. Gathered separately and offered at
  // the end, because the two halves of a pair arrive in tag order and there is
  // no guarantee which comes first.
  uint32_t stripOffset = 0, stripLength = 0;
  uint32_t jpegOffset = 0, jpegLength = 0;

  for (size_t i = 0; i < entries; ++i) {
    const uint8_t *entry = ifd + 2 + i * 12;
    const uint16_t tag = u16(entry, walk.big);
    uint32_t value = 0;

    switch (tag) {
      case 0x0111:  // StripOffsets
        if (scalarAt(entry, walk.big, value)) stripOffset = value;
        break;
      case 0x0117:  // StripByteCounts
        if (scalarAt(entry, walk.big, value)) stripLength = value;
        break;
      case 0x0201:  // JPEGInterchangeFormat
        if (scalarAt(entry, walk.big, value)) jpegOffset = value;
        break;
      case 0x0202:  // JPEGInterchangeFormatLength
        if (scalarAt(entry, walk.big, value)) jpegLength = value;
        break;
      case 0x014A: {  // SubIFDs — where NEF and DNG keep their previews
        const uint32_t howMany = u32(entry + 4, walk.big);
        if (howMany == 1) {
          if (scalarAt(entry, walk.big, value)) walk.schedule(value);
          break;
        }
        // More than one does not fit in the entry, so the value is an offset
        // to the list. Capped: the count is a number from the file.
        const uint32_t listAt = u32(entry + 8, walk.big);
        const uint32_t capped = std::min<uint32_t>(howMany, kMaxDirectories);
        for (uint32_t k = 0; k < capped; ++k) {
          const size_t itemAt = size_t(listAt) + size_t(k) * 4;
          if (itemAt + 4 > walk.count) break;
          walk.schedule(u32(walk.b + itemAt, walk.big));
        }
        break;
      }
      default:
        break;
    }
  }

  walk.offer(stripOffset, stripLength);
  walk.offer(jpegOffset, jpegLength);

  // The next directory in the chain, written after the entries.
  const size_t nextAt = at + 2 + entries * 12;
  if (nextAt + 4 <= walk.count) walk.schedule(u32(walk.b + nextAt, walk.big));
}

/// The whole of a file, or as much of its head as asked for.
std::vector<uint8_t> readHead(std::FILE *file, size_t bytes) {
  std::vector<uint8_t> head(bytes);
  const size_t got = std::fread(head.data(), 1, head.size(), file);
  head.resize(got);
  return head;
}

std::vector<uint8_t> readSpan(std::FILE *file, const PreviewSpan &span,
                              size_t limit) {
  if (std::fseek(file, static_cast<long>(span.offset), SEEK_SET) != 0) {
    return {};
  }
  const size_t want = static_cast<size_t>(std::min<uint64_t>(span.length, limit));
  std::vector<uint8_t> out(want);
  const size_t got = std::fread(out.data(), 1, out.size(), file);
  out.resize(got);
  return out;
}

}  // namespace

bool isRawPhoto(const std::string &path) {
  const size_t dot = path.find_last_of('.');
  if (dot == std::string::npos) return false;
  std::string ext = path.substr(dot + 1);
  for (char &c : ext) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
  // Canon only, deliberately. The walk above is container-generic and a NEF or
  // an ARW would very likely come out of it correctly — but "very likely" is
  // not something to claim about somebody's photographs without a file of that
  // kind to check it against. Adding one is a word here and a word in
  // `ImageFormats.extensions`.
  return ext == "cr2";
}

bool isDisplayableJpeg(const uint8_t *bytes, size_t count) {
  if (bytes == nullptr || count < 4) return false;
  if (bytes[0] != 0xFF || bytes[1] != 0xD8) return false;  // no SOI

  size_t i = 2;
  while (i + 4 <= count) {
    if (bytes[i] != 0xFF) return false;
    const uint8_t marker = bytes[i + 1];
    if (marker == 0xFF) {  // fill byte: any number may precede a marker
      ++i;
      continue;
    }
    if (marker == 0xD8 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
      i += 2;
      continue;
    }
    // Scan data, or the end of the file, without a frame header having been
    // seen. Not a frame anybody can draw.
    if (marker == 0xDA || marker == 0xD9) return false;

    // The frame header, which is the whole question. SOF0/1/2 are baseline,
    // extended sequential and progressive — what stb decodes and what every
    // camera writes its preview as. SOF3 is *lossless* JPEG, which is how a
    // CR2 stores its sensor data: a real JPEG stream, reached through the same
    // tags, larger than the preview, and an undemosaiced mosaic rather than a
    // picture. The arithmetic-coded frames (SOF9 and up) are equally real and
    // equally undecodable here.
    if (marker == 0xC0 || marker == 0xC1 || marker == 0xC2) return true;
    if (marker >= 0xC3 && marker <= 0xCF && marker != 0xC4 && marker != 0xC8 &&
        marker != 0xCC) {
      return false;
    }

    const size_t length = size_t(bytes[i + 2]) << 8 | bytes[i + 3];
    if (length < 2) return false;  // the length counts its own two bytes
    i += 2 + length;
  }
  return false;
}

std::vector<PreviewSpan> findRawPreviews(const uint8_t *bytes, size_t count,
                                         uint64_t fileSize) {
  if (bytes == nullptr || count < 8) return {};

  Walk walk;
  walk.b = bytes;
  walk.count = count;
  walk.fileSize = fileSize;

  if (bytes[0] == 0x49 && bytes[1] == 0x49) {
    walk.big = false;  // "II" — Intel, little-endian
  } else if (bytes[0] == 0x4D && bytes[1] == 0x4D) {
    walk.big = true;  // "MM" — Motorola, big-endian
  } else {
    return {};
  }
  // 42, in whichever order the two bytes above declared. A CR2 then writes
  // "CR" and a version at offset 8, and a DNG writes nothing in particular;
  // neither is checked, because what follows is the same TIFF either way and a
  // magic number nobody reads is a magic number that eventually lies.
  if (u16(bytes + 2, walk.big) != 42) return {};

  walk.schedule(u32(bytes + 4, walk.big));
  while (!walk.pending.empty()) {
    const size_t at = walk.pending.front();
    walk.pending.erase(walk.pending.begin());
    readDirectory(walk, at);
  }

  // Largest first, which is the order they are worth trying in: a container
  // holds a thumbnail as well as a preview, and both are displayable.
  std::sort(walk.found.begin(), walk.found.end(),
            [](const PreviewSpan &a, const PreviewSpan &b) {
              return a.length > b.length;
            });
  return walk.found;
}

std::vector<uint8_t> readRawPreview(const std::string &path) {
  std::FILE *file = std::fopen(path.c_str(), "rb");
  if (file == nullptr) return {};

  uint64_t fileSize = 0;
  if (std::fseek(file, 0, SEEK_END) == 0) {
    const long end = std::ftell(file);
    if (end > 0) fileSize = static_cast<uint64_t>(end);
  }
  if (fileSize == 0 || std::fseek(file, 0, SEEK_SET) != 0) {
    std::fclose(file);
    return {};
  }

  const std::vector<uint8_t> head = readHead(file, kRawHeaderBytes);
  const std::vector<PreviewSpan> spans =
      findRawPreviews(head.data(), head.size(), fileSize);

  for (const PreviewSpan &span : spans) {
    // A hundred bytes cannot be a photograph, and skipping the small ones
    // keeps the probe below off every stray offset in the file.
    if (span.length < 1024) continue;
    const std::vector<uint8_t> probe = readSpan(file, span, kJpegProbeBytes);
    if (!isDisplayableJpeg(probe.data(), probe.size())) continue;
    if (span.length <= probe.size()) {
      std::fclose(file);
      return probe;  // already read whole
    }
    std::vector<uint8_t> whole = readSpan(file, span, span.length);
    std::fclose(file);
    return whole;
  }

  std::fclose(file);
  return {};
}

}  // namespace canvas
