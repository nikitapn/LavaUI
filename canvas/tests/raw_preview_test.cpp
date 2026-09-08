// What a raw container has to survive being asked.
//
// The fixtures are built byte by byte rather than shipped, for the reason the
// EXIF tests are: a checked-in CR2 is 13 MB of somebody's photograph, and the
// interesting cases — a directory that points at itself, a length that runs
// off the end of the file, a preview that is really the sensor data — are ones
// no camera writes and so no real file can test.
//
// The shape being built is a real CR2's, measured from one: four directories,
// where #0 holds the displayable preview, #1 a thumbnail, #2 an *uncompressed*
// block bigger than the preview, and #3 the sensor data as a lossless JPEG
// four times bigger than everything else put together. Taking the largest
// span would return #3 every time, which is why the test exists.

#include "render/raw_preview.hpp"

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

using canvas::findRawPreviews;
using canvas::isDisplayableJpeg;
using canvas::isRawPhoto;
using canvas::PreviewSpan;

namespace {

int failures = 0;

void check(bool ok, const std::string &what) {
  if (ok) return;
  std::printf("FAIL: %s\n", what.c_str());
  ++failures;
}

// ─── Building files nobody would ship ──────────────────────────────────────

void put16(std::vector<uint8_t> &out, size_t at, uint16_t value, bool big) {
  if (big) {
    out[at] = uint8_t(value >> 8);
    out[at + 1] = uint8_t(value);
  } else {
    out[at] = uint8_t(value);
    out[at + 1] = uint8_t(value >> 8);
  }
}

void put32(std::vector<uint8_t> &out, size_t at, uint32_t value, bool big) {
  if (big) {
    out[at] = uint8_t(value >> 24);
    out[at + 1] = uint8_t(value >> 16);
    out[at + 2] = uint8_t(value >> 8);
    out[at + 3] = uint8_t(value);
  } else {
    out[at] = uint8_t(value);
    out[at + 1] = uint8_t(value >> 8);
    out[at + 2] = uint8_t(value >> 16);
    out[at + 3] = uint8_t(value >> 24);
  }
}

struct Entry {
  uint16_t tag;
  uint16_t type;  // 3 = SHORT, 4 = LONG
  uint32_t count;
  uint32_t value;
};

/// One directory written at `at`, chaining to `next`.
void writeIfd(std::vector<uint8_t> &file, size_t at,
              const std::vector<Entry> &entries, uint32_t next, bool big) {
  const size_t need = at + 2 + entries.size() * 12 + 4;
  if (file.size() < need) file.resize(need, 0);
  put16(file, at, static_cast<uint16_t>(entries.size()), big);
  for (size_t i = 0; i < entries.size(); ++i) {
    const size_t e = at + 2 + i * 12;
    put16(file, e, entries[i].tag, big);
    put16(file, e + 2, entries[i].type, big);
    put32(file, e + 4, entries[i].count, big);
    if (entries[i].type == 3) {
      // A SHORT sits in the first half of the value field, which is not the
      // same two bytes in both byte orders — the bug this catches is writing
      // it as a LONG and having little-endian silently agree.
      put16(file, e + 8, static_cast<uint16_t>(entries[i].value), big);
      put16(file, e + 10, 0, big);
    } else {
      put32(file, e + 8, entries[i].value, big);
    }
  }
  put32(file, at + 2 + entries.size() * 12, next, big);
}

/// A JPEG stream with the frame header a decoder would find, and nothing else
/// that matters. `sof` is the marker byte: 0xC0 baseline, 0xC3 lossless.
std::vector<uint8_t> fakeJpeg(uint8_t sof, size_t padTo) {
  std::vector<uint8_t> j = {
      0xFF, 0xD8,                          // SOI
      0xFF, 0xDB, 0x00, 0x04, 0x00, 0x00,  // a quantisation table, of sorts
      0xFF, sof,  0x00, 0x0B, 0x08, 0x01, 0x00, 0x01, 0x00, 0x01, 0x01, 0x11,
      0x00,                                // SOFn: 256x256, one component
      0xFF, 0xDA, 0x00, 0x02,              // SOS
  };
  while (j.size() < padTo) j.push_back(0x00);
  return j;
}

void place(std::vector<uint8_t> &file, size_t at,
           const std::vector<uint8_t> &blob) {
  if (file.size() < at + blob.size()) file.resize(at + blob.size(), 0);
  std::memcpy(file.data() + at, blob.data(), blob.size());
}

/// A file shaped like the CR2 this was written against.
///
/// Offsets are chosen to leave room and are not otherwise meaningful, except
/// that the sensor data is deliberately the biggest thing in the file.
struct Cr2 {
  std::vector<uint8_t> bytes;
  uint32_t previewAt = 0, previewLen = 0;
  uint32_t rawAt = 0, rawLen = 0;
};

Cr2 buildCr2(bool big) {
  Cr2 out;
  std::vector<uint8_t> &f = out.bytes;
  f.resize(0x200, 0);

  f[0] = big ? 0x4D : 0x49;
  f[1] = big ? 0x4D : 0x49;
  put16(f, 2, 42, big);
  put32(f, 4, 0x10, big);  // IFD#0
  // The "CR" signature a real file carries and this parser deliberately
  // ignores. Present so the fixture is honest, not because anything reads it.
  f[8] = 'C';
  f[9] = 'R';
  f[10] = 2;
  f[11] = 0;

  const uint32_t thumbAt = 0x300, thumbLen = 2048;
  const uint32_t previewAt = 0x1000, previewLen = 40000;
  const uint32_t plainAt = 0x20000, plainLen = 90000;  // uncompressed, no SOI
  const uint32_t rawAt = 0x40000, rawLen = 400000;     // lossless: the biggest

  writeIfd(f, 0x10,
           {{0x0100, 3, 1, 256},
            {0x0103, 3, 1, 6},
            {0x0111, 4, 1, previewAt},
            {0x0112, 3, 1, 1},
            {0x0117, 4, 1, previewLen}},
           0x100, big);
  writeIfd(f, 0x100, {{0x0201, 4, 1, thumbAt}, {0x0202, 4, 1, thumbLen}}, 0x160,
           big);
  writeIfd(f, 0x160,
           {{0x0103, 3, 1, 1},
            {0x0111, 4, 1, plainAt},
            {0x0117, 4, 1, plainLen}},
           0x1C0, big);
  writeIfd(f, 0x1C0,
           {{0x0103, 3, 1, 6}, {0x0111, 4, 1, rawAt}, {0x0117, 4, 1, rawLen}},
           0, big);

  place(f, thumbAt, fakeJpeg(0xC0, thumbLen));
  place(f, previewAt, fakeJpeg(0xC0, previewLen));
  std::vector<uint8_t> plain(plainLen, 0x7F);  // no SOI anywhere in it
  place(f, plainAt, plain);
  place(f, rawAt, fakeJpeg(0xC3, rawLen));  // lossless — a mosaic, not a photo

  out.previewAt = previewAt;
  out.previewLen = previewLen;
  out.rawAt = rawAt;
  out.rawLen = rawLen;
  return out;
}

// ─── The cases ─────────────────────────────────────────────────────────────

/// What `readRawPreview` does, over bytes rather than a file: the spans in
/// order, filtered the way the reader filters them.
std::vector<uint8_t> chooseFrom(const std::vector<uint8_t> &file) {
  for (const PreviewSpan &span :
       findRawPreviews(file.data(), file.size(), file.size())) {
    if (span.length < 1024) continue;
    if (span.offset + span.length > file.size()) continue;
    const uint8_t *at = file.data() + span.offset;
    if (!isDisplayableJpeg(at, static_cast<size_t>(span.length))) continue;
    return std::vector<uint8_t>(at, at + span.length);
  }
  return {};
}

void theBiggestSpanIsNotThePicture() {
  for (const bool big : {false, true}) {
    const Cr2 cr2 = buildCr2(big);
    const std::string where = big ? " (MM)" : " (II)";

    const std::vector<PreviewSpan> spans =
        findRawPreviews(cr2.bytes.data(), cr2.bytes.size(), cr2.bytes.size());
    check(spans.size() == 4, "all four directories are found" + where);
    check(!spans.empty() && spans[0].length == cr2.rawLen,
          "the sensor data is the largest span" + where);

    const std::vector<uint8_t> chosen = chooseFrom(cr2.bytes);
    check(chosen.size() == cr2.previewLen,
          "the preview is chosen over the sensor data" + where);
    check(chosen.size() > 1 && chosen[0] == 0xFF && chosen[1] == 0xD8,
          "what is chosen begins a JPEG" + where);
  }
}

void aFileWithOnlyASensorFrameHasNoPreview() {
  Cr2 cr2 = buildCr2(false);
  // Break the preview's frame header, leaving it the same size: a container
  // whose only JPEGs are lossless must answer with nothing rather than with a
  // mosaic. The thumbnail goes too, so nothing else can stand in.
  cr2.bytes[cr2.previewAt + 9] = 0xC3;
  cr2.bytes[0x300 + 9] = 0xC3;
  check(chooseFrom(cr2.bytes).empty(),
        "a container of lossless frames yields nothing");
}

void thumbnailsLoseToPreviews() {
  const Cr2 cr2 = buildCr2(false);
  const std::vector<uint8_t> chosen = chooseFrom(cr2.bytes);
  check(chosen.size() == cr2.previewLen,
        "the 40 KB preview wins over the 2 KB thumbnail");
}

void spansOutsideTheFileAreRefused() {
  std::vector<uint8_t> f(0x200, 0);
  f[0] = 0x49;
  f[1] = 0x49;
  put16(f, 2, 42, false);
  put32(f, 4, 0x10, false);
  writeIfd(f, 0x10,
           {{0x0111, 4, 1, 0xF000'0000u}, {0x0117, 4, 1, 0x1000'0000u}}, 0,
           false);
  check(findRawPreviews(f.data(), f.size(), f.size()).empty(),
        "an offset past the end of the file is not offered");

  // The other half of the same lie: an offset inside the file with a length
  // that runs off it. Wrapping is the bug being guarded against here.
  writeIfd(f, 0x10, {{0x0111, 4, 1, 0x100}, {0x0117, 4, 1, 0xFFFF'FF00u}}, 0,
           false);
  check(findRawPreviews(f.data(), f.size(), f.size()).empty(),
        "a length that runs off the end is not offered");
}

void loopsTerminate() {
  std::vector<uint8_t> f(0x200, 0);
  f[0] = 0x49;
  f[1] = 0x49;
  put16(f, 2, 42, false);
  put32(f, 4, 0x10, false);
  // A directory that chains to itself, and a sub-directory pointing back at
  // the parent. Either would spin for ever without the seen-set.
  writeIfd(f, 0x10, {{0x014A, 4, 1, 0x10}}, 0x10, false);
  const std::vector<PreviewSpan> spans =
      findRawPreviews(f.data(), f.size(), f.size());
  check(spans.empty(), "a self-referencing chain terminates and finds nothing");
}

void everyTruncationIsSafe() {
  const Cr2 cr2 = buildCr2(false);
  // Every prefix of a real container, which is what a partial read gives and
  // what a corrupt file looks like. None may crash; the answer is whatever can
  // still be reached, and past a point that is nothing.
  for (size_t n = 0; n <= 0x400; ++n) {
    const std::vector<PreviewSpan> spans =
        findRawPreviews(cr2.bytes.data(), n, cr2.bytes.size());
    for (const PreviewSpan &span : spans) {
      check(span.offset + span.length <= cr2.bytes.size(),
            "a span found in a truncated head is still inside the file");
    }
  }
  check(true, "every truncation of a container parses without crashing");
}

void nonContainersAreRejected() {
  const std::vector<uint8_t> png = {0x89, 'P', 'N', 'G', 0x0D,
                                    0x0A, 0x1A, 0x0A, 0, 0};
  check(findRawPreviews(png.data(), png.size(), png.size()).empty(),
        "a PNG is not a TIFF container");

  std::vector<uint8_t> notFortyTwo(0x100, 0);
  notFortyTwo[0] = 0x49;
  notFortyTwo[1] = 0x49;
  put16(notFortyTwo, 2, 43, false);  // BigTIFF, which this does not read
  put32(notFortyTwo, 4, 0x10, false);
  check(findRawPreviews(notFortyTwo.data(), notFortyTwo.size(),
                        notFortyTwo.size())
            .empty(),
        "a version this cannot read is refused rather than guessed at");

  check(findRawPreviews(nullptr, 0, 0).empty(), "no bytes, no previews");
}

void frameHeadersAreToldApart() {
  check(isDisplayableJpeg(fakeJpeg(0xC0, 64).data(), 64), "SOF0 is displayable");
  check(isDisplayableJpeg(fakeJpeg(0xC1, 64).data(), 64), "SOF1 is displayable");
  check(isDisplayableJpeg(fakeJpeg(0xC2, 64).data(), 64), "SOF2 is displayable");
  check(!isDisplayableJpeg(fakeJpeg(0xC3, 64).data(), 64),
        "SOF3, lossless, is not");
  check(!isDisplayableJpeg(fakeJpeg(0xC9, 64).data(), 64),
        "SOF9, arithmetic, is not");

  const std::vector<uint8_t> notJpeg(64, 0x7F);
  check(!isDisplayableJpeg(notJpeg.data(), notJpeg.size()), "raw bytes are not");

  // Every truncation of a frame: a header cut before its marker must answer
  // no, never read past the end.
  const std::vector<uint8_t> whole = fakeJpeg(0xC0, 64);
  for (size_t n = 0; n < whole.size(); ++n) {
    if (isDisplayableJpeg(whole.data(), n) && n < 10) {
      check(false, "a frame header cannot be recognised before it is present");
    }
  }
  check(true, "every truncation of a frame answers without crashing");
}

void extensionsAreMatchedLoosely() {
  check(isRawPhoto("/photos/IMG_4073.CR2"), "an upper-case extension counts");
  check(isRawPhoto("x.cr2"), "so does lower case");
  check(!isRawPhoto("x.cr2.jpg"), "the last extension is the one that decides");
  check(!isRawPhoto("cr2"), "a bare name with no dot is not a raw");
  check(!isRawPhoto("/photos/holiday.jpg"), "a JPEG is not a raw");
}

}  // namespace

int main(int argc, char **argv) {
  theBiggestSpanIsNotThePicture();
  aFileWithOnlyASensorFrameHasNoPreview();
  thumbnailsLoseToPreviews();
  spansOutsideTheFileAreRefused();
  loopsTerminate();
  everyTruncationIsSafe();
  nonContainersAreRejected();
  frameHeadersAreToldApart();
  extensionsAreMatchedLoosely();

  // A real file, when one is named: `raw_preview_test /photos/IMG_4073.CR2`.
  // Not part of the suite, because a 13 MB photograph is not something to
  // check into a repository — but the one thing a synthetic fixture cannot
  // prove is that a camera agrees with what this expects of it.
  if (argc > 1) {
    const std::vector<uint8_t> preview = canvas::readRawPreview(argv[1]);
    check(preview.size() > 1024, "a real raw yields a preview");
    check(preview.size() > 1 && preview[0] == 0xFF && preview[1] == 0xD8,
          "and it begins a JPEG");
    std::printf("%s: %zu byte preview\n", argv[1], preview.size());
  }

  if (failures == 0) std::printf("raw preview: all checks passed\n");
  return failures == 0 ? 0 : 1;
}
