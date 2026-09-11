#include "drag.hpp"

#include "uri_list.hpp"

#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <unistd.h>
#include <wayland-server-core.h>
#include <wayland-server-protocol.h>

namespace lava {
namespace {

struct FileDragSource {
  wlr_data_source base{};
  std::string uriList;
  wl_event_loop *loop = nullptr;
  /// The destroy `dnd_finish` deferred, while it is pending. See there.
  wl_event_source *reap = nullptr;
};

FileDragSource *from_base(wlr_data_source *source) {
  return reinterpret_cast<FileDragSource *>(source);
}

void file_drag_send(wlr_data_source *source, const char *mime_type,
                    int32_t fd) {
  (void)mime_type;
  const std::string &text = from_base(source)->uriList;
  // Non-blocking, so a receiver that handed over something other than a
  // fresh pipe — or never reads — costs a short list rather than a frozen
  // desktop. A fresh pipe takes `kMaxDragUriListBytes` without blocking,
  // which is why the list is capped below that.
  const int flags = fcntl(fd, F_GETFL);
  if (flags >= 0) fcntl(fd, F_SETFL, flags | O_NONBLOCK);
  const char *p = text.data();
  size_t left = text.size();
  while (left > 0) {
    const ssize_t n = write(fd, p, left);
    if (n > 0) {
      p += n;
      left -= static_cast<size_t>(n);
      continue;
    }
    if (n < 0 && errno == EINTR) continue;
    if (left > 0) {
      wlr_log(WLR_ERROR, "drag: receiver took %zu of %zu bytes, gave up",
              text.size() - left, text.size());
    }
    break;
  }
  close(fd);
}

void file_drag_accept(wlr_data_source *, uint32_t, const char *) {}

void file_drag_reap(void *data) {
  auto *source = static_cast<FileDragSource *>(data);
  // An idle source is gone once it has fired; forget it before the destroy
  // below looks for one to remove.
  source->reap = nullptr;
  wlr_data_source_destroy(&source->base);
}

/// The receiver has the files. Nothing is left for this source to do.
///
/// Implemented at all because wlroots treats a source with no `dnd_finish`
/// as one somebody else owns: a cancelled drag and an offer destroyed
/// unfinished both destroy the source *only* when this is set, and a
/// compositor-made source has no client to destroy it otherwise — it would
/// live until the next drag replaced it.
///
/// Deferred to idle rather than done here, because wlroots calls this from
/// inside the offer's own finish handler and goes on to touch the offer
/// afterwards; destroying the source under it is a use-after-free waiting
/// for a listener to be added in the wrong place.
void file_drag_dnd_finish(wlr_data_source *base) {
  FileDragSource *source = from_base(base);
  if (source->reap != nullptr || source->loop == nullptr) return;
  source->reap = wl_event_loop_add_idle(source->loop, file_drag_reap, source);
}

void file_drag_destroy(wlr_data_source *base) {
  FileDragSource *source = from_base(base);
  if (source->reap != nullptr) wl_event_source_remove(source->reap);
  delete source;
}

constexpr wlr_data_source_impl kFileDragImpl = {
    .send = file_drag_send,
    .accept = file_drag_accept,
    .destroy = file_drag_destroy,
    .dnd_drop = nullptr,
    .dnd_finish = file_drag_dnd_finish,
    .dnd_action = nullptr,
};

}  // namespace

void init_drag_seat_client(wlr_seat *seat, wlr_seat_client *out) {
  *out = {};
  out->seat = seat;
  wl_list_init(&out->link);
  wl_list_init(&out->resources);
  wl_list_init(&out->pointers);
  wl_list_init(&out->keyboards);
  wl_list_init(&out->touches);
  wl_list_init(&out->data_devices);
  wl_signal_init(&out->events.destroy);
}

wlr_drag *start_file_drag(wlr_seat *seat, wl_display *display,
                          wlr_seat_client *client, uint32_t button,
                          uint32_t timeMsec,
                          const std::vector<std::string> &paths) {
  if (seat == nullptr || display == nullptr || client == nullptr) {
    return nullptr;
  }
  if (seat->drag != nullptr) return nullptr;
  std::string list = uri_list_from_paths(paths);
  if (list.empty()) return nullptr;
  if (list.size() > kMaxDragUriListBytes) {
    wlr_log(WLR_ERROR, "drag: %zu paths make a %zu byte list, refused",
            paths.size(), list.size());
    return nullptr;
  }

  auto *source = new FileDragSource();
  source->uriList = std::move(list);
  source->loop = wl_display_get_event_loop(display);
  wlr_data_source_init(&source->base, &kFileDragImpl);
  char *mime = strdup("text/uri-list");
  auto **slot = static_cast<char **>(
      wl_array_add(&source->base.mime_types, sizeof(char *)));
  if (mime == nullptr || slot == nullptr) {
    std::free(mime);
    wlr_data_source_destroy(&source->base);
    return nullptr;
  }
  *slot = mime;
  // Copy only. A receiving file manager given "move" moves the files out of
  // the folder they were dragged from, and nothing on this side watches the
  // disk yet to notice they went.
  source->base.actions = WL_DATA_DEVICE_MANAGER_DND_ACTION_COPY;

  wlr_drag *drag = wlr_drag_create(client, &source->base, nullptr);
  if (drag == nullptr) {
    wlr_data_source_destroy(&source->base);
    return nullptr;
  }
  // Nobody focused, so telling the seat about the press sends it to no one;
  // what it does do is make the release that ends the drag one it expects.
  wlr_seat_pointer_clear_focus(seat);
  wlr_seat_pointer_notify_button(seat, timeMsec, button,
                                 WL_POINTER_BUTTON_STATE_PRESSED);
  wlr_seat_start_pointer_drag(seat, drag, wl_display_next_serial(display));
  return drag;
}

}  // namespace lava
