#include "clipboard.hpp"

#include "wlr.hpp"

#include <fcntl.h>
#include <poll.h>
#include <unistd.h>

#include <cerrno>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <string>

namespace lava {
namespace {

/// What a text selection is called, in the order a taker should prefer.
///
/// The first is what every modern Wayland client uses. The rest are what X11
/// clients ask for through Xwayland, and offering them is the difference
/// between a copy that pastes into an xterm and one that does not.
constexpr const char *kTextMimeTypes[] = {
    "text/plain;charset=utf-8",
    "text/plain",
    "UTF8_STRING",
    "STRING",
    "TEXT",
};

/// What a PNG selection is called. The first is what every modern Wayland
/// client asks for; the second is the spelling some X11 clients still use
/// through Xwayland.
constexpr const char *kPngMimeTypes[] = {
    "image/png",
    "image/x-png",
};

/// How long a paste waits for whoever owns the selection.
///
/// The owner is another process, and asking it for the data means writing a
/// request down its Wayland connection and waiting for it to write back. It
/// may be busy, stopped in a debugger, or gone without the compositor having
/// noticed yet — and this call runs on the compositor's event loop, so an
/// unbounded wait is a frozen desktop. A quarter of a second is far longer
/// than a healthy client needs and short enough that a sick one costs a
/// dropped paste rather than a session.
constexpr auto kReadTimeout = std::chrono::milliseconds(250);

/// The loop to hand a slow write to.
///
/// A `wlr_data_source_impl` callback is a plain function pointer with no user
/// data of its own beyond the source, and the loop is the one thing `send`
/// cannot derive from what it is given. One compositor, one loop, so a file
/// static is the honest shape rather than a shortcut.
wl_event_loop *g_loop = nullptr;

/// A selection owned by this compositor on a client's behalf.
///
/// `wlr_data_source` is a base with an impl table; this is the derived thing,
/// recovered from the base pointer the way wlroots' own sources are. Its
/// lifetime belongs to the seat — `wlr_seat_set_selection` takes it and
/// destroys it when the selection is replaced or the seat goes away — which is
/// why nothing here keeps a second pointer to it.
struct TextSource {
  wlr_data_source base{};
  std::string text;
};

/// One in-flight answer to a `send`: the bytes still to write, and where.
///
/// Writing straight through in `send` would be simpler and is wrong: a pipe
/// holds 64 KiB, the taker may not be reading yet, and a blocking write of a
/// larger selection stops the compositor until it is. So the fd joins the
/// event loop and the copy proceeds as the reader drains it.
struct PendingWrite {
  std::string bytes;
  size_t offset = 0;
  wl_event_source *source = nullptr;
};

void finish(PendingWrite *pending, int fd) {
  if (pending->source != nullptr) wl_event_source_remove(pending->source);
  close(fd);
  delete pending;
}

int on_writable(int fd, uint32_t mask, void *data) {
  auto *pending = static_cast<PendingWrite *>(data);

  if (mask & (WL_EVENT_HANGUP | WL_EVENT_ERROR)) {
    // The taker closed its end: it has what it wanted, or has given up.
    finish(pending, fd);
    return 0;
  }

  while (pending->offset < pending->bytes.size()) {
    const ssize_t written = write(fd, pending->bytes.data() + pending->offset,
                                  pending->bytes.size() - pending->offset);
    if (written > 0) {
      pending->offset += static_cast<size_t>(written);
      continue;
    }
    if (written < 0 && errno == EINTR) continue;
    if (written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
      return 0; // The pipe is full; the loop will call back.
    }
    break; // EPIPE, or anything else: the taker is gone.
  }

  finish(pending, fd);
  return 0;
}

/// Hands `text` to `fd` without waiting for whoever is reading it.
void writeAsync(const std::string &text, int fd) {
  // Non-blocking, because the writer is allowed to find the pipe full and
  // come back to it.
  const int flags = fcntl(fd, F_GETFL, 0);
  if (flags != -1) fcntl(fd, F_SETFL, flags | O_NONBLOCK);

  auto *pending = new PendingWrite{text, 0, nullptr};
  if (g_loop != nullptr) {
    pending->source =
        wl_event_loop_add_fd(g_loop, fd, WL_EVENT_WRITABLE, on_writable, pending);
  }
  // Then try immediately: the common case is a short selection into an empty
  // pipe, which finishes here and never troubles the loop again.
  on_writable(fd, 0, pending);
}

void source_send(wlr_data_source *source, const char *mime_type, int32_t fd) {
  (void)mime_type; // Every type this offers is the same bytes.
  writeAsync(reinterpret_cast<TextSource *>(source)->text, fd);
}

void source_accept(wlr_data_source *, uint32_t, const char *) {}

void source_destroy(wlr_data_source *source) {
  // Only the derived part. wlroots frees the mime type strings and releases
  // the array itself before calling this — which is why they are strdup'd
  // into it rather than pointed at the constants above.
  delete reinterpret_cast<TextSource *>(source);
}

constexpr wlr_data_source_impl kTextSourceImpl = {
    .send = source_send,
    .accept = source_accept,
    .destroy = source_destroy,
    .dnd_drop = nullptr,
    .dnd_finish = nullptr,
    .dnd_action = nullptr,
};

/// Same shape as `TextSource`, holding a PNG instead of a string. A
/// separate impl table is what lets `get` tell "this is ours and it is
/// text" from "this is ours and it is a picture" — pasting text from a
/// screenshot should be empty, not a hang on a pipe that will never write
/// characters.
struct ImageSource {
  wlr_data_source base{};
  std::string png;
};

void image_send(wlr_data_source *source, const char *mime_type, int32_t fd) {
  (void)mime_type;
  writeAsync(reinterpret_cast<ImageSource *>(source)->png, fd);
}

void image_destroy(wlr_data_source *source) {
  delete reinterpret_cast<ImageSource *>(source);
}

constexpr wlr_data_source_impl kImageSourceImpl = {
    .send = image_send,
    .accept = source_accept,
    .destroy = image_destroy,
    .dnd_drop = nullptr,
    .dnd_finish = nullptr,
    .dnd_action = nullptr,
};

/// The same thing again for the primary selection, which is a separate
/// protocol with a separate source type — same fields, two callbacks instead
/// of six, and no way to express "these are the same" that is shorter than
/// saying it twice.
struct PrimaryTextSource {
  wlr_primary_selection_source base{};
  std::string text;
};

void primary_send(wlr_primary_selection_source *source, const char *mime_type,
                  int fd) {
  (void)mime_type;
  writeAsync(reinterpret_cast<PrimaryTextSource *>(source)->text, fd);
}

void primary_destroy(wlr_primary_selection_source *source) {
  delete reinterpret_cast<PrimaryTextSource *>(source);
}

constexpr wlr_primary_selection_source_impl kPrimarySourceImpl = {
    .send = primary_send,
    .destroy = primary_destroy,
};

/// Whether a source is one of ours — which is what lets a read answer from
/// memory instead of asking a pipe a question only this thread could answer.
bool isOurText(const wlr_data_source *source) {
  return source != nullptr && source->impl == &kTextSourceImpl;
}
bool isOurImage(const wlr_data_source *source) {
  return source != nullptr && source->impl == &kImageSourceImpl;
}
bool isOurs(const wlr_data_source *source) {
  return isOurText(source) || isOurImage(source);
}
bool isOurs(const wlr_primary_selection_source *source) {
  return source != nullptr && source->impl == &kPrimarySourceImpl;
}

/// First match of `wanted` in `mime_types`, or nullptr.
const char *findMime(const wl_array &mime_types,
                     const char *const *wanted, size_t nWanted) {
  const auto *offered = static_cast<const char *const *>(mime_types.data);
  const size_t count = mime_types.size / sizeof(char *);
  for (size_t w = 0; w < nWanted; ++w) {
    for (size_t i = 0; i < count; ++i) {
      if (offered[i] != nullptr && std::strcmp(offered[i], wanted[w]) == 0) {
        return offered[i];
      }
    }
  }
  return nullptr;
}

/// The first MIME type this array offers that we understand, or nullptr.
///
/// Iterated by hand rather than with `wl_array_for_each`, whose first
/// statement assigns `void *` to a typed pointer — legal C, and not C++.
const char *preferredMime(const wl_array &mime_types) {
  return findMime(mime_types, kTextMimeTypes,
                  sizeof(kTextMimeTypes) / sizeof(kTextMimeTypes[0]));
}

/// A screenshot is a few megabytes; past that the client is not a crop.
constexpr size_t kMaxPersistBytes = 32 * 1024 * 1024;

/// In-flight copy of a client selection into one of ours.
///
/// The source process is allowed to exit the moment it has called
/// `set_selection`. We have to pull the bytes off the pipe it will write
/// before that, without blocking the compositor's loop on the write.
struct PersistRead {
  wl_display *display = nullptr;
  wlr_seat *seat = nullptr;
  uint32_t generation = 0;
  bool wantPng = false;
  std::string bytes;
  wl_event_source *event = nullptr;
  int fd = -1;
};

uint32_t g_persistGen = 0;
PersistRead *g_persist = nullptr;

void finishPersist(PersistRead *pending, bool install);

int on_persist_readable(int fd, uint32_t mask, void *data) {
  auto *pending = static_cast<PersistRead *>(data);
  if (mask & (WL_EVENT_HANGUP | WL_EVENT_ERROR)) {
    // Drain whatever arrived with the hangup, then settle.
    char buffer[4096];
    for (;;) {
      const ssize_t got = read(fd, buffer, sizeof(buffer));
      if (got > 0) {
        if (pending->bytes.size() + static_cast<size_t>(got) > kMaxPersistBytes) {
          finishPersist(pending, false);
          return 0;
        }
        pending->bytes.append(buffer, static_cast<size_t>(got));
        continue;
      }
      break;
    }
    finishPersist(pending, true);
    return 0;
  }

  char buffer[4096];
  for (;;) {
    const ssize_t got = read(fd, buffer, sizeof(buffer));
    if (got > 0) {
      if (pending->bytes.size() + static_cast<size_t>(got) > kMaxPersistBytes) {
        finishPersist(pending, false);
        return 0;
      }
      pending->bytes.append(buffer, static_cast<size_t>(got));
      continue;
    }
    if (got < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return 0;
    finishPersist(pending, got == 0);
    return 0;
  }
}

void abortPersist() {
  ++g_persistGen;
  if (g_persist == nullptr) return;
  PersistRead *pending = g_persist;
  g_persist = nullptr;
  if (pending->event != nullptr) wl_event_source_remove(pending->event);
  if (pending->fd >= 0) close(pending->fd);
  delete pending;
}

void finishPersist(PersistRead *pending, bool install) {
  const uint32_t generation = pending->generation;
  const bool wantPng = pending->wantPng;
  std::string bytes = std::move(pending->bytes);
  wl_display *display = pending->display;
  wlr_seat *seat = pending->seat;

  if (g_persist == pending) g_persist = nullptr;
  if (pending->event != nullptr) wl_event_source_remove(pending->event);
  if (pending->fd >= 0) close(pending->fd);
  delete pending;

  if (!install || generation != g_persistGen || bytes.empty()) return;

  Clipboard clipboard(display, seat);
  if (wantPng) {
    std::vector<uint8_t> png(bytes.begin(), bytes.end());
    clipboard.setImagePng(png);
    wlr_log(WLR_INFO, "clipboard: persisted %zu-byte PNG", png.size());
  } else {
    clipboard.set(bytes);
    wlr_log(WLR_INFO, "clipboard: persisted %zu-byte text", bytes.size());
  }
}

/// Fills `mime_types` with every spelling of "this is text".
void offerTextTypes(wl_array &mime_types) {
  for (const char *mime : kTextMimeTypes) {
    auto **slot = static_cast<char **>(wl_array_add(&mime_types, sizeof(char *)));
    if (slot == nullptr) continue;
    *slot = strdup(mime);
  }
}

void offerPngTypes(wl_array &mime_types) {
  for (const char *mime : kPngMimeTypes) {
    auto **slot = static_cast<char **>(wl_array_add(&mime_types, sizeof(char *)));
    if (slot == nullptr) continue;
    *slot = strdup(mime);
  }
}

/// Asks a source for its bytes and waits, briefly, for them.
///
/// `send` is the protocol's own "write this type down this fd" — the two
/// selections spell it differently and mean exactly the same thing.
template <typename Send>
std::string readMime(wl_display *display, const char *mime, Send send) {
  if (mime == nullptr) return {};

  int fds[2];
  if (pipe(fds) != 0) return {};

  send(mime, fds[1]); // takes fds[1] and closes it

  // That request is sitting in the owner's connection buffer until somebody
  // flushes it, and nothing else is going to: this call is occupying the loop
  // that otherwise would.
  wl_display_flush_clients(display);

  std::string out;
  const auto deadline = std::chrono::steady_clock::now() + kReadTimeout;
  for (;;) {
    const auto remaining = std::chrono::duration_cast<std::chrono::milliseconds>(
        deadline - std::chrono::steady_clock::now());
    if (remaining.count() <= 0) break;

    pollfd waiting{fds[0], POLLIN, 0};
    const int ready = poll(&waiting, 1, static_cast<int>(remaining.count()));
    if (ready < 0 && errno == EINTR) continue;
    if (ready <= 0) break; // Timed out, or poll failed.

    char buffer[4096];
    const ssize_t got = read(fds[0], buffer, sizeof(buffer));
    if (got > 0) {
      out.append(buffer, static_cast<size_t>(got));
      continue;
    }
    if (got < 0 && errno == EINTR) continue;
    break; // EOF — the normal ending — or a read error.
  }

  close(fds[0]);
  return out;
}

} // namespace

void Clipboard::set(const std::string &text) {
  g_loop = wl_display_get_event_loop(display_);

  auto *source = new TextSource();
  source->text = text;
  wlr_data_source_init(&source->base, &kTextSourceImpl);
  offerTextTypes(source->base.mime_types);

  // The serial matters to clients deciding whether this selection is newer
  // than what they hold. There is no input event behind a control-plane copy,
  // so the display's next serial is the honest answer: it orders this after
  // everything that has happened so far.
  wlr_seat_set_selection(seat_, &source->base,
                         wl_display_next_serial(display_));
}

void Clipboard::setImagePng(const std::vector<uint8_t> &png) {
  g_loop = wl_display_get_event_loop(display_);

  auto *source = new ImageSource();
  source->png.assign(reinterpret_cast<const char *>(png.data()), png.size());
  wlr_data_source_init(&source->base, &kImageSourceImpl);
  offerPngTypes(source->base.mime_types);

  wlr_seat_set_selection(seat_, &source->base,
                         wl_display_next_serial(display_));
}

std::string Clipboard::get() {
  wlr_data_source *source = seat_->selection_source;
  if (source == nullptr) return {};

  // Ours: the bytes are right here. Going through a pipe would mean waiting
  // on this thread for a write only this thread can perform — the deadlock
  // would not be a risk, it would be a certainty.
  if (isOurText(source)) {
    return reinterpret_cast<TextSource *>(source)->text;
  }

  return readMime(display_, preferredMime(source->mime_types),
                  [source](const char *mime, int fd) {
                    wlr_data_source_send(source, mime, fd);
                  });
}

std::vector<uint8_t> Clipboard::getPng() {
  wlr_data_source *source = seat_->selection_source;
  if (source == nullptr) return {};

  if (isOurImage(source)) {
    const std::string &png = reinterpret_cast<ImageSource *>(source)->png;
    return {png.begin(), png.end()};
  }

  const char *mime = findMime(source->mime_types, kPngMimeTypes,
                              sizeof(kPngMimeTypes) / sizeof(kPngMimeTypes[0]));
  if (mime == nullptr) return {};
  const std::string raw = readMime(
      display_, mime, [source](const char *wanted, int fd) {
        wlr_data_source_send(source, wanted, fd);
      });
  return {raw.begin(), raw.end()};
}

void Clipboard::setPrimary(const std::string &text) {
  g_loop = wl_display_get_event_loop(display_);

  auto *source = new PrimaryTextSource();
  source->text = text;
  wlr_primary_selection_source_init(&source->base, &kPrimarySourceImpl);
  offerTextTypes(source->base.mime_types);

  wlr_seat_set_primary_selection(seat_, &source->base,
                                 wl_display_next_serial(display_));
}

std::string Clipboard::getPrimary() {
  wlr_primary_selection_source *source = seat_->primary_selection_source;
  if (source == nullptr) return {};

  if (isOurs(source)) {
    return reinterpret_cast<PrimaryTextSource *>(source)->text;
  }

  return readMime(display_, preferredMime(source->mime_types),
                  [source](const char *mime, int fd) {
                    wlr_primary_selection_source_send(source, mime, fd);
                  });
}

void Clipboard::persistClientSelection() {
  g_loop = wl_display_get_event_loop(display_);
  abortPersist();

  wlr_data_source *source = seat_->selection_source;
  if (source == nullptr || isOurs(source)) return;

  const char *png = findMime(source->mime_types, kPngMimeTypes,
                             sizeof(kPngMimeTypes) / sizeof(kPngMimeTypes[0]));
  const char *text = preferredMime(source->mime_types);
  const char *mime = png != nullptr ? png : text;
  if (mime == nullptr) return;

  if (g_loop == nullptr) return;

  int fds[2];
  if (pipe(fds) != 0) return;
  const int flags = fcntl(fds[0], F_GETFL, 0);
  if (flags != -1) fcntl(fds[0], F_SETFL, flags | O_NONBLOCK);

  auto *pending = new PersistRead();
  pending->display = display_;
  pending->seat = seat_;
  pending->generation = g_persistGen;
  pending->wantPng = png != nullptr;
  pending->fd = fds[0];
  g_persist = pending;

  // The source owns and closes fds[1].
  wlr_data_source_send(source, mime, fds[1]);
  wl_display_flush_clients(display_);

  if (g_loop != nullptr) {
    pending->event = wl_event_loop_add_fd(
        g_loop, fds[0], WL_EVENT_READABLE | WL_EVENT_HANGUP,
        on_persist_readable, pending);
  }
  // Try once now: a small selection may already be in the pipe.
  on_persist_readable(fds[0], WL_EVENT_READABLE, pending);
}

} // namespace lava
