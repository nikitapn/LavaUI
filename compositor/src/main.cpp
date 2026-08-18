#include <algorithm>
#include <atomic>
#include <cctype>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstddef>
#include <drm_fourcc.h>
#include <format>
#include <fstream>
#include <spawn.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <linux/input-event-codes.h>  // BTN_RIGHT
#include <cerrno>
#include <csignal>
#include <cstring>
#include <pthread.h>
#include <cstdlib>
#include <ctime>
#include <iostream>
#include <list>
#include <memory>
#include <thread>
#include <unordered_map>
#include <vector>

// The catalogue of keyboard layouts, which is xkb's to know: where the rules
// files live differs between distributions, and this is the API that answers
// without guessing. Separate library from xkbcommon proper, same project.
#include <xkbcommon/xkbregistry.h>

#include "appmenu.hpp"
#include "canvas_surface.hpp"
#include "clipboard.hpp"
#include "config.hpp"
#include "decoration.hpp"
#include "frame_probe.hpp"
#include "control_plane.hpp"
#include "shell.hpp"
#include "screenshot_portal.hpp"
#include "startup_watchdog.hpp"
#include "backdrop_blur.hpp"
#include "background.hpp"
#include "focus_history.hpp"
#include "window_memory.hpp"
#include "wlr.hpp"
#include "render/png_encode.hpp"

extern char **environ;

namespace {

/// What `CreateSurface` stamps on the 3D app switcher, and the name
/// `programPath` finds. Filtered out of the window list so a dock does not
/// offer to switch to the switcher, and skipped by `focusSurface` so the
/// previous window keeps the active title bar while the overlay has the
/// keyboard.
constexpr const char *kSwitcherAppId = "LavaSwitcher";
/// The launcher is a fill-screen overlay spawned per invocation. Remembering
/// it would reopen a "window" the user never placed.
constexpr const char *kLauncherAppId = "LavaLauncher";

bool isTransientApp(const std::string &appId) {
  return appId == kSwitcherAppId || appId == kLauncherAppId;
}

/// Dialogs, tool windows, splash screens: they share the parent's
/// `app_id` / WM_CLASS, so the last-frame cache would open them at the
/// parent's size (and maximized, if that is how the parent last sat).
bool x11IsTransient(const wlr_xwayland_surface *surface) {
  if (surface == nullptr) return false;
  if (surface->parent != nullptr || surface->modal) return true;
  static constexpr wlr_xwayland_net_wm_window_type kTypes[] = {
      WLR_XWAYLAND_NET_WM_WINDOW_TYPE_DIALOG,
      WLR_XWAYLAND_NET_WM_WINDOW_TYPE_UTILITY,
      WLR_XWAYLAND_NET_WM_WINDOW_TYPE_TOOLBAR,
      WLR_XWAYLAND_NET_WM_WINDOW_TYPE_MENU,
      WLR_XWAYLAND_NET_WM_WINDOW_TYPE_SPLASH,
      WLR_XWAYLAND_NET_WM_WINDOW_TYPE_DROPDOWN_MENU,
      WLR_XWAYLAND_NET_WM_WINDOW_TYPE_POPUP_MENU,
      WLR_XWAYLAND_NET_WM_WINDOW_TYPE_TOOLTIP,
      WLR_XWAYLAND_NET_WM_WINDOW_TYPE_NOTIFICATION,
      WLR_XWAYLAND_NET_WM_WINDOW_TYPE_COMBO,
      WLR_XWAYLAND_NET_WM_WINDOW_TYPE_DND,
  };
  for (auto type : kTypes) {
    if (wlr_xwayland_surface_has_window_type(surface, type)) return true;
  }
  return false;
}

/// Pid of a switcher we spawned and have not reaped. Stops Ctrl+Tab during
/// the ~200 ms to first frame from launching a second overlay.
std::atomic<pid_t> g_switcherPid{-1};

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
  /// Unhooks, and does nothing if there is nothing to unhook.
  ///
  /// The tolerance is what makes this usable from a shutdown path, which has
  /// to detach listeners without knowing how far startup got — Xwayland may
  /// have failed to start, and the two listeners it would have owned are then
  /// zero-initialised rather than linked into anything.
  void detach() {
    if (listener.link.next == nullptr) return;
    wl_list_remove(&listener.link);
    wl_list_init(&listener.link);
  }
};

template <typename T>
T *owner_of(wl_listener *listener) {
  return reinterpret_cast<Listener<T> *>(listener)->owner;
}

struct Server;
class SurfaceRegistry;
struct ClientSurface;

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
  /// Same, for fullscreen. The compositor has already covered the output.
  virtual void setFullscreen(bool) {}
  /// `_NET_WM_STATE_HIDDEN` / iconic. Cosmetic to the compositor — the
  /// scene node is already off — but an X11 client that asked to minimize
  /// will keep asking until the property says it did.
  virtual void setMinimized(bool) {}
  /// Told where it ended up. A Wayland window never learns its own position
  /// and does not need this; an X11 client keeps its own copy and draws its
  /// menus against it, so one that is moved without being told puts them in
  /// the wrong place.
  virtual void placed(int, int, uint32_t, uint32_t) {}

  /// Which workspace it is on, and its frame, so the two stay in step.
  uint32_t workspace = 0;
  uint32_t frameId = 0;
};

uint32_t xdgParentFrameId(const wlr_xdg_toplevel *parent) {
  if (parent == nullptr || parent->base == nullptr) return 0;
  auto *tree = static_cast<wlr_scene_tree *>(parent->base->data);
  if (tree == nullptr || tree->node.data == nullptr) return 0;
  return static_cast<FramedWindow *>(tree->node.data)->frameId;
}

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
  /// this tree is never disabled.
  wlr_scene_tree *panels = nullptr;
  /// Whatever a client is dragging, while it is dragging one. Above even the
  /// panels: it hangs off the cursor, and the cursor is over everything.
  wlr_scene_tree *dragIcons = nullptr;
  uint32_t current = 0;

  void init(wlr_scene_tree *root) {
    // Creation order is Z order, and this is the one place the scene's
    // top-level trees are ordered: the windows, the panels over them, and
    // the drag icon over both.
    for (auto *&t : tree) {
      t = wlr_scene_tree_create(root);
      wlr_scene_node_set_enabled(&t->node, false);
    }
    wlr_scene_node_set_enabled(&tree[current]->node, true);
    panels = wlr_scene_tree_create(root);
    dragIcons = wlr_scene_tree_create(root);
  }

  wlr_scene_tree *currentTree() const { return tree[current]; }
};

static_assert(Workspaces::kCount == lava::FocusHistory::kWorkspaces);

// ─── Output ────────────────────────────────────────────────────────────────

struct Output {
  Server *server;
  wlr_output *wlr;
  wlr_scene_output *scene_output;
  Listener<Output> frame;
  Listener<Output> request_state;
  Listener<Output> destroy;
  Listener<Output> commit;

  /// Set by Print Screen only; cleared when the next committed buffer has
  /// been copied to the clipboard. The screenshot portal must not set this
  /// — `finishScreenshot` would replace Flameshot's later crop copy with
  /// the full frame (and a newer serial, so the crop is then ignored).
  bool pendingScreenshot = false;
  /// Whether `scene_output` is hooked to `scene_layout`. The constructor
  /// only attaches when the output starts enabled; enabling it later
  /// (Settings, SIGHUP) has to attach too, or the screen paints the same
  /// origin as the first one — i.e. it mirrors whether you asked it to.
  bool sceneAttached = false;
  /// Whether `wlr_output_lock_attach_render` is held. See `syncScanoutLock`.
  bool compositeLocked = false;
  /// Consecutive frames the covering client has been fenced for. Reset by any
  /// frame that is not, which is what makes locking immediate and unlocking
  /// patient — see `syncScanoutLock`.
  uint32_t fencedFrames = 0;
  /// Half a second at 60 Hz: long enough that a surface swap cannot uncover
  /// the output for a frame, short enough that a game reaches scanout while
  /// it is still showing its loading screen.
  static constexpr uint32_t kFencedFramesToUnlock = 30;

  Output(Server *server, wlr_output *output);
  ~Output();

  /// Direct-scanout of a buffer with no acquire fence is how an X11 game in
  /// windowed-fullscreen paints garbage: the game is still writing the dmabuf
  /// the CRTC is reading, and NVIDIA never honours implicit sync. Windowed
  /// mode never scanouts — other windows are visible — which is why that
  /// looks fine.
  ///
  /// A fence is the whole answer, and it is asked of the buffer rather than of
  /// the client: `linux-drm-syncobj-v1` is advertised, wlroots hands a scanned
  /// out buffer's acquire timeline to the atomic commit as `IN_FENCE_FD`, and
  /// the CRTC then waits for the client's own GPU work by itself. So a fenced
  /// covering client — X11 or Wayland — is scanned out, and only an unfenced
  /// one is composited.
  ///
  /// This used to composite *every* covering X11 client, fenced or not, on the
  /// theory that the fence came and went from frame to frame and the flipping
  /// would jitter. It does not come and go: the protocol makes a buffer commit
  /// without an acquire point a protocol error, and wlroots ignores bufferless
  /// commits when it moves the state — so the fence on record is the fence of
  /// the buffer actually on screen. `LAVA_SCANOUT_PROBE=1` counts it; measured
  /// against a fullscreen X11 GL client on Xwayland 24.1 and NVIDIA 610, it is
  /// fenced on 100% of frames over minutes. What the theory cost was a
  /// full-screen composite, and a whole-output damage, on every frame of every
  /// fullscreen game.
  ///
  /// The lock is still asymmetric, because the two mistakes are not equally
  /// bad: an unfenced buffer locks on the spot, and it takes a run of
  /// `kFencedFramesToUnlock` fenced frames to let scanout back. A surface
  /// swapped out under an X11 window cannot flip the output for one frame.
  ///
  /// While composited the damage ring gets the whole frame: Xwayland often
  /// commits a reused buffer with a tiny damage region, and the other
  /// swapchain image then still holds the previous camera angle.
  void syncScanoutLock();

  /// Applies the config block for this connector: mode, scale, transform,
  /// enabled. Placement is `Server::applyArrangement`. Returns its entry
  /// in the output layout, or null if the config disabled it.
  wlr_output_layout_output *applyConfig();

  /// Puts this output at `(x, y)` in the layout and, the first time,
  /// hooks its scene output so it actually draws that region.
  void placeAt(int x, int y);

  static void on_frame(wl_listener *listener, void *data);
  static void on_request_state(wl_listener *listener, void *data);
  static void on_destroy(wl_listener *listener, void *data);
  static void on_commit(wl_listener *listener, void *data);
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
  Listener<Toplevel> set_app_id;
  Listener<Toplevel> set_parent;
  Listener<Toplevel> request_maximize;
  Listener<Toplevel> request_fullscreen;
  Listener<Toplevel> request_minimize;
  Listener<Toplevel> request_move;
  Listener<Toplevel> request_resize;

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
  void setFullscreen(bool fullscreen) override {
    wlr_xdg_toplevel_set_fullscreen(xdg_toplevel, fullscreen);
  }

  static void on_map(wl_listener *listener, void *data);
  static void on_unmap(wl_listener *listener, void *data);
  static void on_commit(wl_listener *listener, void *data);
  static void on_destroy(wl_listener *listener, void *data);
  static void on_set_title(wl_listener *listener, void *data);
  static void on_set_app_id(wl_listener *listener, void *data);
  static void on_set_parent(wl_listener *listener, void *data);
  static void on_request_maximize(wl_listener *listener, void *data);
  static void on_request_fullscreen(wl_listener *listener, void *data);
  static void on_request_minimize(wl_listener *listener, void *data);
  static void on_request_move(wl_listener *listener, void *data);
  static void on_request_resize(wl_listener *listener, void *data);
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
  Listener<XwaylandSurface> set_class;
  Listener<XwaylandSurface> set_parent;
  Listener<XwaylandSurface> set_window_type;
  Listener<XwaylandSurface> request_move;
  Listener<XwaylandSurface> request_resize;
  Listener<XwaylandSurface> request_fullscreen;
  Listener<XwaylandSurface> request_maximize;
  Listener<XwaylandSurface> request_minimize;
  /// Whether `map`/`unmap` are attached. They can only be while a Wayland
  /// surface exists behind the X11 window, which is not its whole life.
  bool associated = false;
  /// Override-redirect launchers such as Rofi need an explicit exception to
  /// the normal "menus never take focus" rule. Remember what they displaced
  /// so closing the launcher returns the keyboard to the previous client.
  bool overrideFocused = false;
  uint32_t previousClientFocus = 0;

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
  void setMaximized(bool maximized) override {
    wlr_xwayland_surface_set_maximized(xsurface, maximized, maximized);
  }
  void setFullscreen(bool fullscreen) override {
    wlr_xwayland_surface_set_fullscreen(xsurface, fullscreen);
  }
  void setMinimized(bool minimized) override {
    wlr_xwayland_surface_set_minimized(xsurface, minimized);
  }
  /// Tells the client where it now is. Nothing else will: an X11 client keeps
  /// its own idea of its position and draws menus against it, so a window
  /// moved without being told puts its menus in the wrong place.
  void placed(int x, int y, uint32_t width, uint32_t height) override {
    wlr_xwayland_surface_configure(
        xsurface, static_cast<int16_t>(x), static_cast<int16_t>(y),
        static_cast<uint16_t>(width), static_cast<uint16_t>(height));
  }

  /// Whether this compositor draws the frame. X11's answer to the same
  /// question xdg-decoration asks is the Motif hint, which is how a client
  /// that draws its own header — Chrome and the Electron applications — says
  /// so. Absent the hint an X11 window expects to be framed, which is the
  /// opposite of the Wayland default and the reason the two are asked
  /// separately.
  bool serverDecorated() const {
    return (xsurface->decorations &
            WLR_XWAYLAND_SURFACE_DECORATIONS_NO_TITLE) == 0;
  }

  static void on_associate(wl_listener *listener, void *data);
  static void on_dissociate(wl_listener *listener, void *data);
  static void on_map(wl_listener *listener, void *data);
  static void on_unmap(wl_listener *listener, void *data);
  static void on_destroy(wl_listener *listener, void *data);
  static void on_request_configure(wl_listener *listener, void *data);
  static void on_set_title(wl_listener *listener, void *data);
  static void on_set_class(wl_listener *listener, void *data);
  static void on_set_parent(wl_listener *listener, void *data);
  static void on_set_window_type(wl_listener *listener, void *data);
  /// Re-reads `WM_TRANSIENT_FOR` and `_NET_WM_WINDOW_TYPE` onto the frame.
  void refreshTransient();
  static void on_request_move(wl_listener *listener, void *data);
  static void on_request_resize(wl_listener *listener, void *data);
  static void on_request_fullscreen(wl_listener *listener, void *data);
  static void on_request_maximize(wl_listener *listener, void *data);
  static void on_request_minimize(wl_listener *listener, void *data);
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
///
/// The house style is server side, but only where the client has no opinion.
/// A client that explicitly asks for client side is asking because it draws a
/// header it cannot take apart — Chromium's tab strip is its title bar, and
/// Electron applications are the same — and answering "server side" at one of
/// those does not make it stop. It makes it draw its header *under* ours, so
/// the window ends up with two rows of window buttons and the user's title bar
/// is the one that does nothing. Overriding a stated preference cannot win
/// that argument; it can only make the result worse than either answer alone.
///
/// So: asked for client side, it gets client side and no frame. Anything else
/// — server side, or no preference at all — gets the compositor's frame.
struct ToplevelDecoration {
  wlr_xdg_toplevel_decoration_v1 *wlr;
  Listener<ToplevelDecoration> request_mode;
  Listener<ToplevelDecoration> commit;
  Listener<ToplevelDecoration> destroy;
  bool answered = false;

  explicit ToplevelDecoration(wlr_xdg_toplevel_decoration_v1 *decoration)
      : wlr(decoration) {
    wlr->data = this;
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

  /// What we told this client, once we have told it. Read back by
  /// `Server::serverDecorated` when the window maps and the frame is built,
  /// so the answer and the frame cannot disagree.
  bool serverSide = true;

  void apply() {
    // Configuring a surface that has not had its first commit is a protocol
    // error.
    if (answered || !wlr->toplevel->base->initialized) return;
    serverSide = wlr->requested_mode !=
                 WLR_XDG_TOPLEVEL_DECORATION_V1_MODE_CLIENT_SIDE;
    wlr_xdg_toplevel_decoration_v1_set_mode(
        wlr, serverSide ? WLR_XDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE
                        : WLR_XDG_TOPLEVEL_DECORATION_V1_MODE_CLIENT_SIDE);
    answered = true;
    wlr_log(WLR_INFO, "decoration: %s for '%s'",
            serverSide ? "server side" : "client side (asked for it)",
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
  /// The logind/libseat session behind a DRM backend. Null when nested.
  wlr_session *session = nullptr;
  wlr_renderer *renderer = nullptr;
  wlr_allocator *allocator = nullptr;
  wlr_scene *scene = nullptr;
  wlr_output_layout *output_layout = nullptr;
  wlr_scene_output_layout *scene_layout = nullptr;

  /// What the desktop is painted with, under every window. Built first so its
  /// tree is the lowest in the scene — see `Background`.
  lava::Background wallpaper;

  wlr_xdg_shell *xdg_shell = nullptr;
  wlr_seat *seat = nullptr;
  wlr_cursor *cursor = nullptr;
  wlr_xcursor_manager *cursor_mgr = nullptr;

  /// Raw motion and pointer locking. Xwayland translates an X11 pointer grab
  /// into these protocols; without them a game's camera is driven by the
  /// finite desktop cursor and stops turning when that cursor reaches an edge.
  wlr_relative_pointer_manager_v1 *relativePointers = nullptr;
  wlr_pointer_constraints_v1 *pointerConstraints = nullptr;
  wlr_pointer_constraint_v1 *activePointerConstraint = nullptr;

  /// Front is the most recently raised foreign window. Not a complete
  /// focus history: Lava clients never join this list. See `focusHistory`.
  std::list<FramedWindow *> toplevels;
  /// Every X11 window, including override-redirect. `toplevels` only has the
  /// framed ones; a game that maps borderless still has to be visible here
  /// so a covering unfenced buffer can disable scanout.
  std::list<XwaylandSurface *> xwindows;
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

  /// KDE Wayland AppMenu: foreign clients (Dolphin, modern Qt) point a
  /// surface at a dbusmenu export. Looked up when focus changes so the panel
  /// can import without an X11 window id.
  lava::AppMenuManager appmenu;
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
  /// Which sides a resize is pulling — see `edges`. Alt+right-drag sets the
  /// bottom-right corner, a grab on a window's border sets whichever it hit.
  uint32_t dragEdges = 0;
  /// Whether the client asked for this drag rather than the compositor
  /// starting it. The difference is who holds the press: a client that sent
  /// `xdg_toplevel.move` was given one and is waiting for its release, while a
  /// title-bar or Alt+drag never let the press out of the compositor. Sending
  /// the release to the wrong one of those is either a client stuck mid-press
  /// or a button fired that nobody clicked.
  bool dragFromClient = false;

  /// How many pointer buttons are down, and which went down last.
  ///
  /// Kept because a client asking to be moved has to be answered with "only
  /// if the user is actually holding a button" — `BeginMove` from an idle
  /// client would otherwise stick the window to the cursor. The button is
  /// remembered so the synthetic release that hands the pointer over names
  /// the one the client is waiting on.
  int pointerButtonsDown = 0;
  int32_t lastPressedButton = 0;

  /// Which client surface the pointer is currently over, so the one it leaves
  /// can be told. 0 when it is over none.
  uint32_t pointerOver = 0;

  /// Which client surface took the last press, so its release goes to the same
  /// place. 0 when the press landed somewhere else.
  ///
  /// Not the same as the focused surface, and the difference is the whole
  /// reason it exists: a panel takes presses without taking focus, so routing
  /// releases by focus delivered them to the window underneath.
  uint32_t pointerTarget = 0;

  /// Whether a foreign client is holding the pointer through a press it
  /// actually received. X11 calls this the implicit grab and does it in the
  /// server; Wayland leaves it to the compositor, and this one did not do
  /// it at all — so dragging a scrollbar out of its own window handed the
  /// motion to whatever was underneath and the scroll stopped dead.
  ///
  /// A Lava client needs no flag: `pointerTarget` already is one.
  bool pointerGrabbed = false;
  /// Layout-space origin of the surface holding the seat pointer, captured
  /// on the last motion that was free to choose a target. Motion during a
  /// grab is measured from here, because the cursor is by then somewhere
  /// the hit test would answer with a different surface — or with none.
  ///
  /// A surface that *moves* while grabbed drifts from this, which no drag
  /// this exists for can do: the compositor's own window drags take
  /// `update_drag` above and never reach here.
  double pointerGrabOriginX = 0;
  double pointerGrabOriginY = 0;

  /// Title-bar / client move that has not become a drag yet.
  ///
  /// A press on the bar, or a maximized window asking to be moved, must not
  /// restore the window until the pointer actually travels. A click on
  /// VS Code's tab strip is a move request; treating it as a drag is how
  /// a maximized window jumped off the work area. Double-click also
  /// needs the press to stay a click.
  bool pendingMove = false;
  bool pendingFromClient = false;
  uint32_t pendingSurface = 0;
  double pendingX = 0, pendingY = 0;
  uint32_t lastBarClickTime = 0;
  uint32_t lastBarClickSurface = 0;

  /// Remembers a move until the pointer leaves the slop, or the button
  /// comes up. `fromClient` is who holds the press — see `dragFromClient`.
  void armInteractiveMove(ClientSurface &surface, bool fromClient);
  /// Starts the armed move if the pointer has travelled far enough.
  void flushPendingMove();

  /// Carries an in-progress drag to the pointer. True if one was live, which
  /// is the caller's signal that the motion belongs to the drag and not to
  /// whatever is under the cursor.
  bool update_drag();

  /// Puts the image `surface` asked for on the pointer, if the pointer is
  /// over it and nothing of the compositor's own has a better claim.
  ///
  /// For a client that changed its mind without the pointer moving — which is
  /// every `SetCursor`, since what prompts one is the pointer arriving
  /// somewhere it already is.
  void applyCursorFor(const ClientSurface &surface);

  /// Starts an interactive move of a client-framed window, as a title bar
  /// press does for a decorated one. False when there is no button down to
  /// carry it. See `lava::Compositor::BeginMove`.
  bool beginInteractiveMove(ClientSurface &surface, bool fromClient = false);

  /// Starts an interactive resize pulling `edges`, as a drag on a window's
  /// border does. False when there is no button down to carry it.
  bool beginInteractiveResize(ClientSurface &surface, uint32_t edges,
                              bool fromClient = false);

  /// Whether this compositor draws the frame for `toplevel`.
  ///
  /// It does when the client asked through xdg-decoration, because the answer
  /// was "server side" and the client is drawing nothing itself. It does not
  /// when the client never asked at all: a toolkit with no xdg-decoration
  /// support — GTK is the one everybody meets — always draws its own header,
  /// so a bar from us would be the second one on the window. That is what the
  /// protocol means by leaving the mode client-side in the absence of a
  /// decoration object, and what KWin and Mutter do with the same silence.
  bool serverDecorated(wlr_xdg_toplevel *toplevel) const;

  /// The xdg-decoration manager, for the question above. Null before `main`
  /// creates it.
  wlr_xdg_decoration_manager_v1 *decorations = nullptr;

  /// Gives a window the keyboard and the active frame paint, whichever kind
  /// of window it is. Both halves matter and they are easy to do by halves:
  /// the workspace's keyboard target and the decoration's "this one is
  /// active" are separate pieces of state that must agree.
  void focusSurface(ClientSurface &surface);

  /// Hides a window and moves focus off it, so the keyboard does not go on
  /// pointing at something nobody can see.
  void minimizeSurface(ClientSurface &surface);

  /// Windows Win+D: hide every window on this workspace, or bring back
  /// the ones that press hid. A second press restores even if the user
  /// opened something in between.
  void toggleShowDesktop();

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
  /// Who had the keyboard before the window that has it now, per
  /// workspace. Close and minimize consult this rather than stacking
  /// order — see `restoreFocus`.
  lava::FocusHistory focusHistory;
  Workspaces workspaces;

  /// Modifier that keeps the app switcher open (Ctrl, or the desktop mod).
  /// 0 when no switcher session is live. Release of this bit commits.
  uint32_t switcherHold = 0;
  /// Ctrl came up before CreateSurface. Dismiss the overlay on map rather
  /// than showing it after the user already let go.
  bool switcherDismissOnMap = false;

  void beginSwitcherSession(uint32_t holdMask);
  void dismissSwitcherOnMapIfNeeded(ClientSurface &surface);
  void onSwitcherHoldReleased();
  void injectSwitcherCommit();

  /// What the machine looks like: which GPU, which screens at which sizes,
  /// what the keyboard is. Re-read on SIGHUP — see `reload_config`.
  lava::Config config;
  std::string configPath;
  /// Running inside another compositor (inherited `WAYLAND_DISPLAY` /
  /// `DISPLAY`). Shortcuts then use Alt regardless of `mod-key`, so
  /// Super+Shift+S and the rest stay with the host.
  bool nested = false;

  uint32_t focusedSurface() const {
    return focusedByWorkspace[workspaces.current];
  }
  void setFocusedSurface(uint32_t id) {
    if (id != focusedByWorkspace[workspaces.current]) {
      // The held key belonged to the previous focus; do not keep stuffing
      // backspaces into whatever is about to take the keyboard.
      stopKeyRepeat();
    }
    focusedByWorkspace[workspaces.current] = id;
  }

  // ─── Key repeat for Lava clients ───────────────────────────────────────
  //
  // libinput delivers only real press and release. Wayland clients get
  // repeats from `wlr_seat` because they speak `wl_keyboard`; a Lava surface
  // does not, so without this timer a held Backspace would erase one cell
  // and stop. Rate and delay are the same numbers `wlr_keyboard_set_repeat_info`
  // already takes from `lava.conf`.

  /// Arm (or re-arm) repeat for a key just pressed into a client surface.
  void startKeyRepeat(uint32_t surfaceId, int glfwKey, int32_t mods,
                      std::string text);
  void stopKeyRepeat();
  static int on_key_repeat(void *data);

  wl_event_source *keyRepeatTimer = nullptr;
  uint32_t keyRepeatSurface = 0;
  int keyRepeatKey = 0;
  int32_t keyRepeatMods = 0;
  std::string keyRepeatText;

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

  /// Places every enabled output: stacked at the origin for mirror,
  /// side by side (or at saved non-overlapping positions) for extend.
  void applyArrangement();

  /// Shows workspace `index` and hands it the keyboard. A no-op if it is
  /// already current, so a repeated shortcut costs nothing.
  void switchWorkspace(uint32_t index);
  /// Sends whatever has the keyboard to workspace `index`, and stays put.
  void moveFocusedToWorkspace(uint32_t index);
  /// The front window of a workspace, or null if it has none.
  FramedWindow *frontToplevel(uint32_t workspace);
  /// Our frame id for an X11 window, or 0 for one we do not frame.
  /// `WM_TRANSIENT_FOR` names a `wlr_xwayland_surface`, and the list of
  /// X11 windows is the only way back from one to a frame.
  uint32_t x11FrameId(const wlr_xwayland_surface *xsurface) const;
  /// Notes that `surface` now has the keyboard / the active frame.
  /// Panels and the switcher are ignored.
  void recordFocus(const ClientSurface &surface);
  /// After `exceptId` closed or hid: give this workspace the window that
  /// had focus just before it. Falls back to the topmost live window.
  void restoreFocus(uint32_t workspace, uint32_t exceptId);

  Listener<Server> new_output;
  Listener<Server> new_toplevel;
  Listener<Server> new_popup;
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
  Listener<Server> new_pointer_constraint;
  Listener<Server> pointer_focus_change;
  Listener<Server> active_constraint_destroy;
  Listener<Server> request_set_selection;
  Listener<Server> set_selection;
  Listener<Server> request_set_primary_selection;
  Listener<Server> request_start_drag;
  Listener<Server> start_drag;

  /// Unhooks everything above, for shutdown.
  ///
  /// `wl_display_destroy` asserts that the globals it is tearing down have no
  /// listeners left — `wlr_xdg_shell` is the one that catches it first — so a
  /// compositor that just destroys the display aborts on the way out instead
  /// of returning from `main`. That costs nothing on a real logout and quite a
  /// lot when the session is a nested one being restarted every few minutes:
  /// the control plane's reference is never unlinked, because the destructor
  /// that unlinks it does not run.
  void detachListeners() {
    for (Listener<Server> *listener :
         {&new_output, &new_toplevel, &new_popup, &new_decoration,
          &new_xwayland_surface, &xwayland_ready, &new_input, &cursor_motion,
          &cursor_motion_absolute, &cursor_button, &cursor_axis, &cursor_frame,
          &request_cursor, &new_pointer_constraint, &pointer_focus_change,
          &active_constraint_destroy, &request_set_selection, &set_selection,
          &request_set_primary_selection, &request_start_drag, &start_drag}) {
      listener->detach();
    }
  }

  static void on_new_output(wl_listener *listener, void *data);
  static void on_new_toplevel(wl_listener *listener, void *data);
  static void on_new_popup(wl_listener *listener, void *data);
  /// The box a popup may be placed in, in the coordinates its positioner
  /// uses — the work area translated so the parent window's origin is 0,0.
  wlr_box popupBounds(const wlr_xdg_popup &popup) const;
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
  static void on_new_pointer_constraint(wl_listener *listener, void *data);
  static void on_pointer_focus_change(wl_listener *listener, void *data);
  static void on_active_constraint_destroy(wl_listener *listener, void *data);
  void activatePointerConstraint(wlr_pointer_constraint_v1 *constraint);
  static void on_request_start_drag(wl_listener *listener, void *data);
  static void on_start_drag(wl_listener *listener, void *data);
  /// Keeps the drag icon under the cursor. Does nothing when no client is
  /// dragging anything.
  void moveDragIcon();
  static void on_request_set_selection(wl_listener *listener, void *data);
  static void on_set_selection(wl_listener *listener, void *data);
  static void on_request_set_primary_selection(wl_listener *listener,
                                               void *data);

  /// Deepest surface under a layout-space point, plus that point in the
  /// surface's own coordinates. Null when the cursor is over blank desktop.
  ///
  /// `out_window` is the window that owns the surface — an xdg toplevel or an
  /// X11 one, which is why it is a `FramedWindow` and not a `Toplevel`. Null
  /// for anything that owns its own stacking: a popup, an override-redirect
  /// X11 menu.
  wlr_surface *surface_at(double lx, double ly, double *sx, double *sy,
                          FramedWindow **out_window);

  void focus(FramedWindow *window);
  /// The inverse: nothing is focused, because the click landed on the desktop.
  void blurAll();
  void update_pointer_focus(uint32_t time_msec);
  void update_seat_capabilities();

  /// Sends one event to the client surface under the pointer.
  ///
  /// True when a surface took it, which is also the caller's signal not to
  /// hand the same event to a Wayland client: the two focus models are
  /// separate and an event belongs to exactly one of them.
  bool route_pointer(uint32_t kind, int32_t button, int32_t mods);

  /// Print Screen: copy the output under the cursor onto the seat selection
  /// as a PNG. Tries an offscreen render first so the buffer is not the
  /// one the display is scanning out; falls back to the next committed
  /// frame if that cannot be read. See `Output::pendingScreenshot`.
  void requestScreenshot();
  /// Alt+Print Screen: the same picture, cropped to one window.
  ///
  /// Cropped out of a full render rather than read from the client's own
  /// buffer, so it works the same for a Lava surface as for a foreign one
  /// and comes back with the title bar the user is looking at. What it
  /// cannot do is see through anything sitting on top of the window —
  /// which is the honest answer for a screenshot.
  void requestWindowScreenshot(const ClientSurface &surface);
  bool captureOutputNow(Output *output, const wlr_box *crop = nullptr);
  bool finishScreenshot(wlr_buffer *buffer);
  Output *outputForScreenshot();
  /// The output showing `(x, y)` in layout space, or null.
  Output *outputAtPoint(int x, int y);
  bool renderOutputPng(Output *output, std::vector<uint8_t> &png,
                       uint32_t &width, uint32_t &height,
                       const wlr_box *crop = nullptr);
  /// Ask the output for a new frame so the portal can read the committed
  /// buffer. Does not read GPU memory on this call.
  bool schedulePortalCapture();

  std::unique_ptr<lava::ScreenshotPortal> screenshotPortal;
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
  ///
  /// Null when the window has no frame — a panel, or a LavaUI client that
  /// asked for `WindowFrame::client` and draws its own controls. Everything
  /// that touches the bar therefore checks, and `decorated` is the one flag
  /// that says which world a window is in.
  std::unique_ptr<lava::CanvasSurface> bar;
  wlr_scene_buffer *barNode = nullptr;
  lava::DecorationHit hovered = lava::DecorationHit::Bar;

  /// What the application calls itself — an xdg-shell `app_id`, or what a
  /// lava client passed to `CreateSurface`. The identity a dock finds an icon
  /// by, and the one two windows of an application share; the title is not
  /// that, since it changes with the document.
  std::string appId;

  /// Dialog, tool window, or anything with a parent. Shares the
  /// parent's `appId`, so it must not inherit (or overwrite) the
  /// remembered frame for that name.
  bool transient = false;
  /// Frame id of the parent window, if we know one. Used to centre a
  /// dialog on whatever opened it.
  uint32_t parentId = 0;

  /// Where this surface takes pointer input, in its own coordinates. Zero
  /// width or height means the whole surface, which is every window's answer
  /// and most panels'. See `SetInputRegion`.
  int32_t inputX = 0;
  int32_t inputY = 0;
  uint32_t inputW = 0;
  uint32_t inputH = 0;

  /// The pointer image this client asked for, as a `CursorShape` ordinal.
  ///
  /// A preference, not a setting: it applies while the pointer is inside this
  /// surface and the compositor's own affordances — the resize band, the
  /// title bar — still win over it. See `SetCursor`.
  uint32_t cursorShape = 0;

  /// Whether `sx, sy` — already surface-local — is somewhere this surface
  /// accepts input. A dock is a full-width strip with a few icons in it, and
  /// the strip between them belongs to whatever is underneath.
  bool acceptsInput(double sx, double sy) const {
    if (inputW == 0 || inputH == 0) return true;
    return sx >= inputX && sy >= inputY && sx < inputX + inputW &&
           sy < inputY + inputH;
  }

  /// The drop shadow: nine scene nodes onto one shared image.
  ///
  /// Behind the window rather than around it, which is what lets it exist at
  /// all for a Wayland client — a shadow falls on what is *under* a window and
  /// needs nothing from the window's own pixels, unlike rounding, which has to
  /// reshape them.
  ///
  /// It owns no pixels. A blurred rounded rectangle is the same picture at
  /// every size — corners that do not change, edges that are constant along
  /// their length, an interior that is one colour — so one tile is stretched
  /// over any window by `SurfaceRegistry::ShadowTile`, and what a window keeps
  /// is nine `wlr_scene_buffer`s pointing into it. The tree is what everything
  /// else moves, enables and reparents, exactly as it did the single node this
  /// replaces.
  ///
  /// Only the focused window's is enabled. That is the whole feature: it says
  /// which window is active in the place the user is already looking, instead
  /// of a tinted border they have to go and check.
  wlr_scene_tree *shadowTree = nullptr;
  std::array<wlr_scene_buffer *, 9> shadowSlices{};
  /// What the slices were last laid out for, so a move does not redo a resize's
  /// work. Width and height of the *window*; the tile's own numbers are its.
  uint32_t shadowW = 0;
  uint32_t shadowH = 0;
  float    shadowRadius = -1.f;

  /// Compositor frost under this window. See `SetBackdropBlur`.
  /// A canvas surface so the blur runs on the compositing Vulkan device
  /// (`BlurPass`), not a CPU box filter.
  float backdropBlurRadius = 0.f;
  std::unique_ptr<lava::CanvasSurface> blurCanvas;
  wlr_scene_buffer *blurNode = nullptr;
  std::string blurKey;
  uint32_t blurGen = 0;

  /// Whether the compositor draws this window's non-client area.
  ///
  /// False costs the window nothing except the strip: it is still placed,
  /// stacked, maximized, moved and resized by the compositor, and asks for
  /// those through `BeginMove` / `ToggleMaximize` / `Minimize` instead of
  /// through buttons drawn here. The only geometric difference is that its
  /// content starts at the frame origin rather than a bar below it, which
  /// `contentY` is the single place that knows.
  bool decorated = true;

  int x = 0;
  int y = 0;
  uint32_t width = 0;
  uint32_t height = 0;

  /// Which workspace it is on. Assigned at creation, from whichever was
  /// current: `CreateSurface` has no say in it and should not — a client that
  /// could choose its workspace could also follow the user around.
  uint32_t workspace = 0;

  /// The smallest the client says this window may usefully be, in pixels;
  /// 0 means it has no opinion about that axis. See `SetMinSize`.
  uint32_t minWidth = 0;
  uint32_t minHeight = 0;

  /// Panels have no frame and are laid out by their edge, not by the user.
  bool panel = false;
  /// Which edge, for a panel. Meaningless otherwise. Kept rather than inferred
  /// from the position, so the work area does not have to guess.
  uint32_t edge = 0;
  /// How much of a panel's thickness windows are laid out around, in pixels.
  /// 0 floats over them, which is what an overlay wants.
  ///
  /// A number rather than a flag, because the two stopped being the same
  /// thing: a panel with a menu on it grows to make room for an open dropdown
  /// while still reserving only its strip, so the windows underneath do not
  /// jump every time a menu opens. See `SetPanelThickness`.
  uint32_t reserved = 0;

  /// Where a maximized or fullscreen window came from, so restoring is exact.
  bool maximized = false;
  /// Covers the output, including the panel. Distinct from maximize: a
  /// maximized window leaves the work area, a fullscreen one does not.
  bool fullscreen = false;
  bool deferredWhileOccluded = false;
  int restoreX = 0;
  int restoreY = 0;
  uint32_t restoreW = 0;
  uint32_t restoreH = 0;

  /// Hidden, but alive: the client keeps its surface, its arena and its input
  /// stream, and the scene simply stops drawing it. See `Minimize`.
  bool minimized = false;

  /// Content node is off until the first `Present`. CreateSurface puts an
  /// empty buffer in the scene; showing it is a flash of desktop-through-
  /// a-hole (or a black slab) before the client has drawn. The switcher
  /// is the case that made this load-bearing.
  bool awaitingFirstFrame = false;

  /// Whether the compositor title bar is on screen.
  ///
  /// A maximized window gives the bar up: the panel already names it, and a
  /// 32 px strip under the panel is just a second title. Fullscreen does
  /// the same, and covers the panel too. Restoring puts the bar back.
  /// `decorated` is still the lasting choice (who draws the chrome); this
  /// is only whether that chrome is showing *now*.
  bool showsBar() const { return decorated && !maximized && !fullscreen; }

  /// Where the content starts — below the bar, or at the frame origin when
  /// there is no bar to be below.
  int contentY() const {
    return showsBar() ? y + lava::Decoration::kHeight : y;
  }

  /// Total height on screen, frame included. What a resize drag works in, and
  /// what an edge is measured from.
  int frameHeight() const {
    return static_cast<int>(height) +
           (showsBar() ? lava::Decoration::kHeight : 0);
  }

  /// Whether `lx, ly` (layout space) is inside the content, and where in it.
  bool hit(double lx, double ly, double &sx, double &sy) const {
    sx = lx - x;
    sy = ly - contentY();
    return sx >= 0 && sy >= 0 && sx < width && sy < height;
  }

  /// Whether `lx, ly` is on the title bar, and where along it. Always false
  /// for a window that has none — which is what keeps every bar path below
  /// from needing to ask twice.
  bool hitBar(double lx, double ly, double &sx, double &sy) const {
    if (!showsBar()) return false;
    sx = lx - x;
    sy = ly - y;
    return sx >= 0 && sy >= 0 && sx < width &&
           sy < lava::Decoration::kHeight;
  }
};

/// Puts a canvas surface's buffer on its scene node: the one way one of ours
/// reaches the screen.
///
/// Three things have to be said together, and saying any two of them is a bug
/// that only shows up sometimes:
///
///   * **the buffer**, again on every frame, because the contents changed even
///     though the buffer did not;
///   * **the crop**, because an exported buffer is allocated in steps and is
///     normally larger than the window it carries (see
///     `Application::exportCapacity`) — the frame lands in its top-left
///     corner, and past that corner is whatever the last larger frame left
///     behind. The source box says which part to sample; the destination size
///     says to draw it at its own size rather than stretched over the whole
///     buffer;
///   * **the fence**, because the frame may still be being drawn. Canvas used
///     to block until the GPU had finished before it returned — on the event
///     loop, where it cost every other client the same milliseconds — and now
///     hands over the point that will be signalled instead. Waiting is the
///     scene's job from here.
void show_surface(wlr_scene_buffer *node, lava::CanvasSurface &surface) {
  if (node == nullptr) return;
  const lava::CanvasSurface::FrameFence fence = surface.frameFence();
  const wlr_scene_buffer_set_buffer_options options{
      .damage = nullptr,
      .wait_timeline = fence.timeline,
      .wait_point = fence.point,
  };
  wlr_scene_buffer_set_buffer_with_options(node, surface.buffer(), &options);

  const wlr_fbox source{
      .x = 0,
      .y = 0,
      .width = static_cast<double>(surface.width()),
      .height = static_cast<double>(surface.height()),
  };
  wlr_scene_buffer_set_source_box(node, &source);
  wlr_scene_buffer_set_dest_size(node, static_cast<int>(surface.width()),
                                 static_cast<int>(surface.height()));

  // ...and **the opaque region**, a fourth thing that has to be said with the
  // rest of them.
  //
  // A canvas surface is exported as ARGB8888 with premultiplied alpha and the
  // scene has no way to know that most of one is a solid slab, so without this
  // it blends every pixel of every Lava window and draws everything behind
  // them to have something to blend against. Saying which part cannot let
  // light through lets it skip both.
  //
  // Shrunk to the frame rather than the buffer: an exported image is allocated
  // in steps and is normally larger than the window it carries, and the slack
  // past `width()`/`height()` is whatever the last larger frame left there —
  // the same reason the source box exists a few lines up.
  //
  // Re-stated every frame because the claim is per frame: the client rebuilds
  // it from its own backdrop each time, so a window that fades itself out
  // stops being opaque without anyone having to remember to retract anything.
  pixman_region32_t opaque;
  pixman_region32_init(&opaque);
  float ox = 0.f, oy = 0.f, ow = 0.f, oh = 0.f;
  if (surface.opaqueBounds(ox, oy, ow, oh)) {
    const int x0 = std::max(0, static_cast<int>(std::ceil(ox)));
    const int y0 = std::max(0, static_cast<int>(std::ceil(oy)));
    const int x1 = std::min(static_cast<int>(surface.width()),
                            static_cast<int>(std::floor(ox + ow)));
    const int y1 = std::min(static_cast<int>(surface.height()),
                            static_cast<int>(std::floor(oy + oh)));
    if (x1 > x0 && y1 > y0) {
      pixman_region32_union_rect(&opaque, &opaque, x0, y0,
                                 static_cast<unsigned>(x1 - x0),
                                 static_cast<unsigned>(y1 - y0));
    }
  }
  // An empty region is the honest answer for a frame that claimed nothing, and
  // is also what restores the default — so the unset case needs no branch.
  wlr_scene_buffer_set_opaque_region(node, &opaque);
  pixman_region32_fini(&opaque);
}

// ─── Scene-graph input regions ─────────────────────────────────────────────
//
// `SetInputRegion` is how a panel or dock says "only this rectangle is mine".
// The Lava hit path (`hitTest` / `acceptsInput`) has always honoured it. The
// *scene* did not: `wlr_scene_node_at` walks buffers top-down and treats every
// opaque-or-not canvas node as a hard occluder. A taskbar that is 600 px tall
// so menus can paint into it — with only the top 32 px accepting input — was
// still a 600 px scene buffer above every window, so `surface_at` returned
// null for GTK and friends and the seat never got `pointer.enter`. No enter,
// no clicks. Shadows had the same shape of bug on a smaller scale: a blur
// ring around the focused window that sat above every window behind it.
//
// `point_accepts_input` is wlroots' hook for this. Returning false makes the
// hit walk continue underneath, which is exactly "these pixels are not input".

/// Content of a Lava surface: honour `SetInputRegion` (whole surface when
/// unset). `node.data` is the owning `ClientSurface`.
bool content_point_accepts_input(wlr_scene_buffer *buffer, double *sx,
                                 double *sy) {
  auto *surface = static_cast<ClientSurface *>(buffer->node.data);
  if (surface == nullptr) return true;
  return surface->acceptsInput(*sx, *sy);
}

/// Never: decorations that only *look* like they occupy space (shadows).
bool never_point_accepts_input(wlr_scene_buffer *, double *, double *) {
  return false;
}

/// Wires a content buffer to its surface's input region. Safe to call more
/// than once; the region itself is read live from the surface.
void bind_content_input(wlr_scene_buffer *node, ClientSurface *surface) {
  if (node == nullptr || surface == nullptr) return;
  node->node.data = surface;
  node->point_accepts_input = content_point_accepts_input;
}

void bind_never_input(wlr_scene_buffer *node) {
  if (node == nullptr) return;
  node->point_accepts_input = never_point_accepts_input;
}

/// Which sides of a window a resize drag is pulling. A bitmask because a
/// corner is two of them, and there is no third thing an edge can be.
namespace edges {
constexpr uint32_t kLeft = 1u;
constexpr uint32_t kRight = 2u;
constexpr uint32_t kTop = 4u;
constexpr uint32_t kBottom = 8u;
}  // namespace edges

/// wlroots' edge bits in ours. The two disagree — `WLR_EDGE_*` is
/// top/bottom/left/right and `edges::` is left/right/top/bottom — and a
/// straight cast would turn a client dragging its top edge into a resize from
/// the left. Written out rather than reordered to match, because the four
/// constants above are also what the control plane sends to LavaUI clients.
inline uint32_t fromWlrEdges(uint32_t wlr) {
  uint32_t out = 0;
  if (wlr & WLR_EDGE_LEFT) out |= edges::kLeft;
  if (wlr & WLR_EDGE_RIGHT) out |= edges::kRight;
  if (wlr & WLR_EDGE_TOP) out |= edges::kTop;
  if (wlr & WLR_EDGE_BOTTOM) out |= edges::kBottom;
  return out;
}

/// What a layout-space pointer resolved to, walking the window stack top-down.
///
/// Bars and contents of a single window are both rectangles in the same plane
/// as every other window. Testing "any title bar under this point" without
/// asking whether a higher window's content covers that point first is how a
/// click on the active window ends up on the inactive window's non-client
/// strip and raises it.
enum class SurfaceHitKind {
  None,
  /// Compositor-owned title bar.
  Bar,
  /// LavaUI client content — input goes through the control plane.
  ClientContent,
  /// Wayland/X11 content — occludes what is behind; input goes through the seat.
  ForeignContent,
};

struct SurfaceHit {
  ClientSurface *surface = nullptr;
  SurfaceHitKind kind = SurfaceHitKind::None;
  double sx = 0;
  double sy = 0;
};

/// A number for a config file: no trailing zeros, no exponent, no locale.
///
/// `1` rather than `1.000000`, because this is written into a file people
/// read and edit, and a scale of 1 written as 1.000000 is a compositor
/// showing its floating point.
std::string format_float(double value) {
  std::string text = std::format("{:.3f}", value);
  const auto lastNonZero = text.find_last_not_of('0');
  if (lastNonZero != std::string::npos) {
    text.erase(text[lastNonZero] == '.' ? lastNonZero : lastNonZero + 1);
  }
  return text;
}

/// "1920x1080@74.973", or "preferred" when no size was asked for.
std::string format_mode(const lava::OutputConfig &output) {
  if (!output.hasMode()) return "preferred";
  std::string text =
      std::to_string(output.width) + "x" + std::to_string(output.height);
  // Written in Hz because that is how a monitor is sold, and stored in mHz
  // because that is what modes are matched in — see `parseMode`.
  if (output.refresh > 0) text += "@" + format_float(output.refresh / 1000.0);
  return text;
}

/// The `wl_output_transform` names the config parser accepts.
std::string format_transform(int32_t transform) {
  switch (transform) {
  case WL_OUTPUT_TRANSFORM_90: return "90";
  case WL_OUTPUT_TRANSFORM_180: return "180";
  case WL_OUTPUT_TRANSFORM_270: return "270";
  case WL_OUTPUT_TRANSFORM_FLIPPED: return "flipped";
  case WL_OUTPUT_TRANSFORM_FLIPPED_90: return "flipped-90";
  case WL_OUTPUT_TRANSFORM_FLIPPED_180: return "flipped-180";
  case WL_OUTPUT_TRANSFORM_FLIPPED_270: return "flipped-270";
  default: return "normal";
  }
}

/// What to call a screen in a list, when "DP-3" is not enough to tell two
/// connectors apart. Empty when the display says nothing about itself.
std::string describe_output(const wlr_output &output) {
  if (output.description != nullptr && output.description[0] != '\0') {
    return output.description;
  }
  std::string text;
  if (output.make != nullptr && output.make[0] != '\0') text = output.make;
  if (output.model != nullptr && output.model[0] != '\0') {
    if (!text.empty()) text += ' ';
    text += output.model;
  }
  return text;
}

/// The compositor's shortcuts, from the table the key handler dispatches
/// through. Defined next to that table, near the bottom of this file.
void collect_key_bindings(std::vector<lava::CompositorHost::BindingEntry> &out,
                          const char *modName = "Alt");
/// Canonical form of `KeyboardConfig::modKey`: "alt" or "super".
std::string normalize_mod_key(const std::string &value);
/// WLR modifier bit for the configured shortcut mod.
uint32_t shortcut_mod_mask(const lava::KeyboardConfig &keyboard);

/// Every layout this machine's xkb offers, from libxkbregistry.
void collect_keyboard_layouts(
    std::vector<lava::CompositorHost::LayoutEntry> &out);

/// Packs one DRM fourcc pixel into RGBA8. Unknown formats are treated as
/// ARGB8888 (B,G,R,A in memory), which is what almost every Wayland client
/// actually commits.
void drmPixelToRgba(uint32_t format, const uint8_t *src, uint8_t *dst) {
  switch (format) {
  case DRM_FORMAT_ABGR8888:
  case DRM_FORMAT_XBGR8888:
    dst[0] = src[0];
    dst[1] = src[1];
    dst[2] = src[2];
    dst[3] = format == DRM_FORMAT_XBGR8888 ? 255 : src[3];
    break;
  case DRM_FORMAT_RGBA8888:
  case DRM_FORMAT_RGBX8888:
    dst[0] = src[0];
    dst[1] = src[1];
    dst[2] = src[2];
    dst[3] = format == DRM_FORMAT_RGBX8888 ? 255 : src[3];
    break;
  case DRM_FORMAT_BGRA8888:
  case DRM_FORMAT_BGRX8888:
    dst[0] = src[2];
    dst[1] = src[1];
    dst[2] = src[0];
    dst[3] = format == DRM_FORMAT_BGRX8888 ? 255 : src[3];
    break;
  case DRM_FORMAT_ARGB8888:
  case DRM_FORMAT_XRGB8888:
  default:
    dst[0] = src[2];
    dst[1] = src[1];
    dst[2] = src[0];
    dst[3] = format == DRM_FORMAT_XRGB8888 ? 255 : src[3];
    break;
  }
}

bool encodeForeignRgba(const uint8_t *src, int width, int height, int stride,
                       uint32_t format, int32_t maxSide,
                       std::vector<uint8_t> &outPng, uint32_t &outW,
                       uint32_t &outH) {
  if (src == nullptr || width < 1 || height < 1 || stride < width * 4) {
    return false;
  }
  std::vector<uint8_t> rgba(static_cast<size_t>(width) *
                            static_cast<size_t>(height) * 4);
  for (int y = 0; y < height; ++y) {
    const uint8_t *row = src + static_cast<size_t>(y) * stride;
    uint8_t *dst = rgba.data() + static_cast<size_t>(y) * width * 4;
    for (int x = 0; x < width; ++x) {
      drmPixelToRgba(format, row, dst);
      row += 4;
      dst += 4;
    }
  }
  int encW = 0, encH = 0;
  if (!canvas::encodeRgbaPng(rgba.data(), width, height, width * 4, maxSide,
                             outPng, encW, encH)) {
    return false;
  }
  outW = static_cast<uint32_t>(encW);
  outH = static_cast<uint32_t>(encH);
  return true;
}

/// Reads a foreign (Wayland / X11) window's last committed buffer into a PNG.
///
/// Two paths, cheapest first: a CPU map when the buffer exposes one (shm,
/// some dmabufs), then a GPU readback through the scene texture. Either can
/// fail — a client that has not committed, a format we do not unpack, a
/// vulkan renderer that cannot read its own textures — and the caller then
/// draws an icon instead of a poster.
bool captureForeign(const ClientSurface &surface, int32_t maxSide,
                    std::vector<uint8_t> &outPng, uint32_t &outW,
                    uint32_t &outH) {
  if (!surface.isForeign() || surface.window == nullptr) return false;
  wlr_surface *wl = surface.window->focusSurface();
  if (wl == nullptr || wl->buffer == nullptr) return false;

  wlr_client_buffer *client = wl->buffer;
  wlr_buffer *source = client->source != nullptr ? client->source : &client->base;
  wlr_buffer_lock(source);

  bool ok = false;
  void *data = nullptr;
  uint32_t format = 0;
  size_t stride = 0;
  if (wlr_buffer_begin_data_ptr_access(source, WLR_BUFFER_DATA_PTR_ACCESS_READ,
                                       &data, &format, &stride)) {
    ok = encodeForeignRgba(static_cast<const uint8_t *>(data), source->width,
                           source->height, static_cast<int>(stride), format,
                           maxSide, outPng, outW, outH);
    wlr_buffer_end_data_ptr_access(source);
  }

  if (!ok && client->texture != nullptr) {
    wlr_texture *texture = client->texture;
    uint32_t readFormat = wlr_texture_preferred_read_format(texture);
    if (readFormat == 0) readFormat = DRM_FORMAT_ARGB8888;
    const int width = static_cast<int>(texture->width);
    const int height = static_cast<int>(texture->height);
    if (width > 0 && height > 0) {
      std::vector<uint8_t> pixels(static_cast<size_t>(width) *
                                  static_cast<size_t>(height) * 4);
      wlr_texture_read_pixels_options opts{};
      opts.data = pixels.data();
      opts.format = readFormat;
      opts.stride = static_cast<uint32_t>(width * 4);
      if (wlr_texture_read_pixels(texture, &opts)) {
        ok = encodeForeignRgba(pixels.data(), width, height, width * 4,
                               readFormat, maxSide, outPng, outW, outH);
      }
    }
  }

  wlr_buffer_unlock(source);
  return ok;
}

/// PNG of a compositor output buffer: the last presented frame, wallpaper
/// and decorations and every window together.
///
/// Same two paths as `captureForeign`. A GBM/Vulkan swapchain almost never
/// maps, so the useful one is a texture readback. `maxSide` is 0 — Print
/// Screen is a 1:1 copy, not a poster.
/// `crop`, when given, is a rectangle in buffer pixels: the encode reads a
/// window out of the frame rather than the whole thing. Free, because
/// `encodeForeignRgba` already takes a stride — the crop is an offset into
/// the first row and a smaller width and height, with the row pitch of the
/// full buffer left alone.
bool encodeBufferPng(wlr_buffer *buffer, wlr_renderer *renderer,
                     std::vector<uint8_t> &outPng, uint32_t &outW,
                     uint32_t &outH, const wlr_box *crop = nullptr) {
  if (buffer == nullptr || renderer == nullptr) return false;
  wlr_buffer_lock(buffer);

  // Clamped against the buffer rather than trusted: the rectangle comes
  // from layout space, and a window hanging off the edge of its output
  // would otherwise read past the end of the last row.
  const auto clip = [&](int w, int h, int &x0, int &y0, int &cw, int &ch) {
    x0 = 0;
    y0 = 0;
    cw = w;
    ch = h;
    if (crop == nullptr) return true;
    x0 = std::clamp(crop->x, 0, w);
    y0 = std::clamp(crop->y, 0, h);
    cw = std::min(crop->width, w - x0);
    ch = std::min(crop->height, h - y0);
    return cw > 0 && ch > 0;
  };

  bool ok = false;
  void *data = nullptr;
  uint32_t format = 0;
  size_t stride = 0;
  if (wlr_buffer_begin_data_ptr_access(buffer, WLR_BUFFER_DATA_PTR_ACCESS_READ,
                                       &data, &format, &stride)) {
    int x0 = 0, y0 = 0, cw = 0, ch = 0;
    if (clip(buffer->width, buffer->height, x0, y0, cw, ch)) {
      const auto *src = static_cast<const uint8_t *>(data) +
                        static_cast<size_t>(y0) * stride +
                        static_cast<size_t>(x0) * 4;
      ok = encodeForeignRgba(src, cw, ch, static_cast<int>(stride), format, 0,
                             outPng, outW, outH);
    }
    wlr_buffer_end_data_ptr_access(buffer);
  }

  if (!ok) {
    wlr_texture *texture = wlr_texture_from_buffer(renderer, buffer);
    if (texture != nullptr) {
      uint32_t readFormat = wlr_texture_preferred_read_format(texture);
      if (readFormat == 0) readFormat = DRM_FORMAT_ARGB8888;
      const int width = static_cast<int>(texture->width);
      const int height = static_cast<int>(texture->height);
      if (width > 0 && height > 0) {
        std::vector<uint8_t> pixels(static_cast<size_t>(width) *
                                    static_cast<size_t>(height) * 4);
        wlr_texture_read_pixels_options opts{};
        opts.data = pixels.data();
        opts.format = readFormat;
        opts.stride = static_cast<uint32_t>(width * 4);
        if (wlr_texture_read_pixels(texture, &opts)) {
          int x0 = 0, y0 = 0, cw = 0, ch = 0;
          if (clip(width, height, x0, y0, cw, ch)) {
            const uint8_t *src = pixels.data() +
                                 static_cast<size_t>(y0) * width * 4 +
                                 static_cast<size_t>(x0) * 4;
            ok = encodeForeignRgba(src, cw, ch, width * 4, readFormat, 0,
                                   outPng, outW, outH);
          }
        }
      }
      wlr_texture_destroy(texture);
    }
  }

  wlr_buffer_unlock(buffer);
  return ok;
}

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
    if (renderer_ != nullptr) {
      renderer_->setSurfaceTextureResolver(this, &posterResolveThunk);
    }
  }

  /// The seat and the pointer live on `Server`, and a client asking to be
  /// moved or hidden needs both — the drag it starts is the same one a title
  /// bar starts, and the focus it gives up is the same focus a click takes.
  void bind(Server *server) { server_ = server; }

  /// Arms the timer that carries renderer-owned animations along.
  void start(wl_event_loop *loop) {
    animation_ = wl_event_loop_add_timer(loop, on_animation, this);
    // The trailing edge of a settings burst — see `save`.
    saveTimer_ = wl_event_loop_add_timer(loop, on_save_timer, this);
    placements_ = lava::WindowMemory::load(
        lava::WindowMemory::defaultPath(server_ && server_->nested));
    // Periodic, not per-move: the map lives in memory and this is what
    // survives a crash. Shutdown flushes again. On the loop rather than
    // a thread — the file is tiny and a second thread would only add a
    // lock around every remember.
    placementTimer_ = wl_event_loop_add_timer(loop, on_placement_timer, this);
    if (placementTimer_ != nullptr) {
      wl_event_source_timer_update(placementTimer_, kPlacementFlushMs);
    }
  }

  /// Snapshots every live window and writes if the map changed. The
  /// timer and SIGTERM both come through here.
  void flushPlacements() {
    for (const auto &surface : surfaces_) rememberPlacement(*surface);
    placements_.flush();
  }
  void bind(lava::ControlPlane *control) { control_ = control; }
  lava::ControlPlane *control() const { return control_; }

  ClientSurface *find(uint32_t id) {
    for (auto &s : surfaces_) {
      if (s->id == id) return s.get();
    }
    return nullptr;
  }

  ClientSurface *findByAppId(const std::string &appId) {
    if (appId.empty()) return nullptr;
    for (auto &s : surfaces_) {
      if (s->appId == appId) return s.get();
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
    if (surface.minimized) return false;
    // Hidden, not gone: a fullscreen window on this workspace owns the
    // output, and the panel staying clickable on top of a game is how
    // fullscreen failed to be fullscreen.
    if (surface.panel && fullscreenCoversShell()) return false;
    return surface.panel || workspaces_ == nullptr ||
           surface.workspace == workspaces_->current;
  }

  /// True when this window owns an output the way a fullscreen game does:
  /// either it asked (`_NET_WM_STATE_FULLSCREEN` / xdg fullscreen), or it is
  /// an undecorated foreign window sitting exactly on an output — CS:GO's
  /// "windowed fullscreen" is the second, and it never sends the property.
  bool coversItsOutput(const ClientSurface &surface) const {
    if (surface.fullscreen) return true;
    if (!surface.isForeign() || surface.showsBar()) return false;
    int ox = 0, oy = 0;
    uint32_t ow = 0, oh = 0;
    outputBoxAt(surface.x + static_cast<int>(surface.width) / 2,
                surface.y + surface.frameHeight() / 2, ox, oy, ow, oh);
    return surface.x == ox && surface.y == oy && surface.width == ow &&
           surface.frameHeight() == static_cast<int>(oh);
  }

  /// True when a frontmost fullscreen (including an undecorated X11 window
  /// sized exactly to an output) completely hides this surface.
  bool fullyOccluded(const ClientSurface &surface) const {
    if (!visible(surface) || surface.panel) return false;
    for (const auto &front : surfaces_) {
      if (front.get() == &surface) return false;
      if (!visible(*front) || front->workspace != surface.workspace) continue;
      if (!coversItsOutput(*front)) continue;
      if (front->x <= surface.x && front->y <= surface.y &&
          front->x + static_cast<int>(front->width) >=
              surface.x + static_cast<int>(surface.width) &&
          front->y + front->frameHeight() >=
              surface.y + surface.frameHeight()) return true;
    }
    return false;
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
    // A Wayland/X11 window has no canvas node — its pixels live on
    // `window->contentNode()`, which `Server::moveFocusedToWorkspace`
    // already reparents. Dereferencing `node` here is how sending a
    // game to another workspace used to take the compositor with it.
    if (surface.node != nullptr) {
      wlr_scene_node_reparent(&surface.node->node, workspaces_->tree[index]);
    }
    if (surface.barNode != nullptr) {
      wlr_scene_node_reparent(&surface.barNode->node, workspaces_->tree[index]);
    }
    if (surface.shadowTree != nullptr) {
      wlr_scene_node_reparent(&surface.shadowTree->node,
                              workspaces_->tree[index]);
      placeShadow(surface);
    }
    if (surface.blurNode != nullptr) {
      wlr_scene_node_reparent(&surface.blurNode->node,
                              workspaces_->tree[index]);
      placeBackdrop(surface);
    }
    scheduleBackdropRefresh();
    // The pointer is not going with it, so nothing on its frame is hovered any
    // more — and a button left lit would still be lit when it comes back.
    hoverBar(surface, lava::DecorationHit::Bar);
    announceWindows();
    syncShellForFullscreen();
  }

  /// Topmost hit under a layout-space point. Front of `surfaces_` is topmost.
  ///
  /// Walks each window's bar, then its content, before the next window — so a
  /// content rectangle occludes every bar (and every content) behind it. That
  /// is the Z-order the scene graph already draws; hit testing has to match it.
  ///
  /// Panels are tested before windows, whatever order the list is in, because
  /// that is where the scene puts them: they live in their own tree, above
  /// every workspace, and `raise` deliberately never reorders them. Hit
  /// testing did not know that. It mattered the moment a panel became bigger
  /// than its strip — a panel grown to hold an open menu is a tall rectangle
  /// under the window in front of it, so every dropdown row below the window's
  /// top edge answered to the *window*, and only the first row or two of a
  /// menu could be clicked at all.
  SurfaceHit hitTest(double lx, double ly) const {
    if (SurfaceHit hit = hitTestPass(lx, ly, true); hit.surface != nullptr) {
      return hit;
    }
    return hitTestPass(lx, ly, false);
  }

 private:
  SurfaceHit hitTestPass(double lx, double ly, bool panels) const {
    for (const auto &s : surfaces_) {
      if (s->panel != panels || !visible(*s)) continue;
      double sx = 0, sy = 0;
      // Within one window the bar is drawn above the content.
      if (s->hitBar(lx, ly, sx, sy)) {
        return {s.get(), SurfaceHitKind::Bar, sx, sy};
      }
      if (s->hit(lx, ly, sx, sy) && s->acceptsInput(sx, sy)) {
        return {s.get(),
                s->isForeign() ? SurfaceHitKind::ForeignContent
                               : SurfaceHitKind::ClientContent,
                sx, sy};
      }
    }
    return {};
  }

 public:

  /// Updates every window's bar hover for a pointer at `lx, ly`.
  ///
  /// True when the pointer is over a bar, which is also the caller's signal to
  /// stop: a title bar is the compositor's and the window under it should not
  /// also see the motion.
  bool hoverFrames(double lx, double ly) {
    const SurfaceHit top = hitTest(lx, ly);
    for (auto &surface : surfaces_) {
      if (!visible(*surface)) continue;
      lava::DecorationHit hit = lava::DecorationHit::Bar;
      const bool on =
          top.kind == SurfaceHitKind::Bar && top.surface == surface.get();
      if (on) {
        hit = lava::Decoration::hitTest(static_cast<float>(top.sx),
                                        static_cast<float>(top.sy),
                                        surface->width);
      }
      // Windows the pointer is *not* over have their highlight cleared, which
      // is what stops a button staying lit after the cursor leaves it.
      hoverBar(*surface, on ? hit : lava::DecorationHit::Bar);
    }
    return top.kind == SurfaceHitKind::Bar;
  }

  /// Topmost window whose bar is under a layout-space point, with nothing
  /// higher in the stack covering that point.
  ClientSurface *frameAt(double lx, double ly, double &sx, double &sy) {
    const SurfaceHit top = hitTest(lx, ly);
    if (top.kind != SurfaceHitKind::Bar) return nullptr;
    sx = top.sx;
    sy = top.sy;
    return top.surface;
  }

  /// Topmost *window* under a point, of either kind.
  ///
  /// Separate from `at` because the two questions differ: `at` asks "who
  /// should receive this pointer event", which a Wayland window answers
  /// through the seat instead; this asks "which window is here", which is what
  /// a compositor-level gesture like Alt+drag needs.
  ClientSurface *windowAt(double lx, double ly) {
    const SurfaceHit top = hitTest(lx, ly);
    if (top.surface == nullptr || top.surface->panel) return nullptr;
    return top.surface;
  }

  /// Topmost LavaUI content under a layout-space point.
  ///
  /// Foreign (Wayland) content is deliberately absent: its pointer input goes
  /// through the seat. It still occludes via `hitTest`, so a window behind a
  /// Wayland client is not reachable here either.
  ClientSurface *at(double lx, double ly, double &sx, double &sy) {
    const SurfaceHit top = hitTest(lx, ly);
    if (top.kind != SurfaceHitKind::ClientContent) return nullptr;
    sx = top.sx;
    sy = top.sy;
    return top.surface;
  }

  /// A window whose edge is within grabbing distance of `lx, ly`, and which
  /// edges those are.
  ///
  /// The zone is *outside* the window rather than a margin cut out of it: a
  /// window with no title bar has no spare pixels to give up, and an app whose
  /// own scrollbar sits four pixels from the edge should not find the last
  /// four of them belonging to the compositor. Nothing is drawn there — the
  /// band is over whatever is behind the window, which is why this is only
  /// asked when the ordinary hit test found nothing at all. That refusal is
  /// deliberate: an invisible band that took precedence over a *visible*
  /// window underneath would resize a window the user was not pointing at.
  ClientSurface *borderAt(double lx, double ly, uint32_t &outEdges) {
    outEdges = 0;
    if (hitTest(lx, ly).kind != SurfaceHitKind::None) return nullptr;
    for (const auto &s : surfaces_) {
      // A panel is on an edge of the screen by definition and is not the
      // user's to resize; a maximized window has already been given the work
      // area and would fight the next thing that re-applied it.
      if (!visible(*s) || s->panel || s->maximized || s->fullscreen) continue;
      const double x0 = s->x, y0 = s->y;
      const double x1 = x0 + s->width, y1 = y0 + s->frameHeight();
      if (lx < x0 - kGrab || lx > x1 + kGrab) continue;
      if (ly < y0 - kGrab || ly > y1 + kGrab) continue;

      uint32_t hit = 0;
      if (lx <= x0) hit |= edges::kLeft;
      if (lx >= x1) hit |= edges::kRight;
      if (ly <= y0) hit |= edges::kTop;
      if (ly >= y1) hit |= edges::kBottom;
      // Inside on both axes means the point is in the window, which the hit
      // test above has already ruled out — but a window whose content is
      // covered by nothing still owns its own interior, so refuse rather than
      // return an empty edge set.
      if (hit == 0) continue;
      outEdges = hit;
      return s.get();
    }
    return nullptr;
  }

  /// Hides a window without ending it, or brings it back.
  ///
  /// The scene node is disabled rather than reparented or destroyed: the
  /// client goes on owning its surface and its arena, keeps publishing frames
  /// if it feels like it, and none of them are drawn. `visible` is what keeps
  /// the pointer out — a hidden window that still hit-tested would take clicks
  /// from whatever the user can actually see.
  void setMinimized(ClientSurface &surface, bool minimized) {
    if (surface.panel) return;
    if (surface.minimized == minimized) {
      if (surface.isForeign()) surface.window->setMinimized(minimized);
      return;
    }
    surface.minimized = minimized;
    if (surface.isForeign()) {
      wlr_scene_node_set_enabled(surface.window->contentNode(), !minimized);
      surface.window->setMinimized(minimized);
    } else if (surface.node != nullptr) {
      wlr_scene_node_set_enabled(&surface.node->node, !minimized);
    }
    syncBar(surface);
    if (surface.shadowTree != nullptr) {
      wlr_scene_node_set_enabled(&surface.shadowTree->node, false);
    }
    // Nothing on a hidden window's frame is hovered, and a button left lit
    // would still be lit when it comes back.
    hoverBar(surface, lava::DecorationHit::Bar);
    if (minimized) {
      minimizedOrder_.push_back(surface.id);
      // The window node is off; the frost plate is a sibling and would
      // otherwise keep blurring the desktop where the terminal was.
      if (surface.blurNode != nullptr) {
        wlr_scene_node_set_enabled(&surface.blurNode->node, false);
      }
    } else {
      std::erase(minimizedOrder_, surface.id);
      if (surface.backdropBlurRadius > 0.f) scheduleBackdropRefresh();
    }
    announceWindows();
    syncShellForFullscreen();
    wlr_log(WLR_INFO, "window %u: %s", surface.id,
            minimized ? "minimized" : "restored");
  }

  /// Un-hides the most recently minimized window *of this workspace* and
  /// returns it, or null if it has none hidden.
  ///
  /// A stack rather than a list, because there is nothing yet that can *show*
  /// the set — the panel has no window list, so "the one you just put away" is
  /// the only entry a user could name. When a window list exists this becomes
  /// its click handler and the stack becomes a detail.
  ///
  /// Per workspace for the reason everything else here is: a window belongs to
  /// one, and restoring one from another workspace would bring back something
  /// the user cannot see and did not ask for.
  ClientSurface *restoreLastMinimized() {
    // Closed while hidden — drop them here, since nothing else walks this.
    std::erase_if(minimizedOrder_,
                  [this](uint32_t id) { return find(id) == nullptr; });
    for (auto it = minimizedOrder_.rbegin(); it != minimizedOrder_.rend();
         ++it) {
      ClientSurface *surface = find(*it);
      if (workspaces_ != nullptr &&
          surface->workspace != workspaces_->current) {
        continue;
      }
      setMinimized(*surface, false);
      return surface;
    }
    return nullptr;
  }

  /// Hide every visible window on the current workspace. Remembers them
  /// so `restoreDesktop` can put the same set back.
  void hideDesktop() {
    desktopHidden_.clear();
    std::vector<uint32_t> ids;
    for (const auto &s : surfaces_) {
      if (s->panel || s->minimized) continue;
      if (s->appId == kSwitcherAppId) continue;
      if (workspaces_ != nullptr && s->workspace != workspaces_->current) {
        continue;
      }
      ids.push_back(s->id);
    }
    for (uint32_t id : ids) {
      if (ClientSurface *s = find(id)) {
        setMinimized(*s, true);
        desktopHidden_.push_back(id);
      }
    }
    desktopShown_ = !desktopHidden_.empty();
  }

  /// Bring back what `hideDesktop` hid. Returns the window that was in
  /// front, or 0 if there was nothing to restore.
  uint32_t restoreDesktop() {
    const uint32_t front = desktopHidden_.empty() ? 0 : desktopHidden_.front();
    for (auto it = desktopHidden_.rbegin(); it != desktopHidden_.rend(); ++it) {
      if (ClientSurface *s = find(*it); s != nullptr && s->minimized) {
        setMinimized(*s, false);
      }
    }
    desktopHidden_.clear();
    desktopShown_ = false;
    return front;
  }

  bool desktopShown() const { return desktopShown_; }

  bool empty() const { return surfaces_.empty(); }

  /// The smallest a window is allowed to get. Public because a resize drag
  /// lives on `Server` and has to stop at the same number this does.
  static constexpr uint32_t minSurface() { return kMinSurface; }

  // ─── CompositorHost ──────────────────────────────────────────────────────

  int registerFont(const std::string &path, uint32_t pixelSize26_6,
                   uint32_t faceIndex, uint32_t rasterFlags) override {
    // Straight to the device, which exists before any surface does — that is
    // the whole reason the renderer and the surfaces are separate objects.
    // The atlas is device-wide, so a face registered by one client is already
    // rasterised for the next, and the id means the same thing to both.
    return renderer_ ? renderer_->registerFont(path, pixelSize26_6, faceIndex,
                                               rasterFlags)
                     : -1;
  }

  int registerImage(const std::string &key, const std::string &path,
                    uint32_t maxPixelSize, uint32_t &outWidth,
                    uint32_t &outHeight) override {
    // Straight to the device for the same reason a font is: the texture cache
    // is device-wide, so an asset one client names is already resident for the
    // next, and the id means the same thing to both.
    return renderer_ ? renderer_->registerImage(key, path, maxPixelSize,
                                                outWidth, outHeight)
                     : -1;
  }

  int registerImageData(const std::string &key, const uint8_t *bytes,
                        size_t byteCount, uint32_t maxPixelSize,
                        uint32_t &outWidth, uint32_t &outHeight) override {
    return renderer_ ? renderer_->registerImageData(key, bytes, byteCount,
                                                    maxPixelSize, outWidth,
                                                    outHeight)
                     : -1;
  }

  void releaseImage(const std::string &key) override {
    if (renderer_) renderer_->releaseImage(key);
  }

  /// Periodic VRAM dump under `LAVA_VRAM_STATS`. Called once per output frame;
  /// the interval and the decision to print at all live in canvas.
  void reportVramIfDue() {
    if (renderer_) renderer_->reportVramIfDue();
  }

  /// The GPU report, with every canvas window named.
  ///
  /// Naming is the whole value added here. One window on screen is up to four
  /// canvas windows — the contents, the title bar, the drop shadow and the
  /// frost under it — and they are wildly different sizes: a frost surface is
  /// output-sized where the contents are window-sized. A report that said
  /// "window 7: 128 MiB" would send the reader looking for a client that owns
  /// none of it.
  canvas::GpuReport gpuReport() override {
    canvas::GpuReport report;
    if (renderer_ == nullptr) return report;
    report = renderer_->gpuReport();

    std::unordered_map<uint32_t, std::string> names;
    const auto name = [&](const std::unique_ptr<lava::CanvasSurface> &surface,
                          const ClientSurface &owner, const char *role) {
      if (!surface) return;
      std::string label = owner.title.empty() ? owner.appId : owner.title;
      if (label.empty()) label = "surface " + std::to_string(owner.id);
      names[surface->canvasWindowId()] =
        label + " (" + role + ", surface " + std::to_string(owner.id) + ")";
    };
    for (const auto &surface : surfaces_) {
      name(surface->canvas, *surface, "contents");
      name(surface->bar, *surface, "title bar");
      name(surface->blurCanvas, *surface, "backdrop frost");
    }
    // One tile serves every window, so it is named after the shape it holds
    // rather than after any of them.
    for (const auto &tile : shadowTiles_) {
      if (!tile.surface) continue;
      names[tile.surface->canvasWindowId()] =
        "drop shadow tile (radius " +
        std::to_string(static_cast<int>(tile.radius)) + ", shared)";
    }
    for (canvas::GpuWindowReport &window : report.windows) {
      if (auto found = names.find(window.id); found != names.end()) {
        window.title = found->second;
      }
    }
    return report;
  }

  /// Writes the atlas pages to `dir` as PNGs, filling in their paths.
  size_t dumpAtlases(const std::string &dir, canvas::GpuReport &report) {
    return renderer_ ? renderer_->dumpAtlases(dir, report) : 0;
  }

  std::vector<std::string> dumpAtlasImages(const std::string &directory,
                                           std::string &outError) override {
    if (renderer_ == nullptr) {
      outError = "this compositor has no canvas device";
      return {};
    }
    // The report is what says which pages exist; dumping fills in where each
    // one went. Built here rather than taken from the caller so a dump cannot
    // be asked to write pages that have since been replaced by a growth.
    canvas::GpuReport report = gpuReport();
    if (report.atlases.empty()) return {};  // nothing to write is not an error
    const size_t written = dumpAtlases(directory, report);
    std::vector<std::string> paths;
    for (const canvas::GpuAtlasPage &page : report.atlases) {
      if (!page.pngPath.empty()) paths.push_back(page.pngPath);
    }
    if (written == 0) {
      outError = "no page could be read back or written";
    }
    return paths;
  }

  uint32_t createSurface(const std::string &arenaId, uint32_t width,
                         uint32_t height, const std::string &title,
                         bool decorated, const std::string &appId) override {
    if (workspaces_ == nullptr) return 0;
    // On whichever workspace is current, because that is where the user was
    // when they asked for it.
    const uint32_t id = openSurface(arenaId, width, height, title,
                                    workspaces_->currentTree(),
                                    workspaces_->current, decorated);
    if (ClientSurface *opened = find(id)) {
      opened->appId = appId;
      // A new overlay must not reuse posters from the last Alt+Tab.
      if (appId == kSwitcherAppId) invalidatePosters();
      applyInitialPlacement(*opened);
    }
    // A window that opens is the window the user is now looking at, and it
    // should not need a click to become so. It matters more than it used to:
    // focus is what a panel's global menu follows, so a window that opened
    // unfocused would show its title bar as active — it is on top — while the
    // menu on the panel still belonged to whatever was there before.
    if (id != 0 && server_ != nullptr) {
      if (ClientSurface *surface = find(id)) server_->focusSurface(*surface);
    }
    // Now that it has its identity and its focus: one announcement describing
    // the window as it actually is.
    announceWindows();
    return id;
  }

  /// Frames a Wayland window: a title bar, a place in the stack, a workspace.
  ///
  /// Everything an ordinary application gets from this compositor comes from
  /// here. Without it a toplevel sits at the scene origin forever, because a
  /// Wayland client cannot place its own window and nothing else would.
  uint32_t adoptWindow(FramedWindow *window, const std::string &title,
                       uint32_t width, uint32_t height,
                       const std::string &appId, bool decorated = true,
                       bool transient = false, uint32_t parentId = 0);

  /// Where this window should sit, now that we know its `app_id`.
  ///
  /// A remembered frame (position, size, maximized) is restored for an
  /// ordinary window; a first launch is centred on the primary work area.
  /// Dialogs and tool windows keep the size they asked for, centred on
  /// their parent, and do not inherit its saved maximized state — being a
  /// child is what marks them, not sharing an `app_id` with something
  /// already on screen. Overlays (launcher, switcher) and panels are left
  /// alone.
  void applyInitialPlacement(ClientSurface &surface);

  /// Records the floating rectangle (and whether it was maximized) in
  /// memory. The file is flushed on a timer and at shutdown. Dialogs
  /// are skipped — they share the parent's identity and must not
  /// overwrite it.
  void rememberPlacement(const ClientSurface &surface);

  /// Size a Wayland toplevel should be configured to on its first commit,
  /// before it has a frame. `width`/`height` stay 0 when there is nothing
  /// to say — the client then picks its own default.
  bool hintToplevelConfigure(const std::string &appId, uint32_t &width,
                             uint32_t &height, bool &maximized,
                             bool transient = false) const;

  /// Topmost live window on `workspace` that can take the keyboard.
  ClientSurface *frontOnWorkspace(uint32_t workspace);

  /// Late parent / window-type. Recomputed rather than only set: a
  /// client that drops `WM_TRANSIENT_FOR`, or a tool window that turns
  /// into an ordinary one, earns its slot in window memory back.
  void setTransient(ClientSurface &surface, bool transient,
                    uint32_t parentId);

  /// A Wayland client committed at a new size.
  ///
  /// The frame follows the window rather than the other way round: a resize is
  /// a request, and the client is the authority on what it settled at.
  void toplevelResized(ClientSurface &surface, uint32_t width,
                       uint32_t height) {
    // Fullscreen already asked for the output size. A client that answers
    // with something else is still fullscreen — shrinking the frame would
    // show the desktop around a game that thought it owned the screen.
    if (surface.fullscreen) return;
    if (width == surface.width && height == surface.height) return;
    surface.width = width;
    surface.height = height;
    if (surface.bar &&
        surface.bar->resize(width, lava::Decoration::kHeight)) {
      show_surface(surface.barNode, *surface.bar);
    }
    drawBar(surface);
    // The client settled at a different size than we asked — a terminal
    // rounding to cells, or CSD chrome the geometry box does not include.
    // The dock's overlap answer follows the committed rectangle.
    if (control_ != nullptr) control_->postPanelAreas();
  }

  void setTitle(ClientSurface &surface, const std::string &title) {
    if (surface.title == title) return;
    surface.title = title;
    drawBar(surface);
    // A panel showing the active window's name is showing this string, and a
    // window that renames itself while focused — a browser changing tabs — is
    // the ordinary case rather than an odd one.
    if (control_ != nullptr && surface.id == focused_) {
      postActive(surface);
    }
    announceWindows();
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
    // The window went up; its shadow has to follow it rather than stay where
    // the old stacking left it, which would be behind whatever this window was
    // just raised over.
    placeShadow(surface);
    placeBackdrop(surface);
    scheduleBackdropRefresh();
    // Front of the list is front of the stack, and the two must not disagree:
    // the hit tests walk this list and would otherwise answer with a window
    // that is visibly behind another.
    for (auto it = surfaces_.begin(); it != surfaces_.end(); ++it) {
      if (it->get() != &surface) continue;
      auto owned = std::move(*it);
      surfaces_.erase(it);
      surfaces_.push_front(std::move(owned));
      break;
    }
    syncShellForFullscreen();
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

  /// Moves a window. Every node, because a frame, its content and the shadow
  /// under them are one window and only ever move together.
  void moveSurface(ClientSurface &surface, int x, int y) {
    surface.x = x;
    surface.y = y;
    place(surface);
    placeShadow(surface);
    placeBackdrop(surface);
    scheduleBackdropRefresh();
    // Geometry, which the window list does not carry — a dock that hides
    // itself when something is in the way learns about it here and nowhere
    // else. Cheap when nobody has asked: see `postPanelAreas`.
    if (control_ != nullptr && !surface.panel) control_->postPanelAreas();
  }

  /// Fills the work area, or goes back to where the window came from.
  ///
  /// The previous frame is remembered rather than recomputed, so restoring
  /// puts a window back exactly where the user left it.
  void setMaximized(ClientSurface &surface, bool maximized) {
    if (surface.maximized == maximized) {
      // X11 still wants the property ack, the same as a no-op fullscreen.
      if (surface.isForeign()) surface.window->setMaximized(maximized);
      return;
    }
    // Fullscreen already owns the rectangle. Remember maximize for when
    // it ends, but do not pull a game off the output to fill the work area.
    if (surface.fullscreen) {
      surface.maximized = maximized;
      if (surface.isForeign()) surface.window->setMaximized(maximized);
      tellClientWindowState(surface);
      rememberPlacement(surface);
      return;
    }
    if (!maximized) {
      // Flag first: `showsBar` / `contentY` / `fillWorkArea` / rounding
      // all read it.
      surface.maximized = false;
      syncBar(surface);
      applyCorners(surface);
      const uint32_t wasW = surface.width;
      const uint32_t wasH = surface.height;
      moveSurface(surface, surface.restoreX, surface.restoreY);
      resizeSurface(surface, surface.restoreW, surface.restoreH);
      evictOntoLayout(surface);
      // Same rectangle as before: resize is a no-op, so the mask
      // change has to be drawn here or the window stays square.
      if (surface.width == wasW && surface.height == wasH) {
        restyleFrame(surface);
      }
      if (surface.isForeign()) surface.window->setMaximized(false);
      tellClientWindowState(surface);
      rememberPlacement(surface);
      wlr_log(WLR_INFO, "window %u: unmaximized", surface.id);
      return;
    }
    if (outputWidth_ == 0 || outputHeight_ == 0) return;
    surface.restoreX = surface.x;
    surface.restoreY = surface.y;
    surface.restoreW = surface.width;
    surface.restoreH = surface.height;
    surface.maximized = true;
    syncBar(surface);
    applyCorners(surface);
    const uint32_t wasW = surface.width;
    const uint32_t wasH = surface.height;
    fillWorkArea(surface);
    if (surface.width == wasW && surface.height == wasH) {
      restyleFrame(surface);
    }
    if (surface.isForeign()) surface.window->setMaximized(true);
    tellClientWindowState(surface);
    rememberPlacement(surface);
    wlr_log(WLR_INFO, "window %u: maximized", surface.id);
  }

  /// Covers the output, or goes back to maximize / the floating rectangle.
  ///
  /// The output, not the work area: fullscreen is what a game asked for when
  /// it said 1920×1080, and leaving the panel on top of it is how that
  /// request used to become a movable window of that size.
  void setFullscreen(ClientSurface &surface, bool fullscreen) {
    if (surface.panel) return;
    if (surface.fullscreen == fullscreen) {
      // Protocol still wants an ack even when nothing moved.
      if (surface.isForeign()) surface.window->setFullscreen(fullscreen);
      return;
    }
    if (fullscreen) {
      if (outputWidth_ == 0 || outputHeight_ == 0) return;
      if (surface.minimized) setMinimized(surface, false);
      // Maximize already saved the floating rectangle. Overwriting it here
      // with the work-area size would restore a "maximized" window to
      // maximized instead of to where the user left it.
      if (!surface.maximized) {
        surface.restoreX = surface.x;
        surface.restoreY = surface.y;
        surface.restoreW = surface.width;
        surface.restoreH = surface.height;
      }
      surface.fullscreen = true;
      syncBar(surface);
      applyCorners(surface);
      const uint32_t wasW = surface.width;
      const uint32_t wasH = surface.height;
      fillOutput(surface);
      if (surface.width == wasW && surface.height == wasH) {
        restyleFrame(surface);
      }
      raise(surface);
      if (surface.isForeign()) surface.window->setFullscreen(true);
      tellClientWindowState(surface);
      wlr_log(WLR_INFO, "window %u: fullscreen", surface.id);
      return;
    }
    surface.fullscreen = false;
    syncBar(surface);
    applyCorners(surface);
    const uint32_t wasW = surface.width;
    const uint32_t wasH = surface.height;
    if (surface.maximized) {
      fillWorkArea(surface);
    } else {
      moveSurface(surface, surface.restoreX, surface.restoreY);
      resizeSurface(surface, surface.restoreW, surface.restoreH);
    }
    if (surface.width == wasW && surface.height == wasH) {
      restyleFrame(surface);
    }
    if (surface.isForeign()) surface.window->setFullscreen(false);
    tellClientWindowState(surface);
    syncShellForFullscreen();
    wlr_log(WLR_INFO, "window %u: left fullscreen", surface.id);
  }

  /// Corners and shadow for the current flags, then a redraw.
  ///
  /// Used when maximize flips but the rectangle does not: `resizeSurface`
  /// is a no-op in that case, and a flush window still has to become
  /// square (and drop its shadow) or a restored one round again.
  void restyleFrame(ClientSurface &surface) {
    applyCorners(surface);
    applyShadow(surface);
    if (surface.canvas && surface.canvas->redraw()) damage(surface);
  }

  /// A Lava client that draws its own chrome has to hide that strip when
  /// we would have dropped a title bar — including maximize from a key
  /// the client never saw. Resize already says the new size; this says
  /// why. Foreign windows have no Lava input stream.
  void tellClientWindowState(const ClientSurface &surface) {
    if (control_ == nullptr || !surface.canvas) return;
    // Both states drop the chrome; the client only needs to know whether
    // its title strip should be showing. A bitmask would be the next
    // verb, and nothing here has asked for one yet.
    control_->postInput(
        surface.id,
        static_cast<uint32_t>(canvas::InputEventKind::WindowState), 0.f, 0.f,
        (surface.maximized || surface.fullscreen) ? 1 : 0, 0);
  }

  /// Title bar on screen only when the window is decorated *and* not
  /// maximized — and not minimized. One place so the three flags cannot
  /// disagree about whether the strip is visible.
  void syncBar(ClientSurface &surface) {
    if (surface.barNode == nullptr) return;
    wlr_scene_node_set_enabled(&surface.barNode->node,
                               surface.showsBar() && !surface.minimized);
  }

  /// Spreads a window over everything a panel has not claimed.
  ///
  /// The work area of the *window's* output, not the primary and not the
  /// layout union: maximizing a window on the laptop must not jump it to
  /// the external monitor just because that is where the panel lives.
  void fillWorkArea(ClientSurface &surface) {
    const WorkArea area = workAreaAt(surfaceCenterX(surface),
                                     surfaceCenterY(surface));
    moveSurface(surface, area.x, area.y);
    // The frame comes out of the height, and a window with no frame keeps all
    // of it — which is most of what an app gives up its title bar for.
    const uint32_t frame =
        surface.showsBar() ? static_cast<uint32_t>(lava::Decoration::kHeight)
                           : 0;
    resizeSurface(surface, area.width,
                  area.height > frame ? area.height - frame : area.height);
  }

  /// Spreads a window over its output, panel and all.
  void fillOutput(ClientSurface &surface) {
    int x = primaryX_;
    int y = primaryY_;
    uint32_t w = primaryWidth_;
    uint32_t h = primaryHeight_;
    outputBoxAt(surfaceCenterX(surface), surfaceCenterY(surface), x, y, w, h);
    moveSurface(surface, x, y);
    resizeSurface(surface, w, h);
  }

  /// Whether a fullscreen window on the current workspace owns the output.
  ///
  /// Any such window, not only the focused one: a game that is still
  /// fullscreen underneath a raised terminal is still a game that should
  /// not have a taskbar painted across it.
  bool fullscreenCoversShell() const {
    for (const auto &s : surfaces_) {
      if (s->panel || s->minimized || !coversItsOutput(*s)) continue;
      if (workspaces_ != nullptr && s->workspace != workspaces_->current) {
        continue;
      }
      return true;
    }
    return false;
  }

  /// Hides the panel tree while a fullscreen window owns the output.
  ///
  /// Panels live in a tree created after the workspaces, so they draw on
  /// top of every window. Disabling their nodes is what makes fullscreen
  /// actually cover the screen rather than sit under the taskbar.
  void syncShellForFullscreen() {
    const bool hide = fullscreenCoversShell();
    for (auto &s : surfaces_) {
      if (!s->panel || s->node == nullptr) continue;
      wlr_scene_node_set_enabled(&s->node->node, !hide);
    }
  }

  /// How big the primary output currently is. Used to size a fullscreen
  /// configure before the window has a frame (xdg initial commit).
  void outputSize(uint32_t &width, uint32_t &height) const {
    width = primaryWidth_;
    height = primaryHeight_;
  }

  /// Puts a panel back on the primary output's edge, at that edge's length.
  void layoutPanel(ClientSurface &panel) {
    const bool horizontal =
        panel.edge == kPanelTop || panel.edge == kPanelBottom;
    // A panel chose only its thickness; the length is the screen's to decide.
    const uint32_t thickness = horizontal ? panel.height : panel.width;
    resizeSurface(panel, horizontal ? primaryWidth_ : thickness,
                  horizontal ? thickness : primaryHeight_);
    // Origin is the *primary* box, not the layout union and not (0,0):
    // unplugging the leftmost monitor leaves the laptop at x=1920, and a
    // strip at the origin would sit in the hole. Spanning the union would
    // paint the panel across every screen.
    moveSurface(panel,
                panel.edge == kPanelRight
                    ? primaryX_ + static_cast<int>(primaryWidth_) -
                          static_cast<int>(thickness)
                    : primaryX_,
                panel.edge == kPanelBottom
                    ? primaryY_ + static_cast<int>(primaryHeight_) -
                          static_cast<int>(thickness)
                    : primaryY_);
  }

  /// Recomputes the layout union and the primary output's box.
  ///
  /// The union is what eviction uses — a window on the laptop is still
  /// on the desktop when the external is primary. The primary box is
  /// where the panel lives. Two monitors side by side are 1920+2560
  /// wide; unplugging the 1920 must shrink the union or a window that
  /// lived only there sits in the hole forever.
  void refreshFromLayout() {
    if (server_ == nullptr || server_->output_layout == nullptr) return;
    wlr_box unionBox{};
    wlr_output_layout_get_box(server_->output_layout, nullptr, &unionBox);
    if (unionBox.width <= 0 || unionBox.height <= 0) return;

    int px = unionBox.x;
    int py = unionBox.y;
    uint32_t pw = static_cast<uint32_t>(unionBox.width);
    uint32_t ph = static_cast<uint32_t>(unionBox.height);
    if (wlr_output *primary = resolvePrimaryOutput()) {
      wlr_box box{};
      wlr_output_layout_get_box(server_->output_layout, primary, &box);
      if (box.width > 0 && box.height > 0) {
        px = box.x;
        py = box.y;
        pw = static_cast<uint32_t>(box.width);
        ph = static_cast<uint32_t>(box.height);
      }
    }
    setLayoutGeometry(unionBox.x, unionBox.y,
                      static_cast<uint32_t>(unionBox.width),
                      static_cast<uint32_t>(unionBox.height), px, py, pw, ph);
  }

  void setLayoutGeometry(int x, int y, uint32_t width, uint32_t height,
                         int primaryX, int primaryY, uint32_t primaryW,
                         uint32_t primaryH) {
    if (x == layoutX_ && y == layoutY_ && width == outputWidth_ &&
        height == outputHeight_ && primaryX == primaryX_ &&
        primaryY == primaryY_ && primaryW == primaryWidth_ &&
        primaryH == primaryHeight_) {
      return;
    }
    wlr_log(WLR_INFO,
            "layout: %ux%u at %d,%d primary %ux%u at %d,%d (was %ux%u at "
            "%d,%d primary %ux%u at %d,%d)",
            width, height, x, y, primaryW, primaryH, primaryX, primaryY,
            outputWidth_, outputHeight_, layoutX_, layoutY_, primaryWidth_,
            primaryHeight_, primaryX_, primaryY_);
    layoutX_ = x;
    layoutY_ = y;
    outputWidth_ = width;
    outputHeight_ = height;
    primaryX_ = primaryX;
    primaryY_ = primaryY;
    primaryWidth_ = primaryW;
    primaryHeight_ = primaryH;
    // Panels first: every one of them spans an edge that just changed
    // length or moved to another screen, and the work area is measured
    // from where they end up.
    for (auto &surface : surfaces_) {
      if (surface->panel) layoutPanel(*surface);
    }
    for (auto &surface : surfaces_) {
      if (surface->panel) continue;
      if (surface->fullscreen) fillOutput(*surface);
      else if (surface->maximized) fillWorkArea(*surface);
      else evictOntoLayout(*surface);
    }
  }

  /// A window that lived entirely on an output that just vanished is
  /// moved onto the primary, rather than sitting in the hole.
  void evictOntoLayout(ClientSurface &surface) {
    if (surface.panel || surface.minimized) return;
    // The union, not the primary work area: a window on the laptop is
    // still on the desktop when the external is primary.
    const int x1 = surface.x + static_cast<int>(surface.width);
    const int y1 = surface.y + surface.frameHeight();
    const int ax1 = layoutX_ + static_cast<int>(outputWidth_);
    const int ay1 = layoutY_ + static_cast<int>(outputHeight_);
    if (x1 > layoutX_ && y1 > layoutY_ && surface.x < ax1 &&
        surface.y < ay1) {
      return;
    }
    const WorkArea area = workArea();
    moveSurface(surface, area.x + 32, area.y + 32);
  }

  /// Every appearance setting at once, from the config and again on reload.
  ///
  /// One call rather than four setters because they are read together and a
  /// window has to be redrawn once when any of them changes: a shadow's corner
  /// radius comes from the same number the window's own corners do, so setting
  /// them one at a time would draw an intermediate frame where the two
  /// disagreed.
  void setAppearance(float radius, float shadowBlur, float shadowOpacity,
                     float shadowOffsetY) {
    const bool same = cornerRadius_ == radius && shadowBlur_ == shadowBlur &&
                      shadowOpacity_ == shadowOpacity &&
                      shadowOffsetY_ == shadowOffsetY;
    if (same) return;
    cornerRadius_ = radius;
    shadowBlur_ = shadowBlur;
    shadowOpacity_ = shadowOpacity;
    shadowOffsetY_ = shadowOffsetY;
    // The tiles were drawn for the old numbers. Dropped before anything asks
    // for one, so the rebuild below hands every window the new shape.
    dropShadowTiles();
    for (auto &surface : surfaces_) {
      applyShadow(*surface);
      applyCorners(*surface);
      // Only the surfaces the compositor fills itself redraw from here; a
      // client's next frame carries its own content, and the mask is applied
      // to whatever that turns out to be.
      drawBar(*surface);
      if (surface->canvas && surface->canvas->redraw()) damage(*surface);
    }
  }

  /// One blurred rounded rectangle, stretched over every window that has a
  /// shadow.
  ///
  /// A shadow used to be a canvas surface the size of its window — a
  /// multisampled attachment, an exported dma-buf and a render every time the
  /// window moved — and eleven of them were what a desktop of eleven windows
  /// cost, for eleven pictures of the same thing at different sizes.
  ///
  /// It *is* the same thing. The falloff of a rounded rectangle depends only
  /// on the distance to it, so away from the corners the picture is constant
  /// along each edge and one colour in the middle: exactly the shape that
  /// nine-slices without approximating anything. What changes with the window
  /// is how far the edges are stretched, and stretching a constant is free.
  ///
  /// So the tile holds four true corners, four one-band-wide edges and a
  /// middle, and every window's shadow is nine `wlr_scene_buffer`s over it.
  /// `corner` is the part that must not stretch: the blur's reach plus the
  /// corner radius.
  struct ShadowTile {
    std::unique_ptr<lava::CanvasSurface> surface;
    /// How far the falloff reaches past the rectangle, and so how far outside
    /// its window a shadow is drawn.
    int pad = 0;
    /// Non-stretchable extent at each side: `pad + radius`.
    int corner = 0;
    /// Stretchable band between the corners, in the tile. More than one pixel
    /// so a source box can sit strictly inside it — a box flush against the
    /// corners would let a linear sample reach into them.
    int band = 0;
    /// What it was built for. A tile is rebuilt when any of these changes, and
    /// there is one per radius — rounded for Lava windows, square for foreign
    /// ones, whose corners nothing here can round.
    float radius = -1.f;
    float blur = -1.f;
    float opacity = -1.f;
  };

  /// The stretchable band, and the inset that keeps a linear sample inside it.
  static constexpr int kShadowBand = 8;
  static constexpr double kShadowInset = 2.0;

  /// Lets go of every tile, after taking them off the windows showing them.
  ///
  /// A tile is a canvas surface, and destroying one while a scene node still
  /// holds its buffer leaves the scene showing an image that has gone back to
  /// the export pool. So the slices are emptied first; each window lays itself
  /// out against the new tile on its next `applyShadow`, which is the call
  /// that follows this one.
  void dropShadowTiles() {
    for (auto &surface : surfaces_) {
      for (wlr_scene_buffer *slice : surface->shadowSlices) {
        if (slice != nullptr) wlr_scene_buffer_set_buffer(slice, nullptr);
      }
      surface->shadowW = 0;
      surface->shadowH = 0;
      surface->shadowRadius = -1.f;
    }
    shadowTiles_.clear();
  }

  /// The tile for `radius`, built if this is the first window to want it.
  /// Null only if the device could not give it a surface.
  ShadowTile *shadowTileFor(float radius) {
    if (renderer_ == nullptr || shadowBlur_ <= 0.f) return nullptr;
    for (auto &tile : shadowTiles_) {
      if (tile.radius == radius && tile.blur == shadowBlur_ &&
          tile.opacity == shadowOpacity_) {
        return tile.surface ? &tile : nullptr;
      }
    }
    // A tile that no longer matches the config is one no window may still be
    // showing — see `dropShadowTiles`. Reached only if something changed the
    // appearance without going through `setAppearance`.
    dropShadowTiles();

    ShadowTile tile;
    tile.radius = radius;
    tile.blur = shadowBlur_;
    tile.opacity = shadowOpacity_;
    // `pushShadow` grows its quad by the blur plus a pixel, and that pixel is
    // part of the picture — the falloff is still nonzero at the edge of the
    // reach, and cutting it off is a visible seam where the slices meet.
    tile.pad = static_cast<int>(std::ceil(shadowBlur_)) + 1;
    const int r = static_cast<int>(std::ceil(radius));
    tile.band = kShadowBand;
    tile.corner = tile.pad + r;
    const uint32_t side =
        static_cast<uint32_t>(tile.corner * 2 + tile.band);

    tile.surface = renderer_->createSurface(side, side);
    if (!tile.surface) return nullptr;

    // The rectangle casting it: two corner radii plus the band, so every
    // corner is whole and the straight runs between them are the band.
    canvas::DrawCommand command{};
    command.kind = static_cast<uint32_t>(canvas::DrawCommandKind::Shadow);
    command.x = static_cast<float>(tile.pad);
    command.y = static_cast<float>(tile.pad);
    command.w = static_cast<float>(r * 2 + tile.band);
    command.h = static_cast<float>(r * 2 + tile.band);
    command.aux = radius;
    command.param = static_cast<uint32_t>(shadowBlur_);
    // Black at the configured opacity. RGBA8 little-endian, so the alpha is
    // the top byte — see the colours in `Decoration`.
    const uint32_t alpha =
        static_cast<uint32_t>(std::clamp(shadowOpacity_, 0.f, 1.f) * 255.f);
    command.color = alpha << 24;

    const std::vector<canvas::DrawCommand> commands{command};
    const std::vector<canvas::GlyphInstance> glyphs;
    tile.surface->renderList(commands, glyphs);
    wlr_log(WLR_INFO,
            "shadow tile %ux%u for radius %.0f, blur %.0f — shared by every "
            "window",
            side, side, radius, shadowBlur_);

    shadowTiles_.push_back(std::move(tile));
    return &shadowTiles_.back();
  }

  /// Builds, moves and resizes a window's shadow.
  ///
  /// One function rather than the four the bar needs, because a shadow has no
  /// state of its own worth tracking: it is entirely a function of the
  /// window's rectangle, the config, and whether the window is focused. Called
  /// whenever any of those changes, and cheap when nothing did — nothing is
  /// drawn here at all, and the slices are re-laid-out only when the size or
  /// the radius actually differs.
  void applyShadow(ClientSurface &surface) {
    const bool wanted =
        shadowBlur_ > 0.f && !surface.panel && !surface.maximized &&
        !coversItsOutput(surface) && renderer_ != nullptr &&
        workspaces_ != nullptr && surface.id == focused_ && !surface.minimized;
    if (!wanted) {
      if (surface.shadowTree != nullptr) {
        wlr_scene_node_set_enabled(&surface.shadowTree->node, false);
      }
      return;
    }

    // The silhouette this shadow falls under — square for a foreign window,
    // whose corners nothing here can round. A rounded shadow under a square
    // window shows as a wedge of dark poking past the corner.
    const float radius = frameIsRoundable(surface) ? cornerRadius_ : 0.f;
    ShadowTile *tile = shadowTileFor(radius);
    if (tile == nullptr) return;

    if (surface.shadowTree == nullptr) {
      surface.shadowTree =
          wlr_scene_tree_create(workspaces_->tree[surface.workspace]);
      if (surface.shadowTree == nullptr) return;
      for (wlr_scene_buffer *&slice : surface.shadowSlices) {
        slice = wlr_scene_buffer_create(surface.shadowTree, nullptr);
        if (slice == nullptr) continue;
        // A shadow is drawn around the window but must not own the pointer —
        // otherwise the blur ring steals clicks from whatever sits under it.
        bind_never_input(slice);
      }
      surface.shadowW = 0;  // force the layout below
    }

    const uint32_t frameH = static_cast<uint32_t>(surface.frameHeight());
    if (surface.shadowW != surface.width || surface.shadowH != frameH ||
        surface.shadowRadius != radius) {
      layoutShadow(surface, *tile, surface.width, frameH);
      surface.shadowW = surface.width;
      surface.shadowH = frameH;
      surface.shadowRadius = radius;
    }
    wlr_scene_node_set_enabled(&surface.shadowTree->node, true);
    placeShadow(surface);
  }

  /// Points the nine slices at their parts of the tile and stretches them.
  ///
  /// Dest sizes are the shadow's footprint — the window grown by the tile's
  /// reach on every side — cut into a fixed corner, a stretched middle and a
  /// fixed corner along each axis. The middle is what absorbs every size a
  /// window can be.
  void layoutShadow(ClientSurface &surface, ShadowTile &tile, uint32_t winW,
                    uint32_t winH) {
    const int paintedW = static_cast<int>(winW) + tile.pad * 2;
    const int paintedH = static_cast<int>(winH) + tile.pad * 2;
    // A window narrower than two corners has nowhere to put a middle. Rather
    // than refuse it a shadow, the corners are squeezed — wlroots scales the
    // slice — which is wrong by a fraction of a pixel on a window nobody has.
    const int cw = std::min(tile.corner, (paintedW - 1) / 2);
    const int ch = std::min(tile.corner, (paintedH - 1) / 2);
    if (cw < 1 || ch < 1) return;
    const int midW = paintedW - cw * 2;
    const int midH = paintedH - ch * 2;

    // Source: the corners at their own size, and the band's middle for
    // anything stretched. Inset, because a linear sample at the end of a
    // stretched run reaches half a texel past the box it was given.
    const double srcCorner = static_cast<double>(tile.corner);
    const double srcFar = static_cast<double>(tile.corner + tile.band);
    const double srcBand = static_cast<double>(tile.corner) + kShadowInset;
    const double srcBandSize =
        static_cast<double>(tile.band) - kShadowInset * 2.0;

    const struct {
      double sx, sy, sw, sh;
      int dx, dy, dw, dh;
    } slices[9] = {
        {0, 0, srcCorner, srcCorner, 0, 0, cw, ch},
        {srcBand, 0, srcBandSize, srcCorner, cw, 0, midW, ch},
        {srcFar, 0, srcCorner, srcCorner, cw + midW, 0, cw, ch},
        {0, srcBand, srcCorner, srcBandSize, 0, ch, cw, midH},
        {srcBand, srcBand, srcBandSize, srcBandSize, cw, ch, midW, midH},
        {srcFar, srcBand, srcCorner, srcBandSize, cw + midW, ch, cw, midH},
        {0, srcFar, srcCorner, srcCorner, 0, ch + midH, cw, ch},
        {srcBand, srcFar, srcBandSize, srcCorner, cw, ch + midH, midW, ch},
        {srcFar, srcFar, srcCorner, srcCorner, cw + midW, ch + midH, cw, ch},
    };

    const lava::CanvasSurface::FrameFence fence = tile.surface->frameFence();
    const wlr_scene_buffer_set_buffer_options options{
        .damage = nullptr,
        .wait_timeline = fence.timeline,
        .wait_point = fence.point,
    };
    for (size_t i = 0; i < surface.shadowSlices.size(); ++i) {
      wlr_scene_buffer *slice = surface.shadowSlices[i];
      if (slice == nullptr) continue;
      const auto &s = slices[i];
      if (s.dw < 1 || s.dh < 1) {
        wlr_scene_node_set_enabled(&slice->node, false);
        continue;
      }
      wlr_scene_buffer_set_buffer_with_options(slice, tile.surface->buffer(),
                                               &options);
      const wlr_fbox source{s.sx, s.sy, s.sw, s.sh};
      wlr_scene_buffer_set_source_box(slice, &source);
      wlr_scene_buffer_set_dest_size(slice, s.dw, s.dh);
      wlr_scene_node_set_position(&slice->node, s.dx, s.dy);
      wlr_scene_node_set_enabled(&slice->node, true);
    }
  }

  /// Puts the shadow under its window, in position and in the stack.
  void placeShadow(ClientSurface &surface) {
    if (surface.shadowTree == nullptr) return;
    const ShadowTile *tile = nullptr;
    for (const auto &candidate : shadowTiles_) {
      if (candidate.radius == surface.shadowRadius) tile = &candidate;
    }
    if (tile == nullptr) return;
    // The tile's reach out from the window, and the offset that makes it read
    // as a shadow rather than a glow. The offset is a translation of the whole
    // picture, which is why it is applied here and not drawn into the tile.
    wlr_scene_node_set_position(
        &surface.shadowTree->node, surface.x - tile->pad,
        surface.y - tile->pad + static_cast<int>(shadowOffsetY_));
    // Below this window's own nodes and nothing else's: `lower_to_bottom`
    // would put it under every other window too, so a shadow would fall behind
    // the window it belongs in front of.
    wlr_scene_node *content = surface.isForeign()
                                  ? surface.window->contentNode()
                                  : (surface.node != nullptr
                                         ? &surface.node->node
                                         : nullptr);
    if (content != nullptr) {
      wlr_scene_node_place_below(&surface.shadowTree->node, content);
    }
  }

  void placeBackdrop(ClientSurface &surface) {
    if (surface.blurNode == nullptr) return;
    wlr_scene_node_set_position(&surface.blurNode->node, surface.x, surface.y);
    wlr_scene_node *content = surface.isForeign()
                                  ? surface.window->contentNode()
                                  : (surface.node != nullptr
                                         ? &surface.node->node
                                         : nullptr);
    if (content != nullptr) {
      wlr_scene_node_place_below(&surface.blurNode->node, content);
    }
    if (surface.shadowTree != nullptr) {
      wlr_scene_node_place_below(&surface.shadowTree->node,
                                 &surface.blurNode->node);
    }
  }

  void clearBackdrop(ClientSurface &surface) {
    if (surface.blurNode != nullptr) {
      wlr_scene_node_destroy(&surface.blurNode->node);
      surface.blurNode = nullptr;
    }
    surface.blurCanvas.reset();
    if (renderer_ != nullptr && !surface.blurKey.empty()) {
      // Discarded, not released: this snapshot's key names a generation that
      // will never come round again, so keeping it warm keeps 8 MiB of a
      // screen that has already changed.
      renderer_->discardImage(surface.blurKey);
      surface.blurKey.clear();
    }
  }

  void scheduleBackdropRefresh() {
    backdropBlurDirty_ = true;
    if (server_ == nullptr) return;
    for (Output *output : server_->outputs) {
      if (output->wlr != nullptr && output->wlr->enabled) {
        wlr_output_schedule_frame(output->wlr);
      }
    }
  }

  void setNodeEnabled(wlr_scene_node *node, bool on) {
    if (node != nullptr) wlr_scene_node_set_enabled(node, on);
  }

  /// Hide this window (not the others), render the output it sits on,
  /// crop + frost, put the plate back under it.
  void captureBackdrop(ClientSurface &surface) {
    if (surface.backdropBlurRadius <= 0.f || server_ == nullptr ||
        renderer_ == nullptr) {
      clearBackdrop(surface);
      return;
    }
    if (surface.minimized || surface.fullscreen) {
      if (surface.blurNode != nullptr) {
        wlr_scene_node_set_enabled(&surface.blurNode->node, false);
      }
      return;
    }

    const int frameW = static_cast<int>(surface.width);
    const int frameH = surface.frameHeight();
    if (frameW < 1 || frameH < 1) return;

    Output *output = outputUnder(surface.x + frameW / 2, surface.y + frameH / 2);
    if (output == nullptr || output->wlr == nullptr) return;

    setNodeEnabled(surface.node != nullptr ? &surface.node->node : nullptr,
                   false);
    setNodeEnabled(surface.barNode != nullptr ? &surface.barNode->node : nullptr,
                   false);
    setNodeEnabled(surface.blurNode != nullptr ? &surface.blurNode->node
                                               : nullptr,
                   false);
    setNodeEnabled(
        surface.shadowTree != nullptr ? &surface.shadowTree->node : nullptr,
        false);
    if (surface.isForeign() && surface.window != nullptr) {
      setNodeEnabled(surface.window->contentNode(), false);
    }

    wlr_buffer *captured = renderOutputBuffer(output);
    if (surface.node != nullptr) {
      setNodeEnabled(&surface.node->node, !surface.minimized);
    }
    if (surface.barNode != nullptr) {
      setNodeEnabled(&surface.barNode->node, surface.showsBar());
    }
    if (surface.isForeign() && surface.window != nullptr) {
      setNodeEnabled(surface.window->contentNode(), !surface.minimized);
    }
    // Shadow comes back through applyShadow's own rules.
    applyShadow(surface);

    if (captured == nullptr) return;

    wlr_box layoutBox{};
    wlr_output_layout_get_box(server_->output_layout, output->wlr, &layoutBox);
    const float scale = output->wlr->scale > 0.f ? output->wlr->scale : 1.f;
    const int ix = std::max(surface.x, layoutBox.x);
    const int iy = std::max(surface.y, layoutBox.y);
    const int ix2 = std::min(surface.x + frameW, layoutBox.x + layoutBox.width);
    const int iy2 = std::min(surface.y + frameH, layoutBox.y + layoutBox.height);
    const int srcX = static_cast<int>(std::lround((ix - layoutBox.x) * scale));
    const int srcY = static_cast<int>(std::lround((iy - layoutBox.y) * scale));
    int srcW = static_cast<int>(std::lround((ix2 - ix) * scale));
    int srcH = static_cast<int>(std::lround((iy2 - iy) * scale));
    srcW = std::max(1, std::min(srcW, captured->width - srcX));
    srcH = std::max(1, std::min(srcH, captured->height - srcY));

    wlr_scene_tree *parent = workspaces_->tree[surface.workspace];
    const uint32_t destW = static_cast<uint32_t>(frameW);
    const uint32_t destH = static_cast<uint32_t>(frameH);
    if (!surface.blurCanvas) {
      surface.blurCanvas = renderer_->createSurface(destW, destH);
      if (!surface.blurCanvas) {
        wlr_buffer_unlock(captured);
        return;
      }
      surface.blurNode =
          wlr_scene_buffer_create(parent, surface.blurCanvas->buffer());
      if (surface.blurNode == nullptr) {
        surface.blurCanvas.reset();
        wlr_buffer_unlock(captured);
        return;
      }
      bind_never_input(surface.blurNode);
    } else if (surface.blurCanvas->resize(destW, destH)) {
      show_surface(surface.blurNode, *surface.blurCanvas);
    }

    // Every refresh is a new full-screen texture, so the one it replaces has to
    // go rather than go dormant — see `CanvasRenderer::discardImage`. Ten
    // refreshes of one window used to leave 79 MiB of snapshots resident, none
    // of which any draw list could name again.
    if (!surface.blurKey.empty()) renderer_->discardImage(surface.blurKey);
    surface.blurKey = "frost:" + std::to_string(surface.id) + ":" +
                      std::to_string(++surface.blurGen);
    const float corners =
        frameIsRoundable(surface) ? cornerRadius_ : 0.f;
    const float frost = corners > 0.f ? corners + 2.f : 0.f;
    surface.blurCanvas->setCornerRadius(frost, true, true);

    // Prefer a GPU import of the capture: same DRM node, the other
    // VkDevice. The CPU path is the fallback when the buffer is shm or
    // the modifier will not import as a blit source.
    bool frosted = false;
    wlr_dmabuf_attributes attribs{};
    if (srcX >= 0 && srcY >= 0 &&
        wlr_buffer_get_dmabuf(captured, &attribs)) {
      frosted = surface.blurCanvas->frostFromDmabuf(
          attribs, srcX, srcY, srcW, srcH, surface.backdropBlurRadius,
          surface.blurKey, frost);
    }
    if (!frosted) {
      std::vector<uint8_t> raw;
      const bool read = srcX >= 0 && srcY >= 0 &&
                        lava::readBufferRgba(server_->renderer, captured, srcX,
                                             srcY, srcW, srcH, raw);
      frosted = read && surface.blurCanvas->frostFromRgba(
                            raw.data(), static_cast<uint32_t>(srcW),
                            static_cast<uint32_t>(srcH),
                            surface.backdropBlurRadius, surface.blurKey,
                            frost);
    }
    wlr_buffer_unlock(captured);
    if (!frosted) return;
    show_surface(surface.blurNode, *surface.blurCanvas);
    wlr_scene_node_set_enabled(&surface.blurNode->node, true);
    placeBackdrop(surface);
  }

  Output *outputUnder(int lx, int ly) const {
    if (server_ == nullptr || server_->output_layout == nullptr) return nullptr;
    wlr_output *at =
        wlr_output_layout_output_at(server_->output_layout, lx, ly);
    if (at == nullptr) return nullptr;
    for (Output *output : server_->outputs) {
      if (output->wlr == at && output->wlr->enabled) return output;
    }
    return nullptr;
  }

  /// One offscreen composite of `output`. The caller unlocks the buffer.
  wlr_buffer *renderOutputBuffer(Output *output) {
    if (output == nullptr || output->wlr == nullptr ||
        server_ == nullptr || server_->allocator == nullptr) {
      return nullptr;
    }
    const int w = output->wlr->width;
    const int h = output->wlr->height;
    if (w <= 0 || h <= 0) return nullptr;

    const wlr_drm_format *fmt = nullptr;
    if (output->wlr->swapchain != nullptr) {
      fmt = &output->wlr->swapchain->format;
    } else {
      const wlr_drm_format_set *formats = wlr_output_get_primary_formats(
          output->wlr, server_->allocator->buffer_caps);
      if (formats != nullptr) {
        fmt = wlr_drm_format_set_get(formats, DRM_FORMAT_XRGB8888);
        if (fmt == nullptr) {
          fmt = wlr_drm_format_set_get(formats, DRM_FORMAT_ARGB8888);
        }
        if (fmt == nullptr && formats->len > 0) fmt = &formats->formats[0];
      }
    }
    if (fmt == nullptr) return nullptr;

    wlr_swapchain *chain = wlr_swapchain_create(server_->allocator, w, h, fmt);
    if (chain == nullptr) return nullptr;

    wlr_output_state state;
    wlr_output_state_init(&state);
    wlr_scene_output_state_options opts{};
    opts.swapchain = chain;
    const bool built =
        wlr_scene_output_build_state(output->scene_output, &state, &opts);
    wlr_buffer *locked = nullptr;
    if (built && state.buffer != nullptr) {
      locked = state.buffer;
      wlr_buffer_lock(locked);
    }
    wlr_output_state_finish(&state);
    wlr_swapchain_destroy(chain);
    wlr_damage_ring_add_whole(&output->scene_output->damage_ring);
    return locked;
  }

  /// "The window set changed" — to whatever shell is watching.
  ///
  /// Called from everywhere a dock would draw something different: a window
  /// opening, closing, renaming itself, taking focus, being minimized, or
  /// moving between workspaces. Cheap when nobody subscribed, which is the
  /// usual case — the control plane checks before building a snapshot.
  void announceWindows() {
    if (control_ == nullptr) return;
    control_->postWindowList();
    // Every reason to announce the set is also a reason to recheck the
    // panels: a window that opened, closed, minimized or changed workspace
    // was in the way a moment ago or is now. Geometry-only changes — a drag,
    // a resize — do not come through here and are notified where they happen.
    control_->postPanelAreas();
  }

  /// Rounds a surface the way its place in the window says it should be.
  ///
  /// A decorated window is two surfaces stacked, so each rounds the pair of
  /// corners it actually owns and the seam between them stays straight. A
  /// frameless window is one surface and rounds all four. A panel or a
  /// maximized window rounds none: it is flush against an edge of the
  /// screen, and rounding the corners of something that is meant to look
  /// like part of the frame would just show the wallpaper through the gap.
  ///
  /// A **foreign window is square, bar included**, and that is a decision
  /// rather than a limitation left showing. Its content is the client's own
  /// buffer, composited by `wlr_scene`, which offers no way to reshape it —
  /// so rounding the bar above it would round two corners of a rectangle whose
  /// other two stay sharp, and the shadow behind it can match one end or the
  /// other but not both. Square all the way round is the version that looks
  /// finished. It stops being the answer the day foreign buffers are drawn
  /// through canvas, and that is the day this line changes.
  void applyCorners(ClientSurface &surface) {
    const float radius = cornerRadius_ * (frameIsRoundable(surface) ? 1.f : 0.f);
    if (surface.canvas) {
      const bool top = !surface.showsBar();
      surface.canvas->setCornerRadius(surface.panel ? 0.f : radius, top,
                                      !surface.panel);
    }
    if (surface.bar) {
      surface.bar->setCornerRadius(radius, true, false);
    }
    // The frost plate is the whole frame, so it takes every corner the
    // outline has. Square frost under a rounded window is the tab in the
    // screenshot.
    if (surface.blurCanvas) {
      // One pixel more than the window so the frost's AA sits inside the
      // window's, not beside it as a bright speck.
      const float frost = radius > 0.f ? radius + 2.f : 0.f;
      surface.blurCanvas->setCornerRadius(frost, true, true);
    }
  }

  /// Whether this window's whole outline is the compositor's to shape.
  ///
  /// False for a Wayland client: the pixels in the middle are its own.
  /// False for a maximized window: it is flush to the work area, the
  /// same reason a panel is square.
  static bool frameIsRoundable(const ClientSurface &surface) {
    return !surface.isForeign() && !surface.panel && !surface.maximized &&
           !surface.fullscreen;
  }

  /// Redraws the title bar. Cheap — a strip, from commands built here.
  void drawBar(ClientSurface &surface) {
    if (!surface.bar) return;
    decoration_.build(surface.title, surface.width, surface.hovered,
                      surface.id == focused_);
    if (surface.bar->renderList(decoration_.commands(), decoration_.glyphs())) {
      show_surface(surface.barNode, *surface.bar);
    }
  }

  /// Which window's bar is drawn as active. Not the seat's focus: a client
  /// surface is not a `wlr_surface` and the seat has no object for it.
  uint32_t focusedId() const { return focused_; }

  void setFocused(uint32_t id) {
    if (focused_ == id) return;
    const uint32_t previous = focused_;
    focused_ = id;
    if (ClientSurface *was = find(previous)) {
      drawBar(*was);
      applyShadow(*was);
    }
    ClientSurface *now = find(id);
    if (now != nullptr) {
      drawBar(*now);
      applyShadow(*now);
    }
    // The one place focus changes, so the one place anyone else can be told.
    // A panel with a global menu on it is the caller that needs this; there is
    // usually nobody subscribed and this costs a virtual call.
    //
    // A panel is never reported as the active window. `focusSurface` already
    // refuses to focus one, and this is the second half of the same rule: what
    // a panel wants to know is which *window* is active, and answering "you
    // are" would be both useless and, for a panel showing that window's menu,
    // actively wrong.
    if (control_ != nullptr && (now == nullptr || !now->panel)) {
      if (now != nullptr)
        postActive(*now);
      else
        control_->postActiveWindow(0, {}, {}, {});
    }
    announceWindows();
  }

  /// DBus address of this window's menu, from `org_kde_kwin_appmenu`.
  void menuAddress(const ClientSurface &surface, std::string &outService,
                   std::string &outPath) const {
    outService.clear();
    outPath.clear();
    if (!surface.isForeign() || server_ == nullptr || surface.window == nullptr)
      return;
    wlr_surface *fs = surface.window->focusSurface();
    if (fs == nullptr) return;
    lava::AppMenuAddress addr = server_->appmenu.addressFor(fs);
    outService = std::move(addr.service);
    outPath = std::move(addr.objectPath);
  }

  /// Tell every panel which window is focused and where its menu lives.
  void postActive(const ClientSurface &surface) {
    if (control_ == nullptr) return;
    std::string service, path;
    menuAddress(surface, service, path);
    control_->postActiveWindow(surface.id, surface.title, service, path);
  }

  /// A surface's AppMenu address changed. If it is the focused window, re-post
  /// so the panel can open the menu that arrived after focus.
  void onAppMenuChanged(wlr_surface *surface) {
    if (control_ == nullptr || surface == nullptr) return;
    for (const auto &s : surfaces_) {
      if (!s->isForeign() || s->window == nullptr) continue;
      if (s->window->focusSurface() != surface) continue;
      if (s->id == focused_ && !s->panel) postActive(*s);
      return;
    }
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
    const int id = registerFont(fontPath, canvas::pixelSizeTo26_6(pixelSize), 0,
                                canvas::RasterFlags::of(canvas::FontHinting::Normal));
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
      applyShadow(surface);
      scheduleBackdropRefresh();
      if (surface.bar &&
          surface.bar->resize(width, lava::Decoration::kHeight)) {
        show_surface(surface.barNode, *surface.bar);
      }
      drawBar(surface);
      // Same as the Lava path below. Maximize is move-then-resize: the
      // move posts with the *old* size (usually still clear of the dock)
      // and this is the step that actually covers the strip. Skipping
      // it is why a maximized VS Code left the dock up.
      if (control_ != nullptr) control_->postPanelAreas();
      return;
    }

    if (!surface.canvas->resize(width, height)) return;
    surface.width = width;
    surface.height = height;
    // The shadow is the window's rectangle blurred, so a new rectangle is a
    // new shadow. Rebuilt rather than stretched: a stretched one would soften
    // along one axis and not the other.
    applyShadow(surface);
    scheduleBackdropRefresh();
    // Usually the same buffer at a smaller or larger crop — a surface only
    // hands back a different one when the window outgrew it.
    show_surface(surface.node, *surface.canvas);
    // The bar spans the window, so it follows every width change.
    if (surface.bar && surface.bar->resize(width, lava::Decoration::kHeight)) {
      show_surface(surface.barNode, *surface.bar);
    }
    drawBar(surface);
    // The `Resize` the surface just queued for its client is sitting in the
    // renderer's queue; this is what forwards it, and what redraws the frame
    // already held into the new extent meanwhile.
    pump(surface);
    if (surface.canvas->redraw()) damage(surface);
    // A window that grew into the dock's strip is in the way of it now.
    if (control_ != nullptr && !surface.panel) control_->postPanelAreas();
  }

  uint32_t createPanel(const std::string &arenaId, uint32_t edge,
                       uint32_t thickness, bool reserve,
                       const std::string &title,
                       const std::string &appId) override {
    if (primaryWidth_ == 0 || primaryHeight_ == 0 || workspaces_ == nullptr) {
      wlr_log(WLR_ERROR, "panel: no output yet");
      return 0;
    }
    // A panel is given the length of its edge and chooses only its thickness.
    const bool horizontal = edge == kPanelTop || edge == kPanelBottom;
    const uint32_t w = horizontal ? primaryWidth_ : thickness;
    const uint32_t h = horizontal ? thickness : primaryHeight_;

    // Into the panel tree, which no workspace switch ever disables — a taskbar
    // that vanished on Alt+2 would be a strange sort of taskbar. Undecorated,
    // because there is nothing on a panel to drag, close or maximize.
    const uint32_t id =
        openSurface(arenaId, w, h, title, workspaces_->panels, 0, false);
    if (id == 0) return 0;
    ClientSurface *panel = find(id);
    panel->panel = true;
    panel->edge = edge;
    panel->appId = appId;
    // A panel that reserves, reserves all of itself — the strip it draws is
    // the strip it is owed. Only `SetPanelThickness` can make the two differ,
    // and only for as long as something is open.
    panel->reserved = reserve ? thickness : 0;
    // `openSurface` applied corners while `panel` was still false, so it
    // used the desktop window radius. Re-apply now that this is known to be
    // a panel — flush to the screen edge, square corners (see applyCorners).
    applyCorners(*panel);

    layoutPanel(*panel);
    // Above ordinary windows, which is what "panel" mostly means to a user.
    wlr_scene_node_raise_to_top(&panel->node->node);
    // With the position it settled at, which is not the one `openSurface`
    // logged: a panel is placed by its edge, and that happens here.
    wlr_log(WLR_INFO, "panel %u: '%s' at %d,%d on edge %u, %u deep%s", id,
            title.c_str(), panel->x, panel->y, edge, thickness,
            reserve ? ", reserving" : "");
    // A panel that appears while a game is fullscreen must not draw on top
    // of it — the same rule as every other shell change.
    syncShellForFullscreen();
    return id;
  }

  // ─── Window state ────────────────────────────────────────────────────────
  //
  // The other end of the buttons in `Decoration`. A client that draws its own
  // frame reaches the same code the compositor's strip does, which is what
  // stops the two kinds of window from acquiring two ideas of what "maximize"
  // means.

  bool beginMove(uint32_t id) override;

  bool toggleMaximize(uint32_t id, bool &outMaximized) override {
    ClientSurface *surface = find(id);
    if (surface == nullptr) return false;
    // A panel is placed by its edge and has nothing to restore to.
    if (!surface->panel) setMaximized(*surface, !surface->maximized);
    outMaximized = surface->maximized;
    return true;
  }

  bool minimize(uint32_t id) override;

  bool setMinSize(uint32_t id, uint32_t minWidth, uint32_t minHeight) override {
    ClientSurface *surface = find(id);
    if (surface == nullptr) return false;
    surface->minWidth = minWidth;
    surface->minHeight = minHeight;
    // Recorded, not acted on. This bounds what the *user* can drag the window
    // down to, which is what a minimum is for; a window that opened smaller
    // than its own minimum asked for that size explicitly and is left alone.
    //
    // Growing it here was the first version and is deliberately gone: the
    // resize goes out through the exported buffer, which at this point in a
    // surface's life is not yet in a state to take one, so the call returned
    // quietly having done nothing. A feature that works only sometimes and
    // says nothing when it does not is worse than one with a stated edge.
    return true;
  }

  /// The floor for one axis: the client's own, never below the compositor's
  /// and never above what the work area can show — a minimum that does not
  /// fit on the screen is not a minimum anybody can honour.
  uint32_t minFor(const ClientSurface &surface, bool horizontal) const {
    const uint32_t asked = horizontal ? surface.minWidth : surface.minHeight;
    const WorkArea area = workAreaAt(surface.x, surface.y);
    const uint32_t available = horizontal ? area.width : area.height;
    uint32_t floor = std::max(asked, kMinSurface);
    if (available > 0) floor = std::min(floor, available);
    return std::max(floor, kMinSurface);
  }

  bool setPanelThickness(uint32_t id, uint32_t thickness,
                         uint32_t reserved) override {
    ClientSurface *panel = find(id);
    if (panel == nullptr || !panel->panel) return false;
    // A panel cannot be owed more than it occupies. Clamped rather than
    // refused: the caller's intent is plain, and the arithmetic below would
    // otherwise hand out a negative work area.
    panel->reserved = reserved > thickness ? thickness : reserved;
    const bool horizontal =
        panel->edge == kPanelTop || panel->edge == kPanelBottom;
    resizeSurface(*panel, horizontal ? primaryWidth_ : thickness,
                  horizontal ? thickness : primaryHeight_);
    layoutPanel(*panel);
    // A bottom or right panel grows *into* the screen, so its origin moved;
    // `layoutPanel` has just put it back. What is left is everything that was
    // laid out against the old reservation — which is only the maximized
    // windows, since a maximized window is a promise about the work area
    // rather than a size the user chose.
    for (auto &surface : surfaces_) {
      if (surface->panel) continue;
      if (surface->fullscreen) fillOutput(*surface);
      else if (surface->maximized) fillWorkArea(*surface);
    }
    return true;
  }

  void windowList(uint32_t &outCurrentWorkspace,
                  std::vector<WindowEntry> &outWindows) const override {
    outCurrentWorkspace = workspaces_ != nullptr ? workspaces_->current : 0;
    outWindows.clear();
    for (const auto &surface : surfaces_) {
      // Panels are furniture, not windows. A dock listing itself, and the
      // taskbar beside it, would be a dock listing the desktop's own parts.
      if (surface->panel) continue;
      // The switcher is a regular surface (it needs the keyboard, which a
      // panel never gets) but it is not an application the user opened.
      if (surface->appId == kSwitcherAppId) continue;
      WindowEntry entry;
      entry.surfaceId = surface->id;
      entry.title = surface->title;
      entry.appId = surface->appId;
      entry.workspace = surface->workspace;
      entry.minimized = surface->minimized;
      entry.focused = surface->id == focused_;
      entry.width = surface->width;
      entry.height = surface->height;
      outWindows.push_back(std::move(entry));
    }
  }

  bool activateWindow(uint32_t id) override;

  void setCursor(uint32_t id, uint32_t shape) override;

  bool setInputRegion(uint32_t id, int32_t x, int32_t y, uint32_t w,
                      uint32_t h) override {
    ClientSurface *surface = find(id);
    if (surface == nullptr) return false;
    surface->inputX = x;
    surface->inputY = y;
    surface->inputW = w;
    surface->inputH = h;
    // The Lava hit path reads these on every test. The scene path needs the
    // callback installed once; re-bind is cheap and covers a surface that was
    // somehow created without it.
    if (surface->node != nullptr) bind_content_input(surface->node, surface);
    return true;
  }

  bool setBackdropBlur(uint32_t id, float radius) override {
    ClientSurface *surface = find(id);
    if (surface == nullptr) return false;
    const float next = std::clamp(radius, 0.f, 64.f);
    if (surface->backdropBlurRadius == next) return true;
    surface->backdropBlurRadius = next;
    if (next <= 0.f) {
      clearBackdrop(*surface);
    }
    wlr_log(WLR_INFO, "surface %u: backdrop blur %.0f", id, next);
    scheduleBackdropRefresh();
    return true;
  }

  /// Recaptures frosted plates when something behind a window may have
  /// moved. Cheap when nobody asked: no surface with a radius, nothing
  /// to do. Called from the output frame callback, before the composite.
  void refreshBackdropBlurs() {
    if (!backdropBlurDirty_ || server_ == nullptr || workspaces_ == nullptr) {
      return;
    }
    backdropBlurDirty_ = false;
    for (auto &owned : surfaces_) {
      if (owned->backdropBlurRadius > 0.f && !owned->minimized) {
        captureBackdrop(*owned);
      }
    }
  }

  void appearance(float &outCornerRadius, float &outShadowBlur,
                  float &outShadowOpacity,
                  float &outShadowOffsetY) const override {
    outCornerRadius = cornerRadius_;
    outShadowBlur = shadowBlur_;
    outShadowOpacity = shadowOpacity_;
    outShadowOffsetY = shadowOffsetY_;
  }

  void systemTheme(std::string &outName) const override {
    if (server_ == nullptr) {
      outName = "dark";
      return;
    }
    outName = server_->config.theme.name;
  }

  void updateSystemTheme(const std::string &name,
                         std::string &outError) override {
    std::string taken = name;
    if (taken != "light" && taken != "nebula") taken = "dark";
    if (server_ != nullptr) server_->config.theme.name = taken;
    save({{"theme", "name", taken}}, outError);
    if (control_ != nullptr) control_->postSystemTheme();
  }

  // ─── Settings ────────────────────────────────────────────────────────────
  //
  // Apply, then save. The applying is what makes a slider worth having; the
  // saving is what makes it worth using. Both halves go through the same
  // paths a SIGHUP reload does — this is the same change, arriving by a
  // different route, and a second implementation of "put the config into
  // effect" is a second implementation to keep in step.

  std::string configPath() const override {
    return server_ != nullptr ? server_->configPath : lava::Config::defaultPath();
  }

  void updateAppearance(float cornerRadius, float shadowBlur,
                        float shadowOpacity, float shadowOffsetY,
                        std::string &outError) override {
    // The same limits the config parser applies, for the same reason: these
    // are what the renderer will actually draw, and a client should not have
    // to know them to avoid asking for nonsense.
    const auto clampInt = [](float value, int32_t low, int32_t high) {
      const int32_t rounded = static_cast<int32_t>(std::lround(value));
      return rounded < low ? low : (rounded > high ? high : rounded);
    };
    const int32_t radius = clampInt(cornerRadius, 0, 64);
    const int32_t blur = clampInt(shadowBlur, 0, 128);
    const int32_t offsetY = clampInt(shadowOffsetY, -128, 128);
    const float opacity =
        shadowOpacity < 0.f ? 0.f : (shadowOpacity > 1.f ? 1.f : shadowOpacity);

    if (server_ != nullptr) {
      server_->config.appearance.cornerRadius = radius;
      server_->config.appearance.shadowBlur = blur;
      server_->config.appearance.shadowOpacity = opacity;
      server_->config.appearance.shadowOffsetY = offsetY;
    }
    setAppearance(static_cast<float>(radius), static_cast<float>(blur), opacity,
                  static_cast<float>(offsetY));

    save({{"appearance", "corner-radius", std::to_string(radius)},
          {"appearance", "shadow-blur", std::to_string(blur)},
          {"appearance", "shadow-opacity", format_float(opacity)},
          {"appearance", "shadow-offset-y", std::to_string(offsetY)}},
         outError);
  }

  void background(std::string &outMode, uint32_t &outColor,
                  std::string &outPicture, std::string &outFit) const override {
    // Read off the live backdrop rather than off the config, so a picture that
    // was refused at startup reports the colour that is actually up. The two
    // agree in every other case; this is the one that matters.
    const lava::BackgroundConfig &background =
        server_ != nullptr ? server_->wallpaper.config()
                           : lava::BackgroundConfig{};
    outMode    = background.mode;
    outColor   = background.color;
    outPicture = background.picture;
    outFit     = background.fit;
  }

  void updateBackground(const std::string &mode, uint32_t color,
                        const std::string &picture, const std::string &fit,
                        std::string &outPictureError,
                        std::string &outError) override {
    if (server_ == nullptr) return;

    lava::BackgroundConfig wanted;
    wanted.mode    = lava::canonicalWallpaperMode(mode);
    wanted.color   = color & 0x00ffffffu;
    wanted.picture = picture;
    wanted.fit     = lava::canonicalWallpaperFit(fit);

    // Applied first, and only saved if it took. A path that does not decode
    // must not reach the config file: the next start would read it back, fail
    // again, and the desktop would come up wrong every time from then on.
    if (!server_->wallpaper.apply(wanted, outPictureError)) return;

    server_->config.background = server_->wallpaper.config();
    const lava::BackgroundConfig &saved = server_->config.background;
    save({{"background", "mode", saved.mode},
          {"background", "color", lava::formatWallpaperColor(saved.color)},
          {"background", "picture", saved.picture},
          {"background", "fit", saved.fit}},
         outError);
  }

  void keyboardSettings(KeyboardState &out) const override {
    if (server_ == nullptr) return;
    const lava::KeyboardConfig &keyboard = server_->config.keyboard;
    out.layout = keyboard.layout;
    out.variant = keyboard.variant;
    out.options = keyboard.options;
    out.model = keyboard.model;
    out.rules = keyboard.rules;
    out.repeatRate = keyboard.repeatRate;
    out.repeatDelay = keyboard.repeatDelay;
    out.modKey = keyboard.modKey.empty() ? "alt" : keyboard.modKey;
  }

  void setKeyboardSettings(const KeyboardState &settings,
                           std::string &outError) override {
    if (server_ == nullptr) return;
    lava::KeyboardConfig &keyboard = server_->config.keyboard;
    keyboard.layout = settings.layout;
    keyboard.variant = settings.variant;
    keyboard.options = settings.options;
    keyboard.model = settings.model;
    keyboard.rules = settings.rules;
    // Nonsense here would be a keyboard that repeats forever or not at all,
    // and neither is recoverable by typing.
    keyboard.repeatRate = std::clamp(settings.repeatRate, 0, 100);
    keyboard.repeatDelay = std::clamp(settings.repeatDelay, 100, 2000);
    // Nested: Alt stays the shortcut mod so we do not steal Super from
    // the host, and we do not write that override into the shared
    // `lava.conf` or a SIGHUP of the session compositor would pick it up.
    if (server_->nested) {
      keyboard.modKey = "alt";
    } else {
      keyboard.modKey = normalize_mod_key(settings.modKey);
    }

    // Every connected client is sent the new keymap by wlroots as a side
    // effect, so this reaches applications that are already running.
    for (Keyboard *device : server_->keyboards) device->applyKeymap(keyboard);

    std::vector<lava::Setting> writes = {
        {"keyboard", "layout", keyboard.layout},
        {"keyboard", "variant", keyboard.variant},
        {"keyboard", "options", keyboard.options},
        {"keyboard", "model", keyboard.model},
        {"keyboard", "rules", keyboard.rules},
        {"keyboard", "repeat-rate", std::to_string(keyboard.repeatRate)},
        {"keyboard", "repeat-delay", std::to_string(keyboard.repeatDelay)},
    };
    if (!server_->nested) {
      writes.push_back({"keyboard", "mod-key", keyboard.modKey});
    }
    save(writes, outError);
  }

  void keyboardLayouts(std::vector<LayoutEntry> &out) const override {
    collect_keyboard_layouts(out);
  }

  void keyBindings(std::vector<BindingEntry> &out) const override {
    // Pass the live mod name so the list matches what will actually fire.
    const char *mod =
        (server_ != nullptr && server_->config.keyboard.modKey == "super")
            ? "Super"
            : "Alt";
    collect_key_bindings(out, mod);
  }

  void outputList(std::vector<OutputEntry> &out) const override {
    if (server_ == nullptr) return;
    for (Output *output : server_->outputs) {
      OutputEntry entry;
      entry.name = output->wlr->name != nullptr ? output->wlr->name : "";
      entry.description = describe_output(*output->wlr);
      entry.enabled = output->wlr->enabled;
      entry.width = static_cast<uint32_t>(output->wlr->width);
      entry.height = static_cast<uint32_t>(output->wlr->height);
      entry.refresh = static_cast<uint32_t>(output->wlr->refresh);
      entry.scale = output->wlr->scale;
      entry.transform = static_cast<uint32_t>(output->wlr->transform);
      if (const wlr_output_layout_output *placed =
              wlr_output_layout_get(server_->output_layout, output->wlr)) {
        entry.x = placed->x;
        entry.y = placed->y;
      }
      out.push_back(std::move(entry));
    }
    // Mark the screen that is actually hosting the panel, not the
    // remembered name — that one may be unplugged.
    const std::string primary = effectivePrimaryName();
    for (OutputEntry &entry : out) {
      entry.primary = entry.enabled && !primary.empty() && entry.name == primary;
    }
  }

  bool outputModes(const std::string &name,
                   std::vector<ModeEntry> &out) const override {
    Output *output = findOutput(name);
    if (output == nullptr) return false;

    wlr_output_mode *mode = nullptr;
    wl_list_for_each(mode, &output->wlr->modes, link) {
      ModeEntry entry;
      entry.width = static_cast<uint32_t>(mode->width);
      entry.height = static_cast<uint32_t>(mode->height);
      entry.refresh = static_cast<uint32_t>(mode->refresh);
      entry.preferred = mode->preferred;
      entry.current = output->wlr->current_mode == mode;
      out.push_back(entry);
    }

    // Biggest first, then fastest. A mode list in the order the display
    // happened to report it reads as random, and the one a person wants is
    // almost always at one end of that ordering.
    std::sort(out.begin(), out.end(), [](const ModeEntry &a, const ModeEntry &b) {
      const uint64_t areaA = uint64_t{a.width} * a.height;
      const uint64_t areaB = uint64_t{b.width} * b.height;
      if (areaA != areaB) return areaA > areaB;
      return a.refresh > b.refresh;
    });
    return true;
  }

  bool setOutput(const OutputChange &change, std::string &outError) override {
    Output *output = findOutput(change.name);
    if (output == nullptr || server_ == nullptr) return false;

    lava::OutputConfig &block = outputBlock(change.name);
    block.enabled = change.enabled;
    block.width = static_cast<int32_t>(change.width);
    block.height = static_cast<int32_t>(change.height);
    block.refresh = static_cast<int32_t>(change.refresh);
    block.scale = change.scale;
    block.x = change.x;
    block.y = change.y;
    block.transform = static_cast<int32_t>(change.transform);

    // The same call SIGHUP makes. A mode the display refuses falls back to its
    // preferred one in there rather than leaving a screen showing nothing —
    // the one failure a user cannot recover from without another machine.
    output->applyConfig();

    const std::string section = "output " + change.name;
    std::vector<lava::Setting> settings{
        {section, "enabled", block.enabled ? "true" : "false"},
        {section, "mode", format_mode(block)},
        {section, "scale", format_float(block.scale)},
        {section, "transform", format_transform(block.transform)},
    };
    // Mirror does not own positions — those are the last extend layout,
    // so switching back does not have to guess. Extend writes where the
    // screen actually landed, not what the request carried: enabling a
    // screen that was never placed used to send 0,0 and stack it on the
    // other one.
    if (lava::canonicalArrangement(server_->config.arrangement) != "mirror") {
      if (const wlr_output_layout_output *placed =
              wlr_output_layout_get(server_->output_layout, output->wlr)) {
        block.x = placed->x;
        block.y = placed->y;
        settings.push_back({section, "position",
                            std::to_string(block.x) + "," +
                                std::to_string(block.y)});
      }
    }
    save(std::move(settings), outError);
    return true;
  }

  bool setPrimaryOutput(const std::string &name,
                        std::string &outError) override {
    if (server_ == nullptr) return false;
    if (!name.empty() && findOutput(name) == nullptr) return false;
    server_->config.primaryOutput = name;
    refreshFromLayout();
    save({{"core", "primary-output", name}}, outError);
    return true;
  }

  std::string arrangement() const override {
    if (server_ == nullptr) return "extend";
    return lava::canonicalArrangement(server_->config.arrangement);
  }

  void setArrangement(const std::string &mode,
                      std::string &outError) override {
    if (server_ == nullptr) {
      outError = "no server";
      return;
    }
    server_->config.arrangement = lava::canonicalArrangement(mode);
    server_->applyArrangement();

    std::vector<lava::Setting> settings{
        {"core", "arrangement", server_->config.arrangement}};
    // Persist where extend put them, so the next start does not have
    // to guess. Mirror leaves the last extend positions alone.
    if (server_->config.arrangement == "extend") {
      for (Output *output : server_->outputs) {
        if (!output->wlr->enabled || output->wlr->name == nullptr) continue;
        const wlr_output_layout_output *placed =
            wlr_output_layout_get(server_->output_layout, output->wlr);
        if (placed == nullptr) continue;
        lava::OutputConfig &block = outputBlock(output->wlr->name);
        block.x = placed->x;
        block.y = placed->y;
        settings.push_back({"output " + block.name, "position",
                            std::to_string(block.x) + "," +
                                std::to_string(block.y)});
      }
    }
    save(std::move(settings), outError);
  }

  void activeWindow(uint32_t &outSurfaceId, std::string &outTitle,
                    std::string &outMenuService,
                    std::string &outMenuObjectPath) const override {
    outSurfaceId = focused_;
    outTitle.clear();
    outMenuService.clear();
    outMenuObjectPath.clear();
    for (const auto &surface : surfaces_) {
      if (surface->id == focused_) {
        outTitle = surface->title;
        menuAddress(*surface, outMenuService, outMenuObjectPath);
        return;
      }
    }
    // Focused id with no surface behind it means the window went away between
    // the two; nothing is focused, and saying so is better than a stale name.
    if (outSurfaceId != 0 && outTitle.empty()) outSurfaceId = 0;
  }

  bool destroySurface(uint32_t id) override {
    for (auto it = surfaces_.begin(); it != surfaces_.end(); ++it) {
      if ((*it)->id != id) continue;
      if ((*it)->appId == kSwitcherAppId) invalidatePosters();
      else forgetPosters(id);
      rememberPlacement(**it);
      const uint32_t workspace = (*it)->workspace;
      const bool hadFocus =
          id == focused_ ||
          (server_ != nullptr && server_->focusedSurface() == id);
      if (server_ != nullptr && server_->pendingMove &&
          server_->pendingSurface == id) {
        server_->pendingMove = false;
      }
      std::erase(minimizedOrder_, id);
      // A Wayland window's contents are not ours to destroy — the scene tree
      // belongs to its `Toplevel`, which outlives the frame across an unmap.
      // Only the decoration we added comes down with it.
      if (!(*it)->isForeign() && (*it)->node != nullptr) {
        wlr_scene_node_destroy(&(*it)->node->node);
      }
      if ((*it)->barNode) wlr_scene_node_destroy(&(*it)->barNode->node);
      if ((*it)->shadowTree) wlr_scene_node_destroy(&(*it)->shadowTree->node);
      clearBackdrop(**it);
      scheduleBackdropRefresh();
      if ((*it)->isForeign()) (*it)->window->frameId = 0;
      surfaces_.erase(it);
      // A press whose surface went away before its release: nothing left to
      // deliver it to, and the id would otherwise resolve to whatever opened
      // next.
      if (server_ != nullptr && server_->pointerTarget == id) {
        server_->pointerTarget = 0;
      }
      // Before `surfaceGone`, so a panel hears "nothing is focused" rather
      // than going on showing the menu of a window that has been destroyed.
      if (id == focused_) {
        focused_ = 0;
        if (control_) control_->postActiveWindow(0, {}, {}, {});
      }
      if (control_) control_->surfaceGone(id);
      lava::FrameProbe::forget(id);
      wlr_log(WLR_INFO, "surface %u: gone", id);
      announceWindows();
      syncShellForFullscreen();
      if (server_ != nullptr) {
        server_->focusHistory.forget(id);
        if (server_->focusedByWorkspace[workspace] == id) {
          server_->focusedByWorkspace[workspace] = 0;
        }
        if (hadFocus && server_->workspaces.current == workspace) {
          server_->restoreFocus(workspace, id);
        }
      }
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

  bool panelCovered(uint32_t id) const override {
    const ClientSurface *panel = nullptr;
    for (const auto &s : surfaces_) {
      if (s->id == id) {
        panel = s.get();
        break;
      }
    }
    if (panel == nullptr || !panel->panel) return false;

    // The strip the panel *shows*, not the surface it was given. Those part
    // company for a panel that reserves less than it occupies — the menu bar
    // is 32 pixels of chrome on a 600-pixel surface it keeps for dropdowns —
    // and testing the surface would report that panel covered by any window in
    // the top third of the screen. A panel that reserves nothing is a dock,
    // and there the surface is the strip.
    const bool horizontal = panel->edge == 0 || panel->edge == 1;  // top/bottom
    const uint32_t along = horizontal ? panel->height : panel->width;
    const uint32_t strip = panel->reserved != 0
                               ? std::min(panel->reserved, along)
                               : along;
    // Which end of the surface the strip sits at: against its own edge.
    const bool atFarEnd = panel->edge == 1 || panel->edge == 3;  // bottom/right
    const int px0 =
        panel->x + (horizontal || !atFarEnd
                        ? 0
                        : static_cast<int>(panel->width - strip));
    const int py0 =
        panel->y + (!horizontal || !atFarEnd
                        ? 0
                        : static_cast<int>(panel->height - strip));
    const int px1 =
        px0 + static_cast<int>(horizontal ? panel->width : strip);
    const int py1 =
        py0 + static_cast<int>(horizontal ? strip : panel->height);

    for (const auto &s : surfaces_) {
      const ClientSurface &other = *s;
      if (other.id == id) continue;
      // Another panel is furniture, not a window: a dock does not hide from
      // the taskbar, and two panels that overlap have already agreed to.
      if (other.panel) continue;
      // Minimized is not on screen, and neither is another workspace's.
      if (other.minimized) continue;
      if (workspaces_ != nullptr && other.workspace != workspaces_->current) {
        continue;
      }

      // The frame, not the content: the title bar is part of the window and
      // a dock that ignored it would show itself under one.
      const int ox1 = other.x + static_cast<int>(other.width);
      const int oy1 = other.y + static_cast<int>(other.frameHeight());
      if (other.x < px1 && ox1 > px0 && other.y < py1 && oy1 > py0) {
        return true;
      }
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
    // The events go out now — an app should hear about a click at the speed it
    // happened, not at the speed the screen refreshes.
    drain(surface);
    // The frame does not. Drawing here would put one unpaced frame in front of
    // every paced one, and buy nothing for it: a pointer event arriving in the
    // middle of a refresh interval is shown at the end of that interval either
    // way. On a touchpad emitting a hundred events a second, it was buying a
    // hundred renders a second whose only effect was to land at a different
    // phase than the ones around them. The repaint the renderer asked for is
    // still pending; `stepAnimations` takes it at the next vblank.
    animate();
  }

  /// Hands the renderer's conclusions to the client.
  void drain(ClientSurface &surface) {
    if (control_ == nullptr || !surface.canvas) return;
    canvas::InputEvent event{};
    while (surface.canvas->pollEvent(event)) {
      control_->postInput(surface.id, event.kind, event.x, event.y,
                          event.button, event.mods);
      lava::FrameProbe::input(surface.id);
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
    // Asks the display for a frame rather than setting a clock of our own.
    //
    // A timer here is wrong however carefully it is tuned: 16 ms against a
    // 75 Hz panel is 62.5 content updates a second for 75 chances to show one,
    // so a quarter of the frames shown repeat the one before and the rest
    // arrive at a phase that walks steadily through the refresh interval. That
    // reads as judder even though every frame was cheap and none were late,
    // which is exactly the shape of "the numbers look fine and it looks bad".
    // Scheduling an output frame instead puts the step in `Output::on_frame`:
    // one per vblank, at whatever rate the panel actually runs, sampled at the
    // moment it will be scanned out.
    bool scheduled = false;
    if (server_ != nullptr) {
      for (Output *output : server_->outputs) {
        if (output->wlr == nullptr || !output->wlr->enabled) continue;
        wlr_output_schedule_frame(output->wlr);
        scheduled = true;
      }
    }
    // Nothing to pace against — a headless run with no output, or every screen
    // disabled. The timer stays as the fallback so an animation still finishes
    // rather than freezing halfway through an ease.
    if (!scheduled && animation_ != nullptr) {
      wl_event_source_timer_update(animation_, kFrameMs);
    }
  }

  /// Carries every renderer-owned animation forward one step and redraws the
  /// surfaces that moved. True while any of them still wants another frame.
  ///
  /// Called once per output frame. The redraws it does land in the buffers the
  /// commit that follows will pick up, so a step and the frame that shows it
  /// are the same vblank rather than consecutive ones.
  bool stepAnimations() {
    // Two screens mean two frame events per refresh, and the second would
    // charge every surface a full redraw for the microseconds since the first.
    // One step per display tick, no matter how many screens are watching.
    const int64_t now = std::chrono::duration_cast<std::chrono::microseconds>(
                            std::chrono::steady_clock::now().time_since_epoch())
                            .count();
    if (lastStepAt_ != 0 && now - lastStepAt_ < kMinStepUs) return animating_;
    lastStepAt_ = now;

    bool again = false;
    for (auto &surface : surfaces_) {
      if (!surface->canvas) continue;
      if (fullyOccluded(*surface)) {
        if (surface->canvas->takeInternalRepaint()) {
          surface->deferredWhileOccluded = true;
        }
        continue;
      }
      if (surface->deferredWhileOccluded) {
        surface->deferredWhileOccluded = false;
        if (surface->canvas->redraw()) damage(*surface);
      }
      if (!surface->canvas->takeInternalRepaint()) continue;
      if (surface->canvas->redraw()) damage(*surface);
      drain(*surface);
      again = true;
    }
    animating_ = again;
    return again;
  }

  /// Tells wlroots the surface's contents changed, and when they will have
  /// finished changing. Same buffer, so without this it keeps showing the
  /// texture it already uploaded — see `show_surface`.
  void damage(ClientSurface &surface) {
    if (!surface.canvas) return;
    const int64_t started =
        lava::FrameProbe::on() ? lava::FrameProbe::now() : 0;
    show_surface(surface.node, *surface.canvas);
    lava::FrameProbe::record(surface.id, lava::FrameProbe::Stage::Scene,
                             started);
  }

  void present(uint32_t id) override {
    ClientSurface *surface = find(id);
    if (surface == nullptr || !surface->canvas) return;
    if (fullyOccluded(*surface)) {
      if (surface->canvas->consumeArena()) surface->deferredWhileOccluded = true;
      return;
    }
    if (!surface->canvas->renderFromArena()) return;
    if (surface->awaitingFirstFrame) {
      surface->awaitingFirstFrame = false;
      wlr_scene_node_set_enabled(&surface->node->node, true);
    }
    damage(*surface);
    lava::FrameProbe::frame(id);
    lava::FrameProbe::report();
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
    // This is the one scroll that does not arrive as a pointer event, so
    // nothing has scheduled a frame for it. Every other input path pumps; a
    // notch a widget declined has to ask for its own, or the ease it just
    // aimed sits still until some unrelated event wakes the loop.
    animate();
  }

  void heartbeat(uint32_t id) override {
    if (shell_ == nullptr) return;
    // Resolved to an application here rather than in the supervisor: this is
    // the side that knows what a surface is. Every client sends these and only
    // the two the compositor started are watched, so the usual answer is that
    // nothing matches and nothing happens.
    const ClientSurface *surface = find(id);
    if (surface != nullptr) shell_->heartbeat(surface->appId);
  }

  void bind(lava::ShellSupervisor *shell) { shell_ = shell; }

  /// Bind a compositor surface to a sampled texture for `ImageSurface`.
  ///
  /// GPU import of the window's last dma-buf when we can; CPU readback
  /// only when the buffer will not import. Cached per (surface, maxSide)
  /// for the current switcher session so a frame does not re-import
  /// twenty windows. The cache dies with the overlay — a second Alt+Tab
  /// must see the windows as they are now, not as they were last time.
  static int posterResolveThunk(void *ctx, uint32_t surfaceId,
                                uint32_t maxSide) {
    return static_cast<SurfaceRegistry *>(ctx)->posterTexture(surfaceId,
                                                              maxSide);
  }

  std::string posterKey(uint32_t surfaceId, uint32_t maxSide) const {
    // Generation is in the TextureManager key so a dormant entry from the
    // last session cannot be revived under the same name.
    return "poster:" + std::to_string(posterGen_) + ":" +
           std::to_string(surfaceId) + ":" + std::to_string(maxSide);
  }

  int posterTexture(uint32_t surfaceId, uint32_t maxSide) {
    if (renderer_ == nullptr || surfaceId == 0) return 0;
    const uint64_t cacheKey =
        (static_cast<uint64_t>(surfaceId) << 32) | maxSide;
    if (const auto it = posters_.find(cacheKey); it != posters_.end()) {
      return it->second;
    }
    ClientSurface *surface = find(surfaceId);
    if (surface == nullptr) return 0;

    const std::string texKey = posterKey(surfaceId, maxSide);
    int id = 0;

    if (surface->canvas) {
      if (wlr_buffer *buf = surface->canvas->buffer()) {
        wlr_buffer_lock(buf);
        id = renderer_->importBufferTexture(buf, texKey, maxSide);
        wlr_buffer_unlock(buf);
      }
      if (id <= 0) {
        std::vector<uint8_t> png;
        uint32_t pw = 0, ph = 0;
        if (surface->canvas->capturePng(0, 0, 0, 0,
                                        static_cast<int32_t>(maxSide), png, pw,
                                        ph) &&
            !png.empty()) {
          uint32_t ow = 0, oh = 0;
          id = renderer_->registerImageData(texKey, png.data(), png.size(),
                                            maxSide, ow, oh);
        }
      }
    } else if (surface->isForeign() && surface->window != nullptr) {
      wlr_surface *wl = surface->window->focusSurface();
      if (wl != nullptr && wl->buffer != nullptr) {
        wlr_client_buffer *client = wl->buffer;
        wlr_buffer *source =
            client->source != nullptr ? client->source : &client->base;
        wlr_buffer_lock(source);
        id = renderer_->importBufferTexture(source, texKey, maxSide);
        if (id <= 0) {
          std::vector<uint8_t> png;
          uint32_t pw = 0, ph = 0;
          if (captureForeign(*surface, static_cast<int32_t>(maxSide), png, pw,
                             ph) &&
              !png.empty()) {
            uint32_t ow = 0, oh = 0;
            id = renderer_->registerImageData(texKey, png.data(), png.size(),
                                              maxSide, ow, oh);
          }
        }
        wlr_buffer_unlock(source);
      }
    }

    if (id > 0) posters_[cacheKey] = id;
    return id;
  }

  void forgetPosters(uint32_t surfaceId) {
    if (renderer_ == nullptr) return;
    for (auto it = posters_.begin(); it != posters_.end();) {
      if ((it->first >> 32) != surfaceId) {
        ++it;
        continue;
      }
      renderer_->releaseImage(
          posterKey(surfaceId, static_cast<uint32_t>(it->first)));
      it = posters_.erase(it);
    }
  }

  void invalidatePosters() {
    if (renderer_ != nullptr) {
      for (const auto &[key, id] : posters_) {
        (void)id;
        renderer_->releaseImage(posterKey(static_cast<uint32_t>(key >> 32),
                                          static_cast<uint32_t>(key)));
      }
    }
    posters_.clear();
    ++posterGen_;
  }

  bool captureSurface(uint32_t id, int32_t x, int32_t y, int32_t w, int32_t h,
                      int32_t maxSide, std::vector<uint8_t> &outPng,
                      uint32_t &outW, uint32_t &outH) override {
    ClientSurface *surface = find(id);
    if (surface == nullptr) return false;
    if (surface->canvas) {
      return surface->canvas->capturePng(x, y, w, h, maxSide, outPng, outW,
                                         outH);
    }
    return captureForeign(*surface, maxSide, outPng, outW, outH);
  }

  // The seat's selection, not a drawer of our own — see `lava::Clipboard`.
  // Both of these run on the compositor's loop, because the servants are
  // dispatched there; `get` is the one that can wait, and is bounded.
  std::string clipboardText() const override {
    if (server_ == nullptr) return {};
    lava::Clipboard clipboard(server_->display, server_->seat);
    return clipboard.get();
  }

  std::vector<uint8_t> clipboardPng() const override {
    if (server_ == nullptr) return {};
    lava::Clipboard clipboard(server_->display, server_->seat);
    return clipboard.getPng();
  }

  void setClipboardText(const std::string &text) override {
    if (server_ == nullptr) return;
    lava::Clipboard clipboard(server_->display, server_->seat);
    clipboard.set(text);
  }

  std::string primarySelectionText() const override {
    if (server_ == nullptr) return {};
    lava::Clipboard clipboard(server_->display, server_->seat);
    return clipboard.getPrimary();
  }

  void setPrimarySelectionText(const std::string &text) override {
    if (server_ == nullptr) return;
    lava::Clipboard clipboard(server_->display, server_->seat);
    clipboard.setPrimary(text);
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
  /// The primary output, because that is where a new window opens. Use
  /// `workAreaAt` for a window that already lives on another screen.
  ///
  /// Computed rather than cached, because it changes whenever a panel opens,
  /// closes or the output is resized, and there is no signal for the last one.
  /// A panel that did not ask to `reserve` is not in here — it floats over the
  /// windows, which is what a dock usually wants.
  WorkArea workArea() const {
    return workAreaIn(primaryX_, primaryY_, static_cast<int>(primaryWidth_),
                      static_cast<int>(primaryHeight_));
  }

  /// The work area of the output that contains `(x, y)`, or the primary
  /// if that point is in the gap between screens.
  WorkArea workAreaAt(int x, int y) const {
    int ox = primaryX_;
    int oy = primaryY_;
    uint32_t ow = primaryWidth_;
    uint32_t oh = primaryHeight_;
    outputBoxAt(x, y, ox, oy, ow, oh);
    return workAreaIn(ox, oy, static_cast<int>(ow), static_cast<int>(oh));
  }

  /// Subtracts reserved panels that actually sit on this rectangle.
  WorkArea workAreaIn(int x, int y, int w, int h) const {
    for (const auto &s : surfaces_) {
      if (!s->panel || s->reserved == 0) continue;
      const int sx1 = s->x + static_cast<int>(s->width);
      const int sy1 = s->y + s->frameHeight();
      if (sx1 <= x || sy1 <= y || s->x >= x + w || s->y >= y + h) continue;
      // What it *reserved*, not how thick it is: a panel that grew to hold an
      // open menu is still only owed its strip, and windows that jumped every
      // time a menu opened would be the most obvious bug on the desktop.
      const int claim = static_cast<int>(s->reserved);
      switch (s->edge) {
        case kPanelTop:
          y += claim;
          h -= claim;
          break;
        case kPanelBottom:
          h -= claim;
          break;
        case kPanelLeft:
          x += claim;
          w -= claim;
          break;
        case kPanelRight:
          w -= claim;
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
  /// Queues settings for the config file, and reports rather than throws.
  ///
  /// The change is already applied by the time this runs, so a failure here is
  /// "it will not survive a restart" and not "it did not happen" — see
  /// `SettingsWriteFailed` in the IDL for why those are different sentences.
  ///
  /// Rate-limited, because the caller is a slider. A drag sends a new radius
  /// every frame and each one is a legitimate change to apply; rewriting the
  /// config file sixty times a second to keep up is not. The first write in a
  /// burst goes out immediately — so a config that cannot be written at all
  /// says so on the first call rather than at the end of the drag — and the
  /// rest are merged and flushed once the drag stops.
  void save(std::vector<lava::Setting> settings, std::string &outError) {
    outError.clear();
    for (lava::Setting &setting : settings) {
      auto existing = std::find_if(
          pendingSave_.begin(), pendingSave_.end(),
          [&](const lava::Setting &queued) {
            return queued.section == setting.section && queued.key == setting.key;
          });
      if (existing != pendingSave_.end()) {
        existing->value = std::move(setting.value);
      } else {
        pendingSave_.push_back(std::move(setting));
      }
    }

    const int64_t now = now_ms();
    if (now - lastSaveMs_ >= kSaveIntervalMs) {
      flushSave(outError);
      return;
    }
    if (saveTimer_ != nullptr) {
      wl_event_source_timer_update(
          saveTimer_, static_cast<int>(kSaveIntervalMs - (now - lastSaveMs_)));
    }
  }

  void flushSave(std::string &outError) {
    if (pendingSave_.empty()) return;
    lastSaveMs_ = now_ms();
    const bool ok = lava::Config::write(configPath(), pendingSave_, outError);
    pendingSave_.clear();
    if (!ok) wlr_log(WLR_ERROR, "settings: not saved: %s", outError.c_str());
  }

  static int64_t now_ms() {
    timespec ts{};
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return int64_t{ts.tv_sec} * 1000 + ts.tv_nsec / 1'000'000;
  }

  static int on_save_timer(void *data) {
    std::string ignored;
    static_cast<SurfaceRegistry *>(data)->flushSave(ignored);
    return 0;
  }

  /// Settings changed since the last write, one entry per section+key.
  std::vector<lava::Setting> pendingSave_;
  wl_event_source *saveTimer_ = nullptr;
  int64_t lastSaveMs_ = 0;
  static constexpr int64_t kSaveIntervalMs = 400;

  Output *findOutput(const std::string &name) const {
    if (server_ == nullptr) return nullptr;
    for (Output *output : server_->outputs) {
      if (output->wlr->name != nullptr && name == output->wlr->name) {
        return output;
      }
    }
    return nullptr;
  }

  /// The output that should host the panel: the configured name if that
  /// screen is still on, otherwise the one covering the layout origin.
  wlr_output *resolvePrimaryOutput() const {
    if (server_ == nullptr || server_->output_layout == nullptr) return nullptr;
    const std::string &wanted = server_->config.primaryOutput;
    if (!wanted.empty()) {
      if (Output *found = findOutput(wanted)) {
        if (found->wlr->enabled &&
            wlr_output_layout_get(server_->output_layout, found->wlr) !=
                nullptr) {
          return found->wlr;
        }
      }
    }
    // No preference, or the named one is gone: the screen at the origin,
    // which is where the panel sat before this existed. Read from the
    // layout, not `layoutX_`: that is still the previous box while
    // `refreshFromLayout` is computing the new one.
    wlr_box unionBox{};
    wlr_output_layout_get_box(server_->output_layout, nullptr, &unionBox);
    if (unionBox.width > 0 && unionBox.height > 0) {
      if (wlr_output *atOrigin = wlr_output_layout_output_at(
              server_->output_layout, static_cast<double>(unionBox.x) + 0.5,
              static_cast<double>(unionBox.y) + 0.5)) {
        return atOrigin;
      }
    }
    for (Output *output : server_->outputs) {
      if (output->wlr->enabled &&
          wlr_output_layout_get(server_->output_layout, output->wlr) !=
              nullptr) {
        return output->wlr;
      }
    }
    return nullptr;
  }

  std::string effectivePrimaryName() const {
    if (wlr_output *out = resolvePrimaryOutput()) {
      return out->name != nullptr ? out->name : "";
    }
    return {};
  }

  /// The output box containing `(x, y)`. Leaves the primary box in the
  /// out-params when that point is in a gap.
  void outputBoxAt(int x, int y, int &outX, int &outY, uint32_t &outW,
                   uint32_t &outH) const {
    if (server_ == nullptr || server_->output_layout == nullptr) return;
    wlr_output *output = wlr_output_layout_output_at(
        server_->output_layout, static_cast<double>(x), static_cast<double>(y));
    if (output == nullptr) return;
    wlr_box box{};
    wlr_output_layout_get_box(server_->output_layout, output, &box);
    if (box.width <= 0 || box.height <= 0) return;
    outX = box.x;
    outY = box.y;
    outW = static_cast<uint32_t>(box.width);
    outH = static_cast<uint32_t>(box.height);
  }

  static int surfaceCenterX(const ClientSurface &surface) {
    return surface.x + static_cast<int>(surface.width / 2);
  }

  static int surfaceCenterY(const ClientSurface &surface) {
    return surface.y + surface.frameHeight() / 2;
  }

  /// The config block for a connector, created if the file never had one.
  ///
  /// Never the `[output *]` fallback: a change made to one screen is about
  /// that screen, and writing it into the wildcard would apply it to every
  /// screen that has no block of its own.
  lava::OutputConfig &outputBlock(const std::string &name) {
    for (lava::OutputConfig &output : server_->config.outputs) {
      if (output.name == name) return output;
    }
    lava::OutputConfig created;
    created.name = name;
    server_->config.outputs.push_back(std::move(created));
    return server_->config.outputs.back();
  }

  /// The shared half of `createSurface` and `createPanel`: everything except
  /// which tree the nodes go in and which workspace owns them.
  uint32_t openSurface(const std::string &arenaId, uint32_t width,
                       uint32_t height, const std::string &title,
                       wlr_scene_tree *parent, uint32_t workspace,
                       bool decorated) {
    if (renderer_ == nullptr || parent == nullptr) return 0;

    // A requested size is a request, and the screen is the limit on it. A
    // client asking for more than there is gets what there is: the alternative
    // is a window whose bottom and right are off the display, which is not
    // what anything means by asking for a big window. It is also how a client
    // says "fill the screen" without a call for it — the launcher asks for
    // 4K and gets the work area, whatever that is here.
    if (const WorkArea area = workArea(); area.width > 0 && area.height > 0) {
      // A decorated window's title bar sits above its content, so the content
      // that fits is the work area less the strip.
      const uint32_t bar = decorated ? lava::Decoration::kHeight : 0;
      const uint32_t limitH = area.height > bar ? area.height - bar : kMinSurface;
      width = std::min(width, area.width);
      height = std::min(height, std::max(limitH, kMinSurface));
    }

    auto surface = std::make_unique<ClientSurface>();
    surface->canvas = renderer_->createSurface(width, height);
    if (!surface->canvas) return 0;
    if (!surface->canvas->attachArena(arenaId)) {
      // The client creates the arena and the compositor attaches, so this
      // means the client asked before it had somewhere to draw.
      return 0;
    }
    surface->id = nextId_++;
    // So the surface's whole frame — the arena poll, the render, the scene
    // handover — reports under the number everything else calls it by.
    surface->canvas->setReportedId(surface->id);
    surface->width = width;
    surface->height = height;
    surface->workspace = workspace;
    // Placeholder only. `createSurface` overwrites this from
    // `applyInitialPlacement` once the app id is known; panels are laid
    // out by their edge. Kept on-screen so a window that somehow skips
    // both is still reachable.
    int peers = 0;
    for (const auto &s : surfaces_) {
      if (!s->panel && s->workspace == workspace) ++peers;
    }
    const WorkArea area = workArea();
    const int cascade = 40 + peers * 40;
    const int bar = decorated ? static_cast<int>(lava::Decoration::kHeight) : 0;
    const int roomX = static_cast<int>(area.width) - static_cast<int>(width);
    const int roomY =
        static_cast<int>(area.height) - static_cast<int>(height) - bar;
    const int x = area.x + std::clamp(cascade, 0, std::max(0, roomX));
    const int y = area.y + std::clamp(cascade, 0, std::max(0, roomY));
    surface->x = x;
    surface->y = y;

    surface->title = title;
    surface->decorated = decorated;
    if (decorated) {
      surface->bar = renderer_->createSurface(width, lava::Decoration::kHeight);
      if (!surface->bar) return 0;
    }

    surface->node = wlr_scene_buffer_create(parent, surface->canvas->buffer());
    if (surface->node == nullptr) return 0;
    show_surface(surface->node, *surface->canvas);
    // Invisible until the client has published a frame. The buffer at this
    // point is a clear — showing it is the flash the switcher was painting
    // over the desktop for a split second.
    wlr_scene_node_set_enabled(&surface->node->node, false);
    surface->awaitingFirstFrame = true;
    // Before the surface moves into the list: the pointer is stable, and
    // every later `SetInputRegion` is read through it — see the scene-graph
    // input region note above `content_point_accepts_input`.
    bind_content_input(surface->node, surface.get());
    if (surface->bar) {
      surface->barNode = wlr_scene_buffer_create(parent, surface->bar->buffer());
      if (surface->barNode == nullptr) return 0;
      show_surface(surface->barNode, *surface->bar);
      // Title bars are fully clickable; leave the default accepts-all.
    }
    applyCorners(*surface);
    place(*surface);
    drawBar(*surface);

    const uint32_t id = surface->id;
    surfaces_.push_front(std::move(surface));
    scheduleBackdropRefresh();
    wlr_log(WLR_INFO, "surface %u: '%s' %ux%u at %d,%d on arena '%s'%s", id,
            title.c_str(), width, height, x, y, arenaId.c_str(),
            decorated ? "" : ", client-framed");
    // Deliberately silent: the caller is still deciding what this surface *is*
    // — whether it is a panel, what application it belongs to — and a shell
    // told about it now would draw a window with no name that turns into a
    // panel a moment later. `createSurface` announces when it has finished.
    return id;
  }

  /// Front is topmost. See `raise`, which is what keeps this in step with the
  /// scene graph's own order.
  std::list<std::unique_ptr<ClientSurface>> surfaces_;
  /// Minimized windows, oldest first — see `restoreLastMinimized`.
  std::vector<uint32_t> minimizedOrder_;
  /// Ids Mod+D hid, in front-to-back order, so the next press can put
  /// them back. Empty and `desktopShown_` false is the idle desktop.
  std::vector<uint32_t> desktopHidden_;
  bool desktopShown_ = false;
  /// The one canvas device. Every surface is a window on it, sharing its
  /// glyph atlas and texture cache.
  lava::CanvasRenderer *renderer_ = nullptr;
  Workspaces *workspaces_ = nullptr;
  lava::ControlPlane *control_ = nullptr;
  Server *server_ = nullptr;
  /// Window corner radius in pixels, from the config. 0 is square.
  lava::ShellSupervisor *shell_ = nullptr;
  float cornerRadius_ = 0.f;
  /// Shadow reach in pixels; 0 turns shadows off. See `applyShadow`.
  float shadowBlur_ = 0.f;
  /// The shared shadow images, one per corner radius in use — see
  /// `ShadowTile`. Two at most: rounded, and square for foreign windows.
  std::vector<ShadowTile> shadowTiles_;
  float shadowOpacity_ = 0.35f;
  float shadowOffsetY_ = 4.f;
  lava::Decoration decoration_;
  /// Whose bar is drawn active.
  uint32_t focused_ = 0;
  uint32_t outputWidth_ = 0;
  uint32_t outputHeight_ = 0;
  /// Top-left of the output layout. Not always (0,0): unplugging the
  /// leftmost screen leaves the rest where they were.
  int layoutX_ = 0;
  int layoutY_ = 0;
  /// The screen the panel lives on. Distinct from the layout union so
  /// a window on another monitor is still "on the desktop".
  int primaryX_ = 0;
  int primaryY_ = 0;
  uint32_t primaryWidth_ = 0;
  uint32_t primaryHeight_ = 0;
  /// Set when a frosted window moved, resized, or asked for a new radius.
  bool backdropBlurDirty_ = false;
  /// `ImageSurface` posters, keyed by `(surfaceId << 32) | maxSide`.
  /// Lives for one switcher session; `posterGen_` is in the texture key
  /// so TextureManager cannot revive last session's pixels.
  std::unordered_map<uint64_t, int> posters_;
  uint32_t posterGen_ = 1;
  /// Never reused, so a stale id from a closed surface fails to resolve rather
  /// than quietly addressing whatever opened next.
  uint32_t nextId_ = 1;
  /// Last frame of each application. See `applyInitialPlacement`.
  lava::WindowMemory placements_;
  wl_event_source *placementTimer_ = nullptr;
  static constexpr int kPlacementFlushMs = 30 * 1000;

  static int on_placement_timer(void *data) {
    auto *self = static_cast<SurfaceRegistry *>(data);
    self->flushPlacements();
    if (self->placementTimer_ != nullptr) {
      wl_event_source_timer_update(self->placementTimer_, kPlacementFlushMs);
    }
    return 0;
  }

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

  /// How far outside its own edge a window can still be grabbed to resize.
  /// Wide enough to hit without aiming, narrow enough that two windows a few
  /// pixels apart do not overlap each other's band. See `borderAt`.
  static constexpr double kGrab = 6.0;

  /// One frame at ~60Hz. Only the fallback for a run with no output at all;
  /// a desktop with a screen paces on that screen — see `animate`.
  static constexpr int kFrameMs = 16;
  /// Closest two animation steps may be, whatever asks for them. Two outputs
  /// send two frame events per refresh and this is what keeps that from
  /// costing two redraws; 2 ms leaves headroom to 500 Hz.
  static constexpr int64_t kMinStepUs = 2000;
  wl_event_source *animation_ = nullptr;
  int64_t lastStepAt_ = 0;
  bool animating_ = false;

  static int on_animation(void *data) {
    auto *self = static_cast<SurfaceRegistry *>(data);
    // Re-armed only while something wanted this frame. An idle desktop stops
    // asking, which is the difference between an animation and a busy loop.
    if (self->stepAnimations()) self->animate();
    return 0;
  }
};


ClientSurface *SurfaceRegistry::frontOnWorkspace(uint32_t workspace) {
  for (auto &surface : surfaces_) {
    if (surface->panel || surface->minimized) continue;
    if (surface->workspace != workspace) continue;
    if (isTransientApp(surface->appId)) continue;
    return surface.get();
  }
  return nullptr;
}

void SurfaceRegistry::setTransient(ClientSurface &surface, bool transient,
                                   uint32_t parentId) {
  surface.transient = transient;
  surface.parentId = parentId;
}

bool SurfaceRegistry::hintToplevelConfigure(const std::string &appId,
                                            uint32_t &width, uint32_t &height,
                                            bool &maximized,
                                            bool transient) const {
  width = 0;
  height = 0;
  maximized = false;
  if (appId.empty() || isTransientApp(appId) || transient) return false;
  const lava::WindowPlacement *saved = placements_.find(appId);
  if (saved == nullptr) return false;
  if (saved->maximized) {
    const WorkArea area =
        workAreaAt(saved->x + static_cast<int>(saved->width / 2),
                   saved->y + static_cast<int>(saved->height / 2));
    width = area.width;
    height = area.height;
    maximized = true;
    return true;
  }
  width = saved->width;
  height = saved->height;
  return true;
}

void SurfaceRegistry::rememberPlacement(const ClientSurface &surface) {
  if (surface.panel || surface.appId.empty() || isTransientApp(surface.appId) ||
      surface.transient) {
    return;
  }
  lava::WindowPlacement placement;
  if (surface.fullscreen || surface.maximized) {
    // The floating rectangle, not the work area: otherwise the next
    // unmaximize would restore a "maximized" window to maximized.
    placement.x = surface.restoreX;
    placement.y = surface.restoreY;
    placement.width = surface.restoreW;
    placement.height = surface.restoreH;
    placement.maximized = surface.maximized;
  } else {
    placement.x = surface.x;
    placement.y = surface.y;
    placement.width = surface.width;
    placement.height = surface.height;
    placement.maximized = false;
  }
  if (!placement.usable()) return;
  placements_.remember(surface.appId, placement);
}

void SurfaceRegistry::applyInitialPlacement(ClientSurface &surface) {
  if (surface.panel || isTransientApp(surface.appId)) return;

  const WorkArea primary = workArea();
  const int bar =
      surface.showsBar() ? static_cast<int>(lava::Decoration::kHeight) : 0;

  // Another window of the same application is not something to step off:
  // it shares the one remembered frame, so the 40 px would come back as
  // the new saved position and the app would walk down the screen a step
  // per launch. Two instances landing on top of each other is the honest
  // reading of one remembered frame per application.
  const auto nudge = [&](int &x, int &y) {
    constexpr int kStep = 40;
    for (int n = 0; n < 12; ++n) {
      bool occupied = false;
      for (const auto &other : surfaces_) {
        if (other.get() == &surface || other->panel) continue;
        if (other->workspace != surface.workspace) continue;
        if (!surface.appId.empty() && other->appId == surface.appId) continue;
        if (other->x == x && other->y == y) {
          occupied = true;
          break;
        }
      }
      if (!occupied) return;
      x += kStep;
      y += kStep;
    }
  };

  const auto clampTo = [&](int &x, int &y, uint32_t w, uint32_t h,
                           const WorkArea &area) {
    const int maxX = area.x + static_cast<int>(area.width) - static_cast<int>(w);
    const int maxY = area.y + static_cast<int>(area.height) - static_cast<int>(h) -
                     bar;
    x = std::clamp(x, area.x, std::max(area.x, maxX));
    y = std::clamp(y, area.y, std::max(area.y, maxY));
  };

  // A dialog shares its parent's identity, and restoring the saved frame
  // is how a viewer opened maximized at the file manager's size. Only
  // being a child disqualifies a window: counting other windows that
  // carry this `app_id` cannot tell a genuine second window from the same
  // window re-created, which is what Qt does between mapping a toplevel
  // and negotiating its decoration.
  const lava::WindowPlacement *saved =
      !surface.transient && !surface.appId.empty()
          ? placements_.find(surface.appId)
          : nullptr;

  if (saved == nullptr) {
    // Keep the size the client asked for. Centre on the parent if this
    // is a dialog, otherwise on the primary — a window the size of the
    // work area has no slack, so the centre is the origin.
    int x = 0;
    int y = 0;
    WorkArea area = primary;
    if (ClientSurface *parent = find(surface.parentId)) {
      area = workAreaAt(parent->x + static_cast<int>(parent->width / 2),
                        parent->y + parent->frameHeight() / 2);
      x = parent->x + (static_cast<int>(parent->width) -
                       static_cast<int>(surface.width)) /
                          2;
      y = parent->y + (parent->frameHeight() - surface.frameHeight()) / 2;
    } else {
      const int roomX =
          static_cast<int>(primary.width) - static_cast<int>(surface.width);
      const int roomY = static_cast<int>(primary.height) -
                        static_cast<int>(surface.height) - bar;
      x = primary.x + std::max(0, roomX) / 2;
      y = primary.y + std::max(0, roomY) / 2;
    }
    nudge(x, y);
    clampTo(x, y, surface.width, surface.height, area);
    moveSurface(surface, x, y);
    wlr_log(WLR_INFO, "window %u: centred at %d,%d %ux%u%s", surface.id, x, y,
            surface.width, surface.height,
            surface.transient ? " (dialog)" : " (first launch)");
    return;
  }

  if (saved->maximized) {
    // Park the floating rectangle on the surface so `setMaximized` copies
    // *that* into restore, not whatever cascade `openSurface` just used.
    // Clamp first: the screen it last sat on may be unplugged, and
    // unmaximizing into the hole is how a window vanishes.
    int rx = saved->x;
    int ry = saved->y;
    uint32_t rw = saved->width > 0 ? saved->width : surface.width;
    uint32_t rh = saved->height > 0 ? saved->height : surface.height;
    const WorkArea area =
        workAreaAt(rx + static_cast<int>(rw / 2),
                   ry + static_cast<int>(rh / 2));
    const uint32_t limitH =
        area.height > static_cast<uint32_t>(bar) ? area.height - bar
                                                 : kMinSurface;
    rw = std::min(rw, area.width);
    rh = std::min(rh, std::max(limitH, kMinSurface));
    if (rw < kMinSurface) rw = kMinSurface;
    if (rh < kMinSurface) rh = kMinSurface;
    clampTo(rx, ry, rw, rh, area);
    surface.x = rx;
    surface.y = ry;
    surface.width = rw;
    surface.height = rh;
    setMaximized(surface, true);
    wlr_log(WLR_INFO, "window %u: restored maximized (from %d,%d %ux%u)",
            surface.id, saved->x, saved->y, saved->width, saved->height);
    return;
  }

  uint32_t w = saved->width;
  uint32_t h = saved->height;
  int x = saved->x;
  int y = saved->y;
  const WorkArea area =
      workAreaAt(x + static_cast<int>(w / 2), y + static_cast<int>(h / 2));
  const uint32_t limitH =
      area.height > static_cast<uint32_t>(bar) ? area.height - bar : kMinSurface;
  w = std::min(w, area.width);
  h = std::min(h, std::max(limitH, kMinSurface));
  if (w < kMinSurface) w = kMinSurface;
  if (h < kMinSurface) h = kMinSurface;
  nudge(x, y);
  clampTo(x, y, w, h, area);
  if (w != surface.width || h != surface.height) {
    resizeSurface(surface, w, h);
  }
  moveSurface(surface, x, y);
  evictOntoLayout(surface);
  wlr_log(WLR_INFO, "window %u: restored at %d,%d %ux%u", surface.id, surface.x,
          surface.y, surface.width, surface.height);
}

uint32_t SurfaceRegistry::adoptWindow(FramedWindow *window,
                                     const std::string &title, uint32_t width,
                                     uint32_t height, const std::string &appId,
                                     bool decorated, bool transient,
                                     uint32_t parentId) {
  if (workspaces_ == nullptr) return 0;
  auto surface = std::make_unique<ClientSurface>();
  surface->id = nextId_++;
  surface->window = window;
  surface->title = title.empty() ? "Untitled" : title;
  surface->appId = appId;
  surface->transient = transient;
  surface->parentId = parentId;
  surface->width = width < kMinSurface ? kMinSurface : width;
  surface->height = height < kMinSurface ? kMinSurface : height;
  surface->workspace = window->workspace;
  // Load-bearing from here on rather than only a note: `contentY`, hit
  // testing and the corner rounding all place the window against its bar, and
  // a window with no bar left marked as having one is drawn 32 px below where
  // everything thinks it is. Nothing noticed while every adopted window was
  // decorated.
  surface->decorated = decorated;

  const WorkArea area = workArea();
  // Placeholder; `applyInitialPlacement` is the authority once the
  // identity is on the surface. A first launch centres, a remembered
  // one comes back where it was.
  surface->x = area.x;
  surface->y = area.y;

  // A client's default size knows nothing about this monitor — alacritty
  // opens at 1100 wide whether or not the screen is that big. Asked to fit
  // so a first-launch centre cannot park half the window off-screen.
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
      show_surface(surface->barNode, *surface->bar);
    }
  }

  const uint32_t id = surface->id;
  window->frameId = id;
  applyCorners(*surface);
  applyInitialPlacement(*surface);
  place(*surface);
  drawBar(*surface);
  announceWindows();
  surfaces_.push_front(std::move(surface));
  wlr_log(WLR_INFO, "window %u: '%s' %ux%u on workspace %u%s", id,
          title.c_str(), surfaces_.front()->width, surfaces_.front()->height,
          window->workspace + 1, decorated ? "" : ", client-framed");
  return id;
}

// ─── X11 windows ───────────────────────────────────────────────────────────

XwaylandSurface::XwaylandSurface(Server *server, wlr_xwayland_surface *surface)
    : server(server), xsurface(surface) {
  workspace = server->workspaces.current;
  server->xwindows.push_front(this);
  // An X11 window exists before it has any Wayland surface behind it, and may
  // outlive several. `associate` is when one appears, and the only point at
  // which map and unmap can be listened for.
  associate.attach(&xsurface->events.associate, this, on_associate);
  dissociate.attach(&xsurface->events.dissociate, this, on_dissociate);
  destroy.attach(&xsurface->events.destroy, this, on_destroy);
  request_configure.attach(&xsurface->events.request_configure, this,
                           on_request_configure);
  set_title.attach(&xsurface->events.set_title, this, on_set_title);
  set_class.attach(&xsurface->events.set_class, this, on_set_class);
  set_parent.attach(&xsurface->events.set_parent, this, on_set_parent);
  set_window_type.attach(&xsurface->events.set_window_type, this,
                         on_set_window_type);
  // `_NET_WM_MOVERESIZE`, which is X11's version of the same conversation: a
  // client that draws its own header tells the window manager the user has
  // started dragging it, rather than moving itself.
  request_move.attach(&xsurface->events.request_move, this, on_request_move);
  request_resize.attach(&xsurface->events.request_resize, this,
                        on_request_resize);
  request_fullscreen.attach(&xsurface->events.request_fullscreen, this,
                            on_request_fullscreen);
  request_maximize.attach(&xsurface->events.request_maximize, this,
                          on_request_maximize);
  request_minimize.attach(&xsurface->events.request_minimize, this,
                          on_request_minimize);
}

XwaylandSurface::~XwaylandSurface() {
  server->xwindows.remove(this);
  if (associated) on_dissociate(&dissociate.listener, nullptr);
  associate.detach();
  dissociate.detach();
  destroy.detach();
  request_configure.detach();
  set_title.detach();
  set_class.detach();
  set_parent.detach();
  set_window_type.detach();
  request_move.detach();
  request_resize.detach();
  request_fullscreen.detach();
  request_maximize.detach();
  request_minimize.detach();
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
    // A menu, tooltip or launcher. It has asked the window manager to keep
    // out, so it is placed exactly where it says and never framed. Most such
    // windows must not take focus, but X11 launchers such as Rofi cannot use
    // their traditional keyboard grab through Xwayland. wlroots classifies
    // the small subset that needs the compositor to hand it focus instead.
    wlr_scene_node_set_position(&self->scene_tree->node, self->xsurface->x,
                                self->xsurface->y);
    wlr_scene_node_raise_to_top(&self->scene_tree->node);
    if (wlr_xwayland_surface_override_redirect_wants_focus(self->xsurface)) {
      self->previousClientFocus = server->focusedSurface();
      server->setFocusedSurface(0);
      if (server->surfaces != nullptr) server->surfaces->setFocused(0);
      wlr_xwayland_surface_activate(self->xsurface, true);
      if (wlr_keyboard *keyboard = wlr_seat_get_keyboard(server->seat)) {
        wlr_seat_keyboard_notify_enter(
            server->seat, self->xsurface->surface, keyboard->keycodes,
            keyboard->num_keycodes, &keyboard->modifiers);
      }
      self->overrideFocused = true;
      wlr_log(WLR_INFO, "x11 override-redirect window given keyboard focus");
    }
    return;
  }

  // The back-pointer click-to-focus resolves through — `surface_at` walks up
  // from the surface it hit looking for exactly this, and an X11 window
  // without one is a window that cannot be raised by clicking inside it.
  //
  // Set here rather than beside the tree above, because an override-redirect
  // window must *not* have one: it is a menu, it decides its own stacking and
  // its own focus at map time, and resolving a click on it to a window to
  // raise would undo both.
  self->scene_tree->node.data = static_cast<FramedWindow *>(self);

  server->toplevels.push_front(self);
  if (server->surfaces != nullptr) {
    const uint32_t width = self->xsurface->width > 0
                               ? static_cast<uint32_t>(self->xsurface->width)
                               : 0;
    const uint32_t height = self->xsurface->height > 0
                                ? static_cast<uint32_t>(self->xsurface->height)
                                : 0;
    // X11's WM_CLASS is what a desktop file matches on, the same role
    // `app_id` plays for a Wayland client.
    const uint32_t parentId = server->x11FrameId(self->xsurface->parent);
    const uint32_t id = server->surfaces->adoptWindow(
        self, title ? title : "", width, height,
        self->xsurface->xclass ? self->xsurface->xclass : "",
        self->serverDecorated(), x11IsTransient(self->xsurface), parentId);
    if (ClientSurface *frame = server->surfaces->find(id)) {
      server->surfaces->raise(*frame);
      // Games often map already wanting `_NET_WM_STATE_FULLSCREEN`. Applying
      // it here, after the frame exists, is what turns that into covering
      // the output rather than a 1920×1080 window in the cascade.
      if (self->xsurface->fullscreen) {
        server->surfaces->setFullscreen(*frame, true);
      } else if (self->xsurface->maximized_horz ||
                 self->xsurface->maximized_vert) {
        server->surfaces->setMaximized(*frame, true);
      } else {
        // Borderless and already the output: hide the panel even though the
        // client never sent `_NET_WM_STATE_FULLSCREEN`.
        server->surfaces->syncShellForFullscreen();
      }
    }
  }
  server->focus(self);
  server->setFocusedSurface(0);
  if (self->xsurface->minimized && self->frameId != 0 &&
      server->surfaces != nullptr) {
    if (ClientSurface *frame = server->surfaces->find(self->frameId)) {
      server->minimizeSurface(*frame);
    }
  }
  wlr_log(WLR_INFO, "x11 window mapped: class=%s title=%s",
          self->xsurface->xclass ? self->xsurface->xclass : "(none)",
          title ? title : "(none)");
}

void XwaylandSurface::on_unmap(wl_listener *listener, void *) {
  auto *self = owner_of<XwaylandSurface>(listener);
  Server *server = self->server;
  if (self->overrideFocused) {
    self->overrideFocused = false;
    wlr_xwayland_surface_activate(self->xsurface, false);
    wlr_seat_keyboard_notify_clear_focus(server->seat);
    if (self->previousClientFocus != 0 && server->surfaces != nullptr &&
        server->surfaces->find(self->previousClientFocus) != nullptr) {
      server->setFocusedSurface(self->previousClientFocus);
      server->surfaces->setFocused(self->previousClientFocus);
    } else {
      server->focus(server->frontToplevel(server->workspaces.current));
    }
    self->previousClientFocus = 0;
  }
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
  // Fullscreen owns both: a game that also sends a ConfigureRequest for
  // 1920×1080 at (0,0) is asking for the same thing, and honouring the
  // position as a move would pull it off fullscreen.
  if (frame->fullscreen) {
    wlr_xwayland_surface_configure(
        self->xsurface, 0, 0, static_cast<uint16_t>(frame->width),
        static_cast<uint16_t>(frame->height));
    return;
  }
  // Same for maximize: Steam (and most X11 toolkits) answer a maximize
  // configure by asking for their old size. Honouring that is how the
  // title-bar button looked like a no-op.
  if (frame->maximized) {
    wlr_xwayland_surface_configure(
        self->xsurface, static_cast<int16_t>(frame->x),
        static_cast<int16_t>(frame->contentY()),
        static_cast<uint16_t>(frame->width),
        static_cast<uint16_t>(frame->height));
    return;
  }
  // Framed: the size is the client's to ask for, the position is not.
  self->server->surfaces->resizeSurface(*frame, event->width, event->height);
  // A game that grows to the output after map is the same as one that
  // mapped that way — the panel has to get out.
  self->server->surfaces->syncShellForFullscreen();
}

void XwaylandSurface::on_set_title(wl_listener *listener, void *) {
  auto *self = owner_of<XwaylandSurface>(listener);
  if (self->frameId == 0 || self->server->surfaces == nullptr) return;
  if (ClientSurface *frame = self->server->surfaces->find(self->frameId)) {
    self->server->surfaces->setTitle(
        *frame, self->xsurface->title ? self->xsurface->title : "Untitled");
  }
}

void XwaylandSurface::on_set_class(wl_listener *listener, void *) {
  auto *self = owner_of<XwaylandSurface>(listener);
  if (self->frameId == 0 || self->server->surfaces == nullptr) return;
  if (ClientSurface *frame = self->server->surfaces->find(self->frameId)) {
    frame->appId = self->xsurface->xclass ? self->xsurface->xclass : "";
    self->server->surfaces->announceWindows();
  }
}

/// Both properties can be set at any time, and both can be taken back:
/// a client that clears `WM_TRANSIENT_FOR`, or moves from a utility type
/// to `_NET_WM_WINDOW_TYPE_NORMAL`, is an ordinary window again and its
/// frame is once more the one to remember for that `WM_CLASS`.
void XwaylandSurface::refreshTransient() {
  if (frameId == 0 || server->surfaces == nullptr) return;
  if (ClientSurface *frame = server->surfaces->find(frameId)) {
    server->surfaces->setTransient(*frame, x11IsTransient(xsurface),
                                   server->x11FrameId(xsurface->parent));
  }
}

void XwaylandSurface::on_set_parent(wl_listener *listener, void *) {
  owner_of<XwaylandSurface>(listener)->refreshTransient();
}

void XwaylandSurface::on_set_window_type(wl_listener *listener, void *) {
  owner_of<XwaylandSurface>(listener)->refreshTransient();
}

/// X11's move request. No serial to validate — `_NET_WM_MOVERESIZE` carries
/// none — so the guard is the one `beginInteractiveMove` already applies:
/// a button has to be down for a drag to be carrying anything.
void XwaylandSurface::on_request_move(wl_listener *listener, void *) {
  auto *self = owner_of<XwaylandSurface>(listener);
  Server *server = self->server;
  if (server->surfaces == nullptr || self->frameId == 0) return;
  if (ClientSurface *frame = server->surfaces->find(self->frameId)) {
    if (frame->maximized || frame->fullscreen) {
      server->armInteractiveMove(*frame, true);
    } else {
      server->beginInteractiveMove(*frame, true);
    }
  }
}

void XwaylandSurface::on_request_resize(wl_listener *listener, void *data) {
  auto *self = owner_of<XwaylandSurface>(listener);
  auto *event = static_cast<wlr_xwayland_resize_event *>(data);
  Server *server = self->server;
  if (server->surfaces == nullptr || self->frameId == 0) return;
  if (ClientSurface *frame = server->surfaces->find(self->frameId)) {
    server->beginInteractiveResize(*frame, fromWlrEdges(event->edges), true);
  }
}

/// `_NET_WM_STATE_FULLSCREEN`. wlroots has already written the requested
/// value onto `xsurface->fullscreen` by the time this fires.
void XwaylandSurface::on_request_fullscreen(wl_listener *listener, void *) {
  auto *self = owner_of<XwaylandSurface>(listener);
  const bool want = self->xsurface->fullscreen;
  if (self->frameId != 0 && self->server->surfaces != nullptr) {
    if (ClientSurface *frame = self->server->surfaces->find(self->frameId)) {
      self->server->surfaces->setFullscreen(*frame, want);
      return;
    }
  }
  // Not framed yet — map will apply it. Still ack the property so the
  // client does not sit waiting for a WM that never answers.
  wlr_xwayland_surface_set_fullscreen(self->xsurface, want);
}

/// `_NET_WM_STATE_MAXIMIZED_{HORZ,VERT}`. Both flags are the requested
/// state by the time this fires. This compositor only has all-or-nothing
/// maximize, so both on means fill the work area and both off means
/// restore — a single axis is treated as maximized rather than ignored,
/// because a client that asked for one half still asked to be parked.
void XwaylandSurface::on_request_maximize(wl_listener *listener, void *) {
  auto *self = owner_of<XwaylandSurface>(listener);
  const bool want =
      self->xsurface->maximized_horz || self->xsurface->maximized_vert;
  if (self->frameId != 0 && self->server->surfaces != nullptr) {
    if (ClientSurface *frame = self->server->surfaces->find(self->frameId)) {
      self->server->surfaces->setMaximized(*frame, want);
      return;
    }
  }
  wlr_xwayland_surface_set_maximized(self->xsurface, want, want);
}

/// `_NET_WM_STATE_HIDDEN` / `WM_CHANGE_STATE` Iconic. The event carries
/// the requested state — a client can ask to come back as well as to go.
void XwaylandSurface::on_request_minimize(wl_listener *listener, void *data) {
  auto *self = owner_of<XwaylandSurface>(listener);
  auto *event = static_cast<wlr_xwayland_minimize_event *>(data);
  if (self->frameId != 0 && self->server->surfaces != nullptr) {
    if (ClientSurface *frame = self->server->surfaces->find(self->frameId)) {
      if (event->minimize) {
        self->server->minimizeSurface(*frame);
      } else {
        self->server->surfaces->setMinimized(*frame, false);
        self->server->focusSurface(*frame);
      }
      return;
    }
  }
  wlr_xwayland_surface_set_minimized(self->xsurface, event->minimize);
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
  commit.attach(&wlr->events.commit, this, on_commit);

  wlr_output_init_render(wlr, server->allocator, server->renderer);
  describe_output(wlr);
  server->outputs.push_back(this);

  applyConfig();
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
    sceneAttached = false;
    server->applyArrangement();
    return nullptr;
  }

  wlr_log(WLR_INFO, "output %s: running %dx%d@%.3fHz scale %.2f", wlr->name,
          wlr->width, wlr->height, wlr->refresh / 1000.0, wlr->scale);

  server->applyArrangement();
  return wlr_output_layout_get(server->output_layout, wlr);
}

void Output::placeAt(int x, int y) {
  wlr_output_layout_output *layout_output =
      wlr_output_layout_add(server->output_layout, wlr, x, y);
  if (layout_output == nullptr) return;
  // Removing an output from the layout destroys the scene-layout link.
  // Enabling it again (or adding it the first time after a disabled
  // start) has to put that link back, or this screen keeps painting
  // whatever is at (0,0) — a mirror nobody asked for.
  if (!sceneAttached) {
    wlr_scene_output_layout_add_output(server->scene_layout, layout_output,
                                       scene_output);
    sceneAttached = true;
  }
}

void Server::applyArrangement() {
  std::vector<Output *> enabled;
  for (Output *output : outputs) {
    if (output->wlr->enabled) enabled.push_back(output);
  }

  const bool mirror = lava::canonicalArrangement(config.arrangement) == "mirror";
  if (mirror) {
    for (Output *output : enabled) output->placeAt(0, 0);
  } else {
    // Honour saved positions when they actually describe an extended
    // desktop: every enabled screen has one, and no two sit on the same
    // point. Two screens both at 0,0 is how Settings used to write a
    // newly-enabled output — that is a mirror, not a layout.
    bool honour = !enabled.empty();
    for (Output *output : enabled) {
      const lava::OutputConfig *cfg =
          output->wlr->name != nullptr ? config.forOutput(output->wlr->name)
                                       : nullptr;
      if (cfg == nullptr || cfg->x == lava::OutputConfig::kAuto) {
        honour = false;
        break;
      }
      for (Output *other : enabled) {
        if (other == output) continue;
        const lava::OutputConfig *otherCfg =
            other->wlr->name != nullptr ? config.forOutput(other->wlr->name)
                                        : nullptr;
        if (otherCfg != nullptr && otherCfg->x == cfg->x &&
            otherCfg->y == cfg->y) {
          honour = false;
          break;
        }
      }
      if (!honour) break;
    }

    if (honour) {
      for (Output *output : enabled) {
        const lava::OutputConfig *cfg = config.forOutput(output->wlr->name);
        output->placeAt(cfg->x, cfg->y);
      }
    } else {
      // Primary on the left, the rest strung to its right. A laptop
      // that was stacked on the external becomes a second desktop
      // instead of a second copy of the first.
      Output *primary = nullptr;
      if (!config.primaryOutput.empty()) {
        for (Output *output : enabled) {
          if (output->wlr->name != nullptr &&
              config.primaryOutput == output->wlr->name) {
            primary = output;
            break;
          }
        }
      }
      if (primary == nullptr && !enabled.empty()) primary = enabled.front();

      int x = 0;
      auto place = [&](Output *output) {
        output->placeAt(x, 0);
        int width = 0, height = 0;
        wlr_output_effective_resolution(output->wlr, &width, &height);
        if (width <= 0) width = output->wlr->width;
        x += width;
      };
      if (primary != nullptr) place(primary);
      for (Output *output : enabled) {
        if (output != primary) place(output);
      }
    }
  }

  if (surfaces != nullptr) surfaces->refreshFromLayout();
}

Output::~Output() {
  if (compositeLocked) {
    wlr_output_lock_attach_render(wlr, false);
    compositeLocked = false;
  }
  server->outputs.remove(this);
  frame.detach();
  request_state.detach();
  destroy.detach();
  commit.detach();
}

namespace {

bool surface_has_acquire_fence(wlr_surface *surface) {
  if (surface == nullptr) return false;
  const wlr_linux_drm_syncobj_surface_v1_state *state =
      wlr_linux_drm_syncobj_v1_get_surface_state(surface);
  return state != nullptr && state->acquire_timeline != nullptr;
}

/// True when `node` is on screen and its `width`×`height` covers `box`.
bool node_covers_box(wlr_scene_node *node, int width, int height,
                     const wlr_box &box) {
  if (node == nullptr || width < 1 || height < 1 || box.width < 1) {
    return false;
  }
  int lx = 0, ly = 0;
  if (!wlr_scene_node_coords(node, &lx, &ly)) return false;
  return lx <= box.x && ly <= box.y &&
         lx + width >= box.x + box.width &&
         ly + height >= box.y + box.height;
}

}  // namespace

void Output::syncScanoutLock() {
  wlr_box box{};
  wlr_output_layout_get_box(server->output_layout, wlr, &box);

  // `LAVA_SCANOUT_PROBE=1` answers the question this function is built around:
  // does the covering client attach an acquire fence on *every* frame, or only
  // on some? "Only on some" is what forces a blanket composite, and it is a
  // claim about a particular client on a particular driver — not something to
  // assume in either direction.
  static const bool probe = std::getenv("LAVA_SCANOUT_PROBE") != nullptr;

  // Whoever owns this output's pixels. X11 is looked at first only because it
  // is the case that produced the bug; both kinds are then asked the same
  // question, since both answer it the same way.
  wlr_surface *covering = nullptr;
  for (XwaylandSurface *xwindow : server->xwindows) {
    if (xwindow->scene_tree == nullptr || xwindow->xsurface->surface == nullptr) {
      continue;
    }
    if (!xwindow->xsurface->surface->mapped) continue;
    if (!node_covers_box(&xwindow->scene_tree->node, xwindow->xsurface->width,
                         xwindow->xsurface->height, box)) {
      continue;
    }
    covering = xwindow->xsurface->surface;
    break;
  }
  if (covering == nullptr) {
    for (FramedWindow *window : server->toplevels) {
      wlr_surface *surface = window->focusSurface();
      wlr_scene_node *node = window->contentNode();
      if (surface == nullptr || !surface->mapped || node == nullptr) continue;
      if (!node_covers_box(node, surface->current.width, surface->current.height,
                           box)) {
        continue;
      }
      covering = surface;
      break;
    }
  }

  const bool fenced = covering != nullptr && surface_has_acquire_fence(covering);
  bool lock = compositeLocked;
  if (covering == nullptr) {
    // Nothing owns the output; what wlroots scanouts is its own business.
    lock = false;
    fencedFrames = 0;
  } else if (!fenced) {
    lock = true;
    fencedFrames = 0;
  } else if (++fencedFrames >= kFencedFramesToUnlock) {
    lock = false;
  }

  if (lock != compositeLocked) {
    wlr_output_lock_attach_render(wlr, lock);
    compositeLocked = lock;
    wlr_log(WLR_INFO, "output %s: %s", wlr->name,
            lock ? "compositing a covering client"
                 : "direct scanout allowed again");
  }
  if (lock) {
    wlr_damage_ring_add_whole(&scene_output->damage_ring);
  }

  if (probe) {
    static uint64_t totalFenced = 0, totalUnfenced = 0, frames = 0;
    static auto reported = std::chrono::steady_clock::now();
    if (covering != nullptr) (fenced ? totalFenced : totalUnfenced) += 1;
    ++frames;
    const auto now = std::chrono::steady_clock::now();
    if (now - reported > std::chrono::seconds(2)) {
      reported = now;
      wlr_log(WLR_INFO,
              "scanout probe: %" PRIu64 " frame(s), covering client fenced on "
              "%" PRIu64 ", unfenced on %" PRIu64 ", composite %s",
              frames, totalFenced, totalUnfenced,
              compositeLocked ? "forced" : "not forced");
      frames = totalFenced = totalUnfenced = 0;
    }
  }
}

void Output::on_frame(wl_listener *listener, void *) {
  auto *output = owner_of<Output>(listener);
  // Renderer-owned motion — an eased scroll, a hover tint fading in — steps
  // here, before the composite, so that its clock is the display's and the
  // buffer it produces goes out in *this* commit rather than waiting for the
  // next one. See `SurfaceRegistry::animate` for why not a timer.
  const bool animating = output->server->surfaces != nullptr &&
                         output->server->surfaces->stepAnimations();
  if (output->server->surfaces != nullptr) {
    output->server->surfaces->refreshBackdropBlurs();
  }
  output->syncScanoutLock();
  // Composite is surface 0 in the probe: it is the desktop's own frame rather
  // than any one client's, and it is where a wait that was moved rather than
  // removed would end up — the scene waits for a client's acquire fence here,
  // on this thread, if the renderer cannot hand the wait to the GPU.
  const int64_t started = lava::FrameProbe::on() ? lava::FrameProbe::now() : 0;
  wlr_scene_output_commit(output->scene_output, nullptr);
  lava::StartupWatchdog::dismiss();
  lava::FrameProbe::record(0, lava::FrameProbe::Stage::Render, started);
  lava::FrameProbe::frame(0);
  lava::FrameProbe::report();
  // Same cadence as the frame probe and the same deal: off unless asked for.
  if (output->server->surfaces != nullptr) {
    output->server->surfaces->reportVramIfDue();
  }
  timespec now{};
  clock_gettime(CLOCK_MONOTONIC, &now);
  wlr_scene_output_send_frame_done(output->scene_output, &now);
  // Nothing else will ask: the scene is composited and, as far as wlroots is
  // concerned, settled. An animation that is still running has to keep the
  // output awake itself or it stops one frame in.
  if (animating) wlr_output_schedule_frame(output->wlr);
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
    output->server->surfaces->refreshFromLayout();
  }
}

void Output::on_destroy(wl_listener *listener, void *) {
  auto *output = owner_of<Output>(listener);
  Server *server = output->server;
  // Drop it from the layout before we ask how big the layout is, or
  // the dying output still inflates the box and the panel never shrinks.
  if (server->output_layout != nullptr && output->wlr != nullptr) {
    wlr_output_layout_remove(server->output_layout, output->wlr);
  }
  delete output;
  if (server->surfaces != nullptr) server->surfaces->refreshFromLayout();
}

void Output::on_commit(wl_listener *listener, void *data) {
  auto *output = owner_of<Output>(listener);
  auto *event = static_cast<wlr_output_event_commit *>(data);
  if (event->state == nullptr) return;
  if ((event->state->committed & WLR_OUTPUT_STATE_BUFFER) == 0) return;
  if (event->state->buffer == nullptr) return;

  Server *server = output->server;
  const bool printScreen = output->pendingScreenshot;
  const bool portal = server->screenshotPortal &&
                      server->screenshotPortal->hasPending();
  if (!printScreen && !portal) return;
  output->pendingScreenshot = false;

  // Two consumers, two destinations. Print Screen owns the seat selection.
  // The portal writes a file:// for the caller (Flameshot crops that and
  // copies the crop itself). Sharing the flag used to run both: the full
  // frame landed on the clipboard with `wl_display_next_serial`, and
  // Flameshot's later `set_selection` lost the serial race.
  if (printScreen) server->finishScreenshot(event->state->buffer);
  if (portal) {
    std::vector<uint8_t> png;
    uint32_t width = 0, height = 0;
    if (encodeBufferPng(event->state->buffer, server->renderer, png, width,
                        height) &&
        !png.empty()) {
      server->screenshotPortal->finish(png, width, height);
    } else {
      server->screenshotPortal->fail();
    }
  }
}

Output *Server::outputForScreenshot() {
  // The output the pointer is on, which is the screen the user is looking
  // at. A gap between monitors, or a headless run with no outputs yet,
  // falls through to the first enabled one.
  if (cursor != nullptr && output_layout != nullptr) {
    wlr_output *under =
        wlr_output_layout_output_at(output_layout, cursor->x, cursor->y);
    if (under != nullptr) {
      for (Output *output : outputs) {
        if (output->wlr == under && output->wlr->enabled) return output;
      }
    }
  }
  for (Output *output : outputs) {
    if (output->wlr->enabled) return output;
  }
  return nullptr;
}

void Server::requestScreenshot() {
  Output *target = outputForScreenshot();
  if (target == nullptr) {
    wlr_log(WLR_ERROR, "screenshot: no output to capture");
    return;
  }

  if (captureOutputNow(target)) return;

  // The offscreen path could not read the pixels — usually a renderer
  // that refuses its own textures. Wait for the next presented buffer
  // instead, which is the same picture and sometimes a different
  // allocation that *will* read back.
  target->pendingScreenshot = true;
  wlr_damage_ring_add_whole(&target->scene_output->damage_ring);
  wlr_output_schedule_frame(target->wlr);
}

Output *Server::outputAtPoint(int x, int y) {
  if (output_layout == nullptr) return nullptr;
  for (Output *output : outputs) {
    if (!output->wlr->enabled) continue;
    wlr_box box{};
    wlr_output_layout_get_box(output_layout, output->wlr, &box);
    if (wlr_box_contains_point(&box, x, y)) return output;
  }
  return nullptr;
}

void Server::requestWindowScreenshot(const ClientSurface &surface) {
  // The frame, not the content: the title bar is part of the window as far
  // as anyone looking at the screen is concerned. The shadow is not — it is
  // painted outside this rectangle and belongs to the desktop behind.
  const int fx = surface.x;
  const int fy = surface.y;
  const int fw = static_cast<int>(surface.width);
  const int fh = surface.frameHeight();
  if (fw <= 0 || fh <= 0) return;

  Output *target = outputAtPoint(fx + fw / 2, fy + fh / 2);
  if (target == nullptr) target = outputForScreenshot();
  if (target == nullptr) {
    wlr_log(WLR_ERROR, "screenshot: no output to capture");
    return;
  }

  wlr_box outputBox{};
  wlr_output_layout_get_box(output_layout, target->wlr, &outputBox);
  // Layout space is logical pixels; the buffer is physical ones. Rotation
  // is not handled — a window shot on a rotated screen would need the crop
  // turned with it, and nothing here has ever run on one.
  const float scale = target->wlr->scale > 0 ? target->wlr->scale : 1.f;
  wlr_box crop{};
  crop.x = static_cast<int>((fx - outputBox.x) * scale);
  crop.y = static_cast<int>((fy - outputBox.y) * scale);
  crop.width = static_cast<int>(fw * scale);
  crop.height = static_cast<int>(fh * scale);

  if (captureOutputNow(target, &crop)) return;
  // No deferred path for this one. `pendingScreenshot` copies whatever the
  // next committed frame holds, and it has nowhere to carry a crop — a
  // whole screen where a window was asked for is the wrong answer, and
  // silently the wrong answer.
  wlr_log(WLR_ERROR, "screenshot: could not read the frame to crop");
}

bool Server::renderOutputPng(Output *output, std::vector<uint8_t> &png,
                             uint32_t &width, uint32_t &height,
                             const wlr_box *crop) {
  const int w = output->wlr->width;
  const int h = output->wlr->height;
  if (w <= 0 || h <= 0 || allocator == nullptr) return false;

  // Same format the output already presents. A format the allocator
  // cannot create, or the renderer cannot draw to, fails
  // `wlr_swapchain_create` / `build_state` and we fall back.
  const wlr_drm_format *fmt = nullptr;
  if (output->wlr->swapchain != nullptr) {
    fmt = &output->wlr->swapchain->format;
  } else {
    const wlr_drm_format_set *formats = wlr_output_get_primary_formats(
        output->wlr, allocator->buffer_caps);
    if (formats != nullptr) {
      fmt = wlr_drm_format_set_get(formats, DRM_FORMAT_XRGB8888);
      if (fmt == nullptr) {
        fmt = wlr_drm_format_set_get(formats, DRM_FORMAT_ARGB8888);
      }
      if (fmt == nullptr && formats->len > 0) fmt = &formats->formats[0];
    }
  }
  if (fmt == nullptr) return false;

  wlr_swapchain *chain = wlr_swapchain_create(allocator, w, h, fmt);
  if (chain == nullptr) return false;

  wlr_output_state state;
  wlr_output_state_init(&state);
  wlr_scene_output_state_options opts{};
  opts.swapchain = chain;
  const bool built =
      wlr_scene_output_build_state(output->scene_output, &state, &opts);

  bool ok = false;
  if (built && state.buffer != nullptr) {
    ok = encodeBufferPng(state.buffer, renderer, png, width, height, crop);
  }
  wlr_output_state_finish(&state);
  wlr_swapchain_destroy(chain);
  // `build_state` rotates the damage ring against our capture buffers.
  // The next real frame must not think those were the last presented
  // ones, or it would skip redrawing everything that did not change.
  wlr_damage_ring_add_whole(&output->scene_output->damage_ring);
  return ok && !png.empty();
}

bool Server::captureOutputNow(Output *output, const wlr_box *crop) {
  std::vector<uint8_t> png;
  uint32_t width = 0, height = 0;
  if (!renderOutputPng(output, png, width, height, crop)) return false;
  lava::Clipboard clipboard(display, seat);
  clipboard.setImagePng(png);
  wlr_log(WLR_INFO, "screenshot: %ux%u PNG (%zu bytes) copied to the clipboard",
          width, height, png.size());
  return true;
}

bool Server::schedulePortalCapture() {
  Output *target = outputForScreenshot();
  if (target == nullptr) return false;
  // Damage + a frame only. `on_commit` notices the portal via
  // `hasPending()`; do not raise `pendingScreenshot` or the full frame
  // is also published as the seat selection.
  wlr_damage_ring_add_whole(&target->scene_output->damage_ring);
  wlr_output_schedule_frame(target->wlr);
  return true;
}

bool Server::finishScreenshot(wlr_buffer *buffer) {
  std::vector<uint8_t> png;
  uint32_t width = 0, height = 0;
  if (!encodeBufferPng(buffer, renderer, png, width, height) || png.empty()) {
    wlr_log(WLR_ERROR, "screenshot: could not read the output buffer");
    return false;
  }
  lava::Clipboard clipboard(display, seat);
  clipboard.setImagePng(png);
  wlr_log(WLR_INFO, "screenshot: %ux%u PNG (%zu bytes) copied to the clipboard",
          width, height, png.size());
  return true;
}

// ─── Popups ────────────────────────────────────────────────────────────────
//
// Menus, dropdowns, tooltips, the whole of a browser's right-click. An
// `xdg_popup` is a surface with a *parent* and a positioner describing where
// it wants to sit relative to it, and until this existed the compositor
// ignored the signal entirely: nothing was ever put in the scene, so no
// application under it had a context menu at all. Not a broken menu — no menu.
//
// Almost all of the work is wlroots': `wlr_scene_xdg_surface_create` builds
// the subtree and keeps it positioned against the parent, which is why the
// parent's scene tree is stashed on `xdg_surface::data` when a toplevel is
// created. Two things are ours:
//
//   * the first configure, without which the popup never maps. wlroots
//     signals `initial_commit` and expects a `schedule_configure` back;
//   * unconstraining. A positioner is written in the client's coordinates and
//     assumes infinite room, so a menu opened near the bottom of the screen
//     runs off it unless the compositor says how much room there really is —
//     which only the compositor knows, since it owns the work area and the
//     window's position within it.
struct Popup {
  wlr_xdg_popup *wlr = nullptr;
  Server *server = nullptr;
  Listener<Popup> commit;
  Listener<Popup> destroy;

  Popup(Server *server, wlr_xdg_popup *popup) : wlr(popup), server(server) {
    commit.attach(&popup->base->surface->events.commit, this, on_commit);
    destroy.attach(&popup->events.destroy, this, on_destroy);
  }
  ~Popup() {
    commit.detach();
    destroy.detach();
  }

  static void on_commit(wl_listener *listener, void *);
  static void on_destroy(wl_listener *listener, void *) {
    delete owner_of<Popup>(listener);
  }
};

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
  //
  // As a `FramedWindow`, not as a `Toplevel`: an X11 window stores the same
  // pointer, and the reader has no way to tell the two apart afterwards. The
  // cast is what makes both ends agree on one type.
  scene_tree->node.data = static_cast<FramedWindow *>(this);
  toplevel->base->data = scene_tree;

  // Map/unmap belong to the surface, not the xdg role — they moved there when
  // wlroots unified the lifecycle across shells.
  wlr_surface *surface = toplevel->base->surface;
  map.attach(&surface->events.map, this, on_map);
  unmap.attach(&surface->events.unmap, this, on_unmap);
  commit.attach(&surface->events.commit, this, on_commit);
  destroy.attach(&toplevel->events.destroy, this, on_destroy);
  set_title.attach(&toplevel->events.set_title, this, on_set_title);
  set_app_id.attach(&toplevel->events.set_app_id, this, on_set_app_id);
  set_parent.attach(&toplevel->events.set_parent, this, on_set_parent);
  request_maximize.attach(&toplevel->events.request_maximize, this,
                          on_request_maximize);
  request_fullscreen.attach(&toplevel->events.request_fullscreen, this,
                            on_request_fullscreen);
  request_minimize.attach(&toplevel->events.request_minimize, this,
                          on_request_minimize);
  // How a client that draws its own title bar gets moved. There is no protocol
  // for advertising *where* the draggable part of a window is, and there does
  // not need to be: the client knows where its own header is, sees the press
  // land on it, and asks to be moved. GTK does exactly this, which is why its
  // windows drag under every other compositor and sat still under this one.
  request_move.attach(&toplevel->events.request_move, this, on_request_move);
  request_resize.attach(&toplevel->events.request_resize, this,
                        on_request_resize);
}

Toplevel::~Toplevel() {
  map.detach();
  unmap.detach();
  commit.detach();
  destroy.detach();
  set_title.detach();
  set_app_id.detach();
  set_parent.detach();
  request_maximize.detach();
  request_fullscreen.detach();
  request_minimize.detach();
  request_move.detach();
  request_resize.detach();
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
    const bool transient = toplevel->xdg_toplevel->parent != nullptr;
    const uint32_t parentId =
        xdgParentFrameId(toplevel->xdg_toplevel->parent);
    const uint32_t id = server->surfaces->adoptWindow(
        toplevel, title ? title : "", width, height, app_id ? app_id : "",
        server->serverDecorated(toplevel->xdg_toplevel), transient, parentId);
    if (ClientSurface *frame = server->surfaces->find(id)) {
      server->surfaces->raise(*frame);
      server->surfaces->setFocused(id);
      if (toplevel->xdg_toplevel->requested.fullscreen) {
        server->surfaces->setFullscreen(*frame, true);
      }
    }
  }
  server->focus(toplevel);
  // A Wayland window takes the keyboard through the seat, so no client
  // surface may be holding it as well.
  server->setFocusedSurface(0);
  // After focus: minimizing first would hand the keyboard back to a
  // window that just hid.
  if (toplevel->xdg_toplevel->requested.minimized &&
      toplevel->frameId != 0 && server->surfaces != nullptr) {
    if (ClientSurface *frame = server->surfaces->find(toplevel->frameId)) {
      server->minimizeSurface(*frame);
    }
  }

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
    // Advertise the states this compositor actually implements, or a
    // well-behaved client will not offer fullscreen in its own menu.
    // Only clients that bound xdg-shell v5 understand the event.
    if (wl_resource_get_version(toplevel->xdg_toplevel->resource) >=
        XDG_TOPLEVEL_WM_CAPABILITIES_SINCE_VERSION) {
      wlr_xdg_toplevel_set_wm_capabilities(
          toplevel->xdg_toplevel,
          WLR_XDG_TOPLEVEL_WM_CAPABILITIES_MAXIMIZE |
              WLR_XDG_TOPLEVEL_WM_CAPABILITIES_FULLSCREEN |
              WLR_XDG_TOPLEVEL_WM_CAPABILITIES_MINIMIZE);
    }
    uint32_t width = 0, height = 0;
    const bool fullscreen = toplevel->xdg_toplevel->requested.fullscreen;
    bool maximized = false;
    if (fullscreen && toplevel->server->surfaces != nullptr) {
      toplevel->server->surfaces->outputSize(width, height);
    } else if (toplevel->server->surfaces != nullptr) {
      const char *app_id = toplevel->xdg_toplevel->app_id;
      const bool transient = toplevel->xdg_toplevel->parent != nullptr;
      toplevel->server->surfaces->hintToplevelConfigure(
          app_id ? app_id : "", width, height, maximized, transient);
    }
    wlr_xdg_toplevel_set_size(toplevel->xdg_toplevel,
                              static_cast<int32_t>(width),
                              static_cast<int32_t>(height));
    if (fullscreen) {
      wlr_xdg_toplevel_set_fullscreen(toplevel->xdg_toplevel, true);
    } else if (maximized) {
      wlr_xdg_toplevel_set_maximized(toplevel->xdg_toplevel, true);
    }
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

void Toplevel::on_set_app_id(wl_listener *listener, void *) {
  auto *toplevel = owner_of<Toplevel>(listener);
  if (toplevel->frameId == 0 || toplevel->server->surfaces == nullptr) return;
  if (ClientSurface *frame =
          toplevel->server->surfaces->find(toplevel->frameId)) {
    const char *app_id = toplevel->xdg_toplevel->app_id;
    // Late: some toolkits name themselves after the first commit. The
    // window is already placed; this only corrects the identity the
    // next close will remember under.
    frame->appId = app_id ? app_id : "";
    toplevel->server->surfaces->announceWindows();
  }
}

void Toplevel::on_set_parent(wl_listener *listener, void *) {
  auto *toplevel = owner_of<Toplevel>(listener);
  wlr_xdg_toplevel *parent = toplevel->xdg_toplevel->parent;
  // Before map we have no frame yet. The first configure and
  // `adoptWindow` both re-read `parent`, so marking here is only
  // needed once the window is already placed — otherwise a late
  // set_parent would let the dialog overwrite the parent's slot.
  if (toplevel->frameId == 0 || toplevel->server->surfaces == nullptr) {
    // Already configured at the saved size before the parent arrived:
    // take the hint back so the client can pick a dialog-sized buffer.
    // `initialized` is the whole question — it is what says a configure
    // has gone out. `initial_commit` is true only for the length of the
    // first commit, and this is not that.
    if (parent != nullptr && toplevel->xdg_toplevel->base->initialized) {
      wlr_xdg_toplevel_set_size(toplevel->xdg_toplevel, 0, 0);
      wlr_xdg_toplevel_set_maximized(toplevel->xdg_toplevel, false);
    }
    return;
  }
  // A parent can be taken away as well as given: `set_parent(nil)` makes
  // this an ordinary window of its application again.
  if (ClientSurface *frame =
          toplevel->server->surfaces->find(toplevel->frameId)) {
    toplevel->server->surfaces->setTransient(*frame, parent != nullptr,
                                             xdgParentFrameId(parent));
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
      toplevel->server->surfaces->setMaximized(*frame, !frame->maximized);
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
  auto *toplevel = owner_of<Toplevel>(listener);
  const bool want = toplevel->xdg_toplevel->requested.fullscreen;
  // Before the first commit the surface cannot be configured. wlroots
  // keeps `requested.fullscreen` and initial_commit / map apply it.
  // `set_fullscreen` would schedule a configure and assert.
  if (!toplevel->xdg_toplevel->base->initialized) return;
  if (toplevel->frameId != 0 && toplevel->server->surfaces != nullptr) {
    if (ClientSurface *frame =
            toplevel->server->surfaces->find(toplevel->frameId)) {
      toplevel->server->surfaces->setFullscreen(*frame, want);
    }
  } else {
    wlr_xdg_toplevel_set_fullscreen(toplevel->xdg_toplevel, want);
  }
  // The protocol requires a configure in reply whether or not anything
  // changed. `set_fullscreen` schedules one; this covers the no-op path.
  wlr_xdg_surface_schedule_configure(toplevel->xdg_toplevel->base);
}

/// xdg_toplevel.set_minimized. No configure is owed — the protocol has
/// no minimized state for the client to ack — so this is just "hide it".
void Toplevel::on_request_minimize(wl_listener *listener, void *) {
  auto *toplevel = owner_of<Toplevel>(listener);
  if (toplevel->frameId == 0 || toplevel->server->surfaces == nullptr) return;
  if (ClientSurface *frame =
          toplevel->server->surfaces->find(toplevel->frameId)) {
    toplevel->server->minimizeSurface(*frame);
  }
}

/// "The user is dragging my title bar; please move me."
///
/// The serial is checked because this request is a client asking to take the
/// pointer, and one that has not just been given a press has no business
/// asking. Without the check a background window could glue itself to the
/// cursor at any moment.
void Toplevel::on_request_move(wl_listener *listener, void *data) {
  auto *toplevel = owner_of<Toplevel>(listener);
  auto *event = static_cast<wlr_xdg_toplevel_move_event *>(data);
  Server *server = toplevel->server;
  if (server->surfaces == nullptr || toplevel->frameId == 0) return;
  if (!wlr_seat_validate_pointer_grab_serial(
          server->seat, toplevel->xdg_toplevel->base->surface, event->serial)) {
    return;
  }
  if (ClientSurface *frame = server->surfaces->find(toplevel->frameId)) {
    // Maximized: wait for a real drag. A click on the tab strip is a
    // move request and must not restore the window by itself.
    if (frame->maximized || frame->fullscreen) {
      server->armInteractiveMove(*frame, true);
    } else {
      server->beginInteractiveMove(*frame, true);
    }
  }
}

/// The same, for the resize handles a client-drawn frame has around its edge.
void Toplevel::on_request_resize(wl_listener *listener, void *data) {
  auto *toplevel = owner_of<Toplevel>(listener);
  auto *event = static_cast<wlr_xdg_toplevel_resize_event *>(data);
  Server *server = toplevel->server;
  if (server->surfaces == nullptr || toplevel->frameId == 0) return;
  if (!wlr_seat_validate_pointer_grab_serial(
          server->seat, toplevel->xdg_toplevel->base->surface, event->serial)) {
    return;
  }
  if (ClientSurface *frame = server->surfaces->find(toplevel->frameId)) {
    server->beginInteractiveResize(*frame, fromWlrEdges(event->edges), true);
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
    const xkb_layout_index_t groups = xkb_keymap_num_layouts(keymap);
    if (groups < 2 && config.options.find("grp:") != std::string::npos) {
      wlr_log(WLR_ERROR,
              "keyboard: %s is set but the keymap has only %u layout(s) — "
              "use a comma-separated list such as us,ru",
              config.options.c_str(), groups);
    }
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
    case XKB_KEY_Tab:
    case XKB_KEY_ISO_Left_Tab: return 258;
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
  // Modifiers: the app switcher commits on Control/Alt/Super release, and
  // without these the release arrives as key 0.
  switch (sym) {
    case XKB_KEY_Shift_L: return 340;
    case XKB_KEY_Control_L: return 341;
    case XKB_KEY_Alt_L:
    case XKB_KEY_Meta_L: return 342;
    case XKB_KEY_Super_L: return 343;
    case XKB_KEY_Shift_R: return 344;
    case XKB_KEY_Control_R: return 345;
    case XKB_KEY_Alt_R:
    case XKB_KEY_Meta_R: return 346;
    case XKB_KEY_Super_R: return 347;
    default: break;
  }
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

/// Starts a program without blocking the Wayland event loop.
///
/// The child inherits WAYLAND_DISPLAY and DISPLAY from the compositor. The
/// former lets native clients connect directly; the latter lets X11 clients
/// start Xwayland lazily. Programs launched from either inherit the same
/// environment and therefore open here rather than in a session outside it.
void launch_program(const char *program, char *const argv[],
                    char *const envp[] = environ) {
  pid_t pid = -1;
  // Home cwd so terminals and apps do not open in the canvas assets tree
  // the compositor itself chdirs into for shader loads (see spawnAtHome).
  const int error =
      lava::ShellSupervisor::spawnAtHome(&pid, program, argv, envp);
  if (error != 0) {
    wlr_log(WLR_ERROR, "launcher: could not start %s: %s", program,
            std::strerror(error));
    return;
  }

  wlr_log(WLR_INFO, "launcher: started %s (pid %d)", program,
          static_cast<int>(pid));
  // A launcher may stay open for an arbitrary time. Waiting on a detached
  // thread keeps zombies out without ever parking the compositor's loop.
  std::thread([pid] {
    int status = 0;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
  }).detach();
}

/// Runs the user's autostart script, if they have written one.
///
/// `/bin/sh` rather than the file's own shebang, executable bit or not: this
/// is documented as a shell script and reading it as one means a user who
/// forgot `chmod +x` gets their applets rather than a silent nothing.
///
/// Fire and forget. `ShellSupervisor` watches the panel and the dock because
/// a desktop without them is broken; nothing here is that, and an applet that
/// exits was either told to or is not installed, neither of which is improved
/// by starting it again every ten seconds.
void run_autostart() {
  const std::string path = lava::Config::autostartPath();
  if (::access(path.c_str(), R_OK) != 0) {
    wlr_log(WLR_INFO, "autostart: nothing at '%s'", path.c_str());
    return;
  }
  std::string shell = "/bin/sh";
  std::string script = path;
  char *argv[] = {shell.data(), script.data(), nullptr};
  wlr_log(WLR_INFO, "autostart: running '%s'", path.c_str());
  launch_program(shell.c_str(), argv);
}

void launch_rofi() {
  char program[] = "rofi";
  char show[] = "-show";
  char mode[] = "drun";
  char *argv[] = {program, show, mode, nullptr};

  // Native rofi-wayland requires zwlr_layer_shell_v1, which this compositor
  // does not advertise yet. Keep DISPLAY so Rofi uses our lazy Xwayland, but
  // hide WAYLAND_DISPLAY so it cannot select the unsupported native path.
  std::vector<char *> x11Environment;
  for (char **entry = environ; *entry != nullptr; ++entry) {
    if (std::strncmp(*entry, "WAYLAND_DISPLAY=", 16) != 0) {
      x11Environment.push_back(*entry);
    }
  }
  x11Environment.push_back(nullptr);
  launch_program(program, argv, x11Environment.data());
}

/// Flameshot's interactive capture. The compositor answers the screenshot
/// portal it talks to — see `ScreenshotPortal`.
void launch_flameshot() {
  char program[] = "flameshot";
  char gui[] = "gui";
  char *argv[] = {program, gui, nullptr};
  launch_program(program, argv);
}

/// The application launcher, which is a LavaUI client rather than a program on
/// PATH — so it is found the way the panel and the dock are.
void launch_launcher() {
  const std::string path = lava::ShellSupervisor::programPath("LavaLauncher");
  std::string program = path;
  char *argv[] = {program.data(), nullptr};
  launch_program(program.c_str(), argv);
}

/// The 3D app switcher. Spawned per invocation like the launcher: a LavaUI
/// client is on screen in ~200 ms, and holding one resident for the time
/// nobody is switching would be an arena and a surface for nothing.
///
/// `backwards` is the first chord being Shift+Tab — the overlay then lands
/// on the last window rather than the next one.
void launch_switcher(bool backwards) {
  if (g_switcherPid > 0) return;
  const std::string path = lava::ShellSupervisor::programPath("LavaSwitcher");
  std::string program = path;
  char back[] = "--back";
  char *argvForward[] = {program.data(), nullptr};
  char *argvBack[] = {program.data(), back, nullptr};
  char **argv = backwards ? argvBack : argvForward;

  pid_t pid = -1;
  const int error =
      lava::ShellSupervisor::spawnAtHome(&pid, program.c_str(), argv, environ);
  if (error != 0) {
    wlr_log(WLR_ERROR, "switcher: could not start %s: %s", program.c_str(),
            std::strerror(error));
    return;
  }
  g_switcherPid = pid;
  wlr_log(WLR_INFO, "switcher: started %s (pid %d)%s", program.c_str(),
          static_cast<int>(pid), backwards ? " --back" : "");
  std::thread([pid] {
    int status = 0;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {
    }
    pid_t expected = pid;
    g_switcherPid.compare_exchange_strong(expected, -1);
  }).detach();
}

bool switcherHasKeyboard(Server *server) {
  if (server->surfaces == nullptr) return false;
  ClientSurface *surface = server->surfaces->find(server->focusedSurface());
  return surface != nullptr && surface->appId == kSwitcherAppId;
}

/// LavaTerm — the desktop's own terminal. Found the same way the panel is, so
/// a tree build and an installed package both work without a PATH entry.
void launch_terminal() {
  const std::string path = lava::ShellSupervisor::programPath("LavaTerm");
  std::string program = path;
  char *argv[] = {program.data(), nullptr};
  launch_program(program.c_str(), argv);
}

std::string normalize_mod_key(const std::string &value) {
  std::string lower = value;
  for (char &c : lower)
    c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
  if (lower == "super" || lower == "logo" || lower == "win" ||
      lower == "meta" || lower == "mod4") {
    return "super";
  }
  return "alt";
}

uint32_t shortcut_mod_mask(const lava::KeyboardConfig &keyboard) {
  return keyboard.modKey == "super" ? WLR_MODIFIER_LOGO : WLR_MODIFIER_ALT;
}

/// What a binding does.
enum class BindingAction : uint8_t {
  Quit,
  Launcher,
  AppLauncher,
  AppSwitcher,
  AppSwitcherBack,
  Terminal,
  Close,
  Minimize,
  RestoreLast,
  ToggleMaximize,
  ShowDesktop,
  Flameshot,
  Fullscreen,
  WorkspaceSwitch,
  WorkspaceMove,
  SwitchVt,
  Screenshot,
};

/// One shortcut: which keys reach it, and what to call it.
///
/// The primary modifier (Alt or Super, from config) is implicit when
/// `needMod` is set — and `shift`/`ctrl` are matched exactly. Exactly,
/// because these are distinct bindings and not a loose prefix: Mod+Shift+1
/// sends a window where Mod+1 follows it, and Mod+Shift+Return is
/// deliberately nothing rather than a sloppy second spelling of "open a
/// terminal".
///
/// `needMod` is false for chords that must work without the desktop mod.
/// Alt+Tab is the case: the switcher is the Windows chord even when the
/// desktop key is Super, and requiring Mod as well would make it Super+Alt+Tab.
struct BindingSpec {
  BindingAction action;
  /// The keysym range this covers, inclusive; `last == first` for one key.
  xkb_keysym_t first;
  xkb_keysym_t last;
  bool shift;
  bool ctrl;
  bool needMod;
  /// Shown, never parsed — the key as a person would write it.
  const char *key;
  /// Stable id for a settings app to key off, in case the wording changes.
  const char *id;
  const char *description;
  /// Literal Alt, not the desktop mod. Trailing so the table rows that
  /// do not care can omit it.
  bool alt = false;
};

/// The compositor's shortcuts, as one table.
///
/// One table rather than a chain of ifs, because this list is now something
/// the desktop *shows*: `ListKeyBindings` hands it to a settings app, and a
/// list maintained separately from the code that dispatches would be wrong
/// within one release. Both come from here, so a listed binding is one that
/// works and a working binding is one that is listed.
constexpr BindingSpec kBindings[] = {
    // Shift and a key nothing else in the table uses: Mod+Escape sat one
    // slipped finger from ending the session, next to the Escape every
    // dialog wants and under the same hand as the desktop mod.
    {BindingAction::Quit, XKB_KEY_BackSpace, XKB_KEY_BackSpace, true, false,
     true, "Backspace", "session.quit", "Ends the session"},
    {BindingAction::Launcher, XKB_KEY_space, XKB_KEY_space, false, false, true,
     "Space", "launcher.rofi", "Opens rofi"},
    {BindingAction::AppLauncher, XKB_KEY_p, XKB_KEY_p, false, false, true, "P",
     "launcher.open", "Opens the application launcher"},
    {BindingAction::AppSwitcher, XKB_KEY_Tab, XKB_KEY_Tab, false, true, false,
     "Tab", "window.switch", "Cycles open windows"},
    {BindingAction::AppSwitcherBack, XKB_KEY_Tab, XKB_KEY_Tab, true, true, false,
     "Tab", "window.switch-back", "Cycles open windows backwards"},
    {BindingAction::AppSwitcher, XKB_KEY_Tab, XKB_KEY_Tab, false, false, false,
     "Tab", "window.switch-alt", "Cycles open windows", true},
    {BindingAction::AppSwitcherBack, XKB_KEY_Tab, XKB_KEY_Tab, true, false, false,
     "Tab", "window.switch-alt-back", "Cycles open windows backwards", true},
    {BindingAction::Terminal, XKB_KEY_Return, XKB_KEY_Return, false, false, true,
     "Return", "terminal.open", "Opens LavaTerm"},
    {BindingAction::Close, XKB_KEY_q, XKB_KEY_q, false, false, true, "Q",
     "window.close", "Closes the focused window"},
    {BindingAction::ToggleMaximize, XKB_KEY_m, XKB_KEY_m, false, false, true, "M",
     "window.maximize", "Maximizes or restores the focused window"},
    {BindingAction::RestoreLast, XKB_KEY_m, XKB_KEY_m, true, false, true, "M",
     "window.restore", "Brings back the window hidden last"},
    {BindingAction::ShowDesktop, XKB_KEY_d, XKB_KEY_d, false, false, true, "D",
     "window.desktop", "Hides every window, or brings them back"},
    {BindingAction::Flameshot, XKB_KEY_s, XKB_KEY_s, true, false, true, "S",
     "screen.flameshot", "Opens Flameshot to capture a region"},
    {BindingAction::Fullscreen, XKB_KEY_f, XKB_KEY_f, false, false, true, "F",
     "window.fullscreen", "Toggles fullscreen on the focused window"},
    {BindingAction::WorkspaceSwitch, XKB_KEY_1, XKB_KEY_9, false, false, true,
     "1 … 9", "workspace.switch", "Shows that workspace"},
    {BindingAction::WorkspaceMove, XKB_KEY_1, XKB_KEY_9, true, false, true,
     "1 … 9", "workspace.move", "Sends the focused window to that workspace"},
    {BindingAction::SwitchVt, XKB_KEY_F1, XKB_KEY_F10, false, true, true,
     "F1 … F10", "session.vt", "Switches to that virtual terminal"},
    {BindingAction::Screenshot, XKB_KEY_Print, XKB_KEY_Print, false, false,
     false, "Print", "screen.capture",
     "Copies a screenshot of the screen to the clipboard"},
    {BindingAction::Screenshot, XKB_KEY_Print, XKB_KEY_Print, false, false,
     false, "Print", "screen.capture-window",
     "Copies the focused window to the clipboard", true},
};

/// The modifiers as a person reads them. The primary mod is whatever the
/// desktop is configured to use.
std::string binding_modifiers(const BindingSpec &spec, const char *modName) {
  std::string out;
  if (spec.needMod) out = modName != nullptr ? modName : "Alt";
  if (spec.alt) {
    if (!out.empty()) out += "+";
    out += "Alt";
  }
  if (spec.ctrl) {
    if (!out.empty()) out += "+";
    out += "Ctrl";
  }
  if (spec.shift) {
    if (!out.empty()) out += "+";
    out += "Shift";
  }
  return out.empty() ? "None" : out;
}

/// Every layout and variant this machine's xkb knows about.
///
/// From libxkbregistry rather than by reading `evdev.lst` ourselves, because
/// where those rules live is xkb's business: a machine that keeps them
/// somewhere else is a machine a hand-rolled parser silently finds nothing on,
/// and "no layouts" looks exactly like "no layouts installed".
///
/// Flattened on the way out — a variant is an entry with the same `code` and a
/// non-empty `variant` — so the wire stays a list and the picker groups it in
/// one pass. See `KeyboardLayout` in the IDL.
void collect_keyboard_layouts(
    std::vector<lava::CompositorHost::LayoutEntry> &out) {
  rxkb_context *registry = rxkb_context_new(RXKB_CONTEXT_NO_FLAGS);
  if (registry == nullptr) {
    wlr_log(WLR_ERROR, "keyboard: cannot open the xkb registry");
    return;
  }
  if (!rxkb_context_parse_default_ruleset(registry)) {
    wlr_log(WLR_ERROR, "keyboard: cannot read the xkb rules");
    rxkb_context_unref(registry);
    return;
  }

  for (rxkb_layout *layout = rxkb_layout_first(registry); layout != nullptr;
       layout = rxkb_layout_next(layout)) {
    lava::CompositorHost::LayoutEntry entry;
    const char *code = rxkb_layout_get_name(layout);
    if (code == nullptr) continue;
    entry.code = code;
    if (const char *variant = rxkb_layout_get_variant(layout)) {
      entry.variant = variant;
    }
    const char *description = rxkb_layout_get_description(layout);
    entry.description = description != nullptr ? description : entry.code;
    out.push_back(std::move(entry));
  }

  rxkb_context_unref(registry);
}

/// The window the title-bar buttons and Mod+M act on: decoration focus,
/// not the Lava keyboard target. A Wayland or X11 window has
/// `focusedSurface() == 0` and is still the one on screen.
ClientSurface *focusedWindow(Server *server) {
  if (server->surfaces == nullptr) return nullptr;
  ClientSurface *focused =
      server->surfaces->find(server->surfaces->focusedId());
  if (focused == nullptr || focused->panel) {
    if (FramedWindow *window =
            server->frontToplevel(server->workspaces.current)) {
      focused = server->surfaces->find(window->frameId);
    }
  }
  if (focused == nullptr || focused->panel) return nullptr;
  return focused;
}

void collect_key_bindings(std::vector<lava::CompositorHost::BindingEntry> &out,
                          const char *modName) {
  out.clear();
  out.reserve(std::size(kBindings));
  for (const BindingSpec &spec : kBindings) {
    lava::CompositorHost::BindingEntry entry;
    entry.modifiers = binding_modifiers(spec, modName);
    entry.key = spec.key;
    entry.action = spec.id;
    entry.description = spec.description;
    out.push_back(std::move(entry));
  }
}

/// Runs one binding. False means "not handled after all" — the key falls
/// through to the focused client, which is what a digit past the last
/// workspace should do.
bool perform_binding(Server *server, const BindingSpec &spec,
                     xkb_keysym_t sym) {
  switch (spec.action) {
  case BindingAction::Quit:
    // Worth having while this runs nested inside another compositor: without
    // it the only way out is killing the process from elsewhere, and a
    // compositor that has taken the keyboard is hard to leave.
    lava::arm_shutdown_watchdog();
    wl_display_terminate(server->display);
    return true;

  case BindingAction::Launcher:
    launch_rofi();
    return true;

  case BindingAction::AppLauncher:
    launch_launcher();
    return true;

  case BindingAction::AppSwitcher:
  case BindingAction::AppSwitcherBack:
    server->beginSwitcherSession(
        spec.ctrl ? static_cast<uint32_t>(WLR_MODIFIER_CTRL)
        : spec.alt ? static_cast<uint32_t>(WLR_MODIFIER_ALT)
                   : shortcut_mod_mask(server->config.keyboard));
    if (server->surfaces != nullptr) {
      if (ClientSurface *existing =
              server->surfaces->findByAppId(kSwitcherAppId)) {
        server->focusSurface(*existing);
        return true;
      }
    }
    launch_switcher(spec.action == BindingAction::AppSwitcherBack);
    return true;

  case BindingAction::Terminal:
    launch_terminal();
    return true;

  case BindingAction::Close:
    // Politely: Wayland windows get a close request (save dialogs still work);
    // Lava clients are torn down by their stream ending — see requestClose.
    // `focusedWindow`, not `focusedSurface`: a foreign window holds the
    // seat keyboard and leaves the Lava target at 0, which is why Mod+Q
    // used to do nothing to VS Code.
    if (ClientSurface *focused = focusedWindow(server)) {
      server->surfaces->requestClose(*focused);
    }
    return true;

  case BindingAction::Minimize: {
    if (ClientSurface *focused = focusedWindow(server)) {
      server->minimizeSurface(*focused);
    }
    return true;
  }

  case BindingAction::ToggleMaximize: {
    ClientSurface *focused = focusedWindow(server);
    if (focused == nullptr) return false;
    // Fullscreen already owns the output; drop it first so maximize is
    // a real rectangle change rather than a flag under a covering game.
    if (focused->fullscreen) {
      server->surfaces->setFullscreen(*focused, false);
    }
    server->surfaces->setMaximized(*focused, !focused->maximized);
    return true;
  }

  case BindingAction::ShowDesktop:
    server->toggleShowDesktop();
    return true;

  case BindingAction::Flameshot:
    launch_flameshot();
    return true;

  case BindingAction::RestoreLast:
    if (server->surfaces == nullptr) return false;
    if (ClientSurface *restored = server->surfaces->restoreLastMinimized()) {
      server->focusSurface(*restored);
      server->update_pointer_focus(0);
    }
    return true;

  case BindingAction::Fullscreen: {
    ClientSurface *focused = focusedWindow(server);
    if (focused == nullptr) return false;
    server->surfaces->setFullscreen(*focused, !focused->fullscreen);
    return true;
  }

  case BindingAction::WorkspaceSwitch:
  case BindingAction::WorkspaceMove: {
    const uint32_t index = static_cast<uint32_t>(sym - XKB_KEY_1);
    if (index >= Workspaces::kCount) return false;
    // Shift sends the window instead of following it, which is the
    // arrangement every tiling compositor has settled on.
    if (spec.action == BindingAction::WorkspaceMove) {
      server->moveFocusedToWorkspace(index);
    } else {
      server->switchWorkspace(index);
    }
    return true;
  }

  case BindingAction::SwitchVt: {
    const unsigned vt = static_cast<unsigned>(sym - XKB_KEY_F1) + 1;
    if (server->session == nullptr) {
      wlr_log(WLR_ERROR, "session: cannot switch to VT %u without a DRM session",
              vt);
    } else if (!wlr_session_change_vt(server->session, vt)) {
      wlr_log(WLR_ERROR, "session: failed to switch to VT %u", vt);
    } else {
      wlr_log(WLR_INFO, "session: switching to VT %u", vt);
    }
    return true;
  }

  case BindingAction::Screenshot:
    server->requestScreenshot();
    return true;
  }
  return false;
}

/// The compositor's own shortcuts, taken before any client sees the key.
///
/// True when the key was one of ours, which is the caller's signal to stop: a
/// bound key is not also text, and forwarding it would put a digit in whatever
/// the user was typing in every time they changed workspace.
bool handle_binding(Server *server, xkb_keysym_t sym, bool shift, bool ctrl,
                    bool modDown, bool altDown) {
  // The numeric keypad's Enter is the same intention as the main one, and
  // folding it here keeps the table one row per binding rather than one row
  // per spelling.
  if (sym == XKB_KEY_KP_Enter) sym = XKB_KEY_Return;
  if (sym == XKB_KEY_ISO_Left_Tab) sym = XKB_KEY_Tab;

  // Print Screen is the key, not a chord — handled here rather than from
  // the table because it has to fire whatever the desktop modifier is
  // doing, so a leftover Alt cannot swallow the shot. Some boards emit
  // Sys_Req for it when Alt is held (the historical SysRq spelling), which
  // is why the sym is not what decides between the two shots below.
  //
  // The table still carries both spellings; those rows exist to be listed
  // by `ListKeyBindings`, and this is where they are answered.
  if (sym == XKB_KEY_Print || sym == XKB_KEY_Sys_Req) {
    // Alt is the one modifier that means something: the focused window
    // instead of the screen. Nothing focused falls through to the whole
    // screen rather than doing nothing at all, which from the keyboard is
    // indistinguishable from a key that did not register.
    if (altDown) {
      if (ClientSurface *focused = focusedWindow(server)) {
        server->requestWindowScreenshot(*focused);
        return true;
      }
    }
    server->requestScreenshot();
    return true;
  }

  for (const BindingSpec &spec : kBindings) {
    if (sym < spec.first || sym > spec.last) continue;
    if (spec.shift != shift || spec.ctrl != ctrl) continue;
    if (spec.alt) {
      // Literal Alt, even when the desktop mod is Super. Do not also
      // demand `needMod`: if the desktop mod *is* Alt, Alt+Tab would
      // have `modDown` and a `needMod == false` row would never fire.
      if (!altDown) continue;
    } else if (spec.needMod != modDown) {
      continue;
    }
    // Subsequent Tab while the overlay is up belongs to the overlay — it
    // is how the user cycles. Eating it here would launch a second process
    // and the first would never see the key.
    if ((spec.action == BindingAction::AppSwitcher ||
         spec.action == BindingAction::AppSwitcherBack) &&
        switcherHasKeyboard(server)) {
      return false;
    }
    return perform_binding(server, spec, sym);
  }
  return false;
}

/// Modifier keys themselves do not repeat — holding Shift should not flood
/// the client with Shift presses. Everything else (letters, Backspace, arrows)
/// does, which is what makes held-delete and held-move work.
bool is_modifier_key(int glfwKey) {
  switch (glfwKey) {
  case 340:  // Left Shift
  case 341:  // Left Control
  case 342:  // Left Alt
  case 343:  // Left Super
  case 344:  // Right Shift
  case 345:  // Right Control
  case 346:  // Right Alt
  case 347:  // Right Super
  case 348:  // Menu
    return true;
  default:
    return false;
  }
}

void Server::stopKeyRepeat() {
  if (keyRepeatTimer != nullptr) {
    wl_event_source_timer_update(keyRepeatTimer, 0);
  }
  keyRepeatSurface = 0;
  keyRepeatKey = 0;
  keyRepeatMods = 0;
  keyRepeatText.clear();
}

void Server::startKeyRepeat(uint32_t surfaceId, int glfwKey, int32_t mods,
                            std::string text) {
  if (is_modifier_key(glfwKey)) {
    stopKeyRepeat();
    return;
  }
  const int32_t rate = config.keyboard.repeatRate;
  const int32_t delay = config.keyboard.repeatDelay;
  // rate 0 means "do not repeat", which is a legitimate accessibility choice.
  if (rate <= 0 || delay <= 0) {
    stopKeyRepeat();
    return;
  }

  keyRepeatSurface = surfaceId;
  keyRepeatKey = glfwKey;
  keyRepeatMods = mods;
  keyRepeatText = std::move(text);

  if (keyRepeatTimer == nullptr) {
    wl_event_loop *loop = wl_display_get_event_loop(display);
    if (loop == nullptr) return;
    keyRepeatTimer = wl_event_loop_add_timer(loop, on_key_repeat, this);
  }
  if (keyRepeatTimer != nullptr) {
    wl_event_source_timer_update(keyRepeatTimer, delay);
  }
}

int Server::on_key_repeat(void *data) {
  auto *server = static_cast<Server *>(data);
  if (server->keyRepeatSurface == 0 || server->surfaces == nullptr) {
    return 0;
  }
  // Focus moved, or the surface died, or the user is no longer on this
  // workspace — all mean the held key no longer has a home.
  if (server->keyRepeatSurface != server->focusedSurface()) {
    server->stopKeyRepeat();
    return 0;
  }
  ClientSurface *target =
      server->surfaces->find(server->keyRepeatSurface);
  if (target == nullptr || target->canvas == nullptr) {
    server->stopKeyRepeat();
    return 0;
  }

  // Action 2 is GLFW_REPEAT / ACTION_REPEAT — the Swift side treats any
  // x > 0 as a press, and marks isRepeat when x > 1.
  target->canvas->keyEvent(server->keyRepeatKey, 2, server->keyRepeatMods);
  if (!server->keyRepeatText.empty()) {
    target->canvas->textInput(server->keyRepeatText);
  }
  server->surfaces->pump(*target);

  const int32_t rate = server->config.keyboard.repeatRate;
  if (rate <= 0 || server->keyRepeatTimer == nullptr) {
    server->stopKeyRepeat();
    return 0;
  }
  // ms between repeats. Clamp so a misconfigured "1000 keys/s" cannot pin
  // the event loop at 1 ms forever.
  const int interval = std::max(10, 1000 / rate);
  wl_event_source_timer_update(server->keyRepeatTimer, interval);
  return 0;
}

void Keyboard::on_key(wl_listener *listener, void *data) {
  auto *keyboard = owner_of<Keyboard>(listener);
  auto *event = static_cast<wlr_keyboard_key_event *>(data);
  Server *server = keyboard->server;

  const uint32_t modifiers = wlr_keyboard_get_modifiers(keyboard->wlr);
  const uint32_t modMask = shortcut_mod_mask(server->config.keyboard);
  if (event->state == WL_KEYBOARD_KEY_STATE_PRESSED) {
    // +8 converts evdev to xkb keycodes; the offset is historical, from X.
    const xkb_keycode_t keycode = event->keycode + 8;
    // The *unshifted* keysym, deliberately: Mod+Shift+2 produces "at" on a US
    // layout and something else again on a German one, while the binding is
    // about the key the digit is printed on. Level 0 is that key, whatever the
    // modifiers currently say.
    const xkb_layout_index_t layout =
        xkb_state_key_get_layout(keyboard->wlr->xkb_state, keycode);
    const xkb_keysym_t *syms = nullptr;
    const int count = xkb_keymap_key_get_syms_by_level(
        keyboard->wlr->keymap, keycode, layout, 0, &syms);
    const bool modDown = (modifiers & modMask) != 0;
    for (int i = 0; i < count; ++i) {
      if (handle_binding(server, syms[i], modifiers & WLR_MODIFIER_SHIFT,
                         modifiers & WLR_MODIFIER_CTRL, modDown,
                         modifiers & WLR_MODIFIER_ALT)) {
        // A compositor binding ate the key — do not also start repeating it
        // into a client (Alt+Q held would close a stream of windows).
        server->stopKeyRepeat();
        return;
      }
    }
  } else if (server->switcherHold != 0) {
    // The hold key that opened the switcher. Released here, not in the
    // client: the overlay is often still capturing when the user lets go,
    // so it never sees the key-up and stays on screen.
    const xkb_keycode_t keycode = event->keycode + 8;
    const xkb_layout_index_t layout =
        xkb_state_key_get_layout(keyboard->wlr->xkb_state, keycode);
    const xkb_keysym_t *syms = nullptr;
    const int count = xkb_keymap_key_get_syms_by_level(
        keyboard->wlr->keymap, keycode, layout, 0, &syms);
    uint32_t released = 0;
    for (int i = 0; i < count; ++i) {
      switch (syms[i]) {
      case XKB_KEY_Control_L:
      case XKB_KEY_Control_R:
        released |= WLR_MODIFIER_CTRL;
        break;
      case XKB_KEY_Alt_L:
      case XKB_KEY_Alt_R:
      case XKB_KEY_Meta_L:
      case XKB_KEY_Meta_R:
        released |= WLR_MODIFIER_ALT;
        break;
      case XKB_KEY_Super_L:
      case XKB_KEY_Super_R:
        released |= WLR_MODIFIER_LOGO;
        break;
      default:
        break;
      }
    }
    if (released & server->switcherHold) server->onSwitcherHoldReleased();
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
      // Prefer the first keysym for repeat tracking — multi-sym keys are
      // rare and the first is what we deliver first.
      const int glfwKey = count > 0 ? glfw_key(syms[0]) : 0;
      for (int i = 0; i < count; ++i) {
        target->canvas->keyEvent(glfw_key(syms[i]), pressed ? 1 : 0, mods);
      }
      std::string text;
      if (pressed) {
        const uint32_t utf32 = xkb_state_key_get_utf32(
            keyboard->wlr->xkb_state, event->keycode + 8);
        // Control characters are keys, not text: a client that inserted them
        // would put a literal backspace in its document.
        if (utf32 >= 0x20 && utf32 != 0x7f) {
          text = utf8_of(utf32);
          target->canvas->textInput(text);
        }
        if (glfwKey != 0) {
          server->startKeyRepeat(target->id, glfwKey, mods, std::move(text));
        }
      } else {
        // Only the key that is currently repeating cancels it — releasing
        // an earlier chord member must not kill a later held Backspace.
        if (glfwKey != 0 && glfwKey == server->keyRepeatKey) {
          server->stopKeyRepeat();
        }
      }
      server->surfaces->pump(*target);
    }
    return;
  }

  server->stopKeyRepeat();
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

void Server::on_new_popup(wl_listener *listener, void *data) {
  auto *server = owner_of<Server>(listener);
  auto *popup = static_cast<wlr_xdg_popup *>(data);

  // The parent may be another popup — a submenu — which is why this asks the
  // surface rather than assuming a toplevel. Either way the tree it wants is
  // the one stashed when that surface was created, so a submenu nests inside
  // its menu and the whole stack moves with the window.
  wlr_xdg_surface *parent =
      wlr_xdg_surface_try_from_wlr_surface(popup->parent);
  if (parent == nullptr || parent->data == nullptr) return;
  auto *parentTree = static_cast<wlr_scene_tree *>(parent->data);

  wlr_scene_tree *tree = wlr_scene_xdg_surface_create(parentTree, popup->base);
  if (tree == nullptr) return;
  popup->base->data = tree;

  // Self-owned, like the other shell objects here: it goes when the client
  // closes the menu.
  new Popup(server, popup);
  wlr_log(WLR_DEBUG, "popup: %dx%d",
          popup->scheduled.geometry.width, popup->scheduled.geometry.height);
}

void Popup::on_commit(wl_listener *listener, void *) {
  auto *self = owner_of<Popup>(listener);
  if (!self->wlr->base->initial_commit) return;

  // Where the menu may go, in the popup's own frame of reference: the work
  // area, moved into the coordinates its positioner is written in. Without
  // this a menu near an edge is placed past it and the client never finds
  // out — the protocol makes unconstraining the compositor's job precisely
  // because the client cannot see the screen.
  if (self->server != nullptr && self->server->surfaces != nullptr) {
    wlr_box box = self->server->popupBounds(*self->wlr);
    if (box.width > 0 && box.height > 0) {
      wlr_xdg_popup_unconstrain_from_box(self->wlr, &box);
    }
  }
  // Answers the client's first commit. A popup that is never configured never
  // maps, which looks exactly like a menu that does not open.
  wlr_xdg_surface_schedule_configure(self->wlr->base);
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
                                FramedWindow **out_window) {
  *out_window = nullptr;
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
      *out_window = static_cast<FramedWindow *>(tree->node.data);
      break;
    }
  }
  return scene_surface->surface;
}

wlr_box Server::popupBounds(const wlr_xdg_popup &popup) const {
  wlr_box box{};
  if (surfaces == nullptr) return box;

  // The *root toplevel's* coordinate system, which is what
  // `wlr_xdg_popup_unconstrain_from_box` documents and not what the immediate
  // parent gives: a submenu hangs off another popup, and measuring from that
  // one would offset the screen by however far the first menu already is from
  // the window. The result is a submenu unconstrained against the wrong
  // rectangle — right for the first level, drifting further off-screen with
  // every level after it.
  const wlr_surface *surface = popup.parent;
  const wlr_xdg_surface *root = nullptr;
  while (surface != nullptr) {
    const wlr_xdg_surface *xdg =
        wlr_xdg_surface_try_from_wlr_surface(const_cast<wlr_surface *>(surface));
    if (xdg == nullptr) break;
    if (xdg->role == WLR_XDG_SURFACE_ROLE_TOPLEVEL) {
      root = xdg;
      break;
    }
    if (xdg->role != WLR_XDG_SURFACE_ROLE_POPUP || xdg->popup == nullptr) break;
    surface = xdg->popup->parent;
  }
  if (root == nullptr || root->data == nullptr) return box;

  int lx = 0;
  int ly = 0;
  auto *tree = static_cast<wlr_scene_tree *>(root->data);
  if (!wlr_scene_node_coords(&tree->node, &lx, &ly)) return box;

  const SurfaceRegistry::WorkArea area = surfaces->workAreaAt(lx, ly);
  box.x = area.x - lx;
  box.y = area.y - ly;
  box.width = static_cast<int>(area.width);
  box.height = static_cast<int>(area.height);
  return box;
}

void Server::focus(FramedWindow *window) {
  if (window == nullptr) return;
  wlr_surface *surface = window->focusSurface();
  if (surface == nullptr) return;
  wlr_surface *previous = seat->keyboard_state.focused_surface;
  // Already has the keyboard — but not necessarily the top of the stack, and
  // this is also the raise path. Returning here used to mean a click inside a
  // window that was focused-but-buried did nothing at all: the keyboard was
  // already there, so nothing moved, and the window stayed under the one the
  // user was trying to get out from behind.
  const bool keyboardAlreadyHere = previous == surface;

  // Deactivating tells the old window to stop drawing itself as focused — its
  // caret, its titlebar. Nothing else would ever tell it. Found through the
  // window list rather than by asking the surface what kind it is, so an X11
  // window is deactivated the same way an xdg one is.
  if (!keyboardAlreadyHere) {
    for (FramedWindow *other : toplevels) {
      if (other != window && other->focusSurface() == previous) {
        other->activate(false);
        break;
      }
    }
  }

  // Through the registry, so the title bar comes up with the window: the two
  // are siblings in one tree and raising only the contents would put a
  // window's own frame behind it.
  if (surfaces != nullptr && window->frameId != 0) {
    if (ClientSurface *frame = surfaces->find(window->frameId)) {
      surfaces->raise(*frame);
      surfaces->setFocused(frame->id);
      recordFocus(*frame);
    }
  } else {
    wlr_scene_node_raise_to_top(window->contentNode());
  }
  toplevels.remove(window);
  toplevels.push_front(window);
  window->activate(true);

  if (keyboardAlreadyHere) return;
  if (auto *keyboard = wlr_seat_get_keyboard(seat)) {
    wlr_seat_keyboard_notify_enter(seat, surface, keyboard->keycodes,
                                   keyboard->num_keycodes, &keyboard->modifiers);
  }
}

void Server::blurAll() {
  // Clicking the desktop means "I am not in any window now", and until this
  // existed there was no way to say it: `focus(nullptr)` returns immediately,
  // so the last window kept the keyboard, kept drawing itself active, and kept
  // its menu on the panel — a global menu bar describing a window the user had
  // just clicked away from.
  //
  // Deactivating the outgoing window is the same courtesy `focus` pays the
  // window it replaces: nothing else would ever tell it to put its caret away.
  if (wlr_surface *previous = seat->keyboard_state.focused_surface) {
    for (FramedWindow *other : toplevels) {
      if (other->focusSurface() == previous) {
        other->activate(false);
        break;
      }
    }
  }
  wlr_seat_keyboard_notify_clear_focus(seat);

  // Both halves, as everywhere else focus moves: the workspace's keyboard
  // target for Lava surfaces, and the registry, which repaints the decorations
  // and is the one place that tells a panel the active window changed.
  setFocusedSurface(0);
  if (surfaces != nullptr) surfaces->setFocused(0);
}

void Server::reloadConfig() {
  const lava::Config fresh = lava::Config::load(configPath);
  const std::string previousDevices = config.drmDevices;
  const std::string previousRenderer = config.renderer;
  config = fresh;
  if (nested) config.keyboard.modKey = "alt";

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
  // Corners are the one appearance setting that can be re-applied while
  // running: it is a number the renderer reads per frame, so every window on
  // screen takes the new one without being told anything.
  if (surfaces != nullptr) {
    surfaces->setAppearance(
        static_cast<float>(config.appearance.cornerRadius),
        static_cast<float>(config.appearance.shadowBlur),
        config.appearance.shadowOpacity,
        static_cast<float>(config.appearance.shadowOffsetY));
    if (surfaces->control()) surfaces->control()->postSystemTheme();
  }
  // A hand-edited wallpaper, on the same signal as everything else. A picture
  // that will not decode leaves the previous one up and says why — the reload
  // must not take the desktop's background away because one line of the file
  // now points at a file that has moved.
  {
    std::string error;
    if (!wallpaper.apply(config.background, error)) {
      wlr_log(WLR_ERROR, "background: %s: %s", config.background.picture.c_str(),
              error.c_str());
      // The config in memory has already been replaced, so put back what is
      // actually on screen. Otherwise `GetWallpaper` would report the picture
      // that was refused, and a settings app would show a wallpaper the
      // desktop does not have.
      config.background = wallpaper.config();
    }
  }
  wlr_log(WLR_INFO, "config: reloaded");
}

uint32_t Server::x11FrameId(const wlr_xwayland_surface *xsurface) const {
  if (xsurface == nullptr) return 0;
  for (const XwaylandSurface *other : xwindows) {
    if (other->xsurface == xsurface) return other->frameId;
  }
  return 0;
}

FramedWindow *Server::frontToplevel(uint32_t workspace) {
  for (FramedWindow *window : toplevels) {
    if (window->workspace != workspace) continue;
    if (window->frameId != 0 && surfaces != nullptr) {
      if (ClientSurface *frame = surfaces->find(window->frameId)) {
        if (frame->minimized) continue;
      }
    }
    return window;
  }
  return nullptr;
}

void Server::recordFocus(const ClientSurface &surface) {
  if (surface.panel || surface.appId == kSwitcherAppId) return;
  focusHistory.record(surface.workspace, surface.id);
}

void Server::restoreFocus(uint32_t workspace, uint32_t exceptId) {
  if (exceptId != 0 && focusedSurface() == exceptId) setFocusedSurface(0);

  auto tryFocus = [&](uint32_t id) -> bool {
    if (id == 0 || id == exceptId || surfaces == nullptr) return false;
    ClientSurface *surface = surfaces->find(id);
    if (surface == nullptr || surface->panel || surface->minimized) return false;
    if (surface->workspace != workspace) return false;
    if (surface->appId == kSwitcherAppId) return false;
    focusSurface(*surface);
    return true;
  };

  if (surfaces != nullptr) {
    for (uint32_t id : focusHistory.of(workspace)) {
      if (tryFocus(id)) {
        update_pointer_focus(0);
        return;
      }
    }
    if (ClientSurface *fallback = surfaces->frontOnWorkspace(workspace)) {
      if (tryFocus(fallback->id)) {
        update_pointer_focus(0);
        return;
      }
    }
  }
  wlr_seat_keyboard_notify_clear_focus(seat);
  if (surfaces != nullptr &&
      (surfaces->focusedId() == 0 || surfaces->focusedId() == exceptId)) {
    surfaces->setFocused(0);
  }
  update_pointer_focus(0);
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
    restoreFocus(index, 0);
  }

  // The cursor did not move, but what is under it did.
  update_pointer_focus(0);
  // A switch changes no window and changes everything a dock shows.
  if (surfaces != nullptr) {
    surfaces->announceWindows();
    surfaces->syncShellForFullscreen();
  }
}

void Server::moveFocusedToWorkspace(uint32_t index) {
  if (index >= Workspaces::kCount || index == workspaces.current) return;

  if (surfaces != nullptr) {
    if (ClientSurface *surface = surfaces->find(focusedSurface())) {
      const uint32_t from = workspaces.current;
      surfaces->moveToWorkspace(*surface, index);
      // It arrives focused on the workspace it was sent to, and leaves this
      // one with nothing focused — the same as if it had been closed here.
      setFocusedSurface(0);
      focusedByWorkspace[index] = surface->id;
      surfaces->setFocused(0);
      focusHistory.move(surface->id, from, index);
      drag = Drag::None;
      restoreFocus(from, surface->id);
      update_pointer_focus(0);
      return;
    }
  }

  // No client surface has the keyboard, so it is a Wayland window's turn — the
  // front one, which is the one the user is looking at.
  if (FramedWindow *window = frontToplevel(workspaces.current)) {
    const uint32_t from = workspaces.current;
    const uint32_t frameId = window->frameId;
    window->workspace = index;
    wlr_scene_node_reparent(window->contentNode(), workspaces.tree[index]);
    // Its frame goes with it, or the title bar stays on this workspace with
    // nothing underneath.
    if (surfaces != nullptr && frameId != 0) {
      if (ClientSurface *frame = surfaces->find(frameId)) {
        surfaces->moveToWorkspace(*frame, index);
      }
    }
    if (frameId != 0) focusHistory.move(frameId, from, index);
    // Left at the front of the stacking list, which makes it the front window
    // of the workspace it arrived on — nothing else is there to be in front.
    wlr_seat_keyboard_notify_clear_focus(seat);
    drag = Drag::None;
    restoreFocus(from, frameId);
    update_pointer_focus(0);
  }
}

/// The theme's name for a `CursorShape` a client asked for.
///
/// Same family of names as `resize_cursor` below, and for the same reason:
/// these are what `wlr_xcursor_manager` loads from an X11 cursor theme, and
/// every theme has had them for decades. The double-headed splitter cursors
/// (`col-resize`, `row-resize`) would read better and are not universal, so a
/// divider gets the one-sided arrow every theme can draw.
const char *client_cursor(uint32_t shape) {
  switch (shape) {
    case 1: return "text";
    case 2: return "pointer";
    case 3: return "crosshair";
    case 4: return "e-resize";
    case 5: return "s-resize";
    default: return "default";
  }
}

/// The cursor image for a set of resize edges.
/// The cursor image for a set of resize edges.
///
/// The X11 names rather than the newer `cursor-shape-v1` ones, because that is
/// what `wlr_xcursor_manager` loads from a theme — and every theme has had
/// these eight since long before Wayland.
const char *resize_cursor(uint32_t hitEdges) {
  const bool left = (hitEdges & edges::kLeft) != 0;
  const bool right = (hitEdges & edges::kRight) != 0;
  const bool top = (hitEdges & edges::kTop) != 0;
  const bool bottom = (hitEdges & edges::kBottom) != 0;
  if (top && left) return "nw-resize";
  if (top && right) return "ne-resize";
  if (bottom && left) return "sw-resize";
  if (bottom && right) return "se-resize";
  if (top) return "n-resize";
  if (bottom) return "s-resize";
  if (left) return "w-resize";
  return "e-resize";
}

void Server::update_pointer_focus(uint32_t time_msec) {
  // Whatever is being dragged hangs off the cursor, wherever the rest of
  // this decides the motion belongs.
  moveDragIcon();

  // A drag owns the pointer until the button comes back up, wherever it has
  // got to — otherwise letting the cursor outrun the window would hand the
  // motion to whatever it crossed.
  if (update_drag()) return;

  // So does a press a client received. Everything below this asks "what is
  // under the cursor now", which is the wrong question while a button is
  // held: the answer changes as soon as the drag leaves the window, and the
  // surface being dragged in stops hearing about the pointer it is
  // tracking. A scrollbar dragged past the edge of its own window is the
  // case people notice.
  //
  // A `wl_data_device` drag is the exception, and it has to be: the button
  // is held for the whole of one, and the *point* is to reach a surface
  // other than the one it started on. wlroots has its own pointer grab
  // installed for the duration, and the enter it sends a drop target is
  // what puts a highlight under the cursor — so during a drag the hit test
  // below is exactly the right question.
  if (pointerButtonsDown > 0 && seat->drag == nullptr) {
    if (pointerTarget != 0 && surfaces != nullptr) {
      if (ClientSurface *held = surfaces->find(pointerTarget)) {
        // The frame of reference the *release* already uses: `contentY`,
        // not `y`, because the frame origin is the top of the title bar.
        if (held->canvas) {
          held->canvas->pointerMove(
              static_cast<float>(cursor->x - held->x),
              static_cast<float>(cursor->y - held->contentY()));
          surfaces->pump(*held);
        }
        return;
      }
    }
    if (pointerGrabbed && seat->pointer_state.focused_surface != nullptr) {
      wlr_seat_pointer_notify_motion(seat, time_msec,
                                     cursor->x - pointerGrabOriginX,
                                     cursor->y - pointerGrabOriginY);
      return;
    }
  }

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
    // Whatever that surface last asked for, which is "default" until a client
    // says otherwise. `route_pointer` has just set `pointerOver` to it.
    uint32_t shape = 0;
    if (surfaces != nullptr) {
      if (const ClientSurface *over = surfaces->find(pointerOver)) {
        shape = over->cursorShape;
      }
    }
    wlr_cursor_set_xcursor(cursor, cursor_mgr, client_cursor(shape));
    wlr_seat_pointer_clear_focus(seat);
    return;
  }

  // Just outside a window's edge: the resize band. Only the cursor changes —
  // the grab itself waits for a press — and it is the one piece of feedback
  // that makes an invisible affordance discoverable at all.
  if (surfaces != nullptr) {
    uint32_t hitEdges = 0;
    if (surfaces->borderAt(cursor->x, cursor->y, hitEdges) != nullptr) {
      wlr_cursor_set_xcursor(cursor, cursor_mgr, resize_cursor(hitEdges));
      wlr_seat_pointer_clear_focus(seat);
      return;
    }
  }

  double sx = 0, sy = 0;
  FramedWindow *window = nullptr;
  wlr_surface *surface =
      surface_at(cursor->x, cursor->y, &sx, &sy, &window);

  if (surface == nullptr) {
    // Over blank desktop: take the cursor image back from whichever client set
    // it last, and tell that client the pointer has left.
    wlr_cursor_set_xcursor(cursor, cursor_mgr, "default");
    wlr_seat_pointer_clear_focus(seat);
    return;
  }
  wlr_seat_pointer_notify_enter(seat, surface, sx, sy);
  wlr_seat_pointer_notify_motion(seat, time_msec, sx, sy);
  // Where that surface's origin is in layout space. Kept so a grab starting
  // on the next press can go on measuring from it once the hit test can no
  // longer find the surface under the cursor.
  pointerGrabOriginX = cursor->x - sx;
  pointerGrabOriginY = cursor->y - sy;
}

void Server::applyCursorFor(const ClientSurface &surface) {
  if (cursor == nullptr || cursor_mgr == nullptr) return;
  // Only while the pointer is actually inside it. A client whose window is in
  // the background must not be able to reach the pointer at all — and one
  // that asks while a drag is live is asking about a pointer the compositor
  // has already given to something else.
  if (pointerOver != surface.id || drag != Drag::None) return;
  wlr_cursor_set_xcursor(cursor, cursor_mgr, client_cursor(surface.cursorShape));
}

void Server::armInteractiveMove(ClientSurface &surface, bool fromClient) {
  pendingMove = true;
  pendingFromClient = fromClient;
  pendingSurface = surface.id;
  pendingX = cursor->x;
  pendingY = cursor->y;
}

void Server::flushPendingMove() {
  if (!pendingMove || surfaces == nullptr) return;
  constexpr double kSlop = 8.0;
  const double dx = cursor->x - pendingX;
  const double dy = cursor->y - pendingY;
  if (dx * dx + dy * dy < kSlop * kSlop) return;
  pendingMove = false;
  if (ClientSurface *surface = surfaces->find(pendingSurface)) {
    beginInteractiveMove(*surface, pendingFromClient);
  }
}

bool Server::update_drag() {
  if (pendingMove) {
    flushPendingMove();
    if (drag == Drag::None) return true;
  }
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
    return true;
  }

  // A resize is a move as well whenever it pulls a left or top edge: that
  // side follows the pointer and the opposite one has to stay where it is,
  // which only holds if the origin moves by exactly what the size lost.
  int x = dragOriginX;
  int y = dragOriginY;
  double w = dragOriginW;
  double h = dragOriginH;
  if (dragEdges & edges::kRight) w = dragOriginW + dx;
  if (dragEdges & edges::kBottom) h = dragOriginH + dy;
  if (dragEdges & edges::kLeft) {
    w = dragOriginW - dx;
    x = dragOriginX + static_cast<int>(dx);
  }
  if (dragEdges & edges::kTop) {
    h = dragOriginH - dy;
    y = dragOriginY + static_cast<int>(dy);
  }
  // Past the minimum, the far edge is what the user is holding still, so the
  // near one stops rather than pushing it. Without this a window dragged
  // through its own minimum starts walking sideways.
  //
  // The window's own floor where it has stated one, so a layout that stops
  // working below a certain width cannot be dragged into that state; the
  // compositor's global floor otherwise. Per axis, because a window may care
  // about one and not the other.
  const double floorW = surfaces->minFor(*surface, true);
  const double floorH = surfaces->minFor(*surface, false);
  if (w < floorW) {
    if (dragEdges & edges::kLeft) {
      x = dragOriginX + static_cast<int>(dragOriginW - floorW);
    }
    w = floorW;
  }
  if (h < floorH) {
    if (dragEdges & edges::kTop) {
      y = dragOriginY + static_cast<int>(dragOriginH - floorH);
    }
    h = floorH;
  }
  if (x != surface->x || y != surface->y) surfaces->moveSurface(*surface, x, y);
  // Rebuilding a swapchain-sized set of attachments and re-exporting a
  // dmabuf on every motion event is not free, and a drag produces one per
  // pixel. `resizeSurface` is a no-op when the size has not changed, which
  // the integer truncation above makes true most of the time.
  surfaces->resizeSurface(*surface, static_cast<uint32_t>(w),
                          static_cast<uint32_t>(h));
  return true;
}

bool Server::beginInteractiveMove(ClientSurface &surface, bool fromClient) {
  if (surfaces == nullptr || surface.panel) return false;
  // Nothing to carry the move: a client that asks for one with no button down
  // would get a window glued to the cursor until the next click.
  if (pointerButtonsDown == 0) return false;

  // Dragging a maximized or fullscreen window restores it and hands it back
  // under the pointer, which is what every desktop does and what the
  // gesture means — the user is pulling the window off the edge, not
  // asking to move a full-screen rectangle around. The grab keeps its
  // place along the width so a title bar grabbed near its right end stays
  // grabbed there.
  if (surface.fullscreen) surfaces->setFullscreen(surface, false);
  if (surface.maximized) {
    const double fraction =
        surface.width > 0 ? (cursor->x - surface.x) / surface.width : 0.5;
    const int grabY = static_cast<int>(cursor->y) - surface.y;
    surfaces->setMaximized(surface, false);
    const int height = surface.frameHeight();
    surfaces->moveSurface(
        surface, static_cast<int>(cursor->x - fraction * surface.width),
        static_cast<int>(cursor->y) - std::min(grabY, std::max(0, height - 1)));
  }

  // The release the client is never going to see, because from the next line
  // the pointer is the compositor's. Sent first, so a client that tracks its
  // own button state resolves the press it just handled instead of holding a
  // capture that nothing will ever end.
  if (!surface.isForeign() && surface.canvas) {
    surface.canvas->pointerButton(lastPressedButton, false,
                                  static_cast<float>(cursor->x - surface.x),
                                  static_cast<float>(cursor->y -
                                                     surface.contentY()),
                                  0);
    surfaces->pump(surface);
  }

  drag = Drag::Move;
  dragFromClient = fromClient;
  dragSurface = surface.id;
  dragEdges = 0;
  dragStartX = cursor->x;
  dragStartY = cursor->y;
  dragOriginX = surface.x;
  dragOriginY = surface.y;
  dragOriginW = surface.width;
  dragOriginH = surface.height;
  return true;
}

bool Server::beginInteractiveResize(ClientSurface &surface, uint32_t edges,
                                    bool fromClient) {
  if (surfaces == nullptr || surface.panel) return false;
  if (pointerButtonsDown == 0) return false;
  // A resize with no side named is not a resize. Nothing sensible to grow
  // from, and the drag would move the window instead.
  if (edges == 0) return false;
  // A maximized window has no edges to pull. Honouring the request is how
  // a click on VS Code's chrome — it still sends `xdg_toplevel.resize` —
  // dropped the window off the work area. Fullscreen likewise.
  if (surface.maximized || surface.fullscreen) return false;

  drag = Drag::Resize;
  dragFromClient = fromClient;
  dragEdges = edges;
  dragSurface = surface.id;
  dragStartX = cursor->x;
  dragStartY = cursor->y;
  dragOriginX = surface.x;
  dragOriginY = surface.y;
  dragOriginW = surface.width;
  dragOriginH = surface.height;
  return true;
}

bool Server::serverDecorated(wlr_xdg_toplevel *toplevel) const {
  if (decorations == nullptr || toplevel == nullptr) return true;
  wlr_xdg_toplevel_decoration_v1 *decoration = nullptr;
  wl_list_for_each(decoration, &decorations->decorations, link) {
    if (decoration->toplevel != toplevel) continue;
    // What we actually told it, not merely that it asked. A client that
    // requested client side has been answered client side and is drawing its
    // own header; framing it anyway is how a window gets two title bars.
    const auto *ours = static_cast<const ToplevelDecoration *>(decoration->data);
    return ours == nullptr || ours->serverSide;
  }
  // Never bound the protocol at all. Toolkits that do this — GTK — draw their
  // own and have no way to be told otherwise, so a frame here would be the
  // second one.
  return false;
}

void Server::focusSurface(ClientSurface &surface) {
  if (surfaces == nullptr) return;
  // A panel is not a window and clicking one does not change which window the
  // user is in. This is what a desktop means by a panel — layer-shell spells
  // it `keyboard_interactivity: none` — and here it is load-bearing rather
  // than a nicety: the panel *is* the global menu, so a click on a menu title
  // that made the panel active would replace the menu being opened with the
  // panel's own, which has no items. The menu vanished as it was clicked.
  //
  // The press still reaches the panel; only focus stays where it was. Which
  // also means the keyboard stays in the window the user was typing in, which
  // is what they expect from clicking a menu.
  //
  // The cost is a panel that wants the keyboard — a launcher with a search
  // field — cannot have it. That wants an interactivity flag on
  // `CreatePanel`, not an exception here.
  if (surface.panel) return;

  // The switcher takes the keyboard without becoming the "active window".
  // The previous app keeps its title-bar highlight and stays focused in
  // the dock; only input is redirected. A panel already works this way
  // because it never takes the keyboard at all — the switcher is the one
  // overlay that needs both.
  if (surface.appId == kSwitcherAppId) {
    surfaces->raise(surface);
    setFocusedSurface(surface.id);
    wlr_seat_keyboard_notify_clear_focus(seat);
    dismissSwitcherOnMapIfNeeded(surface);
    return;
  }

  recordFocus(surface);
  surfaces->setFocused(surface.id);
  surfaces->raise(surface);
  if (surface.isForeign()) {
    // A foreign window takes the keyboard through the seat, and no client
    // surface may hold it at the same time — both focused would deliver every
    // key twice.
    setFocusedSurface(0);
    focus(surface.window);
    return;
  }
  setFocusedSurface(surface.id);
  wlr_seat_keyboard_notify_clear_focus(seat);
}

void Server::beginSwitcherSession(uint32_t holdMask) {
  switcherHold = holdMask;
  switcherDismissOnMap = false;
}

void Server::dismissSwitcherOnMapIfNeeded(ClientSurface &surface) {
  if (!switcherDismissOnMap) return;
  switcherDismissOnMap = false;
  switcherHold = 0;
  // Never shown: the hold key was already up. Closing is the whole session.
  if (surfaces != nullptr) surfaces->requestClose(surface);
}

void Server::onSwitcherHoldReleased() {
  const uint32_t hold = switcherHold;
  switcherHold = 0;
  if (hold == 0) return;
  if (surfaces != nullptr) {
    if (surfaces->findByAppId(kSwitcherAppId) != nullptr) {
      injectSwitcherCommit();
      return;
    }
  }
  // Still capturing / not mapped. Kill it so a shelf never flashes after
  // the user already let go.
  const pid_t pid = g_switcherPid.exchange(-1);
  if (pid > 0) {
    kill(pid, SIGTERM);
    return;
  }
  switcherDismissOnMap = true;
}

void Server::injectSwitcherCommit() {
  if (surfaces == nullptr) return;
  ClientSurface *surface = surfaces->findByAppId(kSwitcherAppId);
  if (surface == nullptr || !surface->canvas) return;
  // Left Control release, no mods — the client treats any hold-mod up as
  // commit. 341 is GLFW_KEY_LEFT_CONTROL, matching `KeyCode.leftControl`.
  surface->canvas->keyEvent(341, 0, 0);
  surfaces->pump(*surface);
}

void Server::toggleShowDesktop() {
  if (surfaces == nullptr) return;
  if (surfaces->desktopShown()) {
    const uint32_t front = surfaces->restoreDesktop();
    if (ClientSurface *surface = surfaces->find(front)) {
      focusSurface(*surface);
    } else {
      focus(frontToplevel(workspaces.current));
    }
    update_pointer_focus(0);
    return;
  }
  surfaces->hideDesktop();
  // Nothing on screen to type into. Clearing both halves is the same
  // as the last minimize in a stack of them.
  setFocusedSurface(0);
  surfaces->setFocused(0);
  wlr_seat_keyboard_notify_clear_focus(seat);
  update_pointer_focus(0);
}

void Server::minimizeSurface(ClientSurface &surface) {
  if (surfaces == nullptr || surface.panel) return;
  const uint32_t workspace = surface.workspace;
  const uint32_t id = surface.id;
  const bool hadFocus =
      focusedSurface() == id || surfaces->focusedId() == id;
  surfaces->setMinimized(surface, true);
  // A drag on a window that just vanished would go on moving it invisibly.
  if (drag != Drag::None && dragSurface == id) drag = Drag::None;
  if (pendingMove && pendingSurface == id) pendingMove = false;
  if (surface.isForeign()) surface.window->activate(false);
  // Somebody has to have the keyboard, and the window that had it
  // before this one is the one the user is now looking at.
  if (hadFocus) {
    restoreFocus(workspace, id);
  }
  update_pointer_focus(0);
}

// The two control-plane verbs that need the pointer and the seat, which live
// on `Server` — so they are defined here, below it, rather than inline with
// the rest of the registry.

bool SurfaceRegistry::beginMove(uint32_t id) {
  ClientSurface *surface = find(id);
  if (surface == nullptr) return false;
  // True means "the surface is yours", not "the drag started": a client that
  // asked with no button down has made a harmless mistake, and turning it
  // into `SurfaceNotFound` would say something false about the window.
  if (server_ != nullptr) server_->beginInteractiveMove(*surface);
  return true;
}

bool SurfaceRegistry::activateWindow(uint32_t id) {
  ClientSurface *surface = find(id);
  if (surface == nullptr || surface->panel) return false;
  // Restore first: raising and focusing a hidden window would leave the shell
  // showing it as active and the screen showing nothing.
  setMinimized(*surface, false);
  if (server_ != nullptr) {
    server_->focusSurface(*surface);
    server_->update_pointer_focus(0);
  } else {
    raise(*surface);
    setFocused(id);
  }
  // Deliberately not switching workspace to follow it — see `ActivateWindow`.
  return true;
}

void SurfaceRegistry::setCursor(uint32_t id, uint32_t shape) {
  ClientSurface *surface = find(id);
  if (surface == nullptr) return;
  if (surface->cursorShape == shape) return;
  surface->cursorShape = shape;
  // Applied now rather than at the next pointer motion: the client sends this
  // *because* the pointer crossed into something, and by then the pointer has
  // usually stopped moving. Waiting for motion would mean the cursor only
  // changed on the way back out.
  if (server_ != nullptr) server_->applyCursorFor(*surface);
}

bool SurfaceRegistry::minimize(uint32_t id) {
  ClientSurface *surface = find(id);
  if (surface == nullptr) return false;
  if (server_ != nullptr) {
    server_->minimizeSurface(*surface);
  } else {
    setMinimized(*surface, true);
  }
  return true;
}

bool Server::route_pointer(uint32_t kind, int32_t button, int32_t mods) {
  if (surfaces == nullptr || control == nullptr) return false;
  double sx = 0, sy = 0;
  ClientSurface *surface = surfaces->at(cursor->x, cursor->y, sx, sy);

  // The surface the pointer *was* over hears that it left. Without it a client
  // sees only the last position inside itself and has to assume the pointer is
  // still there: hovers stay lit after the cursor has gone, and a dock that
  // reveals itself on approach never learns to hide.
  const uint32_t nowOver = surface != nullptr ? surface->id : 0;
  if (pointerOver != 0 && pointerOver != nowOver) {
    if (ClientSurface *left = surfaces->find(pointerOver)) {
      if (left->canvas) {
        // The renderer's own hover has to be cleared as well, or the tint it
        // owns outlives the pointer that caused it.
        left->canvas->pointerMove(-1.f, -1.f);
        surfaces->pump(*left);
      }
      control->postInput(
          pointerOver,
          static_cast<uint32_t>(canvas::InputEventKind::PointerLeave), 0.f, 0.f,
          0, 0);
    }
  }
  pointerOver = nowOver;

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

  // Relative motion is independent of the visible cursor. In particular it
  // must keep flowing while a locked pointer is stationary: this is the path
  // Xwayland uses for XI2 raw motion and therefore for first-person cameras.
  if (server->relativePointers != nullptr) {
    wlr_relative_pointer_manager_v1_send_relative_motion(
        server->relativePointers, server->seat,
        static_cast<uint64_t>(event->time_msec) * 1000u, event->delta_x,
        event->delta_y, event->unaccel_dx, event->unaccel_dy);
  }

  wlr_pointer_constraint_v1 *constraint = server->activePointerConstraint;
  if (constraint == nullptr ||
      constraint->type != WLR_POINTER_CONSTRAINT_V1_LOCKED) {
    double dx = event->delta_x;
    double dy = event->delta_y;
    if (constraint != nullptr &&
        constraint->type == WLR_POINTER_CONSTRAINT_V1_CONFINED) {
      const double sx = server->seat->pointer_state.sx;
      const double sy = server->seat->pointer_state.sy;
      double confinedX = sx;
      double confinedY = sy;
      if (wlr_region_confine(&constraint->region, sx, sy, sx + dx, sy + dy,
                             &confinedX, &confinedY)) {
        dx = confinedX - sx;
        dy = confinedY - sy;
      } else {
        dx = 0;
        dy = 0;
      }
    }
    wlr_cursor_move(server->cursor, &event->pointer->base, dx, dy);
  }
  server->update_pointer_focus(event->time_msec);
}

void Server::on_cursor_motion_absolute(wl_listener *listener, void *data) {
  auto *server =
      owner_of<Server>(listener);
  auto *event = static_cast<wlr_pointer_motion_absolute_event *>(data);
  if (server->activePointerConstraint == nullptr ||
      server->activePointerConstraint->type !=
          WLR_POINTER_CONSTRAINT_V1_LOCKED) {
    wlr_cursor_warp_absolute(server->cursor, &event->pointer->base, event->x,
                             event->y);
  }
  server->update_pointer_focus(event->time_msec);
}

void Server::activatePointerConstraint(
    wlr_pointer_constraint_v1 *constraint) {
  if (constraint == activePointerConstraint) return;

  if (activePointerConstraint != nullptr) {
    wlr_pointer_constraint_v1 *old = activePointerConstraint;
    activePointerConstraint = nullptr;
    active_constraint_destroy.detach();
    wlr_pointer_constraint_v1_send_deactivated(old);
  }

  if (constraint == nullptr) return;
  activePointerConstraint = constraint;
  active_constraint_destroy.attach(&constraint->events.destroy, this,
                                   on_active_constraint_destroy);
  wlr_pointer_constraint_v1_send_activated(constraint);
}

void Server::on_new_pointer_constraint(wl_listener *listener, void *data) {
  auto *server = owner_of<Server>(listener);
  auto *constraint = static_cast<wlr_pointer_constraint_v1 *>(data);
  if (server->seat->pointer_state.focused_surface == constraint->surface) {
    server->activatePointerConstraint(constraint);
  }
}

void Server::on_pointer_focus_change(wl_listener *listener, void *data) {
  auto *server = owner_of<Server>(listener);
  auto *event = static_cast<wlr_seat_pointer_focus_change_event *>(data);
  wlr_pointer_constraint_v1 *constraint = nullptr;
  if (event->new_surface != nullptr && server->pointerConstraints != nullptr) {
    constraint = wlr_pointer_constraints_v1_constraint_for_surface(
        server->pointerConstraints, event->new_surface, server->seat);
  }
  server->activatePointerConstraint(constraint);
}

void Server::on_active_constraint_destroy(wl_listener *listener, void *) {
  auto *server = owner_of<Server>(listener);
  server->active_constraint_destroy.detach();
  server->activePointerConstraint = nullptr;
}

void Server::on_cursor_button(wl_listener *listener, void *data) {
  auto *server = owner_of<Server>(listener);
  auto *event = static_cast<wlr_pointer_button_event *>(data);

  const bool pressed = event->state == WL_POINTER_BUTTON_STATE_PRESSED;
  // Left = 0, matching GLFW, which is what the client's event decoding was
  // written against.
  const int32_t lavaButton = static_cast<int32_t>(event->button - 0x110u);
  // Counted rather than tracked per button: the only question anything asks is
  // "is the user holding something", which `BeginMove` needs before it glues a
  // window to the cursor.
  if (pressed) {
    ++server->pointerButtonsDown;
    server->lastPressedButton = lavaButton;
  } else if (server->pointerButtonsDown > 0) {
    --server->pointerButtonsDown;
  }
  // The last button came up, so the implicit grab is over — here rather
  // than at the bottom, because a release leaves this function by whichever
  // of half a dozen paths matches what it was over.
  if (server->pointerButtonsDown == 0) server->pointerGrabbed = false;

  // A click that never became a drag: remember it for double-click on
  // our title bar, and let a client-originated press still see its release.
  if (!pressed && server->pendingMove) {
    if (!server->pendingFromClient) {
      server->lastBarClickTime = event->time_msec;
      server->lastBarClickSurface = server->pendingSurface;
      server->pendingMove = false;
      return;
    }
    server->pendingMove = false;
  }

  // A release always ends a drag, whatever it is over by then.
  if (!pressed && server->drag != Server::Drag::None) {
    const bool answerClient = server->dragFromClient;
    server->drag = Server::Drag::None;
    server->dragFromClient = false;
    // A drag the client asked for began with a press the client was given —
    // that is how it knew to ask — and it is still holding it. Taking the
    // pointer for the drag and then swallowing the release leaves the client
    // in a press that never ends: GTK goes on believing a button is down and
    // ignores everything after, which looks like a window that stops
    // responding the moment you finish moving it.
    //
    // Only then. A title-bar or Alt+drag never let the press out of the
    // compositor, and a release for a press it never saw would fire whatever
    // control the pointer happens to be over.
    if (answerClient) {
      wlr_seat_pointer_notify_button(server->seat, event->time_msec,
                                     event->button, event->state);
    }
    if (ClientSurface *moved = server->surfaces->find(server->dragSurface)) {
      server->surfaces->rememberPlacement(*moved);
    }
    // What is under the pointer has not been tracked during the drag, and the
    // window it was over has probably moved out from under it.
    server->update_pointer_focus(event->time_msec);
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
      server->focusSurface(*frame);
      switch (lava::Decoration::hitTest(static_cast<float>(bx),
                                        static_cast<float>(by),
                                        frame->width)) {
        case lava::DecorationHit::Close:
          // Asked rather than killed, where there is somebody to ask: a
          // Wayland client gets to put up its "save your work?" dialog.
          // A Lava client is destroyed here; `destroySurface` already
          // handed the keyboard to whoever had it last. Zeroing focus
          // after that used to undo the restore.
          server->surfaces->requestClose(*frame);
          return;
        case lava::DecorationHit::Maximize:
          server->surfaces->setMaximized(*frame, !frame->maximized);
          if (frame->isForeign()) {
            // Told, so the client draws itself as maximized — squared corners,
            // a different button in its own menu.
            frame->window->setMaximized(frame->maximized);
          }
          return;
        case lava::DecorationHit::Minimize:
          server->minimizeSurface(*frame);
          return;
        case lava::DecorationHit::Bar: {
          // Double-click maximizes (or restores). A single click must not
          // start a move, or a maximized window would drop off the work
          // area before the second click arrived — and a click that was
          // never a drag would restore it anyway.
          constexpr uint32_t kDoubleClickMs = 400;
          const bool dbl =
              frame->id == server->lastBarClickSurface &&
              event->time_msec - server->lastBarClickTime <= kDoubleClickMs;
          if (dbl) {
            server->lastBarClickSurface = 0;
            if (frame->fullscreen) {
              server->surfaces->setFullscreen(*frame, false);
            }
            server->surfaces->setMaximized(*frame, !frame->maximized);
            return;
          }
          server->armInteractiveMove(*frame, false);
          return;
        }
      }
    }
  }

  // A window's outer edge, which is a resize grip whether or not the window
  // has a frame — and the only one a client-framed window has. Answered only
  // where the ordinary hit test found nothing, so the band never takes a click
  // from a window the user can actually see. See `borderAt`.
  if (pressed && server->surfaces != nullptr) {
    uint32_t hitEdges = 0;
    if (ClientSurface *edge = server->surfaces->borderAt(
            server->cursor->x, server->cursor->y, hitEdges)) {
      server->focusSurface(*edge);
      server->drag = Server::Drag::Resize;
      server->dragEdges = hitEdges;
      server->dragSurface = edge->id;
      server->dragStartX = server->cursor->x;
      server->dragStartY = server->cursor->y;
      server->dragOriginX = edge->x;
      server->dragOriginY = edge->y;
      server->dragOriginW = edge->width;
      server->dragOriginH = edge->height;
      return;
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
    if ((modifiers & shortcut_mod_mask(server->config.keyboard)) &&
        over != nullptr) {
      server->surfaces->raise(*over);
      // Same entry as a title-bar drag: a maximized window has to come off
      // the edge *and* get its decoration back. Setting `drag` here by hand
      // used to skip that and leave a floating window with no title bar.
      if (event->button == BTN_RIGHT) {
        server->beginInteractiveResize(*over, edges::kRight | edges::kBottom);
      } else {
        server->beginInteractiveMove(*over);
      }
      return;
    }
  }

  // A press over a client surface focuses it and is forwarded; a release goes
  // to whichever surface took the press even if the pointer has since left it,
  // so a drag that ends outside still ends.
  if (server->surfaces != nullptr && server->control != nullptr) {
    const int32_t button = lavaButton;
    double sx = 0, sy = 0;
    if (pressed) {
      if (ClientSurface *over =
              server->surfaces->at(server->cursor->x, server->cursor->y, sx, sy)) {
        // Same two halves the title bar sets: the workspace's keyboard target
        // and the decoration's "this window is active" paint. Forgetting the
        // second made a content click raise the window but leave the chrome on
        // whatever last took a bar click — looking like focus only works from
        // the non-client strip.
        server->focusSurface(*over);
        // Remembered separately from focus, because they are different
        // questions and a panel is where they part company: a press on the
        // panel must not move the keyboard, but its *release* still belongs to
        // the panel. Routing the release by focus sent it to the window
        // behind, so every control on a panel got a press it never saw the end
        // of — and a menu item, which fires on release, never fired at all.
        server->pointerTarget = over->id;
        over->canvas->pointerButton(button, true, static_cast<float>(sx),
                                    static_cast<float>(sy), 0);
        server->surfaces->pump(*over);
        return;
      }
      // Pressed on something that is not a client surface: whatever held the
      // pointer before does not hold it now.
      server->pointerTarget = 0;
    } else if (ClientSurface *target = server->surfaces->find(
                   server->pointerTarget != 0 ? server->pointerTarget
                                              : server->focusedSurface())) {
      server->pointerTarget = 0;
      // Recomputed against that surface rather than reusing whatever a hit
      // test left behind: the pointer may be outside it, and `at` only fills
      // the offsets for surfaces it actually tested.
      // `contentY()`, not `y`. The frame origin is the top of the title bar
      // and the content starts one bar below it, so subtracting `y` puts every
      // release 32 pixels below where it happened.
      //
      // That offset is why buttons and toggles could not be clicked while
      // typing into an editor worked. A control fires on *release*, and only
      // if the pointer is still inside it; the displaced release re-resolved
      // hover to whatever is 32px lower — usually nothing — which cleared the
      // hover and cancelled the click, in that order, in the same drain. An
      // editor does not care: it is tall, it acts on the press, and a release
      // slightly low still lands inside it.
      target->canvas->pointerButton(
          button, false, static_cast<float>(server->cursor->x - target->x),
          static_cast<float>(server->cursor->y - target->contentY()), 0);
      server->surfaces->pump(*target);
      return;
    }
  }

  if (pressed) {
    double sx = 0, sy = 0;
    FramedWindow *window = nullptr;
    wlr_surface *hit = server->surface_at(server->cursor->x, server->cursor->y,
                                          &sx, &sy, &window);
    if (hit == nullptr) {
      // Nothing of anyone's under the pointer — the scene's background rect is
      // not a surface, so this is the desktop. Tested on the *surface* and not
      // on `toplevel`: a popup or an override-redirect window has no toplevel
      // to resolve to, and blurring on one of those would drop the keyboard
      // every time a menu was clicked.
      server->blurAll();
    } else {
      // Click to focus. A hit that resolves to no window is a popup or an
      // override-redirect menu, which owns its own stacking and focus.
      server->focus(window);
      server->setFocusedSurface(0);
    }
  }

  wlr_seat_pointer_notify_button(server->seat, event->time_msec, event->button,
                                 event->state);
  // Only a press a client was actually given takes the pointer. The paths
  // above that keep a press for the compositor — the title bar, the resize
  // band, Alt+drag — return before this and never set it.
  if (pressed) {
    server->pointerGrabbed =
        server->seat->pointer_state.focused_surface != nullptr;
  }
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
      // One detent is one notch, whatever units the device counts it in.
      // `delta` is 15 per detent by convention for a wheel and pixels of
      // travel for a touchpad, so on its own it cannot say which it is
      // looking at; `delta_discrete` is 120 per detent and only a device
      // with detents sends it. Preferring it means a high-resolution wheel
      // covers the same distance per detent as an old one instead of moving
      // in eighths of it, while a touchpad keeps its continuous feel.
      constexpr double kUnitsPerDetent    = 15.0;
      constexpr double kDiscretePerDetent = 120.0;
      const float notches = static_cast<float>(
          event->delta_discrete != 0
              ? -event->delta_discrete / kDiscretePerDetent
              : -event->delta / kUnitsPerDetent);
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

/// A client asks to start a drag — the other half of `wl_data_device`, and
/// the half this compositor never answered.
///
/// The same trap the selection handlers above exist for:
/// `wlr_data_device_manager_create` publishes the protocol and nothing more,
/// so without this every `start_drag` was dropped and dragging a file in a
/// Wayland client did nothing at all. Not "the drop was refused" — the drag
/// never began, so there was no cursor change and no icon either.
void Server::on_request_start_drag(wl_listener *listener, void *data) {
  auto *server = owner_of<Server>(listener);
  auto *event = static_cast<wlr_seat_request_start_drag_event *>(data);

  // The serial has to name a press this client actually received on this
  // surface. Unchecked, any client could start a drag at any time — and
  // take the pointer away from whatever the user was really doing with it.
  if (wlr_seat_validate_pointer_grab_serial(server->seat, event->origin,
                                            event->serial)) {
    wlr_seat_start_pointer_drag(server->seat, event->drag, event->serial);
    return;
  }
  wlr_log(WLR_DEBUG, "drag: stale serial %u, refused", event->serial);
  // Refused, and the client is told so by the source going away. Leaking it
  // would leave a data source nobody can ever finish or cancel.
  if (event->drag->source != nullptr) {
    wlr_data_source_destroy(event->drag->source);
  }
}

/// The drag is running: give the icon somewhere to be drawn.
///
/// A drag with no icon is legal and common — a client may drag with only the
/// cursor changing — so the icon is optional here rather than assumed.
void Server::on_start_drag(wl_listener *listener, void *data) {
  auto *server = owner_of<Server>(listener);
  auto *drag = static_cast<wlr_drag *>(data);
  if (drag->icon == nullptr || server->workspaces.dragIcons == nullptr) return;

  wlr_scene_tree *tree =
      wlr_scene_drag_icon_create(server->workspaces.dragIcons, drag->icon);
  if (tree == nullptr) return;
  // On the icon, not on a member of `Server`: the scene tree dies with the
  // icon, and a pointer kept here would outlive it by exactly as long as it
  // takes to drop something.
  drag->icon->data = tree;
  server->moveDragIcon();
}

void Server::moveDragIcon() {
  if (seat == nullptr || seat->drag == nullptr) return;
  wlr_drag_icon *icon = seat->drag->icon;
  if (icon == nullptr || icon->data == nullptr) return;
  auto *tree = static_cast<wlr_scene_tree *>(icon->data);
  wlr_scene_node_set_position(&tree->node, static_cast<int>(cursor->x),
                              static_cast<int>(cursor->y));
}

void Server::on_request_set_selection(wl_listener *listener, void *data) {
  auto *server = owner_of<Server>(listener);
  auto *event = static_cast<wlr_seat_request_set_selection_event *>(data);
  // Reaching this handler means the serial already passed
  // `wlr_seat_request_set_selection`: it was sent to this client, and it
  // is not older than the current offer. Rejected requests never arrive
  // — that is why a Qt fallback copy after Print Screen looks like a
  // successful copy (the client never hears the denial). Clients that
  // speak data-control skip this path entirely.
  wlr_seat_set_selection(server->seat, event->source, event->serial);
}

void Server::on_set_selection(wl_listener *listener, void *) {
  auto *server = owner_of<Server>(listener);
  // After the source is current — data-control and wl_data_device both
  // land here. Snapshot PNG/text so the crop survives Flameshot exiting.
  lava::Clipboard clipboard(server->display, server->seat);
  clipboard.persistClientSelection();
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

  // Before backend start, portal start, anything that can wedge the
  // loop. Default 15 s; `LAVA_NO_WATCHDOG=1` or `_MS=0` turns it off.
  int watchdogMs = 15000;
  if (const char *off = std::getenv("LAVA_NO_WATCHDOG");
      off != nullptr && off[0] != '\0' && off[0] != '0') {
    watchdogMs = 0;
  }
  if (const char *ms = std::getenv("LAVA_STARTUP_WATCHDOG_MS")) {
    watchdogMs = std::atoi(ms);
  }
  lava::StartupWatchdog startupWatchdog(watchdogMs);
  if (watchdogMs > 0) {
    wlr_log(WLR_INFO, "startup watchdog: %d ms", watchdogMs);
  }

  // Whether this compositor is running inside somebody else's session, read
  // before it publishes a socket of its own and becomes the answer itself.
  //
  // What turns on it is the user's autostart script, at the bottom of this
  // function: applets are singletons on the session bus, so a nested session
  // starting a second nm-applet gets a fight over the tray or an immediate
  // exit, and a developer restarting a compositor twenty times an hour wants
  // neither.
  const bool nested = std::getenv("WAYLAND_DISPLAY") != nullptr ||
                      std::getenv("DISPLAY") != nullptr;

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
    // SIGUSR2 for the same reason — it dumps the GPU report through the loop.
    sigaddset(&mask, SIGUSR2);
    // SIGCHLD for the same reason, and it matters more: the compositor is the
    // parent of the panel and the dock, and `ShellSupervisor` learns one died
    // by reading this off the loop's signalfd. Unblocked, the default
    // disposition discards it and a crashed dock never comes back.
    sigaddset(&mask, SIGCHLD);
    // And the two ways a compositor is asked to stop. Taken on the loop
    // instead of by default disposition so that ending one is an orderly
    // shutdown: the control plane unlinks its reference, the shell components
    // are told to go while their sockets still work, and clients see a
    // display that closed rather than one that vanished. Developing a
    // compositor means killing it a hundred times a day — usually a nested
    // one, sharing a runtime directory with the session it runs inside — and
    // every one of those left a stale reference behind before this.
    sigaddset(&mask, SIGTERM);
    sigaddset(&mask, SIGINT);
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
  // After the file: Super on the host and Super in here would both fire
  // on the same chord, and the host wins. Alt is free. Not written back.
  server.nested = nested;
  if (nested) {
    server.config.keyboard.modKey = "alt";
    wlr_log(WLR_INFO,
            "keyboard: nested session, compositor shortcuts use Alt");
  }

  auto *loop = wl_display_get_event_loop(server.display);
  server.backend = wlr_backend_autocreate(loop, &server.session);
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
  // Without this, Xwayland has no way to say when a buffer is finished —
  // implicit dma_resv is what NVIDIA has never honoured, and a windowed-
  // fullscreen game then scanouts mid-write. Tinywl and every other 0.19
  // compositor advertise this; the scene waits on the fences itself.
  {
    const int drmFd = wlr_renderer_get_drm_fd(server.renderer);
    if (drmFd >= 0 && server.renderer->features.timeline &&
        server.backend->features.timeline) {
      if (wlr_linux_drm_syncobj_manager_v1_create(server.display, 1, drmFd) ==
          nullptr) {
        wlr_log(WLR_ERROR, "linux-drm-syncobj: failed to advertise");
      } else {
        wlr_log(WLR_INFO, "linux-drm-syncobj: advertised");
      }
    } else {
      wlr_log(WLR_INFO,
              "linux-drm-syncobj: not advertised (timeline renderer=%d "
              "backend=%d drm_fd=%d)",
              static_cast<int>(server.renderer->features.timeline),
              static_cast<int>(server.backend->features.timeline), drmFd);
    }
  }
  auto *compositor = wlr_compositor_create(server.display, 6, server.renderer);
  wlr_subcompositor_create(server.display);
  // The clipboard, and the X11-style middle-click one beside it. Both are
  // only half of what a working selection needs — see `on_request_set_selection`.
  wlr_data_device_manager_create(server.display);
  wlr_primary_selection_v1_device_manager_create(server.display);
  // Privileged clipboard (no input serial). Flameshot's KGuiAddons
  // `WaylandClipboard` prefers `ext-data-control`, then the older
  // `wlr-data-control`. Without either it falls back to Qt's
  // `wl_data_device.set_selection`, whose serial loses to Print Screen's
  // `wl_display_next_serial` — crop copied, paste still the full frame.
  // Same protocols `wl-copy` / `wl-paste` speak. The portal never uses
  // these; they exist so the *crop* can become the seat selection.
  wlr_data_control_manager_v1_create(server.display);
  wlr_ext_data_control_manager_v1_create(server.display, 1);

  server.scene = wlr_scene_create();
  server.output_layout = wlr_output_layout_create(server.display);
  // Names and layout boxes for clients that capture an output (grim,
  // the screenshot portal's peers). Without this, screencopy has pixels
  // but no idea which output they belong to.
  wlr_xdg_output_manager_v1_create(server.display, server.output_layout);
  server.scene_layout =
      wlr_scene_attach_output_layout(server.scene, server.output_layout);

  // The desktop's own backdrop, first, so everything below is above it. A
  // picture that will not decode is reported and skipped rather than fatal:
  // an unplugged external drive should cost the user their wallpaper, not
  // their session.
  server.wallpaper.init(&server.scene->tree, server.output_layout);
  {
    std::string error;
    if (!server.wallpaper.apply(server.config.background, error)) {
      wlr_log(WLR_ERROR, "background: %s: %s",
              server.config.background.picture.c_str(), error.c_str());
      // Fall back to the colour, which is the half of the setting that cannot
      // fail, rather than to the built-in default — the user chose that colour
      // too, and it is very likely the one the picture was picked to match.
      lava::BackgroundConfig solid = server.config.background;
      solid.mode = "solid";
      solid.picture.clear();
      server.wallpaper.apply(solid, error);
    }
  }

  // After the background and before anything else: the trees created here are
  // siblings above it, and the panel tree created last inside `init` is above
  // them. Every window in the compositor lives in one of these.
  server.workspaces.init(&server.scene->tree);

  server.new_output.attach(&server.backend->events.new_output, &server,
                           Server::on_new_output);

  // xdg-shell: how ordinary applications get a window.
  // Version 5 is `wm_capabilities` — maximize / fullscreen / minimize —
  // which we now implement. Below that a client is allowed to assume we
  // cannot fullscreen, and a call to `set_wm_capabilities` asserts.
  // How grim and similar tools read the framebuffer. Print Screen and
  // the in-process portal do not use this — they render the scene
  // themselves — but the protocol is cheap to advertise.
  wlr_screencopy_manager_v1_create(server.display);

  server.xdg_shell = wlr_xdg_shell_create(server.display, 5);
  server.new_toplevel.attach(&server.xdg_shell->events.new_toplevel, &server,
                             Server::on_new_toplevel);
  server.new_popup.attach(&server.xdg_shell->events.new_popup, &server,
                          Server::on_new_popup);

  // KDE AppMenu: foreign Wayland clients export dbusmenu coordinates here.
  // Before any client can bind, and before surfaces exist so the change
  // callback can resolve a surface to a frame.
  server.appmenu.init(server.display);

  // Server-side decorations, so a window drawn by this compositor is not also
  // drawn by its toolkit. Clients that do not speak this protocol still draw
  // their own — there is no way to stop them, which is the one real cost of
  // decorating from outside.
  server.decorations = wlr_xdg_decoration_manager_v1_create(server.display);
  server.new_decoration.attach(
      &server.decorations->events.new_toplevel_decoration, &server,
      Server::on_new_decoration);

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
  server.relativePointers =
      wlr_relative_pointer_manager_v1_create(server.display);
  server.pointerConstraints =
      wlr_pointer_constraints_v1_create(server.display);
  if (server.relativePointers == nullptr ||
      server.pointerConstraints == nullptr) {
    wlr_log(WLR_ERROR, "relative pointer protocols unavailable");
  }
  if (server.pointerConstraints != nullptr) {
    server.new_pointer_constraint.attach(
        &server.pointerConstraints->events.new_constraint, &server,
        Server::on_new_pointer_constraint);
  }
  server.pointer_focus_change.attach(
      &server.seat->pointer_state.events.focus_change, &server,
      Server::on_pointer_focus_change);
  server.new_input.attach(&server.backend->events.new_input, &server,
                          Server::on_new_input);
  server.request_cursor.attach(&server.seat->events.request_set_cursor, &server,
                               Server::on_request_cursor);
  server.request_set_selection.attach(&server.seat->events.request_set_selection,
                                      &server,
                                      Server::on_request_set_selection);
  server.set_selection.attach(&server.seat->events.set_selection, &server,
                              Server::on_set_selection);
  server.request_set_primary_selection.attach(
      &server.seat->events.request_set_primary_selection, &server,
      Server::on_request_set_primary_selection);
  // Drag and drop. Both halves: one decides whether a drag may start, the
  // other gives what is being dragged somewhere to be drawn.
  server.request_start_drag.attach(&server.seat->events.request_start_drag,
                                   &server, Server::on_request_start_drag);
  server.start_drag.attach(&server.seat->events.start_drag, &server,
                           Server::on_start_drag);

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
  auto canvas_renderer = lava::CanvasRenderer::create(
      server.renderer, static_cast<uint32_t>(server.config.render.msaa));
  SurfaceRegistry surfaces;
  surfaces.bind(canvas_renderer.get(), &server.workspaces);
  surfaces.bind(&server);
  server.surfaces = &surfaces;
  // Late AppMenu addresses (Qt often set_address after map) re-notify the
  // panel only when the surface that changed is the focused one.
  server.appmenu.setOnChanged(
      [&surfaces](wlr_surface *surface) { surfaces.onAppMenuChanged(surface); });
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
  surfaces.setAppearance(
      static_cast<float>(server.config.appearance.cornerRadius),
      static_cast<float>(server.config.appearance.shadowBlur),
      server.config.appearance.shadowOpacity,
      static_cast<float>(server.config.appearance.shadowOffsetY));
  surfaces.start(wl_display_get_event_loop(server.display));

  // Before the control plane, not after it: the socket's name is what tells
  // one session from another, and the control plane publishes its reference
  // under that name. Binding it here costs nothing, because the event loop
  // does not run until `wl_display_run` far below — no client can connect in
  // between, whatever it finds in the environment.
  const char *socket = wl_display_add_socket_auto(server.display);
  if (!socket) {
    std::cerr << "Could not create a Wayland socket\n";
    wl_display_destroy(server.display);
    return EXIT_FAILURE;
  }
  // Clients find the compositor through the environment, so a terminal
  // launched from here inherits the right socket — and, since the reference
  // is named after it, the right control plane — without being told either.
  setenv("WAYLAND_DISPLAY", socket, 1);

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

  // `kill -USR2` dumps the GPU report. Worth a signal of its own rather than
  // only a periodic one: the periodic dump rides the output frame, and a desktop
  // with nothing animating on it produces no frames — so the moment you most
  // want to know what is holding 1.4 GB is the moment the timer stops firing.
  wl_event_loop_add_signal(
      wl_display_get_event_loop(server.display), SIGUSR2,
      [](int, void *data) {
        auto *server = static_cast<Server *>(data);
        if (server->surfaces == nullptr) return 0;
        canvas::printGpuReport(server->surfaces->gpuReport(), std::cerr,
                               /*verbose=*/true);
        return 0;
      },
      &server);

  // `kill` and Ctrl+C leave through the same door the compositor's own quit
  // binding uses: stop the loop, then unwind. See the mask in `main`.
  for (const int signal : {SIGTERM, SIGINT}) {
    wl_event_loop_add_signal(
        wl_display_get_event_loop(server.display), signal,
        [](int number, void *data) {
          wlr_log(WLR_INFO, "shutting down on signal %d", number);
          lava::arm_shutdown_watchdog();
          wl_display_terminate(static_cast<wl_display *>(data));
          return 0;
        },
        server.display);
  }

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

  if (!wlr_backend_start(server.backend)) {
    std::cerr << "Could not start compositor backend\n";
    wl_display_destroy(server.display);
    return EXIT_FAILURE;
  }

  // The desktop's own parts, last: they are clients, and everything a client
  // needs — the socket above, the control plane, an output to be laid out
  // against — exists by now. Started here rather than by a session manager
  // because they are not a choice (see `shell.hpp`).
  lava::ShellSupervisor shell;
  surfaces.bind(&shell);
  if (server.config.shell.enabled && std::getenv("LAVA_NO_SHELL") == nullptr) {
    std::vector<lava::ShellComponent> components;
    const auto want = [](const std::string &program) {
      return !program.empty() && program != "off" && program != "none";
    };
    if (want(server.config.shell.panel)) {
      components.push_back({"panel", server.config.shell.panel, {}});
    }
    if (want(server.config.shell.dock)) {
      components.push_back({"dock", server.config.shell.dock, {}});
    }
    shell.start(wl_display_get_event_loop(server.display), std::move(components));
  } else {
    wlr_log(WLR_INFO, "shell: not starting anything (disabled)");
  }

  // The user's own programs, after the desktop's: the socket is in the
  // environment, the control plane is listening, and the panel is on its way.
  //
  // On its way is enough. An applet that starts before the tray exists is not
  // a lost applet — a StatusNotifierItem re-registers when the watcher
  // appears, which is what happens a moment later when the panel finishes
  // coming up. Waiting for the panel would mean inventing a signal for
  // "ready" that nothing else needs.
  // After the socket exists. A nested compositor claims a .test name
  // so it cannot steal the session's Screenshot impl or restart the
  // user's xdg-desktop-portal — that restart, done synchronously, is
  // what locked the last session: the portal came back, asked us for
  // a shot, and we were still inside `system()`.
  {
    lava::ScreenshotPortal::Options opts;
    if (nested) {
      opts.busName = "org.freedesktop.impl.portal.desktop.lava.test";
      opts.claimDesktop = false;
    }
    server.screenshotPortal = std::make_unique<lava::ScreenshotPortal>();
    if (!server.screenshotPortal->start(
            wl_display_get_event_loop(server.display),
            [&server]() { return server.schedulePortalCapture(); }, opts)) {
      server.screenshotPortal.reset();
    }
  }

  if (nested) {
    wlr_log(WLR_INFO, "autostart: skipped, this session is nested");
  } else if (server.config.shell.enabled &&
             std::getenv("LAVA_NO_SHELL") == nullptr &&
             std::getenv("LAVA_NO_AUTOSTART") == nullptr) {
    run_autostart();
  }

  std::cout << "Compositor running on WAYLAND_DISPLAY=" << socket << '\n';
  wl_display_run(server.display);
  // While the windows are still there: a SIGTERM must not forget where
  // they sat just because nobody closed them first.
  surfaces.flushPlacements();
  // Before the clients are destroyed: they are our children, and a component
  // told to go while its socket still works exits cleanly rather than dying of
  // a broken connection.
  shell.stop();
  // The bus watch lives on this display's loop.
  server.screenshotPortal.reset();
  wl_display_destroy_clients(server.display);
  // Then the control plane, before the display it publishes a way into: a
  // client that reads the reference after this point gets nothing, which is
  // the truth, rather than an endpoint that answers until it does not.
  if (control) {
    surfaces.bind(static_cast<lava::ControlPlane *>(nullptr));
    server.control = nullptr;
    control.reset();
  }
  server.detachListeners();
  // The backend by hand, before the display rather than with it.
  //
  // `wl_display_destroy` tears down its globals first and its event loop
  // second, and the backend hangs off the loop — so every output and input
  // device is destroyed *after* the seat they belong to. The compositor's own
  // handlers run in that window: a keyboard going away recomputes the seat's
  // capabilities, and by then `wlr_seat_set_capabilities` is reading freed
  // memory. Destroying the backend here runs those handlers while the seat,
  // the scene and the output layout are all still there, which is the order
  // they were written for.
  //
  // Only reachable at all since SIGTERM stopped killing the process outright,
  // which is why it survived this long: the quit binding hit it, and quitting
  // by keyboard is not what anyone does to a compositor that is their session.
  wlr_backend_destroy(server.backend);
  wl_display_destroy(server.display);
  return EXIT_SUCCESS;
}
