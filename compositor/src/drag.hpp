#pragma once

#include "wlr.hpp"

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

struct wl_display;
struct wlr_drag;
struct wlr_seat;
struct wlr_seat_client;

namespace lava {

/// Longest `text/uri-list` a compositor-sourced drag will offer.
///
/// Under a pipe's default capacity on purpose. The list is written into the
/// receiver's pipe from the event loop in one go, and a write that fits is a
/// write that cannot block — a receiver that never reads cannot then stall
/// the compositor. A few hundred paths fit. A bigger selection is refused
/// rather than truncated: dropping some of the files is worse than none.
inline constexpr size_t kMaxDragUriListBytes = 60 * 1024;

/// A `wlr_seat_client` that is not a Wayland client.
///
/// `wlr_drag_create` needs one — it reads `seat_client->seat` — and a Lava
/// app has none, because it is not a Wayland client. Filled in once, lives
/// as long as the compositor: the drag listens for this object's destroy
/// signal, so freeing it while a drag is live would cancel the drag.
void init_drag_seat_client(wlr_seat *seat, wlr_seat_client *out);

/// Starts a pointer drag offering `paths` as `text/uri-list`.
///
/// The compositor is the source. Null if there is nothing to offer, the list
/// is too long, a drag is already running, or the seat cannot take one. The
/// returned drag is owned by the seat; do not free it.
///
/// `button` is the Linux code of the button being held (`BTN_LEFT` is
/// 0x110). A press on a Lava surface never reaches the seat, so wlroots does
/// not know one is down — and its drag grab drops only on the release of the
/// button it believes started the drag. Told nothing, it would end every
/// drag as a cancel and no Wayland client would ever receive a drop.
wlr_drag *start_file_drag(wlr_seat *seat, wl_display *display,
                          wlr_seat_client *client, uint32_t button,
                          uint32_t timeMsec,
                          const std::vector<std::string> &paths);

}  // namespace lava
