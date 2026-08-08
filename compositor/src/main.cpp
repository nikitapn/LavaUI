#include <cstddef>
#include <fstream>
#include <sys/stat.h>
#include <cstdlib>
#include <ctime>
#include <iostream>
#include <list>

#include "canvas_surface.hpp"
#include "wlr.hpp"

namespace {

/// A `wl_listener` that remembers what owns it.
///
/// wlroots hands a callback only the listener that fired. C gets back to the
/// owning struct with `wl_container_of`, which is `offsetof` — and `offsetof`
/// stops being portable the moment a struct holds anything like a `std::list`,
/// because it is no longer standard-layout. GCC allows it with a warning; the
/// standard calls it conditionally-supported.
///
/// Carrying the owner next to the listener costs a pointer and sidesteps the
/// question. `wl_listener` is the first member, so the cast back in `owner_of`
/// is the one reinterpret_cast that is actually well-defined.
template <typename T>
struct Listener {
  wl_listener listener{};
  T *owner = nullptr;

  void attach(wl_signal *signal, T *o, wl_notify_func_t notify) {
    owner = o;
    listener.notify = notify;
    wl_signal_add(signal, &listener);
  }
  void detach() { wl_list_remove(&listener.link); }
};

template <typename T>
T *owner_of(wl_listener *listener) {
  return reinterpret_cast<Listener<T> *>(listener)->owner;
}

struct Server;

// ─── Output ────────────────────────────────────────────────────────────────

struct Output {
  Server *server;
  wlr_output *wlr;
  wlr_scene_output *scene_output;
  Listener<Output> frame;
  Listener<Output> request_state;
  Listener<Output> destroy;

  Output(Server *server, wlr_output *output);
  ~Output();

  static void on_frame(wl_listener *listener, void *data);
  static void on_request_state(wl_listener *listener, void *data);
  static void on_destroy(wl_listener *listener, void *data);
};

// ─── Toplevel ──────────────────────────────────────────────────────────────

/// One application window.
///
/// The scene graph owns the pixels: `wlr_scene_xdg_surface_create` builds a
/// subtree for the surface and its children, and moving that subtree is what
/// moves the window. Nothing here draws.
struct Toplevel {
  Server *server;
  wlr_xdg_toplevel *xdg_toplevel;
  wlr_scene_tree *scene_tree;

  Listener<Toplevel> map;
  Listener<Toplevel> unmap;
  Listener<Toplevel> commit;
  Listener<Toplevel> destroy;
  Listener<Toplevel> request_maximize;
  Listener<Toplevel> request_fullscreen;

  Toplevel(Server *server, wlr_xdg_toplevel *toplevel);
  ~Toplevel();

  static void on_map(wl_listener *listener, void *data);
  static void on_unmap(wl_listener *listener, void *data);
  static void on_commit(wl_listener *listener, void *data);
  static void on_destroy(wl_listener *listener, void *data);
  static void on_request_maximize(wl_listener *listener, void *data);
  static void on_request_fullscreen(wl_listener *listener, void *data);
};

// ─── Keyboard ──────────────────────────────────────────────────────────────

struct Keyboard {
  Server *server;
  wlr_keyboard *wlr;
  Listener<Keyboard> modifiers;
  Listener<Keyboard> key;
  Listener<Keyboard> destroy;

  Keyboard(Server *server, wlr_input_device *device);
  ~Keyboard();

  static void on_modifiers(wl_listener *listener, void *data);
  static void on_key(wl_listener *listener, void *data);
  static void on_destroy(wl_listener *listener, void *data);
};

// ─── Server ────────────────────────────────────────────────────────────────

struct Server {
  wl_display *display = nullptr;
  wlr_backend *backend = nullptr;
  wlr_renderer *renderer = nullptr;
  wlr_allocator *allocator = nullptr;
  wlr_scene *scene = nullptr;
  wlr_output_layout *output_layout = nullptr;
  wlr_scene_output_layout *scene_layout = nullptr;

  wlr_xdg_shell *xdg_shell = nullptr;
  wlr_seat *seat = nullptr;
  wlr_cursor *cursor = nullptr;
  wlr_xcursor_manager *cursor_mgr = nullptr;

  /// Front is the most recently focused. Focus order and stacking order are
  /// the same thing here, which is why one list serves both.
  std::list<Toplevel *> toplevels;
  /// Kept here because `wlr_seat` does not expose one, and seat capabilities
  /// have to be recomputed whenever a keyboard comes or goes.
  std::list<Keyboard *> keyboards;

  Listener<Server> new_output;
  Listener<Server> new_toplevel;
  Listener<Server> new_input;
  Listener<Server> cursor_motion;
  Listener<Server> cursor_motion_absolute;
  Listener<Server> cursor_button;
  Listener<Server> cursor_axis;
  Listener<Server> cursor_frame;
  Listener<Server> request_cursor;

  static void on_new_output(wl_listener *listener, void *data);
  static void on_new_toplevel(wl_listener *listener, void *data);
  static void on_new_input(wl_listener *listener, void *data);
  static void on_cursor_motion(wl_listener *listener, void *data);
  static void on_cursor_motion_absolute(wl_listener *listener, void *data);
  static void on_cursor_button(wl_listener *listener, void *data);
  static void on_cursor_axis(wl_listener *listener, void *data);
  static void on_cursor_frame(wl_listener *listener, void *data);
  static void on_request_cursor(wl_listener *listener, void *data);

  /// Deepest surface under a layout-space point, plus that point in the
  /// surface's own coordinates. Null when the cursor is over blank desktop.
  wlr_surface *surface_at(double lx, double ly, double *sx, double *sy,
                          Toplevel **out_toplevel);

  void focus(Toplevel *toplevel);
  void update_pointer_focus(uint32_t time_msec);
  void update_seat_capabilities();
};

// ─── Output ────────────────────────────────────────────────────────────────

Output::Output(Server *server, wlr_output *output)
    : server(server), wlr(output),
      scene_output(wlr_scene_output_create(server->scene, output)) {
  frame.attach(&wlr->events.frame, this, on_frame);
  request_state.attach(&wlr->events.request_state, this, on_request_state);
  destroy.attach(&wlr->events.destroy, this, on_destroy);

  wlr_output_init_render(wlr, server->allocator, server->renderer);

  wlr_output_state state;
  wlr_output_state_init(&state);
  wlr_output_state_set_enabled(&state, true);
  if (auto *mode = wlr_output_preferred_mode(wlr)) {
    wlr_output_state_set_mode(&state, mode);
  }
  wlr_output_commit_state(wlr, &state);
  wlr_output_state_finish(&state);

  auto *layout_output = wlr_output_layout_add_auto(server->output_layout, wlr);
  wlr_scene_output_layout_add_output(server->scene_layout, layout_output,
                                     scene_output);
}

Output::~Output() {
  frame.detach();
  request_state.detach();
  destroy.detach();
}

void Output::on_frame(wl_listener *listener, void *) {
  auto *output = owner_of<Output>(listener);
  wlr_scene_output_commit(output->scene_output, nullptr);
  timespec now{};
  clock_gettime(CLOCK_MONOTONIC, &now);
  wlr_scene_output_send_frame_done(output->scene_output, &now);
}

void Output::on_request_state(wl_listener *listener, void *data) {
  auto *output = owner_of<Output>(listener);
  auto *event = static_cast<wlr_output_event_request_state *>(data);
  wlr_output_commit_state(output->wlr, event->state);
}

void Output::on_destroy(wl_listener *listener, void *) {
  delete owner_of<Output>(listener);
}

// ─── Toplevel ──────────────────────────────────────────────────────────────

Toplevel::Toplevel(Server *server, wlr_xdg_toplevel *toplevel)
    : server(server), xdg_toplevel(toplevel),
      scene_tree(wlr_scene_xdg_surface_create(&server->scene->tree,
                                              toplevel->base)) {
  // The scene node points back here so `surface_at` can get from a hit node to
  // the window that owns it. wlroots walks up to the nearest node with data.
  scene_tree->node.data = this;
  toplevel->base->data = scene_tree;

  // Map/unmap belong to the surface, not the xdg role — they moved there when
  // wlroots unified the lifecycle across shells.
  wlr_surface *surface = toplevel->base->surface;
  map.attach(&surface->events.map, this, on_map);
  unmap.attach(&surface->events.unmap, this, on_unmap);
  commit.attach(&surface->events.commit, this, on_commit);
  destroy.attach(&toplevel->events.destroy, this, on_destroy);
  request_maximize.attach(&toplevel->events.request_maximize, this,
                          on_request_maximize);
  request_fullscreen.attach(&toplevel->events.request_fullscreen, this,
                            on_request_fullscreen);
}

Toplevel::~Toplevel() {
  map.detach();
  unmap.detach();
  commit.detach();
  destroy.detach();
  request_maximize.detach();
  request_fullscreen.detach();
}

void Toplevel::on_map(wl_listener *listener, void *) {
  auto *toplevel = owner_of<Toplevel>(listener);
  toplevel->server->toplevels.push_front(toplevel);
  toplevel->server->focus(toplevel);
  const char *title = toplevel->xdg_toplevel->title;
  const char *app_id = toplevel->xdg_toplevel->app_id;
  wlr_log(WLR_INFO, "toplevel mapped: app_id=%s title=%s",
          app_id ? app_id : "(none)", title ? title : "(none)");
}

void Toplevel::on_unmap(wl_listener *listener, void *) {
  auto *toplevel = owner_of<Toplevel>(listener);
  wlr_log(WLR_INFO, "toplevel unmapped");
  toplevel->server->toplevels.remove(toplevel);
  // Whatever is under the cursor now is a different surface, and nothing else
  // will tell the seat so — an unmap is not a pointer event.
  toplevel->server->update_pointer_focus(0);
}

void Toplevel::on_commit(wl_listener *listener, void *) {
  auto *toplevel = owner_of<Toplevel>(listener);
  // The first commit is the client asking "how big should I be?". Answering 0x0
  // means "you decide", which is the honest answer until there is a layout
  // policy. Skipping the reply entirely leaves the client waiting forever.
  if (toplevel->xdg_toplevel->base->initial_commit) {
    wlr_xdg_toplevel_set_size(toplevel->xdg_toplevel, 0, 0);
  }
}

void Toplevel::on_destroy(wl_listener *listener, void *) {
  delete owner_of<Toplevel>(listener);
}

void Toplevel::on_request_maximize(wl_listener *listener, void *) {
  auto *toplevel =
      owner_of<Toplevel>(listener);
  // No maximize policy yet, but the protocol requires a configure in reply to
  // the request whether or not anything changed. Silence is a protocol error.
  if (toplevel->xdg_toplevel->base->initialized) {
    wlr_xdg_surface_schedule_configure(toplevel->xdg_toplevel->base);
  }
}

void Toplevel::on_request_fullscreen(wl_listener *listener, void *) {
  auto *toplevel =
      owner_of<Toplevel>(listener);
  if (toplevel->xdg_toplevel->base->initialized) {
    wlr_xdg_surface_schedule_configure(toplevel->xdg_toplevel->base);
  }
}

// ─── Keyboard ──────────────────────────────────────────────────────────────

Keyboard::Keyboard(Server *server, wlr_input_device *device)
    : server(server), wlr(wlr_keyboard_from_input_device(device)) {
  // Every client is sent this keymap and interprets keycodes with it, so the
  // compositor's idea of the layout is the only one that exists.
  xkb_context *context = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
  xkb_keymap *keymap =
      xkb_keymap_new_from_names(context, nullptr, XKB_KEYMAP_COMPILE_NO_FLAGS);
  wlr_keyboard_set_keymap(wlr, keymap);
  xkb_keymap_unref(keymap);
  xkb_context_unref(context);
  wlr_keyboard_set_repeat_info(wlr, 25, 600);

  modifiers.attach(&wlr->events.modifiers, this, on_modifiers);
  key.attach(&wlr->events.key, this, on_key);
  destroy.attach(&device->events.destroy, this, on_destroy);

  server->keyboards.push_back(this);
  wlr_seat_set_keyboard(server->seat, wlr);
}

Keyboard::~Keyboard() {
  server->keyboards.remove(this);
  modifiers.detach();
  key.detach();
  destroy.detach();
}

void Keyboard::on_modifiers(wl_listener *listener, void *) {
  auto *keyboard = owner_of<Keyboard>(listener);
  wlr_seat_set_keyboard(keyboard->server->seat, keyboard->wlr);
  wlr_seat_keyboard_notify_modifiers(keyboard->server->seat,
                                     &keyboard->wlr->modifiers);
}

void Keyboard::on_key(wl_listener *listener, void *data) {
  auto *keyboard = owner_of<Keyboard>(listener);
  auto *event = static_cast<wlr_keyboard_key_event *>(data);
  Server *server = keyboard->server;

  // Alt+Escape quits. Worth having while this runs nested inside another
  // compositor: without it the only way out is killing the process from
  // elsewhere, and a compositor that has taken the keyboard is hard to leave.
  const uint32_t modifiers = wlr_keyboard_get_modifiers(keyboard->wlr);
  if ((modifiers & WLR_MODIFIER_ALT) &&
      event->state == WL_KEYBOARD_KEY_STATE_PRESSED) {
    // +8 converts evdev to xkb keycodes; the offset is historical, from X.
    const xkb_keysym_t *syms = nullptr;
    const int count = xkb_state_key_get_syms(keyboard->wlr->xkb_state,
                                             event->keycode + 8, &syms);
    for (int i = 0; i < count; ++i) {
      if (syms[i] == XKB_KEY_Escape) {
        wl_display_terminate(server->display);
        return;
      }
    }
  }

  wlr_seat_set_keyboard(server->seat, keyboard->wlr);
  wlr_seat_keyboard_notify_key(server->seat, event->time_msec, event->keycode,
                               event->state);
}

void Keyboard::on_destroy(wl_listener *listener, void *) {
  auto *keyboard = owner_of<Keyboard>(listener);
  Server *server = keyboard->server;
  delete keyboard;
  server->update_seat_capabilities();
}

// ─── Server ────────────────────────────────────────────────────────────────

void Server::on_new_output(wl_listener *listener, void *data) {
  auto *server = owner_of<Server>(listener);
  new Output(server, static_cast<wlr_output *>(data));
}

void Server::on_new_toplevel(wl_listener *listener, void *data) {
  auto *server = owner_of<Server>(listener);
  new Toplevel(server, static_cast<wlr_xdg_toplevel *>(data));
}

void Server::on_new_input(wl_listener *listener, void *data) {
  auto *server = owner_of<Server>(listener);
  auto *device = static_cast<wlr_input_device *>(data);
  switch (device->type) {
  case WLR_INPUT_DEVICE_KEYBOARD:
    new Keyboard(server, device);
    break;
  case WLR_INPUT_DEVICE_POINTER:
    // The cursor merges every pointer into one position, so two mice move the
    // same arrow rather than fighting over it.
    wlr_cursor_attach_input_device(server->cursor, device);
    break;
  default:
    break;
  }
  server->update_seat_capabilities();
}

void Server::update_seat_capabilities() {
  // Advertising a keyboard with none attached makes clients wait for key
  // events that can never arrive, so this is recomputed rather than assumed.
  uint32_t caps = WL_SEAT_CAPABILITY_POINTER;
  if (!keyboards.empty()) {
    caps |= WL_SEAT_CAPABILITY_KEYBOARD;
  }
  wlr_seat_set_capabilities(seat, caps);
}

wlr_surface *Server::surface_at(double lx, double ly, double *sx, double *sy,
                                Toplevel **out_toplevel) {
  *out_toplevel = nullptr;
  wlr_scene_node *node = wlr_scene_node_at(&scene->tree.node, lx, ly, sx, sy);
  if (node == nullptr || node->type != WLR_SCENE_NODE_BUFFER) {
    return nullptr;
  }
  wlr_scene_buffer *buffer = wlr_scene_buffer_from_node(node);
  wlr_scene_surface *scene_surface = wlr_scene_surface_try_from_buffer(buffer);
  if (scene_surface == nullptr) {
    return nullptr;  // a buffer of ours, not a client's
  }

  // The hit node is a leaf — the surface, or one of its subsurfaces. The
  // window it belongs to is the nearest ancestor carrying our back-pointer.
  for (wlr_scene_tree *tree = node->parent; tree != nullptr;
       tree = tree->node.parent) {
    if (tree->node.data != nullptr) {
      *out_toplevel = static_cast<Toplevel *>(tree->node.data);
      break;
    }
  }
  return scene_surface->surface;
}

void Server::focus(Toplevel *toplevel) {
  if (toplevel == nullptr) {
    return;
  }
  wlr_surface *surface = toplevel->xdg_toplevel->base->surface;
  wlr_surface *previous = seat->keyboard_state.focused_surface;
  if (previous == surface) {
    return;
  }
  if (previous != nullptr) {
    // Deactivating tells the old window to stop drawing itself as focused —
    // its caret, its titlebar. Nothing else would ever tell it.
    if (auto *prev_toplevel = wlr_xdg_toplevel_try_from_wlr_surface(previous)) {
      wlr_xdg_toplevel_set_activated(prev_toplevel, false);
    }
  }

  wlr_scene_node_raise_to_top(&toplevel->scene_tree->node);
  toplevels.remove(toplevel);
  toplevels.push_front(toplevel);
  wlr_xdg_toplevel_set_activated(toplevel->xdg_toplevel, true);

  if (auto *keyboard = wlr_seat_get_keyboard(seat)) {
    wlr_seat_keyboard_notify_enter(seat, surface, keyboard->keycodes,
                                   keyboard->num_keycodes, &keyboard->modifiers);
  }
}

void Server::update_pointer_focus(uint32_t time_msec) {
  double sx = 0, sy = 0;
  Toplevel *toplevel = nullptr;
  wlr_surface *surface =
      surface_at(cursor->x, cursor->y, &sx, &sy, &toplevel);

  if (surface == nullptr) {
    // Over blank desktop: take the cursor image back from whichever client set
    // it last, and tell that client the pointer has left.
    wlr_cursor_set_xcursor(cursor, cursor_mgr, "default");
    wlr_seat_pointer_clear_focus(seat);
    return;
  }
  wlr_seat_pointer_notify_enter(seat, surface, sx, sy);
  wlr_seat_pointer_notify_motion(seat, time_msec, sx, sy);
}

void Server::on_cursor_motion(wl_listener *listener, void *data) {
  auto *server = owner_of<Server>(listener);
  auto *event = static_cast<wlr_pointer_motion_event *>(data);
  wlr_cursor_move(server->cursor, &event->pointer->base, event->delta_x,
                  event->delta_y);
  server->update_pointer_focus(event->time_msec);
}

void Server::on_cursor_motion_absolute(wl_listener *listener, void *data) {
  auto *server =
      owner_of<Server>(listener);
  auto *event = static_cast<wlr_pointer_motion_absolute_event *>(data);
  wlr_cursor_warp_absolute(server->cursor, &event->pointer->base, event->x,
                           event->y);
  server->update_pointer_focus(event->time_msec);
}

void Server::on_cursor_button(wl_listener *listener, void *data) {
  auto *server = owner_of<Server>(listener);
  auto *event = static_cast<wlr_pointer_button_event *>(data);

  if (event->state == WL_POINTER_BUTTON_STATE_PRESSED) {
    double sx = 0, sy = 0;
    Toplevel *toplevel = nullptr;
    server->surface_at(server->cursor->x, server->cursor->y, &sx, &sy,
                       &toplevel);
    server->focus(toplevel);  // click to focus; null over the desktop is a no-op
  }

  wlr_seat_pointer_notify_button(server->seat, event->time_msec, event->button,
                                 event->state);
}

void Server::on_cursor_axis(wl_listener *listener, void *data) {
  auto *server = owner_of<Server>(listener);
  auto *event = static_cast<wlr_pointer_axis_event *>(data);
  wlr_seat_pointer_notify_axis(server->seat, event->time_msec,
                               event->orientation, event->delta,
                               event->delta_discrete, event->source,
                               event->relative_direction);
}

void Server::on_cursor_frame(wl_listener *listener, void *) {
  auto *server = owner_of<Server>(listener);
  // Groups the events above into one atomic update for the client.
  wlr_seat_pointer_notify_frame(server->seat);
}

void Server::on_request_cursor(wl_listener *listener, void *data) {
  auto *server = owner_of<Server>(listener);
  auto *event = static_cast<wlr_seat_pointer_request_set_cursor_event *>(data);
  // Honoured only from the client the pointer is actually over. Otherwise any
  // client could change the cursor at any time, including while the pointer is
  // somewhere else entirely.
  if (event->seat_client == server->seat->pointer_state.focused_client) {
    wlr_cursor_set_surface(server->cursor, event->surface, event->hotspot_x,
                           event->hotspot_y);
  }
}

// ─── Client surface ────────────────────────────────────────────────────────

/// Size of the surface a client draws into.
///
/// Fixed on both sides for now, and the client is told nothing. A real
/// surface learns its size from the opening `Resize` on its input stream,
/// because the window manager has the last word — see `LavaClient.open`. That
/// stream is part of the control plane this does not have yet.
constexpr uint32_t kSurfaceWidth = 720;
constexpr uint32_t kSurfaceHeight = 480;

/// How often the arena is checked for a new frame.
///
/// Polling, and only because there is nothing to wake us: a shared-memory
/// store signals no one. The control plane's `Present` is exactly the nudge
/// that replaces this, and with it the compositor blocks in
/// `wl_display_run` until a client says there is something to draw instead of
/// asking sixty times a second whether there is.
constexpr int kArenaPollMs = 16;

std::string arena_id() {
  if (const char *fromEnv = std::getenv("LAVA_ARENA")) return fromEnv;
  return "lava-surface";
}

/// Where the client leaves its font table.
std::string font_manifest_path() {
  const char *dir = std::getenv("XDG_RUNTIME_DIR");
  return std::string(dir ? dir : "/tmp") + "/lava-fonts-" + arena_id();
}

/// The faces a client's glyphs are numbered against, in the client's order.
///
/// A `GlyphInstance` carries a font id, and an id means nothing on its own —
/// it is an index into whichever table handed it out. The arena carries the id
/// and nothing that says what it means, so the client writes its table down
/// and this registers the same faces in the same order to reproduce it.
///
/// Guessing the order was tried and was wrong: LavaUI's bootstrap loads the
/// symbols face before the UI face, so "the obvious two in the obvious order"
/// put the UI face at 2 on one side and 0 on the other, and every glyph
/// missed. Hence reading it rather than assuming it — and hence the check
/// below, which says so loudly instead of drawing the wrong glyphs quietly.
///
/// `Compositor.RegisterFont` over NPRPC is what replaces this: a client asks
/// for an id rather than describing a table and hoping it can be reproduced.
/// Returns the number of faces registered, or -1 if there is no manifest yet.
int register_fonts_from_manifest(lava::CanvasSurface &surface, int alreadyHave) {
  // Cheap enough to ask every tick, unlike reading and parsing the file.
  static timespec lastSeen{};
  struct stat info{};
  const std::string path = font_manifest_path();
  if (::stat(path.c_str(), &info) != 0) return alreadyHave;
  if (info.st_mtim.tv_sec == lastSeen.tv_sec &&
      info.st_mtim.tv_nsec == lastSeen.tv_nsec) {
    return alreadyHave;
  }
  lastSeen = info.st_mtim;

  std::ifstream file(path);
  if (!file) return alreadyHave;

  int index = 0;
  std::string line;
  while (std::getline(file, line)) {
    if (line.empty()) continue;
    const size_t firstTab = line.find('\t');
    const size_t secondTab = line.find('\t', firstTab + 1);
    if (firstTab == std::string::npos || secondTab == std::string::npos) continue;
    const int wanted = std::stoi(line.substr(0, firstTab));
    const float pixelSize =
        std::stof(line.substr(firstTab + 1, secondTab - firstTab - 1));
    const std::string path = line.substr(secondTab + 1);

    if (index++ < alreadyHave) continue;  // registered on an earlier pass
    const int got = surface.registerFont(path, pixelSize);
    if (got != wanted) {
      // Not fatal, and much better said than not: text will draw with the
      // wrong face rather than not at all, which is far harder to recognise.
      wlr_log(WLR_ERROR,
              "canvas: font '%s' landed at id %d but the client stamped %d",
              path.c_str(), got, wanted);
    }
  }
  return index;
}

/// What the surface shows before any client has published a frame.
std::vector<canvas::DrawCommand> placeholder_commands() {
  using canvas::DrawCommand;
  using enum canvas::DrawCommandKind;
  const float w = kSurfaceWidth;
  const float h = kSurfaceHeight;
  // RGBA8 little-endian — R in the low byte, so these read as 0xAABBGGRR.
  return {
      {.kind = static_cast<uint32_t>(Rect),
       .x = 0, .y = 0, .w = w, .h = h, .color = 0xff2a1f18u},
      {.kind = static_cast<uint32_t>(RoundedRect),
       .x = 24, .y = 24, .w = w - 48, .h = h - 48, .color = 0xff3a2a20u,
       .aux = 12.f},
      {.kind = static_cast<uint32_t>(Circle),
       .x = w / 2, .y = h / 2, .color = 0xff1973f2u, .aux = 40.f},
  };
}

/// The surface, the scene node showing it, and the poll that keeps it current.
struct ClientSurface {
  std::unique_ptr<lava::CanvasSurface> canvas;
  wlr_scene_buffer *node = nullptr;
  wl_event_source *timer = nullptr;
  /// False until a client has created the arena. Retried rather than required
  /// at startup, because a compositor that only works if its clients started
  /// first is not a compositor.
  bool attached = false;
  /// Faces taken from the client's manifest so far. Re-read rather than read
  /// once: a client that changes content scale registers its faces again at
  /// the new size, and those ids have to exist here before the glyphs
  /// carrying them arrive.
  int fonts = 0;

  void start(wl_event_loop *loop) {
    timer = wl_event_loop_add_timer(loop, on_timer, this);
    wl_event_source_timer_update(timer, kArenaPollMs);
  }

  static int on_timer(void *data) {
    auto *self = static_cast<ClientSurface *>(data);
    if (!self->attached) {
      self->attached = self->canvas->attachArena(arena_id());
    } else if (const int have =
                   register_fonts_from_manifest(*self->canvas, self->fonts);
               have > self->fonts) {
      // Before the frame that uses them, and it costs a frame of latency at
      // most: a client publishes its table when it loads a face, which is
      // always before it can shape anything with it.
      self->fonts = have;
    } else if (self->canvas->renderFromArena()) {
      // Same buffer, new contents. wlroots caches a texture per buffer, so
      // without damage it would keep showing the frame it already uploaded.
      // Null damage means the whole surface, which is honest until a client
      // tells us what it actually changed.
      wlr_scene_buffer_set_buffer_with_damage(self->node,
                                              self->canvas->buffer(), nullptr);
    }
    wl_event_source_timer_update(self->timer, kArenaPollMs);
    return 0;
  }
};

} // namespace

int main() {
  wlr_log_init(WLR_DEBUG, nullptr);
  Server server;
  server.display = wl_display_create();
  if (!server.display) {
    std::cerr << "Could not create Wayland display\n";
    return EXIT_FAILURE;
  }

  auto *loop = wl_display_get_event_loop(server.display);
  server.backend = wlr_backend_autocreate(loop, nullptr);
  server.renderer = server.backend ? wlr_renderer_autocreate(server.backend) : nullptr;
  server.allocator = (server.backend && server.renderer)
                         ? wlr_allocator_autocreate(server.backend, server.renderer)
                         : nullptr;
  if (!server.backend || !server.renderer || !server.allocator) {
    std::cerr << "Could not create wlroots backend, renderer, or allocator\n";
    wl_display_destroy(server.display);
    return EXIT_FAILURE;
  }

  wlr_renderer_init_wl_display(server.renderer, server.display);
  wlr_compositor_create(server.display, 6, server.renderer);
  wlr_subcompositor_create(server.display);
  wlr_data_device_manager_create(server.display);

  server.scene = wlr_scene_create();
  server.output_layout = wlr_output_layout_create(server.display);
  server.scene_layout =
      wlr_scene_attach_output_layout(server.scene, server.output_layout);

  const float background[] = {0.055f, 0.075f, 0.12f, 1.0f};
  wlr_scene_rect_create(&server.scene->tree, 8192, 8192, background);

  server.new_output.attach(&server.backend->events.new_output, &server,
                           Server::on_new_output);

  // xdg-shell: how ordinary applications get a window.
  server.xdg_shell = wlr_xdg_shell_create(server.display, 3);
  server.new_toplevel.attach(&server.xdg_shell->events.new_toplevel, &server,
                             Server::on_new_toplevel);

  // The cursor is a position in layout space; the manager supplies the images
  // it is drawn with, scaled per output.
  server.cursor = wlr_cursor_create();
  wlr_cursor_attach_output_layout(server.cursor, server.output_layout);
  server.cursor_mgr = wlr_xcursor_manager_create(nullptr, 24);

  server.cursor_motion.attach(&server.cursor->events.motion, &server,
                              Server::on_cursor_motion);
  server.cursor_motion_absolute.attach(&server.cursor->events.motion_absolute,
                                       &server,
                                       Server::on_cursor_motion_absolute);
  server.cursor_button.attach(&server.cursor->events.button, &server,
                              Server::on_cursor_button);
  server.cursor_axis.attach(&server.cursor->events.axis, &server,
                            Server::on_cursor_axis);
  server.cursor_frame.attach(&server.cursor->events.frame, &server,
                             Server::on_cursor_frame);

  server.seat = wlr_seat_create(server.display, "seat0");
  server.new_input.attach(&server.backend->events.new_input, &server,
                          Server::on_new_input);
  server.request_cursor.attach(&server.seat->events.request_set_cursor, &server,
                               Server::on_request_cursor);

  // A LavaUI client's window, drawn here and composited with no copy.
  //
  // This is the whole shape of the thing: the client owns no GPU and no
  // window. It runs a view tree, lays it out, and writes draw commands
  // straight into shared memory. Canvas — in *this* process, on the GPU
  // wlroots is using — replays them into an image whose memory is exported as
  // a dmabuf, and the scene graph shows it alongside ordinary Wayland
  // windows. Nothing is copied at either boundary: the bytes the client
  // writes are the bytes canvas reads, and the pixels canvas draws are the
  // pixels wlroots samples.
  ClientSurface client;
  client.canvas = lava::CanvasSurface::create(server.renderer, kSurfaceWidth,
                                              kSurfaceHeight);
  if (client.canvas) {
    // Something to look at before a client connects, and a way to tell "no
    // client" apart from "client publishing nothing" at a glance.
    client.canvas->render(placeholder_commands());
    client.node =
        wlr_scene_buffer_create(&server.scene->tree, client.canvas->buffer());
    if (client.node) {
      wlr_scene_node_set_position(&client.node->node, 80, 60);
      client.start(wl_display_get_event_loop(server.display));
      wlr_log(WLR_INFO, "canvas: surface placed, polling arena '%s'",
              arena_id().c_str());
    }
  }

  const char *socket = wl_display_add_socket_auto(server.display);
  if (!socket || !wlr_backend_start(server.backend)) {
    std::cerr << "Could not start compositor backend\n";
    wl_display_destroy(server.display);
    return EXIT_FAILURE;
  }

  // Clients find the compositor through the environment, so a terminal
  // launched from here inherits the right socket without being told.
  setenv("WAYLAND_DISPLAY", socket, 1);

  std::cout << "Compositor running on WAYLAND_DISPLAY=" << socket << '\n';
  wl_display_run(server.display);
  wl_display_destroy_clients(server.display);
  wl_display_destroy(server.display);
  return EXIT_SUCCESS;
}
