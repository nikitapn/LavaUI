#include <algorithm>
#include <cstdio>
#include <cstddef>
#include <fstream>
#include <sys/stat.h>
#include <linux/input-event-codes.h>  // BTN_RIGHT
#include <csignal>
#include <pthread.h>
#include <cstdlib>
#include <ctime>
#include <iostream>
#include <list>

#include "canvas_surface.hpp"
#include "config.hpp"
#include "decoration.hpp"
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

// ─── Foreign windows ───────────────────────────────────────────────────────

/// A window whose contents the compositor does not draw.
///
/// An xdg toplevel and an X11 window are the same shape from the frame's point
/// of view: something with a scene node, a size it can be asked to take, and a
/// way to be closed, activated and maximized. Everything around them — the
/// title bar, the stacking, the workspace, the drag — should not know which it
/// has, and this interface is what keeps that true. Adding X11 support without
/// it means writing the window management twice and watching the two copies
/// drift.
struct FramedWindow {
  virtual ~FramedWindow() = default;

  /// The scene node holding its pixels. Moving this moves the window.
  virtual wlr_scene_node *contentNode() = 0;
  /// The surface the seat focuses, or null while it is unmapped.
  virtual wlr_surface *focusSurface() = 0;

  /// "Please be this big." A request, not an instruction — see the frame's
  /// resize path, which adopts whatever the client actually commits.
  virtual void requestSize(uint32_t width, uint32_t height) = 0;
  /// "Please close." The client gets to argue, which killing it does not.
  virtual void requestClose() = 0;
  /// Draw yourself focused, or stop.
  virtual void activate(bool activated) = 0;
  /// Draw yourself maximized. Cosmetic — the compositor has already moved it.
  virtual void setMaximized(bool) {}
  /// Told where it ended up. A Wayland window never learns its own position
  /// and does not need this; an X11 client keeps its own copy and draws its
  /// menus against it, so one that is moved without being told puts them in
  /// the wrong place.
  virtual void placed(int, int, uint32_t, uint32_t) {}

  /// Which workspace it is on, and its frame, so the two stay in step.
  uint32_t workspace = 0;
  uint32_t frameId = 0;
};

// ─── Workspaces ────────────────────────────────────────────────────────────

/// The desktop's workspaces: one scene tree each, one of them enabled.
///
/// Switching is two calls to `wlr_scene_node_set_enabled` rather than moving
/// windows between parents. That is not only cheaper — re-parenting every node
/// on a switch dirties the scene wholesale and throws away the damage tracking
/// that makes a switch cost one frame — it also means a window keeps its
/// stacking order, its position and its buffer across a switch without anybody
/// having to remember them.
///
/// A window belongs to exactly one of these. A panel belongs to none: see
/// `panels` below.
struct Workspaces {
  /// Alt+1 … Alt+9. Nine because that is how many the keyboard offers without
  /// a second modifier, and a fixed set means switching never allocates.
  static constexpr uint32_t kCount = 9;

  wlr_scene_tree *tree[kCount] = {};
  /// Panels are not members of a workspace — a taskbar is on all of them — so
  /// this tree is never disabled. Created last, which is what puts panels above
  /// the windows without anybody raising them.
  wlr_scene_tree *panels = nullptr;
  uint32_t current = 0;

  void init(wlr_scene_tree *root) {
    for (auto *&t : tree) {
      t = wlr_scene_tree_create(root);
      wlr_scene_node_set_enabled(&t->node, false);
    }
    wlr_scene_node_set_enabled(&tree[current]->node, true);
    panels = wlr_scene_tree_create(root);
  }

  wlr_scene_tree *currentTree() const { return tree[current]; }
};

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

  /// Applies the config block for this connector: mode, scale, transform,
  /// position, enabled. Returns its entry in the output layout, or null if the
  /// config disabled it. Run again on reload, which is what makes changing a
  /// resolution not need a restart.
  wlr_output_layout_output *applyConfig();

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
struct Toplevel : FramedWindow {
  Server *server;
  wlr_xdg_toplevel *xdg_toplevel;
  wlr_scene_tree *scene_tree;

  Listener<Toplevel> map;
  Listener<Toplevel> unmap;
  Listener<Toplevel> commit;
  Listener<Toplevel> destroy;
  Listener<Toplevel> set_title;
  Listener<Toplevel> request_maximize;
  Listener<Toplevel> request_fullscreen;

  Toplevel(Server *server, wlr_xdg_toplevel *toplevel);
  ~Toplevel();

  /// What the client says its window is, in its own coordinates. Not the
  /// surface size: a client may draw shadows outside its window, and framing
  /// those would put the title bar a centimetre away from the window.
  void geometry(uint32_t &width, uint32_t &height) const;

  wlr_scene_node *contentNode() override { return &scene_tree->node; }
  wlr_surface *focusSurface() override { return xdg_toplevel->base->surface; }
  void requestSize(uint32_t width, uint32_t height) override {
    wlr_xdg_toplevel_set_size(xdg_toplevel, static_cast<int32_t>(width),
                              static_cast<int32_t>(height));
  }
  void requestClose() override { wlr_xdg_toplevel_send_close(xdg_toplevel); }
  void activate(bool activated) override {
    wlr_xdg_toplevel_set_activated(xdg_toplevel, activated);
  }
  void setMaximized(bool maximized) override {
    wlr_xdg_toplevel_set_maximized(xdg_toplevel, maximized);
  }

  static void on_map(wl_listener *listener, void *data);
  static void on_unmap(wl_listener *listener, void *data);
  static void on_commit(wl_listener *listener, void *data);
  static void on_destroy(wl_listener *listener, void *data);
  static void on_set_title(wl_listener *listener, void *data);
  static void on_request_maximize(wl_listener *listener, void *data);
  static void on_request_fullscreen(wl_listener *listener, void *data);
};

// ─── X11 windows ───────────────────────────────────────────────────────────

/// One X11 window, seen through XWayland.
///
/// X11 predates the idea that a window manager owns placement, so these arrive
/// already knowing where they want to be and how big — and they must be *told*
/// where they ended up, unlike a Wayland window which never learns its own
/// position. That is the whole difference in practice: the same frame, plus a
/// configure back to the client whenever the compositor moves it.
///
/// Two kinds arrive. Ordinary windows are framed like anything else.
/// Override-redirect ones — menus, tooltips, drag icons — have explicitly
/// asked the window manager to keep out; they are placed exactly where they
/// say and never decorated. Framing a dropdown menu is a classic way to make
/// an X11 application unusable.
struct XwaylandSurface : FramedWindow {
  Server *server;
  wlr_xwayland_surface *xsurface;
  wlr_scene_tree *scene_tree = nullptr;

  Listener<XwaylandSurface> associate;
  Listener<XwaylandSurface> dissociate;
  Listener<XwaylandSurface> map;
  Listener<XwaylandSurface> unmap;
  Listener<XwaylandSurface> destroy;
  Listener<XwaylandSurface> request_configure;
  Listener<XwaylandSurface> set_title;
  /// Whether `map`/`unmap` are attached. They can only be while a Wayland
  /// surface exists behind the X11 window, which is not its whole life.
  bool associated = false;

  XwaylandSurface(Server *server, wlr_xwayland_surface *surface);
  ~XwaylandSurface();

  bool overrideRedirect() const { return xsurface->override_redirect; }

  wlr_scene_node *contentNode() override { return &scene_tree->node; }
  wlr_surface *focusSurface() override { return xsurface->surface; }
  void requestSize(uint32_t width, uint32_t height) override {
    // X11 configures carry position as well as size, so both go every time —
    // there is no "resize only" request.
    wlr_xwayland_surface_configure(
        xsurface, static_cast<int16_t>(xsurface->x),
        static_cast<int16_t>(xsurface->y), static_cast<uint16_t>(width),
        static_cast<uint16_t>(height));
  }
  void requestClose() override { wlr_xwayland_surface_close(xsurface); }
  void activate(bool activated) override {
    wlr_xwayland_surface_activate(xsurface, activated);
  }
  /// Tells the client where it now is. Nothing else will: an X11 client keeps
  /// its own idea of its position and draws menus against it, so a window
  /// moved without being told puts its menus in the wrong place.
  void placed(int x, int y, uint32_t width, uint32_t height) override {
    wlr_xwayland_surface_configure(
        xsurface, static_cast<int16_t>(x), static_cast<int16_t>(y),
        static_cast<uint16_t>(width), static_cast<uint16_t>(height));
  }

  static void on_associate(wl_listener *listener, void *data);
  static void on_dissociate(wl_listener *listener, void *data);
  static void on_map(wl_listener *listener, void *data);
  static void on_unmap(wl_listener *listener, void *data);
  static void on_destroy(wl_listener *listener, void *data);
  static void on_request_configure(wl_listener *listener, void *data);
  static void on_set_title(wl_listener *listener, void *data);
};

// ─── Decoration negotiation ────────────────────────────────────────────────

/// One client's question: "who draws the title bar, you or me?"
///
/// Without an answer a client assumes it does, and the result is two title
/// bars — the compositor's, and the client's own drawn just below it. Saying
/// "server side" is what makes a window under this compositor look like the
/// others rather than like whichever toolkit it happens to use.
///
/// Answered when asked *and* when the decoration first appears, because a
/// client that never sends `set_mode` still needs telling.
struct ToplevelDecoration {
  wlr_xdg_toplevel_decoration_v1 *wlr;
  Listener<ToplevelDecoration> request_mode;
  Listener<ToplevelDecoration> commit;
  Listener<ToplevelDecoration> destroy;
  bool answered = false;

  explicit ToplevelDecoration(wlr_xdg_toplevel_decoration_v1 *decoration)
      : wlr(decoration) {
    request_mode.attach(&wlr->events.request_mode, this, on_request_mode);
    // A client creates the decoration object *before* its first commit, so at
    // this point the surface cannot be configured at all. Waiting for a commit
    // is the only reliable moment: a client that asked once, got no answer and
    // fell back to drawing its own is not going to ask again.
    commit.attach(&wlr->toplevel->base->surface->events.commit, this,
                  on_commit);
    destroy.attach(&wlr->events.destroy, this, on_destroy);
    apply();
  }
  ~ToplevelDecoration() {
    request_mode.detach();
    commit.detach();
    destroy.detach();
  }

  void apply() {
    // Configuring a surface that has not had its first commit is a protocol
    // error.
    if (answered || !wlr->toplevel->base->initialized) return;
    wlr_xdg_toplevel_decoration_v1_set_mode(
        wlr, WLR_XDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE);
    answered = true;
    wlr_log(WLR_INFO, "decoration: server side for '%s'",
            wlr->toplevel->app_id ? wlr->toplevel->app_id : "(none)");
  }

  static void on_request_mode(wl_listener *listener, void *) {
    owner_of<ToplevelDecoration>(listener)->apply();
  }
  static void on_commit(wl_listener *listener, void *) {
    owner_of<ToplevelDecoration>(listener)->apply();
  }
  static void on_destroy(wl_listener *listener, void *) {
    delete owner_of<ToplevelDecoration>(listener);
  }
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

  /// Compiles the configured layout and hands it to this keyboard. Called
  /// again on reload, which is what makes a layout change take effect without
  /// restarting — every client is sent the new keymap.
  void applyKeymap(const lava::KeyboardConfig &config);

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
  std::list<FramedWindow *> toplevels;
  /// Kept here because `wlr_seat` does not expose one, and seat capabilities
  /// have to be recomputed whenever a keyboard comes or goes.
  std::list<Keyboard *> keyboards;
  /// Every screen, so a config reload can re-apply itself to all of them.
  std::list<Output *> outputs;

  /// LavaUI client surfaces, and the channel their input goes back down.
  /// Both null until `main` builds them; a compositor without a control plane
  /// has neither, and every use below checks.
  SurfaceRegistry *surfaces = nullptr;
  lava::ControlPlane *control = nullptr;
  /// An interactive move or resize in progress, and what it started from.
  ///
  /// Alt+drag rather than window edges: there are no decorations to grab yet,
  /// and a modifier drag works anywhere in the window — which is also what
  /// most compositors offer as the keyboard-friendly alternative. Left moves,
  /// right resizes.
  enum class Drag { None, Move, Resize };
  Drag drag = Drag::None;
  uint32_t dragSurface = 0;
  double dragStartX = 0, dragStartY = 0;
  int dragOriginX = 0, dragOriginY = 0;
  uint32_t dragOriginW = 0, dragOriginH = 0;

  /// Carries an in-progress drag to the pointer. True if one was live, which
  /// is the caller's signal that the motion belongs to the drag and not to
  /// whatever is under the cursor.
  bool update_drag();

  /// Which client surface the keyboard goes to, per workspace, or 0.
  ///
  /// Separate from `wlr_seat`'s focus because a client surface is not a
  /// `wlr_surface` — it has no Wayland object for the seat to focus. Clicking
  /// one takes the keyboard away from any Wayland window, and clicking a
  /// Wayland window takes it back.
  ///
  /// Per workspace rather than one value, because a single one would survive a
  /// switch and leave the keyboard pointed at a window that is no longer on
  /// screen — every keystroke going somewhere the user cannot see.
  uint32_t focusedByWorkspace[Workspaces::kCount] = {};
  Workspaces workspaces;

  /// What the machine looks like: which GPU, which screens at which sizes,
  /// what the keyboard is. Re-read on SIGHUP — see `reload_config`.
  lava::Config config;
  std::string configPath;

  uint32_t focusedSurface() const {
    return focusedByWorkspace[workspaces.current];
  }
  void setFocusedSurface(uint32_t id) {
    focusedByWorkspace[workspaces.current] = id;
  }

  /// Re-reads the config file and applies what can be applied while running.
  ///
  /// This is as close to a hot reload as a Wayland compositor gets. The binary
  /// cannot be swapped underneath a running session — every client holds a
  /// socket to *this* process, and neither libwayland nor wlroots has a way to
  /// hand those over, so restarting is a logout. What a reload can change is
  /// everything the config file describes about the machine: screen modes,
  /// positions, scale, the keyboard layout.
  ///
  /// What it cannot change is which GPU is in use. That is decided when the
  /// backend is created, before any of this exists, and moving it would mean
  /// re-importing every buffer in the compositor.
  void reloadConfig();

  /// Shows workspace `index` and hands it the keyboard. A no-op if it is
  /// already current, so a repeated shortcut costs nothing.
  void switchWorkspace(uint32_t index);
  /// Sends whatever has the keyboard to workspace `index`, and stays put.
  void moveFocusedToWorkspace(uint32_t index);
  /// The front window of a workspace, or null if it has none.
  FramedWindow *frontToplevel(uint32_t workspace);

  Listener<Server> new_output;
  Listener<Server> new_toplevel;
  Listener<Server> new_decoration;
  Listener<Server> new_xwayland_surface;
  Listener<Server> xwayland_ready;
  wlr_xwayland *xwayland = nullptr;
  Listener<Server> new_input;
  Listener<Server> cursor_motion;
  Listener<Server> cursor_motion_absolute;
  Listener<Server> cursor_button;
  Listener<Server> cursor_axis;
  Listener<Server> cursor_frame;
  Listener<Server> request_cursor;
  Listener<Server> request_set_selection;
  Listener<Server> request_set_primary_selection;

  static void on_new_output(wl_listener *listener, void *data);
  static void on_new_toplevel(wl_listener *listener, void *data);
  static void on_new_decoration(wl_listener *listener, void *data);
  static void on_new_xwayland_surface(wl_listener *listener, void *data);
  static void on_xwayland_ready(wl_listener *listener, void *data);
  static void on_new_input(wl_listener *listener, void *data);
  static void on_cursor_motion(wl_listener *listener, void *data);
  static void on_cursor_motion_absolute(wl_listener *listener, void *data);
  static void on_cursor_button(wl_listener *listener, void *data);
  static void on_cursor_axis(wl_listener *listener, void *data);
  static void on_cursor_frame(wl_listener *listener, void *data);
  static void on_request_cursor(wl_listener *listener, void *data);
  static void on_request_set_selection(wl_listener *listener, void *data);
  static void on_request_set_primary_selection(wl_listener *listener,
                                               void *data);

  /// Deepest surface under a layout-space point, plus that point in the
  /// surface's own coordinates. Null when the cursor is over blank desktop.
  wlr_surface *surface_at(double lx, double ly, double *sx, double *sy,
                          Toplevel **out_toplevel);

  void focus(FramedWindow *window);
  void update_pointer_focus(uint32_t time_msec);
  void update_seat_capabilities();

  /// Sends one event to the client surface under the pointer.
  ///
  /// True when a surface took it, which is also the caller's signal not to
  /// hand the same event to a Wayland client: the two focus models are
  /// separate and an event belongs to exactly one of them.
  bool route_pointer(uint32_t kind, int32_t button, int32_t mods);
};

// ─── Client surfaces ───────────────────────────────────────────────────────
//
// One surface is one LavaUI client's window: a canvas render target whose
// pixels a client's arena drives, shown by a scene node like any other buffer.
// Clients ask for them over the control plane and the compositor grants —
// it does not open windows and hope somebody attaches. That is the direction
// Wayland itself runs in, and for the same reason: the process that knows a
// window is wanted is the one with something to put in it.

/// One client's window: its content, and the frame around it.
///
/// `x, y` is the *frame* origin — the top-left of the title bar. The content
/// sits one bar below it. Everything that moves a window moves both, which is
/// the only reason they are one struct rather than two surfaces that happen to
/// be near each other.
struct ClientSurface {
  uint32_t id = 0;
  std::string title;

  /// The contents, when they are a LavaUI draw list: null for a Wayland
  /// window, whose pixels arrive as its own surface instead.
  std::unique_ptr<lava::CanvasSurface> canvas;
  wlr_scene_buffer *node = nullptr;

  /// Set when the contents are an ordinary Wayland client.
  ///
  /// A window is framed the same either way — the title bar, the buttons, the
  /// geometry, which workspace it is on and where it sits in the stack are all
  /// the compositor's, and none of them care where the pixels came from. What
  /// differs is only how the middle is filled and how a resize is asked for:
  /// a LavaUI surface is told its new size and redraws, a Wayland client is
  /// *asked* and answers with a new buffer when it is ready.
  ///
  /// Sharing the frame is the whole point. Two parallel implementations of
  /// dragging a title bar is how the two kinds of window drift apart.
  FramedWindow *window = nullptr;
  bool isForeign() const { return window != nullptr; }

  /// The non-client area. Its own surface, so a title change redraws a strip
  /// rather than the window, and hit testing stays a rectangle comparison.
  std::unique_ptr<lava::CanvasSurface> bar;
  wlr_scene_buffer *barNode = nullptr;
  lava::DecorationHit hovered = lava::DecorationHit::Bar;

  int x = 0;
  int y = 0;
  uint32_t width = 0;
  uint32_t height = 0;

  /// Which workspace it is on. Assigned at creation, from whichever was
  /// current: `CreateSurface` has no say in it and should not — a client that
  /// could choose its workspace could also follow the user around.
  uint32_t workspace = 0;

  /// Panels have no frame and are laid out by their edge, not by the user.
  bool panel = false;
  /// Which edge, for a panel. Meaningless otherwise. Kept rather than inferred
  /// from the position, so the work area does not have to guess.
  uint32_t edge = 0;
  /// Whether windows should be laid out around this panel rather than under
  /// it. See `SurfaceRegistry::workArea`.
  bool reserve = false;

  /// Where a maximized window came from, so restoring is exact.
  bool maximized = false;
  int restoreX = 0;
  int restoreY = 0;
  uint32_t restoreW = 0;
  uint32_t restoreH = 0;

  /// Where the content starts, below the bar.
  int contentY() const {
    return panel ? y : y + lava::Decoration::kHeight;
  }

  /// Whether `lx, ly` (layout space) is inside the content, and where in it.
  bool hit(double lx, double ly, double &sx, double &sy) const {
    sx = lx - x;
    sy = ly - contentY();
    return sx >= 0 && sy >= 0 && sx < width && sy < height;
  }

  /// Whether `lx, ly` is on the title bar, and where along it.
  bool hitBar(double lx, double ly, double &sx, double &sy) const {
    if (panel) return false;
    sx = lx - x;
    sy = ly - y;
    return sx >= 0 && sy >= 0 && sx < width &&
           sy < lava::Decoration::kHeight;
  }
};

/// Every client surface, and the control plane's view of the compositor.
///
/// Implements `lava::CompositorHost`, so the servant calls land here — always
/// on the Wayland event loop thread, because the POA hops there first. Nothing
/// in this class takes a lock, and that is why.
class SurfaceRegistry : public lava::CompositorHost {
 public:
  void bind(lava::CanvasRenderer *renderer, Workspaces *workspaces) {
    renderer_ = renderer;
    workspaces_ = workspaces;
  }

  /// Arms the timer that carries renderer-owned animations along.
  void start(wl_event_loop *loop) {
    animation_ = wl_event_loop_add_timer(loop, on_animation, this);
  }
  void bind(lava::ControlPlane *control) { control_ = control; }

  ClientSurface *find(uint32_t id) {
    for (auto &s : surfaces_) {
      if (s->id == id) return s.get();
    }
    return nullptr;
  }

  /// Whether a surface is on screen right now.
  ///
  /// Every hit test goes through this. The scene graph already refuses to draw
  /// a disabled tree, but it cannot help the tests below — those walk our own
  /// list, and without this a window on another workspace would still take the
  /// pointer, invisibly, from underneath the one the user can see.
  bool visible(const ClientSurface &surface) const {
    return surface.panel || workspaces_ == nullptr ||
           surface.workspace == workspaces_->current;
  }

  /// Sends a window to another workspace.
  ///
  /// Re-parenting, which a switch deliberately avoids — but here the window is
  /// genuinely changing which tree it belongs to, and it happens once per
  /// keystroke rather than once per switch.
  void moveToWorkspace(ClientSurface &surface, uint32_t index) {
    if (workspaces_ == nullptr || index >= Workspaces::kCount) return;
    if (surface.panel || surface.workspace == index) return;
    surface.workspace = index;
    wlr_scene_node_reparent(&surface.node->node, workspaces_->tree[index]);
    if (surface.barNode != nullptr) {
      wlr_scene_node_reparent(&surface.barNode->node, workspaces_->tree[index]);
    }
    // The pointer is not going with it, so nothing on its frame is hovered any
    // more — and a button left lit would still be lit when it comes back.
    hoverBar(surface, lava::DecorationHit::Bar);
  }

  /// Updates every window's bar hover for a pointer at `lx, ly`.
  ///
  /// True when the pointer is over a bar, which is also the caller's signal to
  /// stop: a title bar is the compositor's and the window under it should not
  /// also see the motion.
  bool hoverFrames(double lx, double ly) {
    bool over = false;
    for (auto &surface : surfaces_) {
      if (!visible(*surface)) continue;
      double sx = 0, sy = 0;
      lava::DecorationHit hit = lava::DecorationHit::Bar;
      const bool on = !over && surface->hitBar(lx, ly, sx, sy);
      if (on) {
        hit = lava::Decoration::hitTest(static_cast<float>(sx),
                                        static_cast<float>(sy), surface->width);
        over = true;
      }
      // Windows the pointer is *not* over have their highlight cleared, which
      // is what stops a button staying lit after the cursor leaves it.
      hoverBar(*surface, on ? hit : lava::DecorationHit::Bar);
    }
    return over;
  }

  /// Topmost window whose bar is under a layout-space point.
  ClientSurface *frameAt(double lx, double ly, double &sx, double &sy) {
    for (auto &surface : surfaces_) {
      if (visible(*surface) && surface->hitBar(lx, ly, sx, sy)) {
        return surface.get();
      }
    }
    return nullptr;
  }

  /// Topmost *window* under a point, of either kind.
  ///
  /// Separate from `at` because the two questions differ: `at` asks "who
  /// should receive this pointer event", which a Wayland window answers
  /// through the seat instead; this asks "which window is here", which is what
  /// a compositor-level gesture like Alt+drag needs.
  ClientSurface *windowAt(double lx, double ly) {
    double sx = 0, sy = 0;
    for (auto &s : surfaces_) {
      if (s->panel || !visible(*s)) continue;
      if (s->hit(lx, ly, sx, sy) || s->hitBar(lx, ly, sx, sy)) return s.get();
    }
    return nullptr;
  }

  /// Topmost surface under a layout-space point. Front is most recent.
  ClientSurface *at(double lx, double ly, double &sx, double &sy) {
    for (auto &s : surfaces_) {
      // Wayland windows are deliberately absent: their pointer input goes
      // through the seat, to the client's own surface, and routing it here as
      // well would deliver every event twice.
      if (s->isForeign()) continue;
      if (visible(*s) && s->hit(lx, ly, sx, sy)) return s.get();
    }
    return nullptr;
  }

  bool empty() const { return surfaces_.empty(); }

  // ─── CompositorHost ──────────────────────────────────────────────────────

  int registerFont(const std::string &path, float pixelSize) override {
    // Straight to the device, which exists before any surface does — that is
    // the whole reason the renderer and the surfaces are separate objects.
    // The atlas is device-wide, so a face registered by one client is already
    // rasterised for the next, and the id means the same thing to both.
    return renderer_ ? renderer_->registerFont(path, pixelSize) : -1;
  }

  uint32_t createSurface(const std::string &arenaId, uint32_t width,
                         uint32_t height, const std::string &title) override {
    if (workspaces_ == nullptr) return 0;
    // On whichever workspace is current, because that is where the user was
    // when they asked for it.
    return openSurface(arenaId, width, height, title,
                       workspaces_->currentTree(), workspaces_->current);
  }

  /// Frames a Wayland window: a title bar, a place in the stack, a workspace.
  ///
  /// Everything an ordinary application gets from this compositor comes from
  /// here. Without it a toplevel sits at the scene origin forever, because a
  /// Wayland client cannot place its own window and nothing else would.
  uint32_t adoptWindow(FramedWindow *window, const std::string &title,
                       uint32_t width, uint32_t height, bool decorated = true);

  /// A Wayland client committed at a new size.
  ///
  /// The frame follows the window rather than the other way round: a resize is
  /// a request, and the client is the authority on what it settled at.
  void toplevelResized(ClientSurface &surface, uint32_t width,
                       uint32_t height) {
    if (width == surface.width && height == surface.height) return;
    surface.width = width;
    surface.height = height;
    if (surface.bar &&
        surface.bar->resize(width, lava::Decoration::kHeight)) {
      wlr_scene_buffer_set_buffer(surface.barNode, surface.bar->buffer());
    }
    drawBar(surface);
  }

  void setTitle(ClientSurface &surface, const std::string &title) {
    if (surface.title == title) return;
    surface.title = title;
    drawBar(surface);
  }

  /// Brings a window to the front of its workspace, frame and all.
  ///
  /// The bar after the contents, or focusing a window would raise its own
  /// title bar out from under it — they are siblings in one tree, and "on top"
  /// is decided by order alone.
  void raise(ClientSurface &surface) {
    if (surface.panel) return;  // already above everything, by its own tree
    if (surface.isForeign()) {
      wlr_scene_node_raise_to_top(surface.window->contentNode());
    } else if (surface.node != nullptr) {
      wlr_scene_node_raise_to_top(&surface.node->node);
    }
    if (surface.barNode != nullptr) {
      wlr_scene_node_raise_to_top(&surface.barNode->node);
    }
    // Front of the list is front of the stack, and the two must not disagree:
    // the hit tests walk this list and would otherwise answer with a window
    // that is visibly behind another.
    for (auto it = surfaces_.begin(); it != surfaces_.end(); ++it) {
      if (it->get() != &surface) continue;
      auto owned = std::move(*it);
      surfaces_.erase(it);
      surfaces_.push_front(std::move(owned));
      return;
    }
  }

  /// Puts both of a window's nodes where its frame origin says they go.
  void place(ClientSurface &surface) {
    if (surface.barNode != nullptr) {
      wlr_scene_node_set_position(&surface.barNode->node, surface.x, surface.y);
    }
    if (surface.isForeign()) {
      wlr_scene_node_set_position(surface.window->contentNode(), surface.x,
                                  surface.contentY());
      surface.window->placed(surface.x, surface.contentY(), surface.width,
                             surface.height);
    } else if (surface.node != nullptr) {
      wlr_scene_node_set_position(&surface.node->node, surface.x,
                                  surface.contentY());
    }
  }

  /// Moves a window. Both nodes, because a frame and its content are one
  /// window and only ever move together.
  void moveSurface(ClientSurface &surface, int x, int y) {
    surface.x = x;
    surface.y = y;
    place(surface);
  }

  /// Fills the output, or goes back to where it was.
  ///
  /// The previous frame is remembered rather than recomputed, so restoring
  /// puts a window back exactly where the user left it.
  void toggleMaximize(ClientSurface &surface) {
    if (surface.maximized) {
      moveSurface(surface, surface.restoreX, surface.restoreY);
      resizeSurface(surface, surface.restoreW, surface.restoreH);
      surface.maximized = false;
      return;
    }
    if (outputWidth_ == 0 || outputHeight_ == 0) return;
    surface.restoreX = surface.x;
    surface.restoreY = surface.y;
    surface.restoreW = surface.width;
    surface.restoreH = surface.height;
    fillWorkArea(surface);
    surface.maximized = true;
  }

  /// Spreads a window over everything a panel has not claimed.
  ///
  /// The work area, not the output: a maximized window that covered the panel
  /// would hide the one thing on screen meant to always be reachable.
  void fillWorkArea(ClientSurface &surface) {
    const WorkArea area = workArea();
    moveSurface(surface, area.x, area.y);
    resizeSurface(surface, area.width,
                  area.height > lava::Decoration::kHeight
                      ? area.height - lava::Decoration::kHeight
                      : area.height);
  }

  /// Puts a panel back on its edge, at the full length of that edge.
  void layoutPanel(ClientSurface &panel) {
    const bool horizontal =
        panel.edge == kPanelTop || panel.edge == kPanelBottom;
    // A panel chose only its thickness; the length is the screen's to decide.
    const uint32_t thickness = horizontal ? panel.height : panel.width;
    resizeSurface(panel, horizontal ? outputWidth_ : thickness,
                  horizontal ? thickness : outputHeight_);
    moveSurface(panel,
                panel.edge == kPanelRight
                    ? static_cast<int>(outputWidth_) -
                          static_cast<int>(thickness)
                    : 0,
                panel.edge == kPanelBottom
                    ? static_cast<int>(outputHeight_) -
                          static_cast<int>(thickness)
                    : 0);
  }

  /// How big the screen is. Told by the output, since a surface registry has
  /// no other way to know — and told *again* whenever it changes, which is not
  /// hypothetical: nested in another compositor, the first size is a default
  /// that is replaced within a frame or two of the window appearing.
  void setOutputSize(uint32_t width, uint32_t height) {
    if (width == outputWidth_ && height == outputHeight_) return;
    outputWidth_ = width;
    outputHeight_ = height;
    // Panels first: every one of them spans an edge that just changed length,
    // and the work area is measured from where they end up.
    for (auto &surface : surfaces_) {
      if (surface->panel) layoutPanel(*surface);
    }
    for (auto &surface : surfaces_) {
      if (!surface->panel && surface->maximized) fillWorkArea(*surface);
    }
  }

  /// Redraws the title bar. Cheap — a strip, from commands built here.
  void drawBar(ClientSurface &surface) {
    if (!surface.bar) return;
    decoration_.build(surface.title, surface.width, surface.hovered,
                      surface.id == focused_);
    if (surface.bar->renderList(decoration_.commands(), decoration_.glyphs())) {
      wlr_scene_buffer_set_buffer_with_damage(surface.barNode,
                                              surface.bar->buffer(), nullptr);
    }
  }

  /// Which window's bar is drawn as active. Not the seat's focus: a client
  /// surface is not a `wlr_surface` and the seat has no object for it.
  void setFocused(uint32_t id) {
    if (focused_ == id) return;
    const uint32_t previous = focused_;
    focused_ = id;
    if (ClientSurface *was = find(previous)) drawBar(*was);
    if (ClientSurface *now = find(id)) drawBar(*now);
  }

  /// Lights whichever control is under the pointer. True if it changed.
  bool hoverBar(ClientSurface &surface, lava::DecorationHit hit) {
    if (surface.hovered == hit) return false;
    surface.hovered = hit;
    drawBar(surface);
    return true;
  }

  /// Loads the face titles are drawn in, and registers it for the atlas.
  void initDecoration(const std::string &fontPath, float pixelSize) {
    if (!decoration_.loadFont(fontPath, pixelSize)) {
      wlr_log(WLR_ERROR, "decoration: no title face at '%s'", fontPath.c_str());
      return;
    }
    const int id = registerFont(fontPath, pixelSize);
    if (id >= 0) decoration_.setFontId(static_cast<uint32_t>(id));
  }

  /// Resizes a surface and hands the scene its new buffer.
  ///
  /// Always a new buffer: a dmabuf's size and stride are fixed when it is
  /// allocated, so the scene node has to be pointed at a different one rather
  /// than told the old one changed shape.
  void resizeSurface(ClientSurface &surface, uint32_t width, uint32_t height) {
    // A floor, because zero is not a size and a drag can cross the origin.
    // Panels are exempt: a 32-pixel strip is a perfectly good panel, and there
    // is no drag that could shrink one by accident.
    const uint32_t floor = surface.panel ? 1u : kMinSurface;
    width = width < floor ? floor : width;
    height = height < floor ? floor : height;

    if (surface.isForeign()) {
      // Asked, not told. A client is sent a size and answers with a
      // buffer when it is ready — possibly at a different size, if it has a
      // minimum or snaps to a character cell like a terminal does. The frame
      // takes the requested size now so the bar tracks the drag, and adopts
      // whatever the client actually commits.
      surface.window->requestSize(width, height);
      surface.width = width;
      surface.height = height;
      if (surface.bar &&
          surface.bar->resize(width, lava::Decoration::kHeight)) {
        wlr_scene_buffer_set_buffer(surface.barNode, surface.bar->buffer());
      }
      drawBar(surface);
      return;
    }

    if (!surface.canvas->resize(width, height)) return;
    surface.width = width;
    surface.height = height;
    wlr_scene_buffer_set_buffer(surface.node, surface.canvas->buffer());
    // The bar spans the window, so it follows every width change.
    if (surface.bar && surface.bar->resize(width, lava::Decoration::kHeight)) {
      wlr_scene_buffer_set_buffer(surface.barNode, surface.bar->buffer());
    }
    drawBar(surface);
    // The `Resize` the surface just queued for its client is sitting in the
    // renderer's queue; this is what forwards it, and what redraws the frame
    // already held into the new extent meanwhile.
    pump(surface);
    if (surface.canvas->redraw()) damage(surface);
  }

  uint32_t createPanel(const std::string &arenaId, uint32_t edge,
                       uint32_t thickness, bool reserve,
                       const std::string &title) override {
    if (outputWidth_ == 0 || outputHeight_ == 0 || workspaces_ == nullptr) {
      wlr_log(WLR_ERROR, "panel: no output yet");
      return 0;
    }
    // A panel is given the length of its edge and chooses only its thickness.
    const bool horizontal = edge == kPanelTop || edge == kPanelBottom;
    const uint32_t w = horizontal ? outputWidth_ : thickness;
    const uint32_t h = horizontal ? thickness : outputHeight_;

    // Into the panel tree, which no workspace switch ever disables — a taskbar
    // that vanished on Alt+2 would be a strange sort of taskbar.
    const uint32_t id =
        openSurface(arenaId, w, h, title, workspaces_->panels, 0);
    if (id == 0) return 0;
    ClientSurface *panel = find(id);
    panel->panel = true;
    panel->edge = edge;
    panel->reserve = reserve;

    // No title bar: there is nothing to drag, close or maximize. Dropped
    // rather than hidden, so no hit test has to remember it is not there.
    if (panel->barNode != nullptr) {
      wlr_scene_node_destroy(&panel->barNode->node);
      panel->barNode = nullptr;
    }
    panel->bar.reset();

    layoutPanel(*panel);
    // Above ordinary windows, which is what "panel" mostly means to a user.
    wlr_scene_node_raise_to_top(&panel->node->node);
    wlr_log(WLR_INFO, "panel %u: '%s' on edge %u, %u deep%s", id, title.c_str(),
            edge, thickness, reserve ? ", reserving" : "");
    return id;
  }

  bool destroySurface(uint32_t id) override {
    for (auto it = surfaces_.begin(); it != surfaces_.end(); ++it) {
      if ((*it)->id != id) continue;
      // A Wayland window's contents are not ours to destroy — the scene tree
      // belongs to its `Toplevel`, which outlives the frame across an unmap.
      // Only the decoration we added comes down with it.
      if (!(*it)->isForeign() && (*it)->node != nullptr) {
        wlr_scene_node_destroy(&(*it)->node->node);
      }
      if ((*it)->barNode) wlr_scene_node_destroy(&(*it)->barNode->node);
      if ((*it)->isForeign()) (*it)->window->frameId = 0;
      surfaces_.erase(it);
      if (control_) control_->surfaceGone(id);
      wlr_log(WLR_INFO, "surface %u: gone", id);
      return true;
    }
    return false;
  }

  /// Politely, for a Wayland window: a client that is asked to close gets to
  /// put up its "save your work?" dialog, which killing it does not.
  void requestClose(ClientSurface &surface) {
    if (surface.isForeign()) {
      surface.window->requestClose();
      return;
    }
    // A LavaUI client learns its window is gone by its stream ending — see
    // `SubscribeInput`. There is nothing to ask.
    destroySurface(surface.id);
  }

  bool surfaceExists(uint32_t id) const override {
    for (const auto &s : surfaces_) {
      if (s->id == id) return true;
    }
    return false;
  }

  /// Hands the renderer's conclusions to the client, and redraws the surface
  /// if the renderer changed something on its own.
  ///
  /// Called after every input event. The events that come out are the raw one
  /// plus whatever the scene decided — `NodeHover`, `NodeScroll`,
  /// `NodeAnimationDone` — which is what makes a hover cost no round trip and
  /// a scroll survive a stopped client.
  void pump(ClientSurface &surface) {
    if (!surface.canvas) return;  // a Wayland window draws itself
    drain(surface);
    if (!surface.canvas->takeInternalRepaint()) return;
    if (surface.canvas->redraw()) damage(surface);
    // The redraw steps the scene, which may itself have produced events and
    // may want another frame.
    drain(surface);
    animate();
  }

  /// Hands the renderer's conclusions to the client.
  void drain(ClientSurface &surface) {
    if (control_ == nullptr || !surface.canvas) return;
    canvas::InputEvent event{};
    while (surface.canvas->pollEvent(event)) {
      control_->postInput(surface.id, event.kind, event.x, event.y,
                          event.button, event.mods);
    }
  }

  /// Keeps drawing while the renderer has something in flight of its own.
  ///
  /// A hover tint is *eased* in, not switched on — a highlight that appears
  /// between two frames reads as a flicker at the speed a pointer actually
  /// crosses a list. So the frame that answers a hover is the first of
  /// several, and nothing else will ask for the rest: the client published no
  /// new frame and does not know a fade is happening. Drawing once and
  /// stopping is what "clicks work but there is no hover" looks like.
  void animate() {
    if (animation_ != nullptr) wl_event_source_timer_update(animation_, kFrameMs);
  }

  /// Tells wlroots the surface's contents changed. Same buffer, so without
  /// this it keeps showing the texture it already uploaded.
  void damage(ClientSurface &surface) {
    if (!surface.canvas) return;
    wlr_scene_buffer_set_buffer_with_damage(surface.node,
                                            surface.canvas->buffer(), nullptr);
  }

  void present(uint32_t id) override {
    ClientSurface *surface = find(id);
    if (surface == nullptr || !surface->canvas) return;
    if (!surface->canvas->renderFromArena()) return;
    damage(*surface);
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
    if (surface == nullptr || !surface->canvas) return;
    surface->canvas->scrollUnclaimed(dx, dy);
  }

  bool captureSurface(uint32_t id, int32_t x, int32_t y, int32_t w, int32_t h,
                      int32_t maxSide, std::vector<uint8_t> &outPng,
                      uint32_t &outW, uint32_t &outH) override {
    ClientSurface *surface = find(id);
    if (surface == nullptr || !surface->canvas) return false;
    return surface->canvas->capturePng(x, y, w, h, maxSide, outPng, outW, outH);
  }

 public:
  /// What is left of the output once reserving panels have taken their strip.
  struct WorkArea {
    int x = 0;
    int y = 0;
    uint32_t width = 0;
    uint32_t height = 0;
  };

  /// Where a window may go without being covered by a panel.
  ///
  /// Computed rather than cached, because it changes whenever a panel opens,
  /// closes or the output is resized, and there is no signal for the last one.
  /// A panel that did not ask to `reserve` is not in here — it floats over the
  /// windows, which is what a dock usually wants.
  WorkArea workArea() const {
    int x = 0;
    int y = 0;
    int w = static_cast<int>(outputWidth_);
    int h = static_cast<int>(outputHeight_);
    for (const auto &s : surfaces_) {
      if (!s->panel || !s->reserve) continue;
      // A panel is flush against its edge and spans it, so its thickness is
      // the only measurement that matters.
      switch (s->edge) {
        case kPanelTop:
          y += static_cast<int>(s->height);
          h -= static_cast<int>(s->height);
          break;
        case kPanelBottom:
          h -= static_cast<int>(s->height);
          break;
        case kPanelLeft:
          x += static_cast<int>(s->width);
          w -= static_cast<int>(s->width);
          break;
        case kPanelRight:
          w -= static_cast<int>(s->width);
          break;
        default:
          break;
      }
    }
    // Panels thicker than the screen are a client's mistake, not a reason to
    // hand back a negative extent.
    const int floor = static_cast<int>(kMinSurface);
    return {x, y, static_cast<uint32_t>(w < floor ? floor : w),
            static_cast<uint32_t>(h < floor ? floor : h)};
  }

 private:
  /// The shared half of `createSurface` and `createPanel`: everything except
  /// which tree the nodes go in and which workspace owns them.
  uint32_t openSurface(const std::string &arenaId, uint32_t width,
                       uint32_t height, const std::string &title,
                       wlr_scene_tree *parent, uint32_t workspace) {
    if (renderer_ == nullptr || parent == nullptr) return 0;
    auto surface = std::make_unique<ClientSurface>();
    surface->canvas = renderer_->createSurface(width, height);
    if (!surface->canvas) return 0;
    if (!surface->canvas->attachArena(arenaId)) {
      // The client creates the arena and the compositor attaches, so this
      // means the client asked before it had somewhere to draw.
      return 0;
    }
    surface->id = nextId_++;
    surface->width = width;
    surface->height = height;
    surface->workspace = workspace;
    // Cascaded from the work area, so a second client is visible rather than
    // exactly on top of the first, and the first is not under the panel.
    // Counted per workspace, so each one starts its own cascade. A real layout
    // policy belongs with window management.
    int peers = 0;
    for (const auto &s : surfaces_) {
      if (!s->panel && s->workspace == workspace) ++peers;
    }
    const WorkArea area = workArea();
    surface->x = area.x + 40 + peers * 40;
    surface->y = area.y + 40 + peers * 40;

    surface->title = title;
    surface->bar = renderer_->createSurface(width, lava::Decoration::kHeight);
    if (!surface->bar) return 0;

    surface->node = wlr_scene_buffer_create(parent, surface->canvas->buffer());
    surface->barNode = wlr_scene_buffer_create(parent, surface->bar->buffer());
    if (surface->node == nullptr || surface->barNode == nullptr) return 0;
    place(*surface);
    drawBar(*surface);

    const uint32_t id = surface->id;
    surfaces_.push_front(std::move(surface));
    wlr_log(WLR_INFO, "surface %u: '%s' %ux%u on arena '%s'", id, title.c_str(),
            width, height, arenaId.c_str());
    return id;
  }

  /// Front is topmost. See `raise`, which is what keeps this in step with the
  /// scene graph's own order.
  std::list<std::unique_ptr<ClientSurface>> surfaces_;
  /// The one canvas device. Every surface is a window on it, sharing its
  /// glyph atlas and texture cache.
  lava::CanvasRenderer *renderer_ = nullptr;
  Workspaces *workspaces_ = nullptr;
  lava::ControlPlane *control_ = nullptr;
  lava::Decoration decoration_;
  /// Whose bar is drawn active.
  uint32_t focused_ = 0;
  uint32_t outputWidth_ = 0;
  uint32_t outputHeight_ = 0;
  /// Never reused, so a stale id from a closed surface fails to resolve rather
  /// than quietly addressing whatever opened next.
  uint32_t nextId_ = 1;

  /// Matches `PanelEdge` in the IDL, which is the authority. Named here so
  /// the compositor does not have to include the generated header just to
  /// compare an integer.
  static constexpr uint32_t kPanelTop = 0;
  static constexpr uint32_t kPanelBottom = 1;
  static constexpr uint32_t kPanelLeft = 2;
  static constexpr uint32_t kPanelRight = 3;

  /// Smaller than this and a window is not a window — and a drag that crosses
  /// its own origin would otherwise ask for a zero-sized buffer.
  static constexpr uint32_t kMinSurface = 120;

  /// One frame at ~60Hz, and only while something is actually animating —
  /// re-armed from `on_animation` rather than left running.
  static constexpr int kFrameMs = 16;
  wl_event_source *animation_ = nullptr;

  static int on_animation(void *data) {
    auto *self = static_cast<SurfaceRegistry *>(data);
    bool again = false;
    for (auto &surface : self->surfaces_) {
      if (!surface->canvas) continue;
      if (!surface->canvas->takeInternalRepaint()) continue;
      if (surface->canvas->redraw()) self->damage(*surface);
      self->drain(*surface);
      again = true;
    }
    // Re-armed only while something wanted this frame. An idle desktop stops
    // asking, which is the difference between an animation and a busy loop.
    if (again) self->animate();
    return 0;
  }
};


uint32_t SurfaceRegistry::adoptWindow(FramedWindow *window,
                                     const std::string &title, uint32_t width,
                                     uint32_t height, bool decorated) {
  if (workspaces_ == nullptr) return 0;
  auto surface = std::make_unique<ClientSurface>();
  surface->id = nextId_++;
  surface->window = window;
  surface->title = title.empty() ? "Untitled" : title;
  surface->width = width < kMinSurface ? kMinSurface : width;
  surface->height = height < kMinSurface ? kMinSurface : height;
  surface->workspace = window->workspace;

  int peers = 0;
  for (const auto &other : surfaces_) {
    if (!other->panel && other->workspace == surface->workspace) ++peers;
  }
  const WorkArea area = workArea();
  surface->x = area.x + 40 + peers * 40;
  surface->y = area.y + 40 + peers * 40;

  // A client's default size knows nothing about this monitor — alacritty
  // opens at 1100 wide whether or not the screen is that big. Asked to fit,
  // leaving room for the frame and the cascade it was just placed at.
  const uint32_t fitW = area.width > 80 ? area.width - 80 : area.width;
  const uint32_t fitH = area.height > 80 + lava::Decoration::kHeight
                            ? area.height - 80 - lava::Decoration::kHeight
                            : area.height;
  if (surface->width > fitW || surface->height > fitH) {
    surface->width = std::min(surface->width, fitW);
    surface->height = std::min(surface->height, fitH);
    window->requestSize(surface->width, surface->height);
  }

  // Undecorated if there is no canvas device to draw a bar with. The window
  // still gets a position and a workspace, which is most of what it needed.
  if (renderer_ != nullptr && decorated) {
    surface->bar =
        renderer_->createSurface(surface->width, lava::Decoration::kHeight);
    if (surface->bar) {
      surface->barNode = wlr_scene_buffer_create(
          workspaces_->tree[surface->workspace], surface->bar->buffer());
    }
  }

  const uint32_t id = surface->id;
  window->frameId = id;
  place(*surface);
  drawBar(*surface);
  surfaces_.push_front(std::move(surface));
  wlr_log(WLR_INFO, "window %u: '%s' %ux%u on workspace %u", id, title.c_str(),
          surfaces_.front()->width, surfaces_.front()->height,
          window->workspace + 1);
  return id;
}

// ─── X11 windows ───────────────────────────────────────────────────────────

XwaylandSurface::XwaylandSurface(Server *server, wlr_xwayland_surface *surface)
    : server(server), xsurface(surface) {
  workspace = server->workspaces.current;
  // An X11 window exists before it has any Wayland surface behind it, and may
  // outlive several. `associate` is when one appears, and the only point at
  // which map and unmap can be listened for.
  associate.attach(&xsurface->events.associate, this, on_associate);
  dissociate.attach(&xsurface->events.dissociate, this, on_dissociate);
  destroy.attach(&xsurface->events.destroy, this, on_destroy);
  request_configure.attach(&xsurface->events.request_configure, this,
                           on_request_configure);
  set_title.attach(&xsurface->events.set_title, this, on_set_title);
}

XwaylandSurface::~XwaylandSurface() {
  if (associated) on_dissociate(&dissociate.listener, nullptr);
  associate.detach();
  dissociate.detach();
  destroy.detach();
  request_configure.detach();
  set_title.detach();
}

void XwaylandSurface::on_associate(wl_listener *listener, void *) {
  auto *self = owner_of<XwaylandSurface>(listener);
  if (self->associated) return;
  self->map.attach(&self->xsurface->surface->events.map, self, on_map);
  self->unmap.attach(&self->xsurface->surface->events.unmap, self, on_unmap);
  self->associated = true;
}

void XwaylandSurface::on_dissociate(wl_listener *listener, void *) {
  auto *self = owner_of<XwaylandSurface>(listener);
  if (!self->associated) return;
  self->map.detach();
  self->unmap.detach();
  self->associated = false;
}

void XwaylandSurface::on_map(wl_listener *listener, void *) {
  auto *self = owner_of<XwaylandSurface>(listener);
  Server *server = self->server;
  self->workspace = server->workspaces.current;
  self->scene_tree = wlr_scene_subsurface_tree_create(
      server->workspaces.currentTree(), self->xsurface->surface);
  if (self->scene_tree == nullptr) return;

  const char *title = self->xsurface->title;

  if (self->overrideRedirect()) {
    // A menu, a tooltip, a drag icon. It has asked the window manager to keep
    // out, and it means it: placed exactly where it says, never framed, and
    // never given the keyboard by us — the application manages that itself.
    wlr_scene_node_set_position(&self->scene_tree->node, self->xsurface->x,
                                self->xsurface->y);
    wlr_scene_node_raise_to_top(&self->scene_tree->node);
    return;
  }

  server->toplevels.push_front(self);
  if (server->surfaces != nullptr) {
    const uint32_t width = self->xsurface->width > 0
                               ? static_cast<uint32_t>(self->xsurface->width)
                               : 0;
    const uint32_t height = self->xsurface->height > 0
                                ? static_cast<uint32_t>(self->xsurface->height)
                                : 0;
    const uint32_t id = server->surfaces->adoptWindow(
        self, title ? title : "", width, height);
    if (ClientSurface *frame = server->surfaces->find(id)) {
      server->surfaces->raise(*frame);
    }
  }
  server->focus(self);
  server->setFocusedSurface(0);
  wlr_log(WLR_INFO, "x11 window mapped: class=%s title=%s",
          self->xsurface->xclass ? self->xsurface->xclass : "(none)",
          title ? title : "(none)");
}

void XwaylandSurface::on_unmap(wl_listener *listener, void *) {
  auto *self = owner_of<XwaylandSurface>(listener);
  Server *server = self->server;
  server->toplevels.remove(self);
  if (self->frameId != 0 && server->surfaces != nullptr) {
    server->surfaces->destroySurface(self->frameId);
  }
  if (self->scene_tree != nullptr) {
    wlr_scene_node_destroy(&self->scene_tree->node);
    self->scene_tree = nullptr;
  }
  server->update_pointer_focus(0);
}

void XwaylandSurface::on_destroy(wl_listener *listener, void *) {
  delete owner_of<XwaylandSurface>(listener);
}

void XwaylandSurface::on_request_configure(wl_listener *listener, void *data) {
  auto *self = owner_of<XwaylandSurface>(listener);
  auto *event = static_cast<wlr_xwayland_surface_configure_event *>(data);

  // Before it is framed — or if it never will be — the client's own idea of
  // where it goes is the only one there is, so it gets exactly what it asked
  // for. Refusing here is how X11 splash screens end up in the corner.
  ClientSurface *frame =
      self->frameId != 0 && self->server->surfaces != nullptr
          ? self->server->surfaces->find(self->frameId)
          : nullptr;
  if (frame == nullptr) {
    wlr_xwayland_surface_configure(self->xsurface, event->x, event->y,
                                   event->width, event->height);
    return;
  }
  // Framed: the size is the client's to ask for, the position is not.
  self->server->surfaces->resizeSurface(*frame, event->width, event->height);
}

void XwaylandSurface::on_set_title(wl_listener *listener, void *) {
  auto *self = owner_of<XwaylandSurface>(listener);
  if (self->frameId == 0 || self->server->surfaces == nullptr) return;
  if (ClientSurface *frame = self->server->surfaces->find(self->frameId)) {
    self->server->surfaces->setTitle(
        *frame, self->xsurface->title ? self->xsurface->title : "Untitled");
  }
}

// ─── Output ────────────────────────────────────────────────────────────────

/// Everything a monitor can tell us about itself, in the log.
///
/// This is how anybody finds the connector name to put in a config file, and
/// what modes it will actually accept — guessing either is the difference
/// between a screen that lights up and one that stays dark with no clue why.
void describe_output(wlr_output *output) {
  wlr_log(WLR_INFO, "output %s: %s %s %s (%dmm x %dmm)", output->name,
          output->make ? output->make : "?",
          output->model ? output->model : "?",
          output->serial ? output->serial : "",
          output->phys_width, output->phys_height);
  wlr_output_mode *mode = nullptr;
  wl_list_for_each(mode, &output->modes, link) {
    wlr_log(WLR_INFO, "  mode %dx%d@%.3fHz%s", mode->width, mode->height,
            mode->refresh / 1000.0, mode->preferred ? " (preferred)" : "");
  }
  if (wl_list_empty(&output->modes)) {
    // Nested and headless backends have no mode list — they take any size.
    wlr_log(WLR_INFO, "  no fixed modes; any size accepted");
  }
}

/// The mode nearest what the config asked for, or null to use the preferred.
///
/// Nearest rather than exact on the refresh rate, because a rate is written in
/// the config as a human reads it off a box — "144" — and the mode is really
/// 143.998Hz. Exact matching would reject the mode the user obviously meant.
wlr_output_mode *pick_mode(wlr_output *output, const lava::OutputConfig *cfg) {
  if (cfg == nullptr || !cfg->hasMode()) return wlr_output_preferred_mode(output);
  wlr_output_mode *best = nullptr;
  int32_t bestDelta = 0;
  wlr_output_mode *mode = nullptr;
  wl_list_for_each(mode, &output->modes, link) {
    if (mode->width != cfg->width || mode->height != cfg->height) continue;
    // No rate asked for means the fastest one at that size.
    const int32_t delta =
        cfg->refresh == 0 ? -mode->refresh
                          : std::abs(mode->refresh - cfg->refresh);
    if (best == nullptr || delta < bestDelta) {
      best = mode;
      bestDelta = delta;
    }
  }
  return best;
}

Output::Output(Server *server, wlr_output *output)
    : server(server), wlr(output),
      scene_output(wlr_scene_output_create(server->scene, output)) {
  frame.attach(&wlr->events.frame, this, on_frame);
  request_state.attach(&wlr->events.request_state, this, on_request_state);
  destroy.attach(&wlr->events.destroy, this, on_destroy);

  wlr_output_init_render(wlr, server->allocator, server->renderer);
  describe_output(wlr);
  server->outputs.push_back(this);

  if (wlr_output_layout_output *layout_output = applyConfig()) {
    // Once only: the scene follows the layout from here, so a later reload
    // that moves the output does not need to say so twice.
    wlr_scene_output_layout_add_output(server->scene_layout, layout_output,
                                       scene_output);
  }
}

wlr_output_layout_output *Output::applyConfig() {
  const lava::OutputConfig *cfg = server->config.forOutput(wlr->name);

  wlr_output_state state;
  wlr_output_state_init(&state);
  wlr_output_state_set_enabled(&state, cfg == nullptr || cfg->enabled);

  if (wlr_output_mode *mode = pick_mode(wlr, cfg)) {
    wlr_output_state_set_mode(&state, mode);
  } else if (cfg != nullptr && cfg->hasMode()) {
    // No mode matched. Ask for it anyway as a custom mode: on a nested or
    // headless backend there is no mode list at all and this is the only way
    // to set a size, and on real hardware a rejected commit is a clearer
    // failure than silently running at something else.
    wlr_log(WLR_INFO, "output %s: no mode %dx%d, asking for it directly",
            wlr->name, cfg->width, cfg->height);
    wlr_output_state_set_custom_mode(&state, cfg->width, cfg->height,
                                     cfg->refresh);
  }
  if (cfg != nullptr && cfg->scale > 0.0) {
    wlr_output_state_set_scale(&state, static_cast<float>(cfg->scale));
  }
  if (cfg != nullptr) {
    wlr_output_state_set_transform(
        &state, static_cast<wl_output_transform>(cfg->transform));
  }

  if (!wlr_output_commit_state(wlr, &state)) {
    // Falling back rather than giving up: a bad line in a config file should
    // cost the resolution, not the session — with no screen there is no way
    // left to fix the config.
    wlr_log(WLR_ERROR, "output %s: configuration rejected, using preferred",
            wlr->name);
    wlr_output_state_finish(&state);
    wlr_output_state_init(&state);
    wlr_output_state_set_enabled(&state, true);
    if (auto *mode = wlr_output_preferred_mode(wlr)) {
      wlr_output_state_set_mode(&state, mode);
    }
    wlr_output_commit_state(wlr, &state);
  }
  wlr_output_state_finish(&state);

  if (cfg != nullptr && !cfg->enabled) {
    wlr_log(WLR_INFO, "output %s: disabled by config", wlr->name);
    wlr_output_layout_remove(server->output_layout, wlr);
    return nullptr;
  }

  // Placed where the config says, or strung left to right after the outputs
  // already there. `add_auto` is right for one screen and a guess for two.
  wlr_output_layout_output *layout_output =
      cfg != nullptr && cfg->x != lava::OutputConfig::kAuto
          ? wlr_output_layout_add(server->output_layout, wlr, cfg->x, cfg->y)
          : wlr_output_layout_add_auto(server->output_layout, wlr);

  wlr_log(WLR_INFO, "output %s: running %dx%d@%.3fHz scale %.2f", wlr->name,
          wlr->width, wlr->height, wlr->refresh / 1000.0, wlr->scale);

  // What a maximized window fills. The registry has no other way to know how
  // big the screen is, and this is the only place it changes.
  if (server->surfaces != nullptr) {
    server->surfaces->setOutputSize(static_cast<uint32_t>(wlr->width),
                                    static_cast<uint32_t>(wlr->height));
  }
  return layout_output;
}

Output::~Output() {
  server->outputs.remove(this);
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
  // The screen just changed size, and nothing else would say so. Nested in
  // another compositor this fires within a frame or two of startup — the mode
  // the backend opens with is a placeholder, and a panel laid out against it
  // is the wrong length for the whole session.
  if (output->server->surfaces != nullptr) {
    output->server->surfaces->setOutputSize(
        static_cast<uint32_t>(output->wlr->width),
        static_cast<uint32_t>(output->wlr->height));
  }
}

void Output::on_destroy(wl_listener *listener, void *) {
  delete owner_of<Output>(listener);
}

// ─── Toplevel ──────────────────────────────────────────────────────────────

Toplevel::Toplevel(Server *server, wlr_xdg_toplevel *toplevel)
    : server(server), xdg_toplevel(toplevel),
      // Into the current workspace's tree rather than the scene root, which is
      // all it takes for an ordinary Wayland window to hide and come back with
      // its workspace like a LavaUI one.
      scene_tree(wlr_scene_xdg_surface_create(server->workspaces.currentTree(),
                                              toplevel->base)) {
  workspace = server->workspaces.current;
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
  set_title.attach(&toplevel->events.set_title, this, on_set_title);
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
  set_title.detach();
  request_maximize.detach();
  request_fullscreen.detach();
}

void Toplevel::geometry(uint32_t &width, uint32_t &height) const {
  const wlr_box &box = xdg_toplevel->base->geometry;
  width = box.width > 0 ? static_cast<uint32_t>(box.width) : 0;
  height = box.height > 0 ? static_cast<uint32_t>(box.height) : 0;
}

void Toplevel::on_map(wl_listener *listener, void *) {
  auto *toplevel = owner_of<Toplevel>(listener);
  Server *server = toplevel->server;
  toplevel->server->toplevels.push_front(toplevel);

  const char *title = toplevel->xdg_toplevel->title;
  const char *app_id = toplevel->xdg_toplevel->app_id;

  // A frame: a title bar, a position, a workspace. Until this existed every
  // Wayland window sat at the scene origin, on top of every other one.
  if (server->surfaces != nullptr) {
    uint32_t width = 0, height = 0;
    toplevel->geometry(width, height);
    const uint32_t id = server->surfaces->adoptWindow(
        toplevel, title ? title : "", width, height);
    if (ClientSurface *frame = server->surfaces->find(id)) {
      server->surfaces->raise(*frame);
      server->surfaces->setFocused(id);
    }
  }
  server->focus(toplevel);
  // A Wayland window takes the keyboard through the seat, so no client
  // surface may be holding it as well.
  server->setFocusedSurface(0);

  wlr_log(WLR_INFO, "toplevel mapped: app_id=%s title=%s",
          app_id ? app_id : "(none)", title ? title : "(none)");
}

void Toplevel::on_unmap(wl_listener *listener, void *) {
  auto *toplevel = owner_of<Toplevel>(listener);
  wlr_log(WLR_INFO, "toplevel unmapped");
  toplevel->server->toplevels.remove(toplevel);
  // The frame goes with it, or an unmapped window leaves a title bar floating
  // over the desktop with nothing underneath.
  if (toplevel->frameId != 0 && toplevel->server->surfaces != nullptr) {
    toplevel->server->surfaces->destroySurface(toplevel->frameId);
  }
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
    return;
  }
  // Whatever size the client settled at is the size the frame is, whether or
  // not it is the size we asked for — a terminal snaps to whole character
  // cells and will not honour an arbitrary drag exactly.
  if (toplevel->frameId == 0 || toplevel->server->surfaces == nullptr) return;
  if (ClientSurface *frame =
          toplevel->server->surfaces->find(toplevel->frameId)) {
    uint32_t width = 0, height = 0;
    toplevel->geometry(width, height);
    if (width > 0 && height > 0) {
      toplevel->server->surfaces->toplevelResized(*frame, width, height);
    }
  }
}

void Toplevel::on_set_title(wl_listener *listener, void *) {
  auto *toplevel = owner_of<Toplevel>(listener);
  if (toplevel->frameId == 0 || toplevel->server->surfaces == nullptr) return;
  if (ClientSurface *frame =
          toplevel->server->surfaces->find(toplevel->frameId)) {
    const char *title = toplevel->xdg_toplevel->title;
    toplevel->server->surfaces->setTitle(*frame, title ? title : "Untitled");
  }
}

void Toplevel::on_destroy(wl_listener *listener, void *) {
  delete owner_of<Toplevel>(listener);
}

void Toplevel::on_request_maximize(wl_listener *listener, void *) {
  auto *toplevel = owner_of<Toplevel>(listener);
  if (toplevel->frameId != 0 && toplevel->server->surfaces != nullptr) {
    if (ClientSurface *frame =
            toplevel->server->surfaces->find(toplevel->frameId)) {
      // The same maximize the title bar button does, so a window maximized
      // from its own menu and one maximized from its frame end up in the same
      // state — including remembering where to restore to.
      toplevel->server->surfaces->toggleMaximize(*frame);
      wlr_xdg_toplevel_set_maximized(toplevel->xdg_toplevel, frame->maximized);
    }
  }
  // The protocol requires a configure in reply to the request whether or not
  // anything changed. Silence is a protocol error.
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
  applyKeymap(server->config.keyboard);

  modifiers.attach(&wlr->events.modifiers, this, on_modifiers);
  key.attach(&wlr->events.key, this, on_key);
  destroy.attach(&device->events.destroy, this, on_destroy);

  server->keyboards.push_back(this);
  wlr_seat_set_keyboard(server->seat, wlr);
}

void Keyboard::applyKeymap(const lava::KeyboardConfig &config) {
  // Empty strings mean "xkb's default", which is what nullptr fields ask for.
  xkb_rule_names names{};
  auto or_null = [](const std::string &s) {
    return s.empty() ? nullptr : s.c_str();
  };
  names.rules = or_null(config.rules);
  names.model = or_null(config.model);
  names.layout = or_null(config.layout);
  names.variant = or_null(config.variant);
  names.options = or_null(config.options);

  xkb_context *context = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
  xkb_keymap *keymap =
      xkb_keymap_new_from_names(context, &names, XKB_KEYMAP_COMPILE_NO_FLAGS);
  if (keymap == nullptr) {
    // A layout name with a typo in it compiles to nothing, and a keyboard with
    // no keymap delivers no keys at all — including the one that would let
    // anybody fix the config.
    wlr_log(WLR_ERROR, "keyboard: layout '%s' did not compile, keeping default",
            config.layout.c_str());
    keymap = xkb_keymap_new_from_names(context, nullptr,
                                       XKB_KEYMAP_COMPILE_NO_FLAGS);
  }
  if (keymap != nullptr) {
    wlr_keyboard_set_keymap(wlr, keymap);
    xkb_keymap_unref(keymap);
  }
  xkb_context_unref(context);
  wlr_keyboard_set_repeat_info(wlr, config.repeatRate, config.repeatDelay);
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

/// One Unicode scalar as UTF-8.
///
/// The engine takes committed text as a string because a character is not a
/// key: what the layout produced needs no interpreting, and a codepoint above
/// the BMP is not one `char` anywhere.
std::string utf8_of(uint32_t cp) {
  std::string out;
  if (cp < 0x80) {
    out += static_cast<char>(cp);
  } else if (cp < 0x800) {
    out += static_cast<char>(0xc0 | (cp >> 6));
    out += static_cast<char>(0x80 | (cp & 0x3f));
  } else if (cp < 0x10000) {
    out += static_cast<char>(0xe0 | (cp >> 12));
    out += static_cast<char>(0x80 | ((cp >> 6) & 0x3f));
    out += static_cast<char>(0x80 | (cp & 0x3f));
  } else {
    out += static_cast<char>(0xf0 | (cp >> 18));
    out += static_cast<char>(0x80 | ((cp >> 12) & 0x3f));
    out += static_cast<char>(0x80 | ((cp >> 6) & 0x3f));
    out += static_cast<char>(0x80 | (cp & 0x3f));
  }
  return out;
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

/// The compositor's own shortcuts, taken before any client sees the key.
///
/// True when the key was one of ours, which is the caller's signal to stop: a
/// bound key is not also text, and forwarding it would put a digit in whatever
/// the user was typing in every time they changed workspace.
bool handle_binding(Server *server, xkb_keysym_t sym, bool shift) {
  // Worth having while this runs nested inside another compositor: without it
  // the only way out is killing the process from elsewhere, and a compositor
  // that has taken the keyboard is hard to leave.
  if (sym == XKB_KEY_Escape) {
    wl_display_terminate(server->display);
    return true;
  }
  if (sym >= XKB_KEY_1 && sym <= XKB_KEY_9) {
    const uint32_t index = static_cast<uint32_t>(sym - XKB_KEY_1);
    if (index >= Workspaces::kCount) return false;
    // Shift sends the window instead of following it, which is the arrangement
    // every tiling compositor has settled on.
    if (shift) {
      server->moveFocusedToWorkspace(index);
    } else {
      server->switchWorkspace(index);
    }
    return true;
  }
  return false;
}

void Keyboard::on_key(wl_listener *listener, void *data) {
  auto *keyboard = owner_of<Keyboard>(listener);
  auto *event = static_cast<wlr_keyboard_key_event *>(data);
  Server *server = keyboard->server;

  const uint32_t modifiers = wlr_keyboard_get_modifiers(keyboard->wlr);
  if ((modifiers & WLR_MODIFIER_ALT) &&
      event->state == WL_KEYBOARD_KEY_STATE_PRESSED) {
    // +8 converts evdev to xkb keycodes; the offset is historical, from X.
    const xkb_keycode_t keycode = event->keycode + 8;
    // The *unshifted* keysym, deliberately: Alt+Shift+2 produces "at" on a US
    // layout and something else again on a German one, while the binding is
    // about the key the digit is printed on. Level 0 is that key, whatever the
    // modifiers currently say.
    const xkb_layout_index_t layout =
        xkb_state_key_get_layout(keyboard->wlr->xkb_state, keycode);
    const xkb_keysym_t *syms = nullptr;
    const int count = xkb_keymap_key_get_syms_by_level(
        keyboard->wlr->keymap, keycode, layout, 0, &syms);
    for (int i = 0; i < count; ++i) {
      if (handle_binding(server, syms[i], modifiers & WLR_MODIFIER_SHIFT)) {
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
  if (server->focusedSurface() != 0) {
    const bool pressed = event->state == WL_KEYBOARD_KEY_STATE_PRESSED;
    const xkb_keysym_t *syms = nullptr;
    const int count = xkb_state_key_get_syms(keyboard->wlr->xkb_state,
                                             event->keycode + 8, &syms);
    const int32_t mods = static_cast<int32_t>(glfw_mods(modifiers));
    if (ClientSurface *target =
            server->surfaces->find(server->focusedSurface())) {
      for (int i = 0; i < count; ++i) {
        target->canvas->keyEvent(glfw_key(syms[i]), pressed ? 1 : 0, mods);
      }
      if (pressed) {
        const uint32_t utf32 = xkb_state_key_get_utf32(
            keyboard->wlr->xkb_state, event->keycode + 8);
        // Control characters are keys, not text: a client that inserted them
        // would put a literal backspace in its document.
        if (utf32 >= 0x20 && utf32 != 0x7f) {
          target->canvas->textInput(utf8_of(utf32));
        }
      }
      server->surfaces->pump(*target);
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

void Server::on_new_decoration(wl_listener *, void *data) {
  // Self-owned: it deletes itself when the client drops the decoration.
  new ToplevelDecoration(
      static_cast<wlr_xdg_toplevel_decoration_v1 *>(data));
}

void Server::on_new_xwayland_surface(wl_listener *listener, void *data) {
  auto *server = owner_of<Server>(listener);
  // Self-owned, like Toplevel: it deletes itself when the X11 window goes.
  new XwaylandSurface(server, static_cast<wlr_xwayland_surface *>(data));
}

void Server::on_xwayland_ready(wl_listener *listener, void *) {
  auto *server = owner_of<Server>(listener);
  // The seat can only be handed over once the X server is actually up, which
  // in lazy mode is the moment the first client connects. DISPLAY is set at
  // creation instead — see below for why it cannot wait for this.
  wlr_xwayland_set_seat(server->xwayland, server->seat);
  wlr_log(WLR_INFO, "xwayland: started on DISPLAY=%s",
          server->xwayland->display_name);
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

void Server::focus(FramedWindow *window) {
  if (window == nullptr) return;
  wlr_surface *surface = window->focusSurface();
  if (surface == nullptr) return;
  wlr_surface *previous = seat->keyboard_state.focused_surface;
  if (previous == surface) return;

  // Deactivating tells the old window to stop drawing itself as focused — its
  // caret, its titlebar. Nothing else would ever tell it. Found through the
  // window list rather than by asking the surface what kind it is, so an X11
  // window is deactivated the same way an xdg one is.
  for (FramedWindow *other : toplevels) {
    if (other != window && other->focusSurface() == previous) {
      other->activate(false);
      break;
    }
  }

  // Through the registry, so the title bar comes up with the window: the two
  // are siblings in one tree and raising only the contents would put a
  // window's own frame behind it.
  if (surfaces != nullptr && window->frameId != 0) {
    if (ClientSurface *frame = surfaces->find(window->frameId)) {
      surfaces->raise(*frame);
      surfaces->setFocused(frame->id);
    }
  } else {
    wlr_scene_node_raise_to_top(window->contentNode());
  }
  toplevels.remove(window);
  toplevels.push_front(window);
  window->activate(true);

  if (auto *keyboard = wlr_seat_get_keyboard(seat)) {
    wlr_seat_keyboard_notify_enter(seat, surface, keyboard->keycodes,
                                   keyboard->num_keycodes, &keyboard->modifiers);
  }
}

void Server::reloadConfig() {
  const lava::Config fresh = lava::Config::load(configPath);
  const std::string previousDevices = config.drmDevices;
  const std::string previousRenderer = config.renderer;
  config = fresh;

  if (fresh.drmDevices != previousDevices ||
      fresh.renderer != previousRenderer) {
    wlr_log(WLR_INFO,
            "config: GPU settings changed; they apply on the next start");
  }

  for (Output *output : outputs) {
    output->applyConfig();
  }
  for (Keyboard *keyboard : keyboards) {
    // Every client is sent the new keymap by wlroots as a side effect, so a
    // layout change reaches applications that are already running.
    keyboard->applyKeymap(config.keyboard);
  }
  wlr_log(WLR_INFO, "config: reloaded");
}

FramedWindow *Server::frontToplevel(uint32_t workspace) {
  for (FramedWindow *window : toplevels) {
    if (window->workspace == workspace) return window;
  }
  return nullptr;
}

void Server::switchWorkspace(uint32_t index) {
  if (index >= Workspaces::kCount || index == workspaces.current) return;

  wlr_scene_node_set_enabled(&workspaces.currentTree()->node, false);
  workspaces.current = index;
  wlr_scene_node_set_enabled(&workspaces.currentTree()->node, true);

  // A drag is a grab on a window that is no longer on screen. Dropping it here
  // rather than letting it run means the pointer does not keep dragging
  // something invisible around the workspace the user just arrived in.
  drag = Drag::None;

  // Whatever had the keyboard is hidden now. Clearing first covers both cases
  // at once: the seat is pointed at nothing until something on *this*
  // workspace takes it.
  wlr_seat_keyboard_notify_clear_focus(seat);
  if (surfaces != nullptr) surfaces->setFocused(focusedSurface());
  if (focusedSurface() == 0) {
    focus(frontToplevel(index));
  }

  // The cursor did not move, but what is under it did.
  update_pointer_focus(0);
}

void Server::moveFocusedToWorkspace(uint32_t index) {
  if (index >= Workspaces::kCount || index == workspaces.current) return;

  if (surfaces != nullptr) {
    if (ClientSurface *surface = surfaces->find(focusedSurface())) {
      surfaces->moveToWorkspace(*surface, index);
      // It arrives focused on the workspace it was sent to, and leaves this
      // one with nothing focused — the same as if it had been closed here.
      setFocusedSurface(0);
      focusedByWorkspace[index] = surface->id;
      surfaces->setFocused(0);
      drag = Drag::None;
      update_pointer_focus(0);
      return;
    }
  }

  // No client surface has the keyboard, so it is a Wayland window's turn — the
  // front one, which is the one the user is looking at.
  if (FramedWindow *window = frontToplevel(workspaces.current)) {
    window->workspace = index;
    wlr_scene_node_reparent(window->contentNode(), workspaces.tree[index]);
    // Its frame goes with it, or the title bar stays on this workspace with
    // nothing underneath.
    if (surfaces != nullptr && window->frameId != 0) {
      if (ClientSurface *frame = surfaces->find(window->frameId)) {
        surfaces->moveToWorkspace(*frame, index);
      }
    }
    // Left at the front of the stacking list, which makes it the front window
    // of the workspace it arrived on — nothing else is there to be in front.
    wlr_seat_keyboard_notify_clear_focus(seat);
    focus(frontToplevel(workspaces.current));
    drag = Drag::None;
    update_pointer_focus(0);
  }
}

void Server::update_pointer_focus(uint32_t time_msec) {
  // A drag owns the pointer until the button comes back up, wherever it has
  // got to — otherwise letting the cursor outrun the window would hand the
  // motion to whatever it crossed.
  if (update_drag()) return;

  // The frame before the content. A title bar belongs to the compositor, so
  // its hover is answered here and never reaches the client.
  if (surfaces != nullptr && surfaces->hoverFrames(cursor->x, cursor->y)) {
    wlr_cursor_set_xcursor(cursor, cursor_mgr, "default");
    wlr_seat_pointer_clear_focus(seat);
    return;
  }

  // Client surfaces next: they sit above the Wayland windows in the scene and
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

bool Server::update_drag() {
  if (drag == Drag::None || surfaces == nullptr) return false;
  ClientSurface *surface = surfaces->find(dragSurface);
  if (surface == nullptr) {
    drag = Drag::None;
    return false;
  }
  const double dx = cursor->x - dragStartX;
  const double dy = cursor->y - dragStartY;
  if (drag == Drag::Move) {
    surfaces->moveSurface(*surface, dragOriginX + static_cast<int>(dx),
                          dragOriginY + static_cast<int>(dy));
  } else {
    // Rebuilding a swapchain-sized set of attachments and re-exporting a
    // dmabuf on every motion event is not free, and a drag produces one per
    // pixel. `resizeSurface` is a no-op when the size has not changed, which
    // the integer truncation above makes true most of the time.
    surfaces->resizeSurface(
        *surface, static_cast<uint32_t>(std::max(1.0, dragOriginW + dx)),
        static_cast<uint32_t>(std::max(1.0, dragOriginH + dy)));
  }
  return true;
}

bool Server::route_pointer(uint32_t kind, int32_t button, int32_t mods) {
  if (surfaces == nullptr || control == nullptr) return false;
  double sx = 0, sy = 0;
  ClientSurface *surface = surfaces->at(cursor->x, cursor->y, sx, sy);
  if (surface == nullptr) return false;
  // Through the renderer, not around it — the hover under this pointer is its
  // to answer. See the input section of `CanvasSurface`.
  if (kind == static_cast<uint32_t>(canvas::InputEventKind::MouseMove)) {
    surface->canvas->pointerMove(static_cast<float>(sx),
                                 static_cast<float>(sy));
  }
  (void)button;
  (void)mods;
  surfaces->pump(*surface);
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

  // A release always ends a drag, whatever it is over by then.
  if (!pressed && server->drag != Server::Drag::None) {
    server->drag = Server::Drag::None;
    return;
  }

  // The title bar, before anything else. Its buttons are the compositor's and
  // a press there never reaches a client — which is also what lets a window
  // whose client has stopped answering still be closed.
  if (pressed && server->surfaces != nullptr) {
    double bx = 0, by = 0;
    if (ClientSurface *frame =
            server->surfaces->frameAt(server->cursor->x, server->cursor->y, bx,
                                      by)) {
      server->surfaces->setFocused(frame->id);
      server->surfaces->raise(*frame);
      if (frame->isForeign()) {
        // A foreign window takes the keyboard through the seat, and no client
        // surface may hold it at the same time — both focused would deliver
        // every key twice.
        server->setFocusedSurface(0);
        server->focus(frame->window);
      } else {
        server->setFocusedSurface(frame->id);
        wlr_seat_keyboard_notify_clear_focus(server->seat);
      }
      switch (lava::Decoration::hitTest(static_cast<float>(bx),
                                        static_cast<float>(by),
                                        frame->width)) {
        case lava::DecorationHit::Close:
          // Asked rather than killed, where there is somebody to ask: a
          // Wayland client gets to put up its "save your work?" dialog.
          server->surfaces->requestClose(*frame);
          // Or the workspace goes on pointing at an id that no longer resolves,
          // and the next Alt+Shift would move a Wayland window instead.
          server->setFocusedSurface(0);
          return;
        case lava::DecorationHit::Maximize:
          server->surfaces->toggleMaximize(*frame);
          if (frame->isForeign()) {
            // Told, so the client draws itself as maximized — squared corners,
            // a different button in its own menu.
            frame->window->setMaximized(frame->maximized);
          }
          return;
        case lava::DecorationHit::Bar:
          // Bare bar: drag the window, the way a title bar always has.
          server->drag = Server::Drag::Move;
          server->dragSurface = frame->id;
          server->dragStartX = server->cursor->x;
          server->dragStartY = server->cursor->y;
          server->dragOriginX = frame->x;
          server->dragOriginY = frame->y;
          return;
      }
    }
  }

  // Alt+drag: left moves, right resizes. Checked before anything is forwarded,
  // because these belong to the compositor and not to the window under them.
  if (pressed && server->surfaces != nullptr) {
    const uint32_t modifiers =
        server->seat->keyboard_state.keyboard != nullptr
            ? wlr_keyboard_get_modifiers(server->seat->keyboard_state.keyboard)
            : 0;
    ClientSurface *over =
        server->surfaces->windowAt(server->cursor->x, server->cursor->y);
    if ((modifiers & WLR_MODIFIER_ALT) && over != nullptr) {
      server->surfaces->raise(*over);
      server->drag = event->button == BTN_RIGHT ? Server::Drag::Resize
                                                : Server::Drag::Move;
      server->dragSurface = over->id;
      server->dragStartX = server->cursor->x;
      server->dragStartY = server->cursor->y;
      server->dragOriginX = over->x;
      server->dragOriginY = over->y;
      server->dragOriginW = over->width;
      server->dragOriginH = over->height;
      return;
    }
  }

  // A press over a client surface focuses it and is forwarded; a release goes
  // to whichever surface is focused even if the pointer has since left it, so
  // a drag that ends outside still ends.
  if (server->surfaces != nullptr && server->control != nullptr) {
    // Left = 0, matching GLFW, which is what the client's event decoding was
    // written against.
    const int32_t button = static_cast<int32_t>(event->button - 0x110u);
    double sx = 0, sy = 0;
    if (pressed) {
      if (ClientSurface *over =
              server->surfaces->at(server->cursor->x, server->cursor->y, sx, sy)) {
        server->setFocusedSurface(over->id);
        // Taking the keyboard from any Wayland window: the two focus models
        // are separate, and leaving both focused would deliver every key twice.
        wlr_seat_keyboard_notify_clear_focus(server->seat);
        over->canvas->pointerButton(button, true, static_cast<float>(sx),
                                    static_cast<float>(sy), 0);
        server->surfaces->pump(*over);
        return;
      }
    } else if (ClientSurface *target =
                   server->surfaces->find(server->focusedSurface())) {
      // Recomputed against the focused surface rather than reusing whatever a
      // hit test left behind: the pointer may be outside it, and `at` only
      // fills the offsets for surfaces it actually tested.
      target->canvas->pointerButton(
          button, false, static_cast<float>(server->cursor->x - target->x),
          static_cast<float>(server->cursor->y - target->y), 0);
      server->surfaces->pump(*target);
      return;
    }
  }

  if (pressed) {
    double sx = 0, sy = 0;
    Toplevel *toplevel = nullptr;
    server->surface_at(server->cursor->x, server->cursor->y, &sx, &sy,
                       &toplevel);
    server->focus(toplevel);  // click to focus; null over the desktop is a no-op
    server->setFocusedSurface(0);
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
      // The renderer may take this notch itself — a scrollable node under the
      // pointer moves without the client hearing about it, which is what lets
      // a list scroll while the process that drew it is stopped.
      over->canvas->pointerScroll(horizontal ? notches : 0.f,
                                  horizontal ? 0.f : notches);
      server->surfaces->pump(*over);
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

// ─── Selections ────────────────────────────────────────────────────────────
//
// The clipboard is not a thing the compositor stores. A client that copies
// says "I have a selection, in these formats"; a client that pastes asks the
// seat who has it and reads the data over a pipe straight from the source. All
// the compositor does is decide whose offer is current — which is exactly
// these two handlers, and without them copy and paste silently does nothing at
// all. `wlr_data_device_manager_create` alone is not enough: it publishes the
// protocol, and then every `set_selection` request is dropped on the floor.

void Server::on_request_set_selection(wl_listener *listener, void *data) {
  auto *server = owner_of<Server>(listener);
  auto *event = static_cast<wlr_seat_request_set_selection_event *>(data);
  // The serial is checked by wlroots against a real input event, which is what
  // stops a background client taking the clipboard whenever it likes.
  wlr_seat_set_selection(server->seat, event->source, event->serial);
}

void Server::on_request_set_primary_selection(wl_listener *listener,
                                              void *data) {
  auto *server = owner_of<Server>(listener);
  auto *event =
      static_cast<wlr_seat_request_set_primary_selection_event *>(data);
  // The X11 middle-click clipboard, which every terminal still expects.
  wlr_seat_set_primary_selection(server->seat, event->source, event->serial);
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

  // Blocked here, before anything else, because `wl_event_loop_add_signal`
  // reads it off a signalfd and a signalfd only sees signals that are blocked.
  // libwayland does block it — but only on the thread that registers, and by
  // then the control plane has started NPRPC's threads, which would inherit
  // nothing and take the SIGHUP with its default disposition. The compositor
  // exits, on the signal that was supposed to reload its config.
  //
  // A mask set before any thread exists is inherited by every thread created
  // afterwards, which is the only version of this that stays true.
  {
    sigset_t mask;
    sigemptyset(&mask);
    sigaddset(&mask, SIGHUP);
    pthread_sigmask(SIG_BLOCK, &mask, nullptr);
  }

  Server server;
  server.display = wl_display_create();
  if (!server.display) {
    std::cerr << "Could not create Wayland display\n";
    return EXIT_FAILURE;
  }

  // Before the backend, because the GPU choice is an environment variable
  // wlroots reads while creating it — after this point nothing rereads them.
  server.configPath = lava::Config::defaultPath();
  server.config = lava::Config::load(server.configPath);
  server.config.applyEnvironment();

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
  auto *compositor = wlr_compositor_create(server.display, 6, server.renderer);
  wlr_subcompositor_create(server.display);
  // The clipboard, and the X11-style middle-click one beside it. Both are
  // only half of what a working selection needs — see `on_request_set_selection`.
  wlr_data_device_manager_create(server.display);
  wlr_primary_selection_v1_device_manager_create(server.display);

  server.scene = wlr_scene_create();
  server.output_layout = wlr_output_layout_create(server.display);
  server.scene_layout =
      wlr_scene_attach_output_layout(server.scene, server.output_layout);

  const float background[] = {0.055f, 0.075f, 0.12f, 1.0f};
  wlr_scene_rect_create(&server.scene->tree, 8192, 8192, background);

  // After the background and before anything else: the trees created here are
  // siblings above it, and the panel tree created last inside `init` is above
  // them. Every window in the compositor lives in one of these.
  server.workspaces.init(&server.scene->tree);

  server.new_output.attach(&server.backend->events.new_output, &server,
                           Server::on_new_output);

  // xdg-shell: how ordinary applications get a window.
  server.xdg_shell = wlr_xdg_shell_create(server.display, 3);
  server.new_toplevel.attach(&server.xdg_shell->events.new_toplevel, &server,
                             Server::on_new_toplevel);

  // Server-side decorations, so a window drawn by this compositor is not also
  // drawn by its toolkit. Clients that do not speak this protocol still draw
  // their own — there is no way to stop them, which is the one real cost of
  // decorating from outside.
  auto *decorations = wlr_xdg_decoration_manager_v1_create(server.display);
  server.new_decoration.attach(&decorations->events.new_toplevel_decoration,
                               &server, Server::on_new_decoration);

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
  server.request_set_selection.attach(&server.seat->events.request_set_selection,
                                      &server,
                                      Server::on_request_set_selection);
  server.request_set_primary_selection.attach(
      &server.seat->events.request_set_primary_selection, &server,
      Server::on_request_set_primary_selection);

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
  // One canvas device for the whole compositor, brought up before any client
  // connects. Surfaces are windows on it.
  auto canvas_renderer = lava::CanvasRenderer::create(server.renderer);
  SurfaceRegistry surfaces;
  surfaces.bind(canvas_renderer.get(), &server.workspaces);
  server.surfaces = &surfaces;
  if (!canvas_renderer) {
    wlr_log(WLR_ERROR, "no canvas device — LavaUI surfaces cannot be drawn");
  }

  // The face titles are drawn in. Same directory LavaUI's clients use, since
  // the compositor's own text should not look like a different desktop.
  {
    const char *root = std::getenv("LAVA_UI_FONTS");
    const std::string dir = root ? root : LAVA_UI_FONTS;
    surfaces.initDecoration(dir + "/OpenSans-Regular.ttf", 14.f);
  }
  surfaces.start(wl_display_get_event_loop(server.display));

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

  // `kill -HUP` re-reads the config. The event loop delivers it, so it lands
  // on the loop thread like everything else rather than in a signal handler
  // where almost nothing here would be safe to call.
  wl_event_loop_add_signal(
      wl_display_get_event_loop(server.display), SIGHUP,
      [](int, void *data) {
        static_cast<Server *>(data)->reloadConfig();
        return 0;
      },
      &server);

  // X11 applications, through Xwayland. Lazy: the X server is not started
  // until something actually tries to connect, so a session that never runs an
  // X11 client never pays for one.
  //
  // Not fatal if it fails — a compositor without Xwayland runs every Wayland
  // client exactly as before, and says so rather than looking healthy while
  // `DISPLAY` points at nothing.
  server.xwayland =
      wlr_xwayland_create(server.display, compositor, /*lazy=*/true);
  if (server.xwayland != nullptr) {
    server.new_xwayland_surface.attach(&server.xwayland->events.new_surface,
                                       &server,
                                       Server::on_new_xwayland_surface);
    server.xwayland_ready.attach(&server.xwayland->events.ready, &server,
                                 Server::on_xwayland_ready);
    // Now, not on `ready`. The socket is bound when the server object is
    // created; what lazy mode defers is starting the X server behind it, and
    // that does not happen until a client connects — which no client will do
    // while DISPLAY is unset. Waiting for `ready` to publish it is a deadlock
    // that looks exactly like Xwayland being broken.
    setenv("DISPLAY", server.xwayland->display_name, 1);
    wlr_log(WLR_INFO, "xwayland: DISPLAY=%s (starting on first client)",
            server.xwayland->display_name);
  } else {
    wlr_log(WLR_ERROR, "xwayland: unavailable — X11 clients cannot connect");
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
