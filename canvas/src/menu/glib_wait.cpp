#include "menu/glib_wait.hpp"

#if defined(CANVAS_HAVE_DBUSMENU)
#include <glib.h>

#include <vector>
#endif

namespace canvas {

#if defined(CANVAS_HAVE_DBUSMENU)

bool waitForGLibEvents(int64_t timeoutMs)
{
  GMainContext *ctx = g_main_context_default();
  // The owner only holds it for the length of one non-blocking iteration,
  // so this is a short wait for a frame loop to finish dispatching.
  while (!g_main_context_acquire(ctx)) g_usleep(1000);

  gint priority = 0;
  if (g_main_context_prepare(ctx, &priority)) {
    // Already ready. Still finish the cycle: check is what acknowledges the
    // context's wakeup fd, and skipping it would leave that fd readable.
    g_main_context_check(ctx, priority, nullptr, 0);
    g_main_context_release(ctx);
    return true;
  }

  static thread_local std::vector<GPollFD> fds(16);
  gint timeout = -1;
  gint count;
  while ((count = g_main_context_query(ctx, priority, &timeout, fds.data(),
                                       static_cast<gint>(fds.size()))) >
         static_cast<gint>(fds.size())) {
    fds.resize(static_cast<size_t>(count));
  }
  if (timeoutMs >= 0 && (timeout < 0 || timeoutMs < timeout)) {
    timeout = static_cast<gint>(timeoutMs);
  }

  const bool immediate = timeout == 0;
  g_main_context_get_poll_func(ctx)(fds.data(), static_cast<guint>(count),
                                    timeout);
  g_main_context_check(ctx, priority, fds.data(), count);
  g_main_context_release(ctx);
  return immediate;
}

void wakeGLibWaiter() { g_main_context_wakeup(nullptr); }

#else

bool waitForGLibEvents(int64_t) { return true; }
void wakeGLibWaiter() {}

#endif

} // namespace canvas
