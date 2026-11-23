#pragma once

// Tracy for the canvas engine: CPU zones through Tracy.hpp's own macros, and
// a GPU timeline per window through TracyVulkan.
//
// Everything here is empty unless the build defined TRACY_ENABLE
// (`LAVA_TRACY=1 swift build`, `meson -Dtracy=on`), and only then are
// Tracy's own headers — a submodule — needed at all. The client itself lives
// in CTracy (`trace/lava_trace.cpp`), once per process, whichever of Swift
// and C++ got there first.
//
// One GPU context per RenderWindow rather than per device: a context belongs
// to the queue it calibrated against, and windows lease queues of their own.
// It also gives every window its own GPU track in the profiler, named after
// the window, which is the view you want with a compositor of thirty
// surfaces. Each context owns a query pool of Tracy's default size —
// 64k timestamps, 512 KiB — which is a profiling build's cost to pay.

#include <cstdint>
#include <mutex>
#include <string>

#include <vulkan/vulkan.h>

#include "util/tracy.hpp"
#ifdef TRACY_ENABLE
#include "tracy/TracyVulkan.hpp"
#endif

class RenderDevice;

namespace canvas {

class GpuTrace {
 public:
  GpuTrace() = default;
  GpuTrace(const GpuTrace &) = delete;
  GpuTrace &operator=(const GpuTrace &) = delete;
  ~GpuTrace() { destroy(); }

  /// Calibrates against `queue`, which it submits to and idles once — so
  /// only at window creation, never inside a frame. `pool` lends a command
  /// buffer for that and gets it back.
  void create(RenderDevice &device, VkQueue queue, std::mutex &queueMutex,
              VkCommandPool pool, const std::string &name);
  void destroy();

  /// Reads back finished timestamps and resets their queries. Recorded
  /// outside any render pass, before this frame's first zone.
  void collect(VkCommandBuffer cmd);

#ifdef TRACY_ENABLE
  tracy::VkCtx *context() const { return ctx_; }

 private:
  tracy::VkCtx *ctx_ = nullptr;
#endif
};

} // namespace canvas

#ifdef TRACY_ENABLE
/// A GPU zone from here to the end of the enclosing scope, timed by the
/// commands recorded into `cmd` in between.
#define CANVAS_GPU_ZONE(trace, cmd, name)                                  \
  TracyVkNamedZone((trace).context(), TracyConcat(canvasGpuZone, TracyLine), \
                   cmd, name, (trace).context() != nullptr)
#else
#define CANVAS_GPU_ZONE(trace, cmd, name)
#endif
