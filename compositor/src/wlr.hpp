#pragma once

// The one place wlroots' C headers enter this C++ program.
//
// Several things have to be got right before any of them will compile, and
// each is easier to fix once here than at every use site.

// 1. Every wlroots header opens with `#error` unless this is defined. The name
//    is a promise about API stability between releases, not about maturity —
//    there is no "stable" subset to opt into instead. Also set in meson.build
//    so the flag survives anyone including these headers another way.
#ifndef WLR_USE_UNSTABLE
#define WLR_USE_UNSTABLE
#endif

// Pulled in before anything else, and before `extern "C"`, because section 3
// below renames the `class` keyword for the span of one include — and the C
// headers reached from there include these, which are not as C as they look.
// Their include guards are what makes the rename safe; see section 3.
#include <pthread.h>
#include <stdlib.h>

extern "C" {

#include <wayland-server-core.h>

#include <wlr/backend.h>
#include <wlr/backend/session.h>
#include <wlr/render/allocator.h>
#include <wlr/render/swapchain.h>
#include <wlr/render/wlr_renderer.h>
#include <wlr/render/wlr_texture.h>
#include <wlr/types/wlr_compositor.h>
#include <wlr/types/wlr_cursor.h>
#include <wlr/types/wlr_data_control_v1.h>
#include <wlr/types/wlr_data_device.h>
#include <wlr/types/wlr_ext_data_control_v1.h>
#include <wlr/types/wlr_input_device.h>
#include <wlr/types/wlr_keyboard.h>
#include <wlr/types/wlr_output.h>
#include <wlr/types/wlr_output_layout.h>
#include <wlr/types/wlr_pointer.h>
#include <wlr/types/wlr_pointer_constraints_v1.h>
#include <wlr/types/wlr_primary_selection.h>
#include <wlr/types/wlr_primary_selection_v1.h>
#include <wlr/types/wlr_relative_pointer_v1.h>
#include <wlr/types/wlr_seat.h>
#include <wlr/types/wlr_subcompositor.h>
#include <wlr/types/wlr_viewporter.h>
#include <wlr/types/wlr_xcursor_manager.h>
#include <wlr/types/wlr_screencopy_v1.h>
#include <wlr/types/wlr_xdg_decoration_v1.h>
#include <wlr/types/wlr_xdg_output_v1.h>
#include <wlr/types/wlr_xdg_shell.h>
#include <wlr/types/wlr_xdg_activation_v1.h>
#include <wlr/types/wlr_idle_inhibit_v1.h>
#include <wlr/types/wlr_idle_notify_v1.h>
#include <wlr/interfaces/wlr_buffer.h>
#include <wlr/render/drm_format_set.h>
#include <wlr/types/wlr_buffer.h>
#include <wlr/util/edges.h>
#include <wlr/util/log.h>
#include <wlr/util/region.h>

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
#include <wlr/render/drm_syncobj.h>
#include <wlr/types/wlr_damage_ring.h>
#include <wlr/types/wlr_linux_dmabuf_v1.h>
#include <wlr/types/wlr_linux_drm_syncobj_v1.h>
#include <wlr/util/addon.h>
#include <wlr/util/box.h>

#define static
#include <wlr/types/wlr_scene.h>
#undef static

// 3. `wlr/xwayland/xwayland.h` names a field `class`, which a C header may do
//    and a C++ one may not. Same shape of problem as `static` above, same
//    answer: rename the keyword for the span of this one include. Everything
//    wlroots and xcb pull in here is C, so `class` cannot appear as anything
//    but an identifier — but the wlroots headers this needs are included
//    above, outside the window, so the blast radius stays small.
//
//    The field is reached as `xclass` in this program. Re-check with
//    `grep -n '\bclass\b' wlr/xwayland/*.h` after a wlroots upgrade.
//
//    "Everything here is C" is the claim that has to hold, and on its own it
//    does not: `wlr/xwayland.h` reaches `xcb/xcb.h`, which includes
//    `<pthread.h>`, which defines a C++ class — `__pthread_cleanup_class`,
//    glibc's RAII wrapper for cancellation handlers — whenever it is compiled
//    as C++ with exceptions on. Under the macro that line does not parse. The
//    guard block below pulls it in first, outside the window, so nothing but
//    an include guard is left to find in there.
#define class xclass
#include <wlr/xwayland.h>
#undef class

// 4. `wlr/types/wlr_input_method_v2.h` names a field `delete`. Same problem
//    as `class` above and the same answer, with one difference worth stating:
//    `delete` is not merely a keyword here, it is an *operator*, so leaving
//    the rename in force would silently turn every `delete p;` in the program
//    into a call to something that does not exist. The window is therefore as
//    narrow as it can be — one include, nothing else inside it.
//
//    Everything this header reaches (`wlr_seat.h`, `wlr/util/box.h`,
//    `wayland-server-core.h`) is included above, so only its own text is
//    parsed under the rename and there is no C++ in it to break.
//
//    The field is reached as `delete_` in this program. Re-check with
//    `grep -n '\bdelete\b' wlr/types/wlr_input_method_v2.h` after a wlroots
//    upgrade — upstream renaming it would make this unnecessary rather than
//    wrong, and the `delete_` uses would then fail to compile and say so.
#define delete delete_
#include <wlr/types/wlr_input_method_v2.h>
#undef delete

#include <wlr/types/wlr_text_input_v3.h>

}  // extern "C"
