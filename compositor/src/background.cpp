#include "background.hpp"

#include <algorithm>
#include <cmath>
#include <cstring>

#include <drm_fourcc.h>

#include <stb_image.h>
#include <stb_image_resize2.h>

namespace lava {
namespace {

// ─── wlr_buffer wrapper ────────────────────────────────────────────────────
//
// A plain block of RGBA the scene can sample. Unlike the dmabuf in
// `canvas_surface.cpp` there is nothing shared here and no GPU on the other
// end of it: the wallpaper is scaled once on the CPU and then read by whatever
// renderer wlroots picked, which is what `begin_data_ptr_access` is for.

struct PixelBuffer {
  wlr_buffer base{};
  std::vector<uint8_t> data;
  size_t stride = 0;
};

PixelBuffer *from_buffer(wlr_buffer *buffer) {
  return reinterpret_cast<PixelBuffer *>(buffer);
}

void buffer_destroy(wlr_buffer *buffer) { delete from_buffer(buffer); }

bool buffer_begin_data_ptr_access(wlr_buffer *buffer, uint32_t flags,
                                  void **data, uint32_t *format,
                                  size_t *stride) {
  // Read-only on purpose. Nothing should be drawing into the wallpaper, and
  // saying so is cheaper than discovering that something did.
  if ((flags & WLR_BUFFER_DATA_PTR_ACCESS_WRITE) != 0) return false;
  PixelBuffer *self = from_buffer(buffer);
  *data   = self->data.data();
  // Byte order R,G,B,A — which as a little-endian word is A<<24|B<<16|G<<8|R,
  // and DRM spells that ABGR8888. The name reads backwards from the memory
  // layout, and picking the one that *looks* right gives blue skies in red.
  *format = DRM_FORMAT_ABGR8888;
  *stride = self->stride;
  return true;
}

void buffer_end_data_ptr_access(wlr_buffer *) {}

const wlr_buffer_impl kPixelBufferImpl = {
    .destroy                = buffer_destroy,
    .get_dmabuf             = nullptr,
    .get_shm                = nullptr,
    .begin_data_ptr_access  = buffer_begin_data_ptr_access,
    .end_data_ptr_access    = buffer_end_data_ptr_access,
};

/// A buffer of `width`×`height` filled with opaque `color` (`0x00RRGGBB`).
PixelBuffer *make_buffer(int32_t width, int32_t height, uint32_t color) {
  auto *self   = new PixelBuffer();
  self->stride = static_cast<size_t>(width) * 4;
  self->data.resize(self->stride * static_cast<size_t>(height));

  const uint8_t rgba[4] = {
      static_cast<uint8_t>((color >> 16) & 0xff),
      static_cast<uint8_t>((color >> 8) & 0xff),
      static_cast<uint8_t>(color & 0xff),
      0xff,
  };
  for (size_t i = 0; i < self->data.size(); i += 4) {
    std::memcpy(self->data.data() + i, rgba, 4);
  }

  wlr_buffer_init(&self->base, &kPixelBufferImpl, width, height);
  return self;
}

/// Where the picture goes on one screen, in that screen's own pixels.
struct Placement {
  int32_t srcX = 0, srcY = 0, srcW = 0, srcH = 0;
  int32_t dstX = 0, dstY = 0, dstW = 0, dstH = 0;
};

/// Works out the crop and the target rect for one fit mode.
///
/// All four modes are the same two rectangles with different arithmetic, which
/// is why they share a function: `fill` crops the source and uses the whole
/// screen, `fit` uses the whole source and part of the screen, `stretch` uses
/// all of both, and `center` uses whichever of the two is smaller at 1:1.
Placement placement_for(const std::string &fit, int32_t iw, int32_t ih,
                        int32_t pw, int32_t ph) {
  Placement out;
  out.srcW = iw;
  out.srcH = ih;
  out.dstW = pw;
  out.dstH = ph;

  // Compared as products rather than ratios: `iw/ih > pw/ph` in integers is
  // two truncating divisions and gets 16:9 against 16:10 wrong.
  const bool wider = static_cast<int64_t>(iw) * ph > static_cast<int64_t>(pw) * ih;

  if (fit == "stretch") {
    return out;
  }

  if (fit == "center") {
    // No resampling at all — this mode exists for people who do not want
    // their picture touched. 1:1 against the screen's *device* pixels, so on
    // a 2× display a 1920×1080 picture covers a quarter of a 4K panel, which
    // is what "do not scale it" has to mean if it means anything.
    out.srcW = out.dstW = std::min(iw, pw);
    out.srcH = out.dstH = std::min(ih, ph);
  } else if (fit == "fit") {
    // Contain: the whole picture, letterboxed against the colour.
    if (wider) {
      out.dstW = pw;
      out.dstH = static_cast<int32_t>(static_cast<int64_t>(ih) * pw / iw);
    } else {
      out.dstH = ph;
      out.dstW = static_cast<int32_t>(static_cast<int64_t>(iw) * ph / ih);
    }
  } else {
    // Cover: fills the screen, and the overflowing axis is cropped evenly.
    if (wider) {
      out.srcW = static_cast<int32_t>(static_cast<int64_t>(ih) * pw / ph);
    } else {
      out.srcH = static_cast<int32_t>(static_cast<int64_t>(iw) * ph / pw);
    }
  }

  out.srcW = std::clamp(out.srcW, 1, iw);
  out.srcH = std::clamp(out.srcH, 1, ih);
  out.dstW = std::clamp(out.dstW, 1, pw);
  out.dstH = std::clamp(out.dstH, 1, ph);
  out.srcX = (iw - out.srcW) / 2;
  out.srcY = (ih - out.srcH) / 2;
  out.dstX = (pw - out.dstW) / 2;
  out.dstY = (ph - out.dstH) / 2;
  return out;
}

}  // namespace

// ─── Background ─────────────────────────────────────────────────────────────

Background::~Background() { stopListening(); }

void Background::stopListening() {
  if (!listening_) return;
  wl_list_remove(&layout_change_.link);
  wl_list_remove(&layout_destroy_.link);
  listening_ = false;
  layout_    = nullptr;
}

void Background::on_layout_destroy(wl_listener *listener, void *) {
  Background *self = wl_container_of(listener, self, layout_destroy_);
  // The scene nodes are not touched: they belong to the scene, which is torn
  // down on the same display destroy. Only the listeners are ours to unhook.
  self->stopListening();
  self->panels_.clear();
  self->tree_ = nullptr;
  self->rect_ = nullptr;
}

void Background::init(wlr_scene_tree *parent, wlr_output_layout *layout) {
  layout_ = layout;
  tree_   = wlr_scene_tree_create(parent);

  const float black[4] = {0.f, 0.f, 0.f, 1.f};
  rect_ = wlr_scene_rect_create(tree_, 8192, 8192, black);
  applyColor();

  // One hook for every way the arrangement of screens can change: a monitor
  // plugged in, unplugged, moved, rescaled or given a new mode. Refitting from
  // here rather than from each of those call sites is what keeps a wallpaper
  // correct on a screen that appeared long after it was set.
  if (layout_ != nullptr) {
    layout_change_.notify = on_layout_change;
    wl_signal_add(&layout_->events.change, &layout_change_);
    layout_destroy_.notify = on_layout_destroy;
    wl_signal_add(&layout_->events.destroy, &layout_destroy_);
    listening_ = true;
  }
  refit();
}

void Background::on_layout_change(wl_listener *listener, void *) {
  Background *self =
      wl_container_of(listener, self, layout_change_);
  self->refit();
}

void Background::applyColor() {
  if (rect_ == nullptr) return;
  const uint32_t color = config_.color;
  const float rgba[4] = {
      static_cast<float>((color >> 16) & 0xff) / 255.f,
      static_cast<float>((color >> 8) & 0xff) / 255.f,
      static_cast<float>(color & 0xff) / 255.f,
      1.f,
  };
  wlr_scene_rect_set_color(rect_, rgba);
}

bool Background::apply(const BackgroundConfig &config, std::string &outError) {
  BackgroundConfig wanted = config;
  wanted.mode = canonicalWallpaperMode(wanted.mode);
  wanted.fit  = canonicalWallpaperFit(wanted.fit);
  wanted.color &= 0x00ffffffu;

  std::vector<uint8_t> pixels;
  int32_t width = 0, height = 0;

  if (wanted.mode == "picture") {
    if (wanted.picture.empty()) {
      outError = "no picture was given";
      return false;
    }
    int w = 0, h = 0, channels = 0;
    // Forced to four channels so everything downstream — the fill, the
    // resize, the buffer format — has exactly one layout to handle.
    uint8_t *decoded = stbi_load(wanted.picture.c_str(), &w, &h, &channels, 4);
    if (decoded == nullptr) {
      const char *reason = stbi_failure_reason();
      outError = reason != nullptr ? reason : "not a picture this can read";
      return false;
    }
    if (w <= 0 || h <= 0) {
      stbi_image_free(decoded);
      outError = "the picture has no pixels";
      return false;
    }
    // Copied out of stb's allocation rather than adopted: this is held for the
    // life of the setting, and one `std::vector` is easier to be sure about
    // than a raw pointer with a `stbi_image_free` on every path out.
    pixels.assign(decoded, decoded + static_cast<size_t>(w) * h * 4);
    stbi_image_free(decoded);
    width  = w;
    height = h;
    // Opaque, whatever the file said. The desktop is the bottom of the scene,
    // so a transparent PNG would otherwise blend against uninitialised
    // darkness instead of against the colour underneath it.
    for (size_t i = 3; i < pixels.size(); i += 4) pixels[i] = 0xff;
  }

  // Past every way this could fail: from here nothing can refuse, so the
  // previous background is never half-replaced.
  config_      = wanted;
  image_       = std::move(pixels);
  imageWidth_  = width;
  imageHeight_ = height;

  applyColor();
  if (image_.empty()) clearPanels();
  // Every screen is refitted from scratch, so a new picture at the same size
  // as the old one still replaces it.
  for (Panel &panel : panels_) panel.width = 0;
  refit();
  return true;
}

void Background::clearPanels() {
  for (Panel &panel : panels_) {
    if (panel.node != nullptr) wlr_scene_node_destroy(&panel.node->node);
  }
  panels_.clear();
}

Background::Panel *Background::panelFor(wlr_output *output) {
  for (Panel &panel : panels_) {
    if (panel.output == output) return &panel;
  }
  panels_.push_back(Panel{});
  panels_.back().output = output;
  return &panels_.back();
}

void Background::refit() {
  if (tree_ == nullptr || layout_ == nullptr) return;

  // The colour has to reach past the screens, not just under them. A rect
  // sized to the layout leaves anything outside it — the gap between two
  // monitors that are not flush, a window dragged off the edge — showing
  // whatever was in the framebuffer.
  wlr_box extents{};
  wlr_output_layout_get_box(layout_, nullptr, &extents);
  if (rect_ != nullptr) {
    const int32_t margin = 4096;
    if (wlr_box_empty(&extents)) {
      wlr_scene_node_set_position(&rect_->node, -margin, -margin);
      wlr_scene_rect_set_size(rect_, 8192, 8192);
    } else {
      wlr_scene_node_set_position(&rect_->node, extents.x - margin,
                                  extents.y - margin);
      wlr_scene_rect_set_size(rect_, extents.width + margin * 2,
                              extents.height + margin * 2);
    }
  }

  if (image_.empty()) {
    clearPanels();
    return;
  }

  // Drop panels for screens that have gone. Done before fitting so a monitor
  // unplugged and replaced by another does not keep the first one's buffer.
  wlr_output_layout_output *layout_output = nullptr;
  std::vector<Panel> kept;
  kept.reserve(panels_.size());
  for (Panel &panel : panels_) {
    bool present = false;
    wl_list_for_each(layout_output, &layout_->outputs, link) {
      if (layout_output->output == panel.output) {
        present = true;
        break;
      }
    }
    if (present) {
      kept.push_back(panel);
    } else if (panel.node != nullptr) {
      wlr_scene_node_destroy(&panel.node->node);
    }
  }
  panels_ = std::move(kept);

  wl_list_for_each(layout_output, &layout_->outputs, link) {
    fitPanel(*panelFor(layout_output->output), layout_output);
  }
}

void Background::fitPanel(Panel &panel, wlr_output_layout_output *layout_output) {
  wlr_output *output = layout_output->output;
  wlr_box box{};
  wlr_output_layout_get_box(layout_, output, &box);
  if (box.width <= 0 || box.height <= 0) return;

  const float scale = output->scale > 0.f ? output->scale : 1.f;
  if (panel.node != nullptr && panel.width == box.width &&
      panel.height == box.height && panel.x == box.x && panel.y == box.y &&
      panel.scale == scale && panel.fit == config_.fit) {
    return;  // Nothing about this screen moved.
  }

  // The buffer is in device pixels and the node is sized in logical ones, so
  // a 2× screen gets a picture scaled for the panel it actually has rather
  // than one blown up from half the resolution.
  const int32_t pw = std::max(1, static_cast<int32_t>(std::lround(box.width * scale)));
  const int32_t ph = std::max(1, static_cast<int32_t>(std::lround(box.height * scale)));

  PixelBuffer *buffer = make_buffer(pw, ph, config_.color);
  const Placement at =
      placement_for(config_.fit, imageWidth_, imageHeight_, pw, ph);

  const size_t srcStride = static_cast<size_t>(imageWidth_) * 4;
  const uint8_t *src =
      image_.data() + static_cast<size_t>(at.srcY) * srcStride + static_cast<size_t>(at.srcX) * 4;
  uint8_t *dst = buffer->data.data() +
                 static_cast<size_t>(at.dstY) * buffer->stride +
                 static_cast<size_t>(at.dstX) * 4;

  if (at.srcW == at.dstW && at.srcH == at.dstH) {
    // `center`, or a picture that happens to be exactly the right size.
    for (int32_t row = 0; row < at.dstH; ++row) {
      std::memcpy(dst + static_cast<size_t>(row) * buffer->stride,
                  src + static_cast<size_t>(row) * srcStride,
                  static_cast<size_t>(at.dstW) * 4);
    }
  } else {
    // sRGB-aware, for the same reason the icon loader is: averaging encoded
    // bytes darkens every downscale, and a wallpaper is almost always a
    // downscale. RGBA rather than the premultiplied variant because the alpha
    // was forced opaque above, so there is nothing premultiplied about it.
    stbir_resize_uint8_srgb(src, at.srcW, at.srcH, static_cast<int>(srcStride),
                            dst, at.dstW, at.dstH,
                            static_cast<int>(buffer->stride), STBIR_RGBA);
  }

  if (panel.node == nullptr) panel.node = wlr_scene_buffer_create(tree_, nullptr);
  if (panel.node == nullptr) {
    wlr_buffer_drop(&buffer->base);
    return;
  }

  wlr_scene_buffer_set_buffer(panel.node, &buffer->base);
  // The scene took its own reference; this drops the one `make_buffer` made,
  // so the bytes go away with the node or with the next picture.
  wlr_buffer_drop(&buffer->base);

  wlr_scene_buffer_set_dest_size(panel.node, box.width, box.height);
  wlr_scene_node_set_position(&panel.node->node, box.x, box.y);

  // Filled edge to edge with opaque pixels in every mode — the letterbox is
  // painted with the colour rather than left clear — so the scene can skip
  // whatever is behind it, which is the rect covering the whole desktop.
  pixman_region32_t opaque;
  pixman_region32_init_rect(&opaque, 0, 0, static_cast<unsigned>(box.width),
                            static_cast<unsigned>(box.height));
  wlr_scene_buffer_set_opaque_region(panel.node, &opaque);
  pixman_region32_fini(&opaque);

  panel.x      = box.x;
  panel.y      = box.y;
  panel.width  = box.width;
  panel.height = box.height;
  panel.scale  = scale;
  panel.fit    = config_.fit;
}

}  // namespace lava
