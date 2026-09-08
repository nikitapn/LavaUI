// The orientation tag, and the turn it asks for.
//
// Two halves, and they fail differently. The reader walks offsets a stranger
// wrote, so what it has to do above all is not read past the buffer — every
// case here is also run against every truncation of itself, which is the cheap
// version of a fuzzer and has found more than one off-by-one in code shaped
// like this. The turn is arithmetic with eight cases and no I/O, and it is the
// only implementation of turning pixels in the tree — what a viewer draws and
// what it saves both come through here — so it is checked against a picture
// small enough to write out by hand, and against the fact that these
// transforms form a group: a quarter turn four times is where it started, and
// five of the eight are their own inverse.
//
// No Vulkan, no stb, no file beyond one temporary: an image's metadata is
// bytes, and a test about it should run anywhere.

#include "render/exif.hpp"

#include <unistd.h>

#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

using canvas::applyExifOrientation;
using canvas::ExifOrientation;
using canvas::readExifOrientation;
using canvas::swapsAxes;

namespace {

int failures = 0;

void check(bool ok, const std::string &what) {
  if (ok) return;
  std::fprintf(stderr, "FAIL: %s\n", what.c_str());
  ++failures;
}

void checkOrientation(ExifOrientation got, ExifOrientation want,
                      const std::string &what) {
  check(got == want,
        what + " (got " + std::to_string(static_cast<int>(got)) + ", want " +
            std::to_string(static_cast<int>(want)) + ")");
}

// ─── Building files to read ─────────────────────────────────────────────────

void put16(std::vector<uint8_t> &out, uint16_t v, bool big) {
  if (big) {
    out.push_back(uint8_t(v >> 8));
    out.push_back(uint8_t(v));
  } else {
    out.push_back(uint8_t(v));
    out.push_back(uint8_t(v >> 8));
  }
}

void put32(std::vector<uint8_t> &out, uint32_t v, bool big) {
  if (big) {
    out.push_back(uint8_t(v >> 24));
    out.push_back(uint8_t(v >> 16));
    out.push_back(uint8_t(v >> 8));
    out.push_back(uint8_t(v));
  } else {
    out.push_back(uint8_t(v));
    out.push_back(uint8_t(v >> 8));
    out.push_back(uint8_t(v >> 16));
    out.push_back(uint8_t(v >> 24));
  }
}

/// A TIFF header and an IFD0 holding one or two entries, the orientation last
/// when `decoy` is set — so the walk has to actually walk rather than read the
/// first entry it finds.
std::vector<uint8_t> tiffBlock(int orientation, bool big, bool decoy = false,
                               uint16_t type = 3) {
  std::vector<uint8_t> b;
  b.push_back(big ? 0x4D : 0x49);
  b.push_back(big ? 0x4D : 0x49);
  put16(b, 42, big);
  put32(b, 8, big);  // IFD0 immediately after the header

  const uint16_t entries = decoy ? 2 : 1;
  put16(b, entries, big);
  if (decoy) {
    put16(b, 0x011A, big);  // XResolution — something to step over
    put16(b, 5, big);       // RATIONAL
    put32(b, 1, big);
    put32(b, 0, big);
  }
  put16(b, 0x0112, big);  // Orientation
  put16(b, type, big);
  put32(b, 1, big);
  if (type == 3) {
    put16(b, uint16_t(orientation), big);
    put16(b, 0, big);  // the value is left-aligned in a four-byte field
  } else {
    put32(b, uint32_t(orientation), big);
  }
  put32(b, 0, big);  // no IFD1
  return b;
}

void appendSegment(std::vector<uint8_t> &out, uint8_t marker,
                   const std::vector<uint8_t> &payload) {
  out.push_back(0xFF);
  out.push_back(marker);
  const size_t length = payload.size() + 2;
  out.push_back(uint8_t(length >> 8));
  out.push_back(uint8_t(length));
  out.insert(out.end(), payload.begin(), payload.end());
}

std::vector<uint8_t> jpeg(const std::vector<uint8_t> &tiff, bool withJfif) {
  std::vector<uint8_t> out{0xFF, 0xD8};
  if (withJfif) {
    std::vector<uint8_t> jfif{'J', 'F', 'I', 'F', 0, 1, 1, 0, 0, 1, 0, 1, 0, 0};
    appendSegment(out, 0xE0, jfif);
  }
  if (!tiff.empty()) {
    std::vector<uint8_t> app1{'E', 'x', 'i', 'f', 0, 0};
    app1.insert(app1.end(), tiff.begin(), tiff.end());
    appendSegment(out, 0xE1, app1);
  }
  // A comment after it, then the start of the scan: everything past here is
  // entropy-coded and must stop the walk rather than be read as markers.
  appendSegment(out, 0xFE, {'n', 'o', 't', ' ', 'a', ' ', 't', 'a', 'g'});
  out.push_back(0xFF);
  out.push_back(0xDA);
  out.push_back(0x00);
  out.push_back(0x02);
  for (int i = 0; i < 64; ++i) out.push_back(uint8_t(i * 7));
  return out;
}

void appendChunk(std::vector<uint8_t> &out, const char *type,
                 const std::vector<uint8_t> &data) {
  put32(out, uint32_t(data.size()), true);
  out.insert(out.end(), type, type + 4);
  out.insert(out.end(), data.begin(), data.end());
  put32(out, 0, true);  // CRC, which nothing here checks
}

std::vector<uint8_t> png(const std::vector<uint8_t> &tiff, bool afterIdat) {
  std::vector<uint8_t> out{0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n'};
  appendChunk(out, "IHDR", std::vector<uint8_t>(13, 0));
  if (!tiff.empty() && !afterIdat) appendChunk(out, "eXIf", tiff);
  appendChunk(out, "IDAT", std::vector<uint8_t>(16, 0x55));
  if (!tiff.empty() && afterIdat) appendChunk(out, "eXIf", tiff);
  appendChunk(out, "IEND", {});
  return out;
}

// ─── Reading ────────────────────────────────────────────────────────────────

/// Every prefix of `bytes`, to be sure a short read is answered rather than
/// walked off the end of. Nothing is asserted about *what* it answers — a
/// header cut in half may legitimately lose the tag — only that it answers.
void checkEveryTruncation(const std::vector<uint8_t> &bytes,
                          const std::string &what) {
  for (size_t n = 0; n <= bytes.size(); ++n) {
    const ExifOrientation got = readExifOrientation(bytes.data(), n);
    check(got >= ExifOrientation::topLeft && got <= ExifOrientation::leftBottom,
          what + " truncated to " + std::to_string(n) + " answered in range");
  }
}

void testReadsEveryOrientation() {
  for (int value = 1; value <= 8; ++value) {
    const auto want = static_cast<ExifOrientation>(value);
    for (const bool big : {false, true}) {
      const std::string where =
          std::string(big ? "big" : "little") + "-endian " + std::to_string(value);
      checkOrientation(readExifOrientation(jpeg(tiffBlock(value, big), false).data(),
                                           jpeg(tiffBlock(value, big), false).size()),
                       want, "JPEG, " + where);

      const auto withJfif = jpeg(tiffBlock(value, big, /*decoy=*/true), true);
      checkOrientation(readExifOrientation(withJfif.data(), withJfif.size()), want,
                       "JPEG behind a JFIF segment, " + where);

      const auto pngBytes = png(tiffBlock(value, big), /*afterIdat=*/false);
      checkOrientation(readExifOrientation(pngBytes.data(), pngBytes.size()), want,
                       "PNG eXIf, " + where);

      const auto bare = tiffBlock(value, big);
      checkOrientation(readExifOrientation(bare.data(), bare.size()), want,
                       "bare TIFF block, " + where);
    }
  }
}

void testAbsentAndBrokenReadAsUpright() {
  const auto plain = jpeg({}, true);
  checkOrientation(readExifOrientation(plain.data(), plain.size()),
                   ExifOrientation::topLeft, "JPEG with no Exif");

  const auto late = png(tiffBlock(6, false), /*afterIdat=*/true);
  checkOrientation(readExifOrientation(late.data(), late.size()),
                   ExifOrientation::topLeft, "PNG eXIf after IDAT is not looked for");

  // Values outside 1-8, and a type the tag is never written in.
  for (const int bad : {0, 9, 255}) {
    const auto bytes = jpeg(tiffBlock(bad, false), false);
    checkOrientation(readExifOrientation(bytes.data(), bytes.size()),
                     ExifOrientation::topLeft,
                     "orientation " + std::to_string(bad) + " is not a value");
  }

  // LONG instead of SHORT: out of spec, written anyway, accepted.
  const auto asLong = jpeg(tiffBlock(8, false, false, /*type=*/4), false);
  checkOrientation(readExifOrientation(asLong.data(), asLong.size()),
                   ExifOrientation::leftBottom, "orientation written as LONG");

  // A TIFF header whose byte order is neither.
  std::vector<uint8_t> nonsense = tiffBlock(6, false);
  nonsense[0] = 'X';
  checkOrientation(readExifOrientation(nonsense.data(), nonsense.size()),
                   ExifOrientation::topLeft, "unknown byte order");

  // An IFD offset pointing far past the end of the buffer.
  std::vector<uint8_t> runaway = tiffBlock(6, false);
  runaway[4] = 0xFF;
  runaway[5] = 0xFF;
  runaway[6] = 0xFF;
  runaway[7] = 0x7F;
  checkOrientation(readExifOrientation(runaway.data(), runaway.size()),
                   ExifOrientation::topLeft, "IFD offset past the end");

  std::vector<uint8_t> notAnImage(512);
  for (size_t i = 0; i < notAnImage.size(); ++i) notAnImage[i] = uint8_t(i * 31);
  checkOrientation(readExifOrientation(notAnImage.data(), notAnImage.size()),
                   ExifOrientation::topLeft, "bytes that are not an image");

  checkOrientation(readExifOrientation(nullptr, 0), ExifOrientation::topLeft,
                   "no bytes at all");
}

void testShortReadsAreAnswered() {
  checkEveryTruncation(jpeg(tiffBlock(6, false, true), true), "JPEG");
  checkEveryTruncation(jpeg(tiffBlock(3, true), false), "big-endian JPEG");
  checkEveryTruncation(png(tiffBlock(8, false), false), "PNG");
  checkEveryTruncation(tiffBlock(5, true), "bare TIFF");

  // An Exif segment whose stated length runs past what was read: the tag is
  // still in hand, and refusing it would mean a file whose header is larger
  // than one read loses its orientation.
  auto bytes = jpeg(tiffBlock(6, false), false);
  bytes.resize(bytes.size() - 40);
  checkOrientation(readExifOrientation(bytes.data(), bytes.size()),
                   ExifOrientation::rightTop, "Exif block cut short still parses");
}

void testReadsFromAFile() {
  const std::string path = "/tmp/canvas_exif_test_XXXXXX";
  std::vector<char> name(path.begin(), path.end());
  name.push_back('\0');
  const int fd = ::mkstemp(name.data());
  check(fd >= 0, "temporary file created");
  if (fd < 0) return;

  const auto bytes = jpeg(tiffBlock(8, true), true);
  check(::write(fd, bytes.data(), bytes.size()) ==
            static_cast<ssize_t>(bytes.size()),
        "temporary file written");
  ::close(fd);

  checkOrientation(readExifOrientation(std::string(name.data())),
                   ExifOrientation::leftBottom, "orientation read from a file");
  ::unlink(name.data());

  checkOrientation(readExifOrientation(std::string("/nonexistent/nothing.jpg")),
                   ExifOrientation::topLeft, "a file that is not there");
}

// ─── Turning ────────────────────────────────────────────────────────────────

struct Image {
  std::vector<uint8_t> pixels;
  uint32_t width = 0;
  uint32_t height = 0;

  bool operator==(const Image &other) const {
    return width == other.width && height == other.height &&
           pixels == other.pixels;
  }
};

/// Every pixel says where it came from: red is x, green is y.
Image ramp(uint32_t w, uint32_t h) {
  Image img;
  img.width = w;
  img.height = h;
  img.pixels.resize(size_t(w) * h * 4);
  for (uint32_t y = 0; y < h; ++y) {
    for (uint32_t x = 0; x < w; ++x) {
      uint8_t *p = img.pixels.data() + (size_t(y) * w + x) * 4;
      p[0] = uint8_t(x);
      p[1] = uint8_t(y);
      p[2] = 0;
      p[3] = 255;
    }
  }
  return img;
}

Image turned(Image img, ExifOrientation o) {
  applyExifOrientation(img.pixels, img.width, img.height, o);
  return img;
}

/// Where the pixel now at (x, y) came from, as (red, green).
std::pair<int, int> from(const Image &img, uint32_t x, uint32_t y) {
  const uint8_t *p = img.pixels.data() + (size_t(y) * img.width + x) * 4;
  return {p[0], p[1]};
}

void testTurnMatchesAPictureDoneByHand() {
  // Two wide, three tall. Rotated a quarter turn clockwise, the left-hand
  // column becomes the top row read bottom-to-top:
  //
  //   (0,0) (1,0)                 (0,2) (0,1) (0,0)
  //   (0,1) (1,1)      →          (1,2) (1,1) (1,0)
  //   (0,2) (1,2)
  const Image quarter = turned(ramp(2, 3), ExifOrientation::rightTop);
  check(quarter.width == 3 && quarter.height == 2, "a quarter turn swaps the axes");
  const std::pair<int, int> want[2][3] = {
      {{0, 2}, {0, 1}, {0, 0}},
      {{1, 2}, {1, 1}, {1, 0}},
  };
  for (uint32_t y = 0; y < 2; ++y) {
    for (uint32_t x = 0; x < 3; ++x) {
      check(from(quarter, x, y) == want[y][x],
            "quarter turn at " + std::to_string(x) + "," + std::to_string(y));
    }
  }

  // The mirrors, which no quarter turn can express and which the Swift side
  // therefore cannot do at all.
  const Image mirrored = turned(ramp(2, 3), ExifOrientation::topRight);
  check(mirrored.width == 2 && mirrored.height == 3, "a mirror keeps the axes");
  check(from(mirrored, 0, 0) == std::make_pair(1, 0) &&
            from(mirrored, 1, 2) == std::make_pair(0, 2),
        "mirrored left-to-right");

  const Image transposed = turned(ramp(2, 3), ExifOrientation::leftTop);
  check(transposed.width == 3 && transposed.height == 2, "transpose swaps the axes");
  check(from(transposed, 2, 1) == std::make_pair(1, 2) &&
            from(transposed, 0, 0) == std::make_pair(0, 0),
        "transposed about the main diagonal");
}

void testTurnsFormTheGroupTheyClaimTo() {
  const Image original = ramp(5, 3);

  // Five of the eight are their own inverse: two mirrors, the half turn, and
  // the two diagonal flips.
  for (const ExifOrientation o :
       {ExifOrientation::topRight, ExifOrientation::bottomRight,
        ExifOrientation::bottomLeft, ExifOrientation::leftTop,
        ExifOrientation::rightBottom}) {
    check(turned(turned(original, o), o) == original,
          "orientation " + std::to_string(static_cast<int>(o)) +
              " twice is where it started");
  }

  // A quarter turn four times, and the two quarter turns against each other.
  Image round = original;
  for (int i = 0; i < 4; ++i) round = turned(round, ExifOrientation::rightTop);
  check(round == original, "four quarter turns is where it started");
  check(turned(turned(original, ExifOrientation::rightTop),
               ExifOrientation::leftBottom) == original,
        "the two quarter turns undo each other");
  check(turned(turned(original, ExifOrientation::rightTop),
               ExifOrientation::rightTop) ==
            turned(original, ExifOrientation::bottomRight),
        "two quarter turns is the half turn");

  check(turned(original, ExifOrientation::topLeft) == original,
        "upright moves nothing");
  for (int value = 1; value <= 8; ++value) {
    const auto o = static_cast<ExifOrientation>(value);
    const Image t = turned(original, o);
    check(t.width == (swapsAxes(o) ? original.height : original.width) &&
              t.height == (swapsAxes(o) ? original.width : original.height),
          "orientation " + std::to_string(value) + " reports its own axes");
    check(t.pixels.size() == original.pixels.size(),
          "orientation " + std::to_string(value) + " keeps every pixel");
  }
}

void testTurnRefusesABufferThatIsNotTheImage() {
  Image wrong = ramp(4, 4);
  wrong.pixels.resize(wrong.pixels.size() - 4);  // one pixel short
  const Image before = wrong;
  applyExifOrientation(wrong.pixels, wrong.width, wrong.height,
                       ExifOrientation::rightTop);
  check(wrong == before, "a buffer that is not the image it claims is left alone");

  Image empty;
  applyExifOrientation(empty.pixels, empty.width, empty.height,
                       ExifOrientation::bottomRight);
  check(empty.pixels.empty() && empty.width == 0, "no pixels, nothing to turn");
}

}  // namespace

int main() {
  testReadsEveryOrientation();
  testAbsentAndBrokenReadAsUpright();
  testShortReadsAreAnswered();
  testReadsFromAFile();
  testTurnMatchesAPictureDoneByHand();
  testTurnsFormTheGroupTheyClaimTo();
  testTurnRefusesABufferThatIsNotTheImage();

  if (failures != 0) {
    std::fprintf(stderr, "%d check(s) failed\n", failures);
    return 1;
  }
  std::printf("exif: all checks passed\n");
  return 0;
}
