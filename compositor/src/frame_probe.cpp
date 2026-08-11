#include "frame_probe.hpp"

#include <chrono>
#include <cstdio>
#include <string>
#include <cstdlib>
#include <map>

#include "wlr.hpp"

namespace lava {
namespace {

constexpr auto kInterval = std::chrono::seconds(2);

struct Span {
  uint64_t count = 0;
  int64_t total = 0;
  int64_t worst = 0;

  void add(int64_t us) {
    ++count;
    total += us;
    if (us > worst) worst = us;
  }
  double mean() const { return count == 0 ? 0.0 : double(total) / double(count) / 1000.0; }
  double max() const { return double(worst) / 1000.0; }
};

struct Surface {
  Span stage[static_cast<size_t>(FrameProbe::Stage::Count)];
  Span gap;
  uint64_t frames = 0;
  uint64_t inputs = 0;
  uint64_t idled = 0;
  int64_t lastFrameAt = 0;
};

/// Above this, a gap is a surface that had nothing to draw rather than a
/// surface that was late, and averaging the two together answers neither
/// question — a single idle second buries sixty real frames. Counted
/// separately as `idle` so the report still says a quiet spell happened.
constexpr int64_t kIdleGapUs = 250'000;

/// Ordered, so the report reads in surface order rather than in whatever order
/// a hash table happens to hold. There are a handful of surfaces.
std::map<uint32_t, Surface> &surfaces() {
  static std::map<uint32_t, Surface> map;
  return map;
}

std::chrono::steady_clock::time_point &lastReport() {
  static auto when = std::chrono::steady_clock::now();
  return when;
}

const char *kStageName[] = {"arena", "render", "scene", "redraw"};

}  // namespace

bool FrameProbe::on() {
  static const bool enabled = std::getenv("LAVA_FRAME_PROBE") != nullptr;
  return enabled;
}

int64_t FrameProbe::now() {
  return std::chrono::duration_cast<std::chrono::microseconds>(
             std::chrono::steady_clock::now().time_since_epoch())
      .count();
}

void FrameProbe::record(uint32_t surfaceId, Stage stage, int64_t startedAt) {
  if (!on()) return;
  surfaces()[surfaceId].stage[static_cast<size_t>(stage)].add(now() - startedAt);
}

void FrameProbe::frame(uint32_t surfaceId) {
  if (!on()) return;
  Surface &surface = surfaces()[surfaceId];
  const int64_t at = now();
  // The first frame after a quiet spell has no meaningful gap — nothing was
  // owed one — so only consecutive frames are counted.
  if (surface.lastFrameAt != 0) {
    const int64_t gap = at - surface.lastFrameAt;
    if (gap > kIdleGapUs) {
      ++surface.idled;
    } else {
      surface.gap.add(gap);
    }
  }
  surface.lastFrameAt = at;
  ++surface.frames;
}

void FrameProbe::input(uint32_t surfaceId) {
  if (!on()) return;
  ++surfaces()[surfaceId].inputs;
}

void FrameProbe::forget(uint32_t surfaceId) {
  if (!on()) return;
  surfaces().erase(surfaceId);
}

void FrameProbe::report() {
  if (!on()) return;
  const auto at = std::chrono::steady_clock::now();
  if (at - lastReport() < kInterval) return;
  const double seconds =
      std::chrono::duration<double>(at - lastReport()).count();
  lastReport() = at;

  for (auto &[id, surface] : surfaces()) {
    // Anything at all, not just frames: a surface whose stages ran but whose
    // frames were counted elsewhere is exactly the surface worth looking at,
    // and skipping it is how a client's render cost goes missing entirely.
    bool worked = surface.frames != 0 || surface.inputs != 0;
    for (size_t i = 0; !worked && i < static_cast<size_t>(Stage::Count); ++i) {
      worked = surface.stage[i].count != 0;
    }
    if (!worked) continue;

    // Frames and the gaps between them first, because that is the stutter
    // itself; the stages below are where it came from.
    std::string line;
    char buffer[256];
    std::snprintf(buffer, sizeof(buffer), "frame probe surface %u: %.1f fps",
                  id, double(surface.frames) / seconds);
    line = buffer;
    // Only when there were gaps to average. A surface that draws once a second
    // has every gap counted as idle, and printing the empty average as
    // "gap mean 0.0 max 0.0" reads like a stall rather than like a clock.
    if (surface.gap.count > 0) {
      std::snprintf(buffer, sizeof(buffer), ", gap mean %.1f max %.1f ms",
                    surface.gap.mean(), surface.gap.max());
      line += buffer;
    }

    for (size_t i = 0; i < static_cast<size_t>(Stage::Count); ++i) {
      const Span &span = surface.stage[i];
      if (span.count == 0) continue;
      std::snprintf(buffer, sizeof(buffer), ", %s %llu x mean %.2f max %.2f",
                    kStageName[i], static_cast<unsigned long long>(span.count),
                    span.mean(), span.max());
      line += buffer;
    }
    if (surface.inputs > 0) {
      std::snprintf(buffer, sizeof(buffer), ", %llu input",
                    static_cast<unsigned long long>(surface.inputs));
      line += buffer;
    }
    if (surface.idled > 0) {
      std::snprintf(buffer, sizeof(buffer), ", %llu idle",
                    static_cast<unsigned long long>(surface.idled));
      line += buffer;
    }
    wlr_log(WLR_INFO, "%s", line.c_str());

    const int64_t lastFrameAt = surface.lastFrameAt;
    surface = Surface{};
    surface.lastFrameAt = lastFrameAt;
  }
}

}  // namespace lava
