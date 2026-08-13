#pragma once

#include <cstdint>
#include <string>
#include <vector>

#include "config.hpp"
#include "wlr.hpp"

namespace lava {

/// The desktop's backdrop: a colour, and optionally a picture over it.
///
/// Lives at the very bottom of the scene, in a tree of its own created before
/// anything else. That tree is what makes the z-order safe: a picture applied
/// an hour into the session is added *inside* it rather than at the top of the
/// scene, so it cannot land above the windows it is supposed to be behind.
/// Without it, "set a wallpaper" and "cover every window with a photograph"
/// would be the same operation.
///
/// The colour is a scene rect spanning the whole layout and the picture is one
/// scene buffer per screen, above the rect. Both exist in `picture` mode: the
/// rect is what shows through the letterbox bars under `fit`, around the edges
/// under `center`, and across a screen that has appeared but not yet been
/// fitted. There is no arrangement in which the desktop has nothing to paint.
///
/// Fitting is done on the CPU, once per screen per change, rather than by
/// handing the scene a source box and letting the GPU sample it. Two reasons:
/// each screen gets pixels scaled for *its* size and scale factor, which is
/// what `fill` and `fit` mean on a desk with two different monitors on it; and
/// a buffer that exactly matches its screen is one the compositor can hand
/// straight to the display, rather than one it must resample every frame.
class Background {
 public:
  Background() = default;
  ~Background();

  Background(const Background &)            = delete;
  Background &operator=(const Background &) = delete;

  /// Builds the backdrop tree under `parent`.
  ///
  /// Must be called before any other tree is created under `parent`, because
  /// scene children are ordered by creation and this one has to be lowest.
  void init(wlr_scene_tree *parent, wlr_output_layout *layout);

  /// Puts `config` on screen.
  ///
  /// The picture is decoded first, so a failure changes nothing: false with
  /// `outError` filled means the previous background is still up, and the
  /// caller has not lost the setting that was working. Re-reads the file even
  /// when the path has not changed, which is what makes "I edited the picture"
  /// work without a restart.
  bool apply(const BackgroundConfig &config, std::string &outError);

  /// What is actually on screen, which after a refused `apply` is the older
  /// config rather than the one that was asked for.
  const BackgroundConfig &config() const { return config_; }

  /// Re-fits every screen to the picture. Cheap and idempotent when there is
  /// no picture. Called for layout changes; safe to call at any time.
  void refit();

 private:
  /// One screen's fitted copy of the picture.
  struct Panel {
    wlr_output *output      = nullptr;
    wlr_scene_buffer *node  = nullptr;
    /// What the pixels currently in `node` were fitted to. Refitting a screen
    /// whose size, position, scale and fit mode are all unchanged would be a
    /// full rescale to produce the bytes already on screen, and a layout
    /// change on one monitor fires the change event for all of them.
    int32_t x = 0, y = 0, width = 0, height = 0;
    float scale = 0.f;
    std::string fit;
  };

  void stopListening();
  void clearPanels();
  void applyColor();
  /// Rebuilds one screen's buffer. No-op when nothing about it moved.
  void fitPanel(Panel &panel, wlr_output_layout_output *layout_output);
  Panel *panelFor(wlr_output *output);

  static void on_layout_change(wl_listener *listener, void *data);
  static void on_layout_destroy(wl_listener *listener, void *data);

  wlr_scene_tree *tree_       = nullptr;
  wlr_scene_rect *rect_       = nullptr;
  wlr_output_layout *layout_  = nullptr;
  wl_listener layout_change_  = {};
  /// The layout is destroyed with the display, and this object outlives that:
  /// it is a member of the server struct, which is a local in `main` and is
  /// destructed *after* `wl_display_destroy`. Without this the destructor
  /// would `wl_list_remove` a listener whose signal has already been freed,
  /// writing through a dangling pointer on every clean exit.
  wl_listener layout_destroy_ = {};
  bool listening_             = false;

  BackgroundConfig config_;

  /// The decoded picture, RGBA8, straight from the file at its own size.
  /// Empty in `solid` mode. Held so a screen appearing later can be fitted
  /// without going back to disk.
  std::vector<uint8_t> image_;
  int32_t imageWidth_  = 0;
  int32_t imageHeight_ = 0;

  std::vector<Panel> panels_;
};

}  // namespace lava
