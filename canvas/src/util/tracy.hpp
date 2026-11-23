#pragma once

// Tracy's CPU macros for the engine and the compositor, or nothing.
//
// Tracy is a submodule (canvas/third-party/tracy) that only a profiling build
// needs, so a normal build must not reach for its headers at all — a clone
// without `--recursive` still builds. Its own Tracy.hpp would expand these to
// nothing without TRACY_ENABLE, but it has to be there to be included; this
// header is always there. Add a macro here before using it anywhere.

#ifdef TRACY_ENABLE
#include "tracy/Tracy.hpp"
#else
#define ZoneScopedN(name)
#define ZoneValue(value)
#define TracyPlot(name, value)
#define FrameMark
#endif
