#include "render/frame_damage.hpp"

#include <algorithm>
#include <cmath>
#include <cstring>

namespace canvas {

uint64_t FrameDamage::mix(uint64_t h, uint64_t v)
{
  // Order matters on purpose: two quads swapped in paint order are a
  // different picture wherever they overlap.
  h ^= v + 0x9e3779b97f4a7c15ull + (h << 6) + (h >> 2);
  h *= 0xff51afd7ed558ccdull;
  return h ^ (h >> 33);
}

uint64_t FrameDamage::hashBytes(const void *data, size_t size, uint64_t seed)
{
  const auto *bytes = static_cast<const unsigned char *>(data);
  uint64_t h = seed ^ (size * 0xc6a4a7935bd1e995ull);
  size_t i = 0;
  for (; i + 8 <= size; i += 8) {
    uint64_t word;
    std::memcpy(&word, bytes + i, 8);
    h = mix(h, word);
  }
  if (i < size) {
    uint64_t tail = 0;
    std::memcpy(&tail, bytes + i, size - i);
    h = mix(h, tail);
  }
  return h;
}

void FrameDamage::begin(uint32_t width, uint32_t height)
{
  width_ = width;
  height_ = height;
  cols_ = (width + kTile - 1) / kTile;
  rows_ = (height + kTile - 1) / kTile;
  current_.assign(static_cast<size_t>(cols_) * rows_, 0);
  frameAll_ = false;
}

void FrameDamage::add(float x0, float y0, float x1, float y1, uint64_t hash)
{
  if (cols_ == 0 || rows_ == 0) return;
  // NaN fails every comparison, so test for the good case and treat anything
  // else as the worst one rather than letting a cast decide.
  if (!(x0 <= x1 && y0 <= y1)) {
    if (!(x0 > x1 || y0 > y1)) frameAll_ = true;
    return;
  }
  const float maxX = static_cast<float>(width_);
  const float maxY = static_cast<float>(height_);
  x0 = std::clamp(std::floor(x0), 0.f, maxX);
  y0 = std::clamp(std::floor(y0), 0.f, maxY);
  x1 = std::clamp(std::ceil(x1), 0.f, maxX);
  y1 = std::clamp(std::ceil(y1), 0.f, maxY);
  if (x1 <= x0 || y1 <= y0) return;
  const uint32_t c0 = static_cast<uint32_t>(x0) / kTile;
  const uint32_t r0 = static_cast<uint32_t>(y0) / kTile;
  const uint32_t c1 = (static_cast<uint32_t>(x1) - 1) / kTile;
  const uint32_t r1 = (static_cast<uint32_t>(y1) - 1) / kTile;
  for (uint32_t r = r0; r <= r1 && r < rows_; ++r) {
    uint64_t *row = current_.data() + static_cast<size_t>(r) * cols_;
    for (uint32_t c = c0; c <= c1 && c < cols_; ++c) row[c] = mix(row[c], hash);
  }
}

void FrameDamage::end()
{
  const bool sameGrid = havePrevious_ && previousCols_ == cols_ &&
                        previousRows_ == rows_;
  if (pending_.size() != current_.size()) {
    // The grid changed shape since anything pending was recorded, so those
    // bits name the wrong tiles. A resize damages everything anyway.
    pending_.assign(current_.size(), 0);
    pendingAll_ = true;
  }
  if (frameAll_ || !sameGrid) {
    pendingAll_ = true;
  } else if (!pendingAll_) {
    for (size_t i = 0; i < current_.size(); ++i) {
      if (current_[i] != previous_[i]) pending_[i] = 1;
    }
  }
  previous_.swap(current_);
  previousCols_ = cols_;
  previousRows_ = rows_;
  havePrevious_ = true;
}

bool FrameDamage::take(std::vector<DamageRect> &out)
{
  out.clear();
  if (pendingAll_) {
    pendingAll_ = false;
    std::fill(pending_.begin(), pending_.end(), 0);
    return false;
  }
  if (pending_.size() != static_cast<size_t>(cols_) * rows_) return true;

  // Runs per row, merged downward while the next row has the identical run:
  // a caret is one tall rectangle, not one per row of tiles.
  struct Open {
    uint32_t c0, c1, r0;
    bool extended;
  };
  std::vector<Open> open, next;
  const auto emit = [&](const Open &o, uint32_t r1) {
    const int32_t x = static_cast<int32_t>(o.c0 * kTile);
    const int32_t y = static_cast<int32_t>(o.r0 * kTile);
    const int32_t x1 =
      std::min(static_cast<int32_t>(o.c1 * kTile), static_cast<int32_t>(width_));
    const int32_t y1 =
      std::min(static_cast<int32_t>(r1 * kTile), static_cast<int32_t>(height_));
    if (x1 > x && y1 > y) out.push_back({x, y, x1 - x, y1 - y});
  };
  for (uint32_t r = 0; r <= rows_; ++r) {
    next.clear();
    for (auto &o : open) o.extended = false;
    if (r < rows_) {
      const uint8_t *row = pending_.data() + static_cast<size_t>(r) * cols_;
      uint32_t c = 0;
      while (c < cols_) {
        if (!row[c]) {
          ++c;
          continue;
        }
        const uint32_t c0 = c;
        while (c < cols_ && row[c]) ++c;
        bool merged = false;
        for (auto &o : open) {
          if (!o.extended && o.c0 == c0 && o.c1 == c) {
            o.extended = merged = true;
            next.push_back(o);
            break;
          }
        }
        if (!merged) next.push_back({c0, c, r, true});
      }
    }
    for (const auto &o : open) {
      if (!o.extended) emit(o, r);
    }
    open.swap(next);
  }
  std::fill(pending_.begin(), pending_.end(), 0);
  return true;
}

} // namespace canvas
