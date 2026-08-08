#include <cstddef>
#include <fstream>
#include <sys/stat.h>
#include <cstdlib>
#include <ctime>
#include <iostream>
#include <list>

#include "canvas_surface.hpp"
#include "control_plane.hpp"
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
class SurfaceRegistry;

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

  /// LavaUI client surfaces, and the channel their input goes back down.
  /// Both null until `main` builds them; a compositor without a control plane
  /// has neither, and every use below checks.
  SurfaceRegistry *surfaces = nullptr;
  lava::ControlPlane *control = nullptr;
  /// Which client surface the keyboard goes to, or 0.
  ///
  /// Separate from `wlr_seat`'s focus because a client surface is not a
  /// `wlr_surface` — it has no Wayland object for the seat to focus. Clicking
  /// one takes the keyboard away from any Wayland window, and clicking a
  /// Wayland window takes it back.
  uint32_t focusedSurface = 0;

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

  /// Sends one event to the client surface under the pointer.
  ///
  /// True when a surface took it, which is also the caller's signal not to
  /// hand the same event to a Wayland client: the two focus models are
  /// separate and an event belongs to exactly one of them.
  bool route_pointer(uint32_t kind, int32_t button, int32_t mods);
  /// Sends one event to the focused client surface. True if there was one.
  bool route_to_focused(uint32_t kind, float x, float y, int32_t button,
                        int32_t mods);
};

// ─── Client surfaces ───────────────────────────────────────────────────────
//
// One surface is one LavaUI client's window: a canvas render target whose
// pixels a client's arena drives, shown by a scene node like any other buffer.
// Clients ask for them over the control plane and the compositor grants —
// it does not open windows and hope somebody attaches. That is the direction
// Wayland itself runs in, and for the same reason: the process that knows a
// window is wanted is the one with something to put in it.

/// One client's window.
struct ClientSurface {
  uint32_t id = 0;
  std::unique_ptr<lava::CanvasSurface> canvas;
  wlr_scene_buffer *node = nullptr;
  int x = 0;
  int y = 0;
  uint32_t width = 0;
  uint32_t height = 0;

  /// Whether `lx, ly` (layout space) is inside this surface, and where in it.
  bool hit(double lx, double ly, double &sx, double &sy) const {
    sx = lx - x;
    sy = ly - y;
    return sx >= 0 && sy >= 0 && sx < width && sy < height;
  }
};

/// Every client surface, and the control plane's view of the compositor.
///
/// Implements `lava::CompositorHost`, so the servant calls land here — always
/// on the Wayland event loop thread, because the POA hops there first. Nothing
/// in this class takes a lock, and that is why.
class SurfaceRegistry : public lava::CompositorHost {
 public:
  void bind(wlr_renderer *renderer, wlr_scene_tree *tree) {
    renderer_ = renderer;
    tree_ = tree;
  }
  void bind(lava::ControlPlane *control) { control_ = control; }

  ClientSurface *find(uint32_t id) {
    for (auto &s : surfaces_) {
      if (s->id == id) return s.get();
    }
    return nullptr;
  }

  /// Topmost surface under a layout-space point. Front is most recent.
  ClientSurface *at(double lx, double ly, double &sx, double &sy) {
    for (auto &s : surfaces_) {
      if (s->hit(lx, ly, sx, sy)) return s.get();
    }
    return nullptr;
  }

  bool empty() const { return surfaces_.empty(); }

  // ─── CompositorHost ──────────────────────────────────────────────────────

  int registerFont(const std::string &path, float pixelSize) override {
    // Answered from this table, not from a renderer.
    //
    // A client registers its faces before it asks for a surface — it has to,
    // because it shapes text to lay out and cannot do that without ids — so
    // at this point there is usually no canvas device to ask. Handing out an
    // index here and replaying the table into each surface as it comes up
    // makes the id independent of when it was asked for, which is the only
    // thing the client actually needs it to be.
    for (size_t i = 0; i < fonts_.size(); ++i) {
      if (fonts_[i].first == path && fonts_[i].second == pixelSize) {
        return static_cast<int>(i);
      }
    }
    fonts_.emplace_back(path, pixelSize);
    const int id = static_cast<int>(fonts_.size()) - 1;
    // Every existing surface has its own canvas engine and so its own atlas,
    // and each has to learn the face separately.
    for (auto &s : surfaces_) {
      s->canvas->registerFont(path, pixelSize);
    }
    return id;
  }

  /// Teaches a newly created surface every face registered so far.
  ///
  /// In id order, so canvas' own sequential numbering reproduces the ids this
  /// registry already handed out. A mismatch here would draw the wrong glyphs
  /// rather than none, which is much harder to notice, so it is checked.
  void replayFonts(lava::CanvasSurface &canvas) {
    for (size_t i = 0; i < fonts_.size(); ++i) {
      const int got = canvas.registerFont(fonts_[i].first, fonts_[i].second);
      if (got != static_cast<int>(i)) {
        wlr_log(WLR_ERROR, "font '%s' landed at %d but was handed out as %zu",
                fonts_[i].first.c_str(), got, i);
      }
    }
  }

  uint32_t createSurface(const std::string &arenaId, uint32_t width,
                         uint32_t height, const std::string &title) override {
    auto surface = std::make_unique<ClientSurface>();
    surface->canvas = lava::CanvasSurface::create(renderer_, width, height);
    if (!surface->canvas) return 0;
    if (!surface->canvas->attachArena(arenaId)) {
      // The client creates the arena and the compositor attaches, so this
      // means the client asked before it had somewhere to draw.
      return 0;
    }
    replayFonts(*surface->canvas);
    surface->id = nextId_++;
    surface->width = width;
    surface->height = height;
    // Cascaded, so a second client is visible rather than exactly on top of
    // the first. A real layout policy belongs with window management.
    surface->x = 40 + static_cast<int>(surfaces_.size()) * 40;
    surface->y = 40 + static_cast<int>(surfaces_.size()) * 40;

    surface->node = wlr_scene_buffer_create(tree_, surface->canvas->buffer());
    if (surface->node == nullptr) return 0;
    wlr_scene_node_set_position(&surface->node->node, surface->x, surface->y);

    const uint32_t id = surface->id;
    surfaces_.push_front(std::move(surface));
    wlr_log(WLR_INFO, "surface %u: '%s' %ux%u on arena '%s'", id, title.c_str(),
            width, height, arenaId.c_str());
    return id;
  }

  bool destroySurface(uint32_t id) override {
    for (auto it = surfaces_.begin(); it != surfaces_.end(); ++it) {
      if ((*it)->id != id) continue;
      if ((*it)->node) wlr_scene_node_destroy(&(*it)->node->node);
      surfaces_.erase(it);
      if (control_) control_->surfaceGone(id);
      wlr_log(WLR_INFO, "surface %u: gone", id);
      return true;
    }
    return false;
  }

  bool surfaceExists(uint32_t id) const override {
    for (const auto &s : surfaces_) {
      if (s->id == id) return true;
    }
    return false;
  }

  void present(uint32_t id) override {
    ClientSurface *surface = find(id);
    if (surface == nullptr) return;
    if (!surface->canvas->renderFromArena()) return;
    // Same buffer, new contents. wlroots caches a texture per buffer, so
    // without damage it keeps showing the frame it already uploaded.
    wlr_scene_buffer_set_buffer_with_damage(surface->node,
                                            surface->canvas->buffer(), nullptr);
  }

  void surfaceSize(uint32_t id, float &outW, float &outH) const override {
    outW = 0.f;
    outH = 0.f;
    for (const auto &s : surfaces_) {
      if (s->id != id) continue;
      outW = static_cast<float>(s->width);
      outH = static_cast<float>(s->height);
      return;
    }
  }

  void scrollUnclaimed(uint32_t id, float dx, float dy) override {
    ClientSurface *surface = find(id);
    if (surface == nullptr) return;
    surface->canvas->scrollUnclaimed(dx, dy);
  }

  bool captureSurface(uint32_t id, int32_t x, int32_t y, int32_t w, int32_t h,
                      int32_t maxSide, std::vector<uint8_t> &outPng,
                      uint32_t &outW, uint32_t &outH) override {
    ClientSurface *surface = find(id);
    if (surface == nullptr) return false;
    return surface->canvas->capturePng(x, y, w, h, maxSide, outPng, outW, outH);
  }

 private:
  std::list<std::unique_ptr<ClientSurface>> surfaces_;
  wlr_renderer *renderer_ = nullptr;
  wlr_scene_tree *tree_ = nullptr;
  lava::ControlPlane *control_ = nullptr;
  /// Every face any client has asked for, in the order the ids were handed
  /// out. See `registerFont`.
  std::vector<std::pair<std::string, float>> fonts_;
  /// Never reused, so a stale id from a closed surface fails to resolve rather
  /// than quietly addressing whatever opened next.
  uint32_t nextId_ = 1;
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

/// xkb keysym → the GLFW key code canvas' `Key` events are numbered in.
///
/// Only the keys that mean something structurally: everything a client can
/// act on without knowing the layout. Printable characters deliberately do
/// not appear — they arrive as `Text`, which is the event that knows what the
/// layout actually produced.
int glfw_key(xkb_keysym_t sym) {
  switch (sym) {
    case XKB_KEY_Escape: return 256;
    case XKB_KEY_Return: case XKB_KEY_KP_Enter: return 257;
    case XKB_KEY_Tab: return 258;
    case XKB_KEY_BackSpace: return 259;
    case XKB_KEY_Insert: return 260;
    case XKB_KEY_Delete: return 261;
    case XKB_KEY_Right: return 262;
    case XKB_KEY_Left: return 263;
    case XKB_KEY_Down: return 264;
    case XKB_KEY_Up: return 265;
    case XKB_KEY_Page_Up: return 266;
    case XKB_KEY_Page_Down: return 267;
    case XKB_KEY_Home: return 268;
    case XKB_KEY_End: return 269;
    default: break;
  }
  // Letters and digits keep their ASCII value in GLFW, upper-cased.
  if (sym >= XKB_KEY_a && sym <= XKB_KEY_z) {
    return static_cast<int>(sym - XKB_KEY_a) + 'A';
  }
  if (sym >= XKB_KEY_A && sym <= XKB_KEY_Z) return static_cast<int>(sym);
  if (sym >= XKB_KEY_0 && sym <= XKB_KEY_9) return static_cast<int>(sym);
  return 0;
}

/// wlroots modifier mask → GLFW's, which is what canvas' events carry.
uint32_t glfw_mods(uint32_t modifiers) {
  uint32_t out = 0;
  if (modifiers & WLR_MODIFIER_SHIFT) out |= 1u;
  if (modifiers & WLR_MODIFIER_CTRL) out |= 2u;
  if (modifiers & WLR_MODIFIER_ALT) out |= 4u;
  if (modifiers & WLR_MODIFIER_LOGO) out |= 8u;
  return out;
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

  // A focused client surface takes the keyboard instead of any Wayland
  // window. Two events go out per press, because canvas wants both and only
  // one of them can answer either question: `Key` is the physical key, which
  // is what a shortcut or an arrow is; `Text` is the character the layout
  // produced, which is the only thing that knows about shift, dead keys or a
  // non-US keymap.
  if (server->focusedSurface != 0) {
    const bool pressed = event->state == WL_KEYBOARD_KEY_STATE_PRESSED;
    const xkb_keysym_t *syms = nullptr;
    const int count = xkb_state_key_get_syms(keyboard->wlr->xkb_state,
                                             event->keycode + 8, &syms);
    const int32_t mods = static_cast<int32_t>(glfw_mods(modifiers));
    for (int i = 0; i < count; ++i) {
      server->route_to_focused(
          static_cast<uint32_t>(canvas::InputEventKind::Key),
          pressed ? 1.f : 0.f, static_cast<float>(mods),
          static_cast<int32_t>(glfw_key(syms[i])), mods);
    }
    if (pressed) {
      const uint32_t utf32 =
          xkb_state_key_get_utf32(keyboard->wlr->xkb_state, event->keycode + 8);
      // Control characters are keys, not text: a client that inserted them
      // would put a literal backspace in its document.
      if (utf32 >= 0x20 && utf32 != 0x7f) {
        server->route_to_focused(
            static_cast<uint32_t>(canvas::InputEventKind::Text), 0.f, 0.f,
            static_cast<int32_t>(utf32), mods);
      }
    }
    return;
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
  // Client surfaces first: they sit above the Wayland windows in the scene and
  // are not `wlr_surface`s, so `surface_at` cannot see them at all.
  if (route_pointer(static_cast<uint32_t>(canvas::InputEventKind::MouseMove), 0,
                    0)) {
    wlr_cursor_set_xcursor(cursor, cursor_mgr, "default");
    wlr_seat_pointer_clear_focus(seat);
    return;
  }

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

bool Server::route_pointer(uint32_t kind, int32_t button, int32_t mods) {
  if (surfaces == nullptr || control == nullptr) return false;
  double sx = 0, sy = 0;
  ClientSurface *surface = surfaces->at(cursor->x, cursor->y, sx, sy);
  if (surface == nullptr) return false;
  control->postInput(surface->id, kind, static_cast<float>(sx),
                     static_cast<float>(sy), button, mods);
  return true;
}

bool Server::route_to_focused(uint32_t kind, float x, float y, int32_t button,
                              int32_t mods) {
  if (surfaces == nullptr || control == nullptr || focusedSurface == 0) {
    return false;
  }
  if (!surfaces->surfaceExists(focusedSurface)) {
    focusedSurface = 0;
    return false;
  }
  control->postInput(focusedSurface, kind, x, y, button, mods);
  return true;
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

  const bool pressed = event->state == WL_POINTER_BUTTON_STATE_PRESSED;

  // A press over a client surface focuses it and is forwarded; a release goes
  // to whichever surface is focused even if the pointer has since left it, so
  // a drag that ends outside still ends.
  if (server->surfaces != nullptr) {
    double sx = 0, sy = 0;
    ClientSurface *over =
        server->surfaces->at(server->cursor->x, server->cursor->y, sx, sy);
    if (pressed && over != nullptr) {
      server->focusedSurface = over->id;
      // Taking the keyboard from any Wayland window: the two focus models are
      // separate, and leaving both focused would deliver every key twice.
      wlr_seat_keyboard_notify_clear_focus(server->seat);
    }
    const uint32_t kind =
        static_cast<uint32_t>(pressed ? canvas::InputEventKind::MouseDown
                                      : canvas::InputEventKind::MouseUp);
    if (pressed ? over != nullptr : server->focusedSurface != 0) {
      const uint32_t id = pressed ? over->id : server->focusedSurface;
      // Left = 0, matching GLFW, which is what the client's event decoding
      // was written against.
      const int32_t button = static_cast<int32_t>(event->button - 0x110u);
      if (!pressed) {
        server->surfaces->at(server->cursor->x, server->cursor->y, sx, sy);
      }
      server->control->postInput(id, kind, static_cast<float>(sx),
                                 static_cast<float>(sy), button, 0);
      return;
    }
  }

  if (pressed) {
    double sx = 0, sy = 0;
    Toplevel *toplevel = nullptr;
    server->surface_at(server->cursor->x, server->cursor->y, &sx, &sy,
                       &toplevel);
    server->focus(toplevel);  // click to focus; null over the desktop is a no-op
    server->focusedSurface = 0;
  }

  wlr_seat_pointer_notify_button(server->seat, event->time_msec, event->button,
                                 event->state);
}

void Server::on_cursor_axis(wl_listener *listener, void *data) {
  auto *server = owner_of<Server>(listener);
  auto *event = static_cast<wlr_pointer_axis_event *>(data);

  // Notches, not pixels, and negated: canvas' `Scroll` follows GLFW, where a
  // positive y is a scroll *up*, while wlroots reports a positive delta as
  // downward motion of the content.
  if (server->surfaces != nullptr && server->control != nullptr) {
    double sx = 0, sy = 0;
    if (ClientSurface *over =
            server->surfaces->at(server->cursor->x, server->cursor->y, sx, sy)) {
      const float notches =
          static_cast<float>(-event->delta / 15.0);  // ~15 units per notch
      const bool horizontal =
          event->orientation == WL_POINTER_AXIS_HORIZONTAL_SCROLL;
      server->control->postInput(
          over->id, static_cast<uint32_t>(canvas::InputEventKind::Scroll),
          horizontal ? notches : 0.f, horizontal ? 0.f : notches, 0, 0);
      return;
    }
  }

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
  SurfaceRegistry surfaces;
  surfaces.bind(server.renderer, &server.scene->tree);
  server.surfaces = &surfaces;

  auto control = lava::ControlPlane::start(
      wl_display_get_event_loop(server.display), surfaces);
  if (control) {
    surfaces.bind(control.get());
    server.control = control.get();
  } else {
    // Not fatal: a compositor without a control plane still runs ordinary
    // Wayland clients. What it cannot do is host a LavaUI one, since there is
    // no way left for a client to ask for a surface.
    wlr_log(WLR_ERROR, "no control plane — LavaUI clients cannot connect");
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
