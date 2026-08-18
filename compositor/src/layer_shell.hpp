#pragma once

// Server half of `zwlr_layer_shell_v1`: bars, docks, wallpapers and
// notification daemons written for wlroots compositors — waybar, eww,
// swaybg, swaync.
//
// Not a replacement for `CreatePanel`. The Lava protocol reserves screen
// edges too, but it also carries the things a foreign client has no way to
// say (`SubscribePanelArea`, the appmenu link), and the desktop's own shell
// keeps speaking it. This is for clients that were never going to.
//
// **Stage 1 does not implement keyboard interactivity.** Every layer
// surface is treated as `keyboard_interactivity: none`, whatever it asked
// for. Bars and wallpapers never wanted the keyboard; rofi, wofi and slurp
// do, and giving it to them means a third kind of thing in a focus model
// that currently knows about exactly two (a `ClientSurface` and a
// `FramedWindow`). That is its own change.

#include <cstdint>
#include <functional>
#include <memory>

struct wl_display;
struct wlr_box;
struct wlr_output;
struct wlr_output_layout;
struct wlr_scene_tree;
struct wlr_surface;

namespace lava {

/// The four layers, their surfaces, and the exclusive-zone arithmetic.
///
/// Owns nothing the compositor owns: the scene trees are created by the
/// caller (their order among the workspace trees is what puts a bar above a
/// window and a wallpaper below one) and handed here.
class LayerShell {
 public:
  /// One tree per layer, in layout space — not one set per output. The
  /// scene is a single layout-space graph and a layer surface is placed by
  /// its own output's box, so per-output trees would buy nothing but
  /// bookkeeping. The same shape the desktop's own `panels` tree has.
  struct Trees {
    wlr_scene_tree *background = nullptr;
    wlr_scene_tree *bottom = nullptr;
    wlr_scene_tree *top = nullptr;
    wlr_scene_tree *overlay = nullptr;
  };

  /// A surface reserved, released or resized an exclusive zone: whatever is
  /// laid out against the work area has to be laid out again.
  using Changed = std::function<void()>;

  LayerShell();
  ~LayerShell();

  LayerShell(const LayerShell &) = delete;
  LayerShell &operator=(const LayerShell &) = delete;

  /// Advertises the global. False if the protocol could not be created, in
  /// which case nothing else here does anything and the desktop comes up
  /// without layer-shell rather than not at all.
  bool init(wl_display *display, const Trees &trees, wlr_output_layout *layout,
            Changed onUsableAreaChanged);

  /// Re-runs anchors, margins and exclusive zones for every surface.
  ///
  /// Cheap and idempotent: call it whenever an output moves or resizes.
  void arrange();

  /// What is left of the output under `(x, y)` once the bars have taken
  /// their strips. False when no output is there, or when this compositor
  /// has no layer surfaces reserving anything on it — the caller then keeps
  /// the box it already had.
  bool usableArea(int x, int y, wlr_box &out) const;

  /// A fullscreen window covers the top layer. Not the overlay: a
  /// notification or a lock screen is the one thing that outranks a game.
  void setTopVisible(bool visible);

  /// The output is going away. The protocol makes closing its surfaces the
  /// compositor's job — a client left pointing at a dead output would never
  /// hear that it should re-create itself somewhere else.
  void closeOn(wlr_output *output);

  /// The scene tree of the layer surface `surface` belongs to, for
  /// parenting an `xdg_popup`. Null when it is not a layer surface — which
  /// is the common case, and the caller's cue to try xdg-shell instead.
  wlr_scene_tree *treeFor(wlr_surface *surface) const;

  struct Impl;

 private:
  std::unique_ptr<Impl> impl_;
};

}  // namespace lava
