#include <algorithm>
#include <cstdio>
#include <cstddef>
#include <fstream>
#include <sys/stat.h>
#include <linux/input-event-codes.h>  // BTN_RIGHT
#include <cstdlib>
#include <ctime>
#include <iostream>
#include <list>

#include "canvas_surface.hpp"
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
  /// Which workspace it was opened on. A Wayland client has no say in this and
  /// no way to ask, which is why the compositor is the only place it lives.
  uint32_t workspace = 0;

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

  uint32_t focusedSurface() const {
    return focusedByWorkspace[workspaces.current];
  }
  void setFocusedSurface(uint32_t id) {
    focusedByWorkspace[workspaces.current] = id;
  }

  /// Shows workspace `index` and hands it the keyboard. A no-op if it is
  /// already current, so a repeated shortcut costs nothing.
  void switchWorkspace(uint32_t index);
  /// Sends whatever has the keyboard to workspace `index`, and stays put.
  void moveFocusedToWorkspace(uint32_t index);
  /// The front window of a workspace, or null if it has none.
  Toplevel *frontToplevel(uint32_t workspace);

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

  std::unique_ptr<lava::CanvasSurface> canvas;
  wlr_scene_buffer *node = nullptr;

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

  /// Topmost surface under a layout-space point. Front is most recent.
  ClientSurface *at(double lx, double ly, double &sx, double &sy) {
    for (auto &s : surfaces_) {
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

  /// Puts both of a window's nodes where its frame origin says they go.
  void place(ClientSurface &surface) {
    if (surface.barNode != nullptr) {
      wlr_scene_node_set_position(&surface.barNode->node, surface.x, surface.y);
    }
    wlr_scene_node_set_position(&surface.node->node, surface.x,
                                surface.contentY());
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
      if ((*it)->node) wlr_scene_node_destroy(&(*it)->node->node);
      if ((*it)->barNode) wlr_scene_node_destroy(&(*it)->barNode->node);
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

  /// Hands the renderer's conclusions to the client, and redraws the surface
  /// if the renderer changed something on its own.
  ///
  /// Called after every input event. The events that come out are the raw one
  /// plus whatever the scene decided — `NodeHover`, `NodeScroll`,
  /// `NodeAnimationDone` — which is what makes a hover cost no round trip and
  /// a scroll survive a stopped client.
  void pump(ClientSurface &surface) {
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
    if (control_ == nullptr) return;
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
    wlr_scene_buffer_set_buffer_with_damage(surface.node,
                                            surface.canvas->buffer(), nullptr);
  }

  void present(uint32_t id) override {
    ClientSurface *surface = find(id);
    if (surface == nullptr) return;
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

  // What a maximized window fills. The registry has no other way to know how
  // big the screen is, and this is the only place it changes.
  if (server->surfaces != nullptr) {
    server->surfaces->setOutputSize(static_cast<uint32_t>(wlr->width),
                                    static_cast<uint32_t>(wlr->height));
  }
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
                                              toplevel->base)),
      workspace(server->workspaces.current) {
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

Toplevel *Server::frontToplevel(uint32_t workspace) {
  for (Toplevel *toplevel : toplevels) {
    if (toplevel->workspace == workspace) return toplevel;
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
  if (Toplevel *toplevel = frontToplevel(workspaces.current)) {
    toplevel->workspace = index;
    wlr_scene_node_reparent(&toplevel->scene_tree->node,
                            workspaces.tree[index]);
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
      server->setFocusedSurface(frame->id);
      wlr_seat_keyboard_notify_clear_focus(server->seat);
      switch (lava::Decoration::hitTest(static_cast<float>(bx),
                                        static_cast<float>(by),
                                        frame->width)) {
        case lava::DecorationHit::Close:
          // The client's stream ends with its surface, which is how it learns
          // the window is gone — see `SubscribeInput`.
          server->surfaces->destroySurface(frame->id);
          // Or the workspace goes on pointing at an id that no longer resolves,
          // and the next Alt+Shift would move a Wayland window instead.
          server->setFocusedSurface(0);
          return;
        case lava::DecorationHit::Maximize:
          server->surfaces->toggleMaximize(*frame);
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
    double sx = 0, sy = 0;
    ClientSurface *over =
        server->surfaces->at(server->cursor->x, server->cursor->y, sx, sy);
    if ((modifiers & WLR_MODIFIER_ALT) && over != nullptr) {
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
