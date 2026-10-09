#pragma once

#include <cstdint>

namespace canvas {

/// Sleeps until the default GLib main context has something to dispatch, or
/// `timeoutMs` passes (negative: no limit of the caller's own; GLib's next
/// timeout still applies). Dispatches nothing — the caller hands that to the
/// thread that owns the work, which iterates the context itself.
///
/// This is what lets a process with D-Bus objects sleep. Iterating GLib
/// without blocking every 20 or 50 ms, which is how both the panel and every
/// app exporting a global menu used to answer the bus, is a wakeup that
/// finds nothing nearly every time.
///
/// The context stays *acquired* for the whole sleep, and that is load-
/// bearing: GLib only signals a context's wakeup fd for a source attached
/// from another thread — a GDBus reply, delivered by its worker — when some
/// other thread owns the context. Polling its fds without owning it would
/// sleep straight through every reply. The flip side is that another thread
/// cannot iterate the context while this one waits; `g_main_context_iteration`
/// there returns at once with nothing done, so all dispatching has to go
/// through the waiter's own hand-off.
///
/// Returns true when it returned without sleeping because something was
/// already pending: a source that is always ready makes every call return
/// at once, and the caller is the one that can throttle that.
bool waitForGLibEvents(int64_t timeoutMs);

/// Ends a `waitForGLibEvents` early, from any thread — for a deadline the
/// waiter was not told about, such as toasts resuming their countdown.
void wakeGLibWaiter();

} // namespace canvas
