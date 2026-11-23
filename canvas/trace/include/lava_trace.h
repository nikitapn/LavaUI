#pragma once

// Tracy, for code that cannot use its C++ macros: Swift, mostly.
//
// The header is always the same and always declares everything, whether
// Tracy is compiled in or not. TracyC.h does the opposite — without
// TRACY_ENABLE its functions are not declared at all and its macros expand to
// nothing — and a macro is not something Swift can call. So these are real
// functions, and in a build without Tracy (`LAVA_TRACY` unset when the
// package was built) they are empty. Swift skips even the call
// unless it was built with the `LAVA_TRACY` condition (see `Trace` in LavaUI).
//
// Names passed as `const char *` to `frame_mark` and `plot` are identified by
// their *address*, not their text, so they must be pointers that stay put —
// a string literal, or a Swift `StaticString`. Zone names are copied.

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 1 when this build has Tracy compiled in.
int lava_trace_compiled(void);

/// An open zone: Tracy's own context, held opaquely. Its size depends on the
/// build — `TRACY_ON_DEMAND` adds the connection the zone began under, and a
/// zone ended under a different one is dropped — so it is carried whole
/// rather than packed into an integer, which lost exactly that field.
typedef struct lava_trace_zone {
  uint64_t opaque[2];
} lava_trace_zone;

/// Opens a zone on the calling thread and returns its handle for
/// `lava_trace_zone_end`. Zones on one thread must close in reverse order.
lava_trace_zone lava_trace_zone_begin(const char *name, size_t nameLength,
                               const char *function, size_t functionLength,
                               const char *file, size_t fileLength,
                               uint32_t line, uint32_t color);
void lava_trace_zone_end(lava_trace_zone zone);
/// Text shown with the zone: which window, which document.
void lava_trace_zone_text(lava_trace_zone zone, const char *text, size_t length);
/// A number shown with the zone: a count of nodes, of commands.
void lava_trace_zone_value(lava_trace_zone zone, uint64_t value);

/// The end of a frame. NULL for the process's main frame; otherwise a named
/// frame set, by address.
void lava_trace_frame_mark(const char *name);
/// One sample of a plot, by address of `name`.
void lava_trace_plot(const char *name, double value);
void lava_trace_message(const char *text, size_t length);
/// Copied.
void lava_trace_thread_name(const char *name);

#ifdef __cplusplus
}
#endif
