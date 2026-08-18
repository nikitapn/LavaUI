#include "layer_shell.hpp"

#include "wlr.hpp"

#include <array>
#include <vector>

namespace lava {
namespace {

/// Arrangement order, and it is not the drawing order.
///
/// Exclusive zones accumulate: a bar anchored to the top takes its strip out
/// of what is left for everything under it, so the surface that reserves
/// first wins the space. Overlay downwards is the order every wlroots
/// compositor settled on, and a client that reserves nothing is laid out
/// last against whatever survived — see `arrange`.
constexpr std::array<zwlr_layer_shell_v1_layer, 4> kArrangeOrder = {
    ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY,
    ZWLR_LAYER_SHELL_V1_LAYER_TOP,
    ZWLR_LAYER_SHELL_V1_LAYER_BOTTOM,
    ZWLR_LAYER_SHELL_V1_LAYER_BACKGROUND,
};

bool boxContains(const wlr_box &box, int x, int y) {
  return x >= box.x && y >= box.y && x < box.x + box.width &&
         y < box.y + box.height;
}

bool sameBox(const wlr_box &a, const wlr_box &b) {
  return a.x == b.x && a.y == b.y && a.width == b.width && a.height == b.height;
}

}  // namespace

struct LayerShell::Impl {
  /// One mapped-or-not layer surface.
  ///
  /// Self-owned, like the other shell objects in this compositor: it goes
  /// when the client's surface does.
  struct Surface {
    /// Each listener is a struct whose *first* member is the `wl_listener`,
    /// so the cast back from `wl_listener *` is well-defined — the pattern
    /// `Listener<T>` uses in main.cpp and `AppMenuManager` repeats here,
    /// because `offsetof` through a non-standard-layout type is not.
    template <typename Tag>
    struct Hook {
      wl_listener listener{};
      Surface *owner = nullptr;
    };

    Hook<struct MapTag> map;
    Hook<struct UnmapTag> unmap;
    Hook<struct CommitTag> commit;
    Hook<struct DestroyTag> destroy;

    wlr_layer_surface_v1 *layer = nullptr;
    wlr_scene_layer_surface_v1 *scene = nullptr;
    Impl *shell = nullptr;
    /// What it was in last, so a client that moves between layers gets its
    /// tree reparented rather than drawn in the wrong order forever.
    zwlr_layer_shell_v1_layer currentLayer = ZWLR_LAYER_SHELL_V1_LAYER_BACKGROUND;
  };

  wlr_layer_shell_v1 *shell = nullptr;
  Trees trees;
  wlr_output_layout *layout = nullptr;
  Changed onChanged;
  std::vector<Surface *> surfaces;

  /// The work area each output has left, recomputed by `arrange`. Kept as a
  /// list rather than a map because a desk has two or three screens and the
  /// lookup is on every window placement.
  struct Usable {
    wlr_output *output = nullptr;
    wlr_box full{};
    wlr_box usable{};
  };
  std::vector<Usable> usable;

  struct {
    wl_listener listener{};
    Impl *owner = nullptr;
  } newSurface;

  wlr_scene_tree *treeForLayer(zwlr_layer_shell_v1_layer layer) const {
    switch (layer) {
      case ZWLR_LAYER_SHELL_V1_LAYER_BACKGROUND: return trees.background;
      case ZWLR_LAYER_SHELL_V1_LAYER_BOTTOM: return trees.bottom;
      case ZWLR_LAYER_SHELL_V1_LAYER_TOP: return trees.top;
      case ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY: return trees.overlay;
    }
    return trees.background;
  }

  /// Any output, for a client that did not name one. The protocol says
  /// picking is the compositor's job, and the first in the layout is the
  /// same one `wlr_output_layout` calls the origin.
  wlr_output *anyOutput() const {
    if (layout == nullptr) return nullptr;
    wlr_output_layout_output *entry = nullptr;
    wl_list_for_each(entry, &layout->outputs, link) { return entry->output; }
    return nullptr;
  }

  void arrange();

  static void on_new_surface(wl_listener *listener, void *data);
  static void on_map(wl_listener *listener, void *);
  static void on_unmap(wl_listener *listener, void *);
  static void on_commit(wl_listener *listener, void *);
  static void on_destroy(wl_listener *listener, void *);
};

void LayerShell::Impl::arrange() {
  if (layout == nullptr) return;

  std::vector<Usable> next;
  wlr_output_layout_output *entry = nullptr;
  wl_list_for_each(entry, &layout->outputs, link) {
    wlr_output *output = entry->output;
    wlr_box full{};
    wlr_output_layout_get_box(layout, output, &full);
    if (full.width <= 0 || full.height <= 0) continue;

    wlr_box remaining = full;
    // Two passes: everything that reserves a strip, then everything that
    // does not. A notification that anchors to the top edge must not be
    // pushed down by a bar it drew over — and a bar must not be pushed
    // down by a notification that happens to have mapped first.
    for (const bool exclusivePass : {true, false}) {
      for (const zwlr_layer_shell_v1_layer layer : kArrangeOrder) {
        for (Surface *s : surfaces) {
          if (s->layer->output != output) continue;
          if (s->layer->current.layer != layer) continue;
          if ((s->layer->current.exclusive_zone > 0) != exclusivePass) continue;
          // Before the client has acked anything there is nothing to
          // configure against; the initial commit brings us back here.
          if (!s->layer->initialized) continue;
          wlr_scene_layer_surface_v1_configure(s->scene, &full, &remaining);
        }
      }
    }
    next.push_back(Usable{output, full, remaining});
  }

  bool changed = next.size() != usable.size();
  for (size_t i = 0; !changed && i < next.size(); ++i) {
    changed = next[i].output != usable[i].output ||
              !sameBox(next[i].usable, usable[i].usable);
  }
  usable = std::move(next);
  // Only when it moved: `arrange` runs on every commit of every bar, and a
  // clock that repaints once a second must not relayout every window on the
  // desktop with it.
  if (changed && onChanged) onChanged();
}

void LayerShell::Impl::on_new_surface(wl_listener *listener, void *data) {
  auto *wrap = reinterpret_cast<decltype(Impl::newSurface) *>(listener);
  Impl *self = wrap->owner;
  auto *layer = static_cast<wlr_layer_surface_v1 *>(data);

  // "Note: the output may be NULL. In this case, it is your responsibility
  // to assign an output before returning." A client that names no output is
  // asking for the obvious one.
  if (layer->output == nullptr) {
    layer->output = self->anyOutput();
    if (layer->output == nullptr) {
      wlr_log(WLR_ERROR, "layer-shell: '%s' wants a screen and there is none",
              layer->namespace_ ? layer->namespace_ : "?");
      wlr_layer_surface_v1_destroy(layer);
      return;
    }
  }

  auto *surface = new Surface();
  surface->layer = layer;
  surface->shell = self;
  surface->currentLayer = layer->pending.layer;
  surface->scene = wlr_scene_layer_surface_v1_create(
      self->treeForLayer(layer->pending.layer), layer);
  if (surface->scene == nullptr) {
    delete surface;
    wlr_layer_surface_v1_destroy(layer);
    return;
  }

  // The scene tree goes on the *layer surface*, not on `tree->node.data`.
  // `Server::surface_at` walks tree ancestors for the first non-null
  // `node.data` and casts it to `FramedWindow *`; a layer tree that filled
  // that field in would be a type confusion on every pointer motion over a
  // bar. Popup parenting reads it back through `treeFor`.
  layer->data = surface->scene->tree;

  surface->map.owner = surface;
  surface->map.listener.notify = on_map;
  wl_signal_add(&layer->surface->events.map, &surface->map.listener);
  surface->unmap.owner = surface;
  surface->unmap.listener.notify = on_unmap;
  wl_signal_add(&layer->surface->events.unmap, &surface->unmap.listener);
  surface->commit.owner = surface;
  surface->commit.listener.notify = on_commit;
  wl_signal_add(&layer->surface->events.commit, &surface->commit.listener);
  surface->destroy.owner = surface;
  surface->destroy.listener.notify = on_destroy;
  wl_signal_add(&layer->events.destroy, &surface->destroy.listener);

  self->surfaces.push_back(surface);
  wlr_log(WLR_INFO, "layer-shell: '%s' on %s, layer %u",
          layer->namespace_ ? layer->namespace_ : "?",
          layer->output->name ? layer->output->name : "?",
          static_cast<unsigned>(layer->pending.layer));
}

void LayerShell::Impl::on_map(wl_listener *listener, void *) {
  auto *wrap = reinterpret_cast<Surface::Hook<struct MapTag> *>(listener);
  wrap->owner->shell->arrange();
}

void LayerShell::Impl::on_unmap(wl_listener *listener, void *) {
  auto *wrap = reinterpret_cast<Surface::Hook<struct UnmapTag> *>(listener);
  // The strip it reserved is free again, and whatever was maximized around
  // it should grow back into the space.
  wrap->owner->shell->arrange();
}

void LayerShell::Impl::on_commit(wl_listener *listener, void *) {
  auto *wrap = reinterpret_cast<Surface::Hook<struct CommitTag> *>(listener);
  Surface *self = wrap->owner;
  wlr_layer_surface_v1 *layer = self->layer;

  // A client may move itself between layers while mapped — a bar that goes
  // "always on top" is exactly that. The scene tree has to follow, or it
  // keeps drawing in the order it had when it opened.
  if (layer->current.layer != self->currentLayer) {
    self->currentLayer = layer->current.layer;
    wlr_scene_node_reparent(&self->scene->tree->node,
                            self->shell->treeForLayer(self->currentLayer));
  }

  // The initial commit is the one that has to be answered: a layer surface
  // that is never configured never maps, which looks like a bar that did
  // not start. After that, only a commit that touched the geometry is
  // worth re-arranging for.
  constexpr uint32_t kLayoutFields =
      WLR_LAYER_SURFACE_V1_STATE_DESIRED_SIZE |
      WLR_LAYER_SURFACE_V1_STATE_ANCHOR |
      WLR_LAYER_SURFACE_V1_STATE_EXCLUSIVE_ZONE |
      WLR_LAYER_SURFACE_V1_STATE_MARGIN |
      WLR_LAYER_SURFACE_V1_STATE_LAYER |
      WLR_LAYER_SURFACE_V1_STATE_EXCLUSIVE_EDGE;
  if (layer->initial_commit || (layer->current.committed & kLayoutFields) != 0) {
    self->shell->arrange();
  }
}

void LayerShell::Impl::on_destroy(wl_listener *listener, void *) {
  auto *wrap = reinterpret_cast<Surface::Hook<struct DestroyTag> *>(listener);
  Surface *self = wrap->owner;
  Impl *shell = self->shell;

  wl_list_remove(&self->map.listener.link);
  wl_list_remove(&self->unmap.listener.link);
  wl_list_remove(&self->commit.listener.link);
  wl_list_remove(&self->destroy.listener.link);
  self->layer->data = nullptr;

  for (auto it = shell->surfaces.begin(); it != shell->surfaces.end(); ++it) {
    if (*it == self) {
      shell->surfaces.erase(it);
      break;
    }
  }
  delete self;
  // The scene tree is torn down by `wlr_scene_layer_surface_v1` itself.
  shell->arrange();
}

LayerShell::LayerShell() : impl_(std::make_unique<Impl>()) {}
LayerShell::~LayerShell() = default;

bool LayerShell::init(wl_display *display, const Trees &trees,
                      wlr_output_layout *layout, Changed onUsableAreaChanged) {
  if (display == nullptr || layout == nullptr) return false;
  if (trees.background == nullptr || trees.bottom == nullptr ||
      trees.top == nullptr || trees.overlay == nullptr) {
    return false;
  }
  // Version 4 is `exclusive_edge`, which is what lets a bar anchored to
  // three edges say which one it is reserving against.
  impl_->shell = wlr_layer_shell_v1_create(display, 4);
  if (impl_->shell == nullptr) return false;

  impl_->trees = trees;
  impl_->layout = layout;
  impl_->onChanged = std::move(onUsableAreaChanged);
  impl_->newSurface.owner = impl_.get();
  impl_->newSurface.listener.notify = Impl::on_new_surface;
  wl_signal_add(&impl_->shell->events.new_surface, &impl_->newSurface.listener);
  wlr_log(WLR_INFO, "layer-shell: zwlr_layer_shell_v1 v4");
  return true;
}

void LayerShell::arrange() {
  if (impl_->shell != nullptr) impl_->arrange();
}

bool LayerShell::usableArea(int x, int y, wlr_box &out) const {
  for (const auto &entry : impl_->usable) {
    if (!boxContains(entry.full, x, y)) continue;
    // Nothing reserved anything here: say so rather than handing back a box
    // identical to the one the caller already has.
    if (sameBox(entry.usable, entry.full)) return false;
    out = entry.usable;
    return true;
  }
  return false;
}

void LayerShell::setTopVisible(bool visible) {
  if (impl_->trees.top == nullptr) return;
  wlr_scene_node_set_enabled(&impl_->trees.top->node, visible);
}

void LayerShell::closeOn(wlr_output *output) {
  if (output == nullptr) return;
  // Collected first: `wlr_layer_surface_v1_destroy` runs our destroy
  // handler, which erases from the very vector we would be walking.
  std::vector<wlr_layer_surface_v1 *> doomed;
  for (Impl::Surface *s : impl_->surfaces) {
    if (s->layer->output == output) doomed.push_back(s->layer);
  }
  for (wlr_layer_surface_v1 *layer : doomed) {
    wlr_layer_surface_v1_destroy(layer);
  }
}

wlr_scene_tree *LayerShell::treeFor(wlr_surface *surface) const {
  if (surface == nullptr) return nullptr;
  wlr_layer_surface_v1 *layer =
      wlr_layer_surface_v1_try_from_wlr_surface(surface);
  if (layer == nullptr) return nullptr;
  return static_cast<wlr_scene_tree *>(layer->data);
}

}  // namespace lava
