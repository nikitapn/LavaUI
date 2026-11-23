// The process's one copy of Tracy's client, and the C entry points over it.
//
// Exactly one translation unit may compile TracyClient.cpp: it owns the
// profiler's globals, its listening thread and its queues, and a second copy
// in the same process is a second profiler fighting the first for the port.
// Swift and the canvas engine both reach this one, so a windowed app has a
// single timeline: body, layout and emit beside the engine's record and
// submit, and the GPU's own passes beside both.
//
// Compiled with TRACY_ENABLE only when the build asked for it — `LAVA_TRACY`
// in the environment of `swift build`, `-Dtracy=` for meson. Otherwise the
// functions below are empty and nothing of Tracy is linked at all: no thread,
// no socket, no port.

#include "lava_trace.h"

#ifdef TRACY_ENABLE

#include <cstring>

#include "TracyClient.cpp"
#include "tracy/TracyC.h"

namespace {

static_assert(sizeof(TracyCZoneCtx) <= sizeof(lava_trace_zone),
              "lava_trace_zone must hold Tracy's whole zone context");

lava_trace_zone pack(TracyCZoneCtx ctx)
{
  lava_trace_zone zone{};
  std::memcpy(&zone, &ctx, sizeof ctx);
  return zone;
}

TracyCZoneCtx unpack(lava_trace_zone zone)
{
  TracyCZoneCtx ctx;
  std::memcpy(&ctx, &zone, sizeof ctx);
  return ctx;
}

} // namespace

extern "C" {

int lava_trace_compiled(void) { return 1; }

lava_trace_zone lava_trace_zone_begin(const char *name, size_t nameLength,
                                      const char *function, size_t functionLength,
                                      const char *file, size_t fileLength,
                                      uint32_t line, uint32_t color)
{
  // An allocated source location rather than a static one: Swift has no
  // static storage a C macro could point into. It is a copy per zone, which
  // costs tens of nanoseconds — right for a frame's stages, wrong for a
  // per-glyph loop.
  const uint64_t srcloc = ___tracy_alloc_srcloc_name(
    line, file, fileLength, function, functionLength, name, nameLength, color);
  return pack(___tracy_emit_zone_begin_alloc(srcloc, 1));
}

void lava_trace_zone_end(lava_trace_zone zone) { ___tracy_emit_zone_end(unpack(zone)); }

void lava_trace_zone_text(lava_trace_zone zone, const char *text, size_t length)
{
  ___tracy_emit_zone_text(unpack(zone), text, length);
}

void lava_trace_zone_value(lava_trace_zone zone, uint64_t value)
{
  ___tracy_emit_zone_value(unpack(zone), value);
}

void lava_trace_frame_mark(const char *name) { ___tracy_emit_frame_mark(name); }

void lava_trace_plot(const char *name, double value) { ___tracy_emit_plot(name, value); }

void lava_trace_message(const char *text, size_t length)
{
  TracyCMessage(text, length);
}

void lava_trace_thread_name(const char *name) { ___tracy_set_thread_name(name); }

} // extern "C"

#else

extern "C" {

int lava_trace_compiled(void) { return 0; }
lava_trace_zone lava_trace_zone_begin(const char *, size_t, const char *, size_t,
                                      const char *, size_t, uint32_t, uint32_t)
{
  return lava_trace_zone{};
}
void lava_trace_zone_end(lava_trace_zone) {}
void lava_trace_zone_text(lava_trace_zone, const char *, size_t) {}
void lava_trace_zone_value(lava_trace_zone, uint64_t) {}
void lava_trace_frame_mark(const char *) {}
void lava_trace_plot(const char *, double) {}
void lava_trace_message(const char *, size_t) {}
void lava_trace_thread_name(const char *) {}

} // extern "C"

#endif
