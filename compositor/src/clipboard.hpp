#pragma once

#include <cstdint>
#include <string>
#include <vector>

struct wl_display;
struct wlr_seat;

namespace lava {

/// The bridge between the seat's selection and clients that are not Wayland
/// clients.
///
/// A LavaUI client draws through a shared-memory arena and talks over the
/// control plane; it has no `wl_data_device`, so the copy and paste every
/// other application gets for free are two RPC calls here. What those calls
/// must not become is a private string that only Lava apps can see — a
/// clipboard that does not reach Firefox is not a clipboard — so both ends go
/// through `wlr_seat`'s selection, which is the same one every Wayland client
/// reads and writes.
///
/// Text is the everyday case: `text/plain;charset=utf-8` and the four
/// spellings X11 clients ask for through Xwayland, which is what makes a
/// copy here pasteable in an xterm. Print Screen is the other: a PNG
/// offered as `image/png`, so a paste in Firefox or GIMP is the picture
/// rather than a pile of bytes.
class Clipboard {
 public:
  Clipboard(wl_display *display, wlr_seat *seat)
      : display_(display), seat_(seat) {}

  /// Offers `text` as the seat's selection, replacing whatever was there.
  void set(const std::string &text);

  /// Offers a PNG as the seat's selection. Same pipe as text; a different
  /// MIME type is what makes a paste land as an image.
  void setImagePng(const std::vector<uint8_t> &png);

  /// The selection as text, or empty if there is none or it offers nothing
  /// text-shaped.
  ///
  /// Bounded: a source that never writes cannot hang the compositor, it just
  /// yields an empty paste. See `kReadTimeout` in the implementation for what
  /// that costs when the owner is another process.
  std::string get();

  /// Snapshot a client-owned selection into a compositor source.
  ///
  /// Flameshot (and anything that copies then exits) offers the crop on a
  /// source that dies with the process. Nobody asks for the bytes in time,
  /// paste is empty. Called from the seat's `set_selection` signal — after
  /// data-control or `wl_data_device` — and no-op when the source is already
  /// ours. The copy is async; the event loop is not blocked on the client.
  void persistClientSelection();

  /// The *primary* selection — what middle-click pastes.
  ///
  /// A second selection, filled by the act of selecting rather than by a copy
  /// command, and emptied into the pointer's position by the middle button.
  /// Unix has had it since X11 and it is why you can paste something you
  /// copied an hour ago into a line assembled from things you are selecting
  /// now. A separate protocol (`primary-selection-unstable-v1`) with its own
  /// source type, which is why these are two more methods rather than a flag
  /// on the two above.
  void setPrimary(const std::string &text);
  std::string getPrimary();

 private:
  wl_display *display_ = nullptr;
  wlr_seat *seat_ = nullptr;
};

} // namespace lava
