// Pixel arena: region checks, format conversion, and the truncation the reader
// exists to survive.
//
// No GPU and no second process: the arena is plain shared memory, so a writer
// and a reader in one process exercise everything the compositor does with it
// short of the upload.

#include "ipc/pixel_arena.hpp"

#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>

#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

using canvas::ipc::checkPixelLayout;
using canvas::ipc::PixelArena;
using canvas::ipc::PixelArenaReader;
using canvas::ipc::PixelFormat;
using canvas::ipc::PixelLayout;

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

std::string uniqueId(const char *what)
{
  return std::string("test-") + what + "-" + std::to_string(::getpid());
}

PixelLayout layout(uint64_t offset, uint32_t w, uint32_t h, uint32_t stride,
                   PixelFormat format = PixelFormat::Rgba8)
{
  PixelLayout l;
  l.offset = offset;
  l.width = w;
  l.height = h;
  l.stride = stride;
  l.format = format;
  return l;
}

// ─── what a region may claim ─────────────────────────────────────────────────

void regionsAreCheckedAgainstTheArena()
{
  CHECK(checkPixelLayout(layout(0, 4, 4, 16), 64) == nullptr);
  // The last row needs only its pixels, not a whole stride.
  CHECK(checkPixelLayout(layout(0, 4, 2, 32), 32 + 16) == nullptr);
  CHECK(checkPixelLayout(layout(0, 4, 2, 32), 32 + 15) != nullptr);

  CHECK(checkPixelLayout(layout(0, 0, 4, 16), 64) != nullptr);
  CHECK(checkPixelLayout(layout(0, 4, 0, 16), 64) != nullptr);
  CHECK(checkPixelLayout(layout(0, 4, 4, 15), 64) != nullptr);
  CHECK(checkPixelLayout(layout(1, 4, 4, 16), 64) != nullptr);
  CHECK(checkPixelLayout(layout(65, 1, 1, 4), 64) != nullptr);
  CHECK(checkPixelLayout(layout(0, 16385, 1, 16385 * 4), uint64_t(1) << 40) != nullptr);

  // Values chosen to wrap a careless 64-bit sum or 32-bit product.
  CHECK(checkPixelLayout(layout(~uint64_t(0) - 8, 4, 1, 16), ~uint64_t(0)) != nullptr);
  CHECK(checkPixelLayout(layout(0, 16384, 16384, 0xffffffffu), ~uint64_t(0)) != nullptr);

  PixelLayout bad = layout(0, 1, 1, 4);
  bad.format = static_cast<PixelFormat>(7);
  CHECK(checkPixelLayout(bad, 64) != nullptr);
}

// ─── conversion ──────────────────────────────────────────────────────────────

void formatsArriveAsRgba()
{
  // One pixel, R=1 G=2 B=3 A=4, in each format's memory order.
  struct Case {
    PixelFormat format;
    uint8_t in[4];
    uint8_t out[4];
  } cases[] = {
      {PixelFormat::Rgba8, {1, 2, 3, 4}, {1, 2, 3, 4}},
      {PixelFormat::Bgra8, {3, 2, 1, 4}, {1, 2, 3, 4}},
      {PixelFormat::Rgbx8, {1, 2, 3, 9}, {1, 2, 3, 255}},
      {PixelFormat::Bgrx8, {3, 2, 1, 9}, {1, 2, 3, 255}},
  };
  for (const Case &c : cases) {
    uint8_t got[4];
    canvas::ipc::packRgba(c.in, layout(0, 1, 1, 4, c.format), got);
    CHECK(std::memcmp(got, c.out, 4) == 0);
  }
}

void stridedRowsPackInPlace()
{
  // 3x3 with a 20-byte stride: 12 bytes of pixels and 8 of padding per row.
  // In place is what the reader does, and it is the overlap that could go
  // wrong: row 1's packed position is inside row 0's padding.
  const uint32_t w = 3, h = 3, stride = 20;
  std::vector<uint8_t> buf(stride * (h - 1) + w * 4, 0xee);
  for (uint32_t y = 0; y < h; ++y)
    for (uint32_t x = 0; x < w; ++x) {
      uint8_t *p = &buf[y * stride + x * 4];
      p[0] = uint8_t(10 * y + x);  // B
      p[1] = 100;
      p[2] = uint8_t(200 + x);     // R
      p[3] = 0;
    }
  canvas::ipc::packRgba(buf.data(), layout(0, w, h, stride, PixelFormat::Bgrx8),
                        buf.data());
  for (uint32_t y = 0; y < h; ++y)
    for (uint32_t x = 0; x < w; ++x) {
      const uint8_t *p = &buf[(y * w + x) * 4];
      CHECK(p[0] == uint8_t(200 + x));
      CHECK(p[1] == 100);
      CHECK(p[2] == uint8_t(10 * y + x));
      CHECK(p[3] == 255);
    }
}

// ─── the two ends ────────────────────────────────────────────────────────────

void writerAndReaderAgree()
{
  PixelArena arena;
  CHECK(arena.create(uniqueId("roundtrip"), 4096));
  CHECK(arena.isOpen());
  CHECK(arena.size() == 4096);

  const uint8_t pixels[8] = {3, 2, 1, 4, 30, 20, 10, 40};  // BGRA, 2x1
  CHECK(arena.write(100, pixels, sizeof pixels));
  CHECK(!arena.write(4090, pixels, sizeof pixels));  // runs past the end

  PixelArenaReader reader;
  CHECK(reader.open(arena.name()));
  // What a client does as soon as the attach returns. The reader keeps the
  // file; nothing it does from here needs the name.
  arena.unlinkName();
  CHECK(::shm_open(arena.name().c_str(), O_RDONLY, 0) < 0);

  std::vector<uint8_t> out;
  CHECK(reader.read(layout(100, 2, 1, 8, PixelFormat::Bgra8), out) == nullptr);
  const uint8_t want[8] = {1, 2, 3, 4, 10, 20, 30, 40};
  CHECK(out.size() == 8 && std::memcmp(out.data(), want, 8) == 0);

  // Writes after the attach are seen: the reader reads at call time.
  const uint8_t later[4] = {9, 9, 9, 9};
  CHECK(arena.write(100, later, 4));
  CHECK(reader.read(layout(100, 1, 1, 4), out) == nullptr);
  CHECK(out.size() == 4 && out[0] == 9);
}

void truncationIsAShortReadNotACrash()
{
  // The case the reader's design is for: a client shrinks its object after
  // the compositor opened it. A mapping would SIGBUS on the next read; this
  // must return an error and carry on.
  const std::string name = std::string(canvas::ipc::kPixelArenaPrefix) +
                           uniqueId("truncate");
  const int fd = ::shm_open(name.c_str(), O_CREAT | O_EXCL | O_RDWR, 0600);
  CHECK(fd >= 0);
  CHECK(::ftruncate(fd, 4096) == 0);

  PixelArenaReader reader;
  CHECK(reader.open(name));
  ::shm_unlink(name.c_str());

  std::vector<uint8_t> out;
  CHECK(reader.read(layout(0, 16, 16, 64), out) == nullptr);
  CHECK(::ftruncate(fd, 512) == 0);
  CHECK(reader.read(layout(0, 16, 16, 64), out) != nullptr);
  CHECK(reader.read(layout(0, 8, 2, 32), out) == nullptr);  // what is left
  ::close(fd);
}

void onlyPixelArenasCanBeOpened()
{
  PixelArenaReader reader;
  CHECK(!reader.open("/lava-arena-anything-0"));
  CHECK(!reader.open("/lava-pixels-"));
  CHECK(!reader.open("/lava-pixels-a/b"));
  CHECK(!reader.open("lava-pixels-x"));
  CHECK(!reader.open(std::string(canvas::ipc::kPixelArenaPrefix) +
                     uniqueId("missing")));
  CHECK(!reader.isOpen());
}

void secondArenaWithOneNameIsRefused()
{
  const std::string id = uniqueId("twice");
  PixelArena first, second;
  CHECK(first.create(id, 64));
  CHECK(!second.create(id, 64));
  CHECK(!second.isOpen());
}

} // namespace

int main()
{
  regionsAreCheckedAgainstTheArena();
  formatsArriveAsRgba();
  stridedRowsPackInPlace();
  writerAndReaderAgree();
  truncationIsAShortReadNotACrash();
  onlyPixelArenasCanBeOpened();
  secondArenaWithOneNameIsRefused();

  if (failures != 0) {
    std::fprintf(stderr, "%d check(s) failed\n", failures);
    return 1;
  }
  std::puts("pixel arena: ok");
  return 0;
}
