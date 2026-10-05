#include "game_probe.hpp"

#include <chrono>
#include <cinttypes>
#include <cmath>
#include <cstdlib>
#include <deque>

#include "wlr.hpp"

namespace lava {
namespace {

constexpr auto kInterval = std::chrono::seconds(2);

int64_t nowUs() {
  timespec ts{};
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return int64_t(ts.tv_sec) * 1'000'000 + ts.tv_nsec / 1000;
}

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

/// Refreshes a frame stayed on screen: 1, 2, 3, 4, and 5 or more.
constexpr int kBuckets = 5;

struct Window {
  Span bufferGap;          // between applied buffer commits
  Span materialise;        // request → applied, buffer commits only
  Span flipLatency;        // output commit → present, new frames only
  Span gpuAfterApply;      // applied → acquire point signalled
  uint64_t gpuBehind = 0;
  uint64_t bufferCommits = 0;
  uint64_t bufferless = 0;
  uint64_t shown = 0;
  uint64_t replacedUnseen = 0;
  uint64_t scanout = 0;
  uint64_t composited = 0;
  uint64_t gpuUnfinished = 0;
  uint64_t notPresented = 0;
  uint64_t onScreen[kBuckets] = {};
  unsigned onScreenWorst = 0;
  uint64_t outputFrames = 0;
  uint64_t fenced = 0;
  uint64_t forcedComposite = 0;
};

struct State {
  const void *surface = nullptr;
  Window window;
  /// Request times of buffer commits not applied yet. Commits apply in the
  /// order they were sent, so the front is always the next one to land.
  std::deque<int64_t> requested;
  int64_t lastBufferAt = 0;
  /// Buffer commits applied, and how far the screen has caught up with them.
  uint64_t appliedSeq = 0;
  uint64_t shownSeq = 0;
  /// The flip carrying a new frame, waiting for its present event. The DRM
  /// backend has one flip in flight, so one slot is the whole queue.
  bool pending = false;
  uint32_t pendingCommitSeq = 0;
  int64_t pendingAt = 0;
  /// The last new frame that turned into light.
  bool havePrev = false;
  int64_t prevWhen = 0;
  unsigned prevSeq = 0;
  std::chrono::steady_clock::time_point lastReport =
      std::chrono::steady_clock::now();
};

State &state() {
  static State s;
  return s;
}

void restart(const void *surface) {
  State &s = state();
  const auto lastReport = s.lastReport;
  s = State{};
  s.surface = surface;
  s.lastReport = lastReport;
}

}  // namespace

bool GameProbe::on() {
  static const bool enabled = std::getenv("LAVA_SCANOUT_PROBE") != nullptr;
  return enabled;
}

void GameProbe::covering(const void *surface, bool fenced, bool composited) {
  if (!on()) return;
  State &s = state();
  if (surface == nullptr) return;
  if (surface != s.surface) restart(surface);
  ++s.window.outputFrames;
  if (fenced) ++s.window.fenced;
  if (composited) ++s.window.forcedComposite;
}

bool GameProbe::watching(const void *surface) {
  return on() && surface != nullptr && state().surface == surface;
}

void GameProbe::clientCommit(const void *surface, bool attachesBuffer) {
  if (!watching(surface) || !attachesBuffer) return;
  State &s = state();
  // A client that never gets its commits applied would grow this forever;
  // nothing real queues more than a handful.
  if (s.requested.size() >= 64) s.requested.pop_front();
  s.requested.push_back(nowUs());
}

void GameProbe::applied(const void *surface, bool attachesBuffer) {
  if (!watching(surface)) return;
  State &s = state();
  if (!attachesBuffer) {
    ++s.window.bufferless;
    return;
  }
  const int64_t now = nowUs();
  ++s.window.bufferCommits;
  ++s.appliedSeq;
  if (s.lastBufferAt != 0) s.window.bufferGap.add(now - s.lastBufferAt);
  s.lastBufferAt = now;
  if (!s.requested.empty()) {
    s.window.materialise.add(now - s.requested.front());
    s.requested.pop_front();
  }
}

void GameProbe::gpuSignalled(const void *surface, int64_t us) {
  if (!watching(surface)) return;
  state().window.gpuAfterApply.add(us);
}

void GameProbe::gpuBehind(const void *surface) {
  if (!watching(surface)) return;
  ++state().window.gpuBehind;
}

void GameProbe::outputCommit(uint32_t commitSeq, bool scanout, bool gpuDone) {
  if (!on() || state().surface == nullptr) return;
  State &s = state();
  if (s.appliedSeq == s.shownSeq) return;  // the same frame again — a cursor
  ++s.window.shown;
  s.window.replacedUnseen += s.appliedSeq - s.shownSeq - 1;
  s.shownSeq = s.appliedSeq;
  (scanout ? s.window.scanout : s.window.composited) += 1;
  if (!gpuDone) ++s.window.gpuUnfinished;
  s.pending = true;
  s.pendingCommitSeq = commitSeq;
  s.pendingAt = nowUs();
}

void GameProbe::present(uint32_t commitSeq, bool presented, int64_t whenUs,
                        unsigned vblankSeq, int refreshNs) {
  if (!on()) return;
  State &s = state();
  if (!s.pending || commitSeq != s.pendingCommitSeq) return;
  s.pending = false;
  if (!presented) {
    ++s.window.notPresented;
    return;
  }
  s.window.flipLatency.add(whenUs - s.pendingAt);
  if (s.havePrev) {
    // The vblank counter when the backend has one, the clock otherwise.
    int64_t refreshes = 0;
    if (vblankSeq != 0 && s.prevSeq != 0) {
      refreshes = int64_t(vblankSeq - s.prevSeq);
    } else if (refreshNs > 0) {
      refreshes = std::llround(double(whenUs - s.prevWhen) * 1000.0 /
                               double(refreshNs));
    }
    if (refreshes > 0) {
      const int bucket = refreshes >= kBuckets ? kBuckets - 1 : int(refreshes) - 1;
      ++s.window.onScreen[bucket];
      if (unsigned(refreshes) > s.window.onScreenWorst) {
        s.window.onScreenWorst = unsigned(refreshes);
      }
    }
  }
  s.havePrev = true;
  s.prevWhen = whenUs;
  s.prevSeq = vblankSeq;
}

void GameProbe::forget(const void *surface) {
  if (!on() || surface == nullptr || state().surface != surface) return;
  restart(nullptr);
}

void GameProbe::report() {
  if (!on()) return;
  State &s = state();
  const auto now = std::chrono::steady_clock::now();
  if (now - s.lastReport < kInterval) return;
  const double seconds =
      std::chrono::duration<double>(now - s.lastReport).count();
  s.lastReport = now;
  Window w = s.window;
  s.window = Window{};
  if (s.surface == nullptr || w.outputFrames == 0) return;

  wlr_log(WLR_INFO,
          "game probe: %.1f buffer commits/s (gap mean %.1f max %.1f ms), "
          "%" PRIu64 " bufferless; held for its point mean %.2f max %.2f ms; "
          "GPU done after apply mean %.1f max %.1f ms (%" PRIu64
          " arrived before the previous frame's GPU work finished)",
          double(w.bufferCommits) / seconds, w.bufferGap.mean(),
          w.bufferGap.max(), w.bufferless, w.materialise.mean(),
          w.materialise.max(), w.gpuAfterApply.mean(), w.gpuAfterApply.max(),
          w.gpuBehind);
  wlr_log(WLR_INFO,
          "game probe: shown %" PRIu64 " (scanout %" PRIu64 ", composited %"
          PRIu64 "), replaced unseen %" PRIu64 ", not presented %" PRIu64
          ", flipped before its GPU work signalled %" PRIu64
          "; commit to light mean %.1f max %.1f ms",
          w.shown, w.scanout, w.composited, w.replacedUnseen, w.notPresented,
          w.gpuUnfinished, w.flipLatency.mean(), w.flipLatency.max());
  wlr_log(WLR_INFO,
          "game probe: on screen for 1:%" PRIu64 " 2:%" PRIu64 " 3:%" PRIu64
          " 4:%" PRIu64 " 5+:%" PRIu64 " refreshes (worst %u); fenced on %"
          PRIu64 " of %" PRIu64 " output frames, composite forced on %" PRIu64,
          w.onScreen[0], w.onScreen[1], w.onScreen[2], w.onScreen[3],
          w.onScreen[4], w.onScreenWorst, w.fenced, w.outputFrames,
          w.forcedComposite);
}

}  // namespace lava
