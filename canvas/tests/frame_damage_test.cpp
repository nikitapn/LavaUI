// Frame damage: what it may leave out, and what it must not.
//
// The tally decides which part of a window the compositor recomposites, so the
// two failures are not symmetric. Damaging too much costs a little power;
// damaging too little leaves stale pixels on screen until something else
// happens to touch them. Every doubt therefore has to come out as "all of
// it", and those cases are checked as carefully as the narrow ones.
//
// No GPU: the tally is arithmetic over rectangles and hashes.

#include "render/frame_damage.hpp"

#include <cstdio>
#include <vector>

using canvas::DamageRect;
using canvas::FrameDamage;

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

constexpr int T = FrameDamage::kTile;

/// One frame: a full-window background and a caret at `caretX`, if shown.
void frame(FrameDamage &d, uint32_t w, uint32_t h, bool caret,
           float caretX = 100.f) {
  d.begin(w, h);
  d.add(0, 0, static_cast<float>(w), static_cast<float>(h), 1);
  if (caret) d.add(caretX, 40, caretX + 2, 60, 2);
  d.end();
}

bool covers(const std::vector<DamageRect> &rects, int x, int y) {
  for (const auto &r : rects) {
    if (x >= r.x && x < r.x + r.width && y >= r.y && y < r.y + r.height)
      return true;
  }
  return false;
}

/// The first frame has nothing to be compared with.
void firstFrameIsWhole() {
  FrameDamage d;
  frame(d, 640, 480, true);
  std::vector<DamageRect> out;
  CHECK(!d.take(out));
  CHECK(out.empty());
}

/// The same frame again changes nothing — the reason any of this exists.
void identicalFrameIsEmpty() {
  FrameDamage d;
  std::vector<DamageRect> out;
  frame(d, 640, 480, true);
  d.take(out);
  frame(d, 640, 480, true);
  CHECK(d.take(out));
  CHECK(out.empty());
}

/// A caret blink damages the caret's tiles and nothing else.
void caretBlinkIsOneTile() {
  FrameDamage d;
  std::vector<DamageRect> out;
  frame(d, 640, 480, true);
  d.take(out);
  frame(d, 640, 480, false);
  CHECK(d.take(out));
  CHECK(out.size() == 1);
  CHECK(covers(out, 100, 40));
  CHECK(covers(out, 101, 59));
  CHECK(!covers(out, 0, 0));
  CHECK(!covers(out, 300, 300));
  int area = 0;
  for (const auto &r : out) area += r.width * r.height;
  CHECK(area <= 2 * T * T);  // 40..60 straddles one tile row boundary at 32
}

/// Damage accumulates until taken: two frames shown as one must report both.
void accumulatesUntilTaken() {
  FrameDamage d;
  std::vector<DamageRect> out;
  frame(d, 640, 480, true, 100);
  d.take(out);
  frame(d, 640, 480, true, 400);  // caret moved from 100 to 400
  frame(d, 640, 480, true, 400);  // and stayed
  CHECK(d.take(out));
  CHECK(covers(out, 100, 50));  // where it was
  CHECK(covers(out, 400, 50));  // where it is
}

/// A frame that says it cannot be compared damages everything, and so does
/// the frame after it only if it differs.
void markAllIsWhole() {
  FrameDamage d;
  std::vector<DamageRect> out;
  frame(d, 640, 480, true);
  d.take(out);
  d.begin(640, 480);
  d.add(0, 0, 640, 480, 1);
  d.markAll();
  d.end();
  CHECK(!d.take(out));
}

/// A resize changes every tile's meaning.
void resizeIsWhole() {
  FrameDamage d;
  std::vector<DamageRect> out;
  frame(d, 640, 480, true);
  d.take(out);
  frame(d, 700, 480, true);
  CHECK(!d.take(out));
  // And damage pending from before the resize is not reported against tiles
  // that now mean something else.
  frame(d, 700, 480, false);
  frame(d, 640, 480, false);
  CHECK(!d.take(out));
}

/// Swapping two overlapping quads in paint order is a different picture.
void orderMatters() {
  FrameDamage d;
  std::vector<DamageRect> out;
  d.begin(128, 128);
  d.add(0, 0, 64, 64, 7);
  d.add(0, 0, 64, 64, 9);
  d.end();
  d.take(out);
  d.begin(128, 128);
  d.add(0, 0, 64, 64, 9);
  d.add(0, 0, 64, 64, 7);
  d.end();
  CHECK(d.take(out));
  CHECK(!out.empty());
  CHECK(covers(out, 10, 10));
}

/// A run of tiles down several rows is one rectangle, and rectangles stay
/// inside the window even when the last tile is partial.
void mergesAndClamps() {
  FrameDamage d;
  std::vector<DamageRect> out;
  d.begin(100, 100);
  d.end();
  d.take(out);
  d.begin(100, 100);
  d.add(70, 0, 100, 100, 3);  // the right-hand column of tiles, all rows
  d.end();
  CHECK(d.take(out));
  CHECK(out.size() == 1);
  if (out.size() == 1) {
    CHECK(out[0].x == 64);
    CHECK(out[0].y == 0);
    CHECK(out[0].x + out[0].width == 100);
    CHECK(out[0].y + out[0].height == 100);
  }
}

/// `invalidate` forgets the previous frame — a new destination buffer.
void invalidateIsWhole() {
  FrameDamage d;
  std::vector<DamageRect> out;
  frame(d, 640, 480, true);
  d.take(out);
  d.invalidate();
  frame(d, 640, 480, true);
  CHECK(!d.take(out));
}

/// Taking drains: the next take, with no frame between, is empty.
void takeDrains() {
  FrameDamage d;
  std::vector<DamageRect> out;
  frame(d, 640, 480, true);
  d.take(out);
  frame(d, 640, 480, false);
  CHECK(d.take(out));
  CHECK(!out.empty());
  CHECK(d.take(out));
  CHECK(out.empty());
}

} // namespace

int main()
{
  firstFrameIsWhole();
  identicalFrameIsEmpty();
  caretBlinkIsOneTile();
  accumulatesUntilTaken();
  markAllIsWhole();
  resizeIsWhole();
  orderMatters();
  mergesAndClamps();
  invalidateIsWhole();
  takeDrains();

  if (failures != 0) {
    std::fprintf(stderr, "%d check(s) failed\n", failures);
    return 1;
  }
  std::puts("frame damage: ok");
  return 0;
}
