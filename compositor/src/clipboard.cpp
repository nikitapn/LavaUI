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
bool isOurs(const wlr_data_source *source) {
  return source != nullptr && source->impl == &kTextSourceImpl;
}
bool isOurs(const wlr_primary_selection_source *source) {
  return source != nullptr && source->impl == &kPrimarySourceImpl;
}

/// The first MIME type this array offers that we understand, or nullptr.
///
/// Iterated by hand rather than with `wl_array_for_each`, whose first
/// statement assigns `void *` to a typed pointer — legal C, and not C++.
const char *preferredMime(const wl_array &mime_types) {
  const auto *offered = static_cast<const char *const *>(mime_types.data);
  const size_t count = mime_types.size / sizeof(char *);
  for (const char *wanted : kTextMimeTypes) {
    for (size_t i = 0; i < count; ++i) {
      if (offered[i] != nullptr && std::strcmp(offered[i], wanted) == 0) {
        return offered[i];
      }
    }
  }
  return nullptr;
}

/// Fills `mime_types` with every spelling of "this is text".
void offerTextTypes(wl_array &mime_types) {
  for (const char *mime : kTextMimeTypes) {
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
std::string readSelection(wl_display *display, const wl_array &mime_types,
                          Send send) {
  const char *mime = preferredMime(mime_types);
  if (mime == nullptr) return {}; // An image, a file list: nothing to paste.

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

std::string Clipboard::get() {
  wlr_data_source *source = seat_->selection_source;
  if (source == nullptr) return {};

  // Ours: the bytes are right here. Going through a pipe would mean waiting
  // on this thread for a write only this thread can perform — the deadlock
  // would not be a risk, it would be a certainty.
  if (isOurs(source)) {
    return reinterpret_cast<TextSource *>(source)->text;
  }

  return readSelection(display_, source->mime_types,
                       [source](const char *mime, int fd) {
                         wlr_data_source_send(source, mime, fd);
                       });
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

  return readSelection(display_, source->mime_types,
                       [source](const char *mime, int fd) {
                         wlr_primary_selection_source_send(source, mime, fd);
                       });
}

} // namespace lava
