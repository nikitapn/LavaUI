#pragma once

// The one place wlroots' C headers enter this C++ program.
//
// Two things have to be got right before any of them will compile, and both
// are easier to fix once here than at every use site.

// 1. Every wlroots header opens with `#error` unless this is defined. The name
//    is a promise about API stability between releases, not about maturity —
//    there is no "stable" subset to opt into instead. Also set in meson.build
//    so the flag survives anyone including these headers another way.
#ifndef WLR_USE_UNSTABLE
#define WLR_USE_UNSTABLE
#endif

extern "C" {

#include <wayland-server-core.h>

#include <wlr/backend.h>
#include <wlr/render/allocator.h>
#include <wlr/render/wlr_renderer.h>
#include <wlr/types/wlr_compositor.h>
#include <wlr/types/wlr_cursor.h>
#include <wlr/types/wlr_data_device.h>
#include <wlr/types/wlr_input_device.h>
#include <wlr/types/wlr_keyboard.h>
#include <wlr/types/wlr_output.h>
#include <wlr/types/wlr_output_layout.h>
#include <wlr/types/wlr_pointer.h>
#include <wlr/types/wlr_seat.h>
#include <wlr/types/wlr_subcompositor.h>
#include <wlr/types/wlr_xcursor_manager.h>
#include <wlr/types/wlr_xdg_shell.h>
#include <wlr/util/log.h>

#include <xkbcommon/xkbcommon.h>

// 2. `wlr_scene.h` declares two functions with C99 array parameters —
//    `const float color[static 4]` — which is a syntax error in C++, so the
//    header cannot be parsed at all. Not "the two functions are unavailable":
//    nothing in the file compiles, including the scene types every compositor
//    is built on.
//
//    Neutralising the keyword for the span of this one include turns those
//    into plain `[4]`, which means the same thing to a caller. It is safe here
//    for a reason worth checking rather than assuming: `static` appears in
//    wlr_scene.h *only* on those two lines, so nothing else changes meaning.
//    Its own includes are pulled in first, outside the window, because those
//    do contain `static inline` definitions that must keep their storage
//    class.
//
//    Re-check with `grep -n static wlr_scene.h` after a wlroots upgrade. If a
//    `static inline` ever lands in that header, this stops being safe and the
//    fix becomes a patched private copy of the header instead.
#include <pixman.h>
#include <time.h>
#include <wlr/types/wlr_damage_ring.h>
#include <wlr/types/wlr_linux_dmabuf_v1.h>
#include <wlr/util/addon.h>
#include <wlr/util/box.h>

#define static
#include <wlr/types/wlr_scene.h>
#undef static

}  // extern "C"
