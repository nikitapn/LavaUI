#include "canvas_surface.hpp"

#include <cstdio>
#include <cstdlib>
#include <filesystem>

#include "render/dmabuf_image.hpp"

namespace lava {
namespace {

/// Modifiers the compositor's own renderer can import for `fourcc`.
///
/// The half of the negotiation that is genuinely about wlroots. Both sides can
/// name a modifier the other cannot read; exporting from the full set this GPU
/// supports and hoping is how a buffer ends up technically mappable and subtly
/// wrong. Empty means the renderer advertised none, which canvas treats as a
/// reason to refuse rather than to guess.
std::vector<uint64_t> importable_modifiers(wlr_renderer *renderer,
                                           uint32_t fourcc) {
  std::vector<uint64_t> result;
  const wlr_drm_format_set *formats =
      wlr_renderer_get_texture_formats(renderer, WLR_BUFFER_CAP_DMABUF);
  if (formats == nullptr) {
    return result;
  }
  if (const wlr_drm_format *format = wlr_drm_format_set_get(formats, fourcc)) {
    result.assign(format->modifiers, format->modifiers + format->len);
  }
  return result;
}

/// Where canvas' compiled shaders live.
///
/// Canvas resolves them relative to an assets root it chdirs into, which for a
/// Swift client is the SwiftPM resource bundle. A compositor has no bundle, so
/// the build tells it where the source tree is, and the environment can say
/// otherwise for an installed one.
std::string assets_root() {
  if (const char *fromEnv = std::getenv("LAVA_CANVAS_ASSETS")) {
    return fromEnv;
  }
  return LAVA_CANVAS_ASSETS;
}

// ─── wlr_buffer wrapper ────────────────────────────────────────────────────

DmabufBuffer *from_buffer(wlr_buffer *buffer) {
  return reinterpret_cast<DmabufBuffer *>(buffer);
}

void buffer_destroy(wlr_buffer *buffer) { delete from_buffer(buffer); }

bool buffer_get_dmabuf(wlr_buffer *buffer, wlr_dmabuf_attributes *attribs) {
  const canvas::DmabufImage *image = from_buffer(buffer)->image;
  *attribs = {};
  attribs->width = static_cast<int32_t>(image->width());
  attribs->height = static_cast<int32_t>(image->height());
  attribs->format = image->drmFormat();
  attribs->modifier = image->modifier();
  attribs->n_planes = image->planeCount();
  for (int i = 0; i < image->planeCount(); ++i) {
    attribs->offset[i] = image->offset(i);
    attribs->stride[i] = image->stride(i);
    // Borrowed, not given: wlroots imports these and does not close them.
    attribs->fd[i] = image->fd(i);
  }
  return true;
}

const wlr_buffer_impl kBufferImpl = {
    .destroy = buffer_destroy,
    .get_dmabuf = buffer_get_dmabuf,
    .get_shm = nullptr,
    .begin_data_ptr_access = nullptr,
    .end_data_ptr_access = nullptr,
};

}  // namespace

DmabufBuffer *DmabufBuffer::create(const canvas::DmabufImage *image) {
  auto *self = new DmabufBuffer();
  self->image = image;
  wlr_buffer_init(&self->base, &kBufferImpl, static_cast<int>(image->width()),
                  static_cast<int>(image->height()));
  return self;
}

std::unique_ptr<CanvasSurface> CanvasSurface::create(wlr_renderer *renderer,
                                                     uint32_t width,
                                                     uint32_t height) {
  const int drm_fd = wlr_renderer_get_drm_fd(renderer);
  if (drm_fd < 0) {
    wlr_log(WLR_ERROR, "canvas: the compositor's renderer has no DRM device");
    return nullptr;
  }

  const std::vector<uint64_t> importable =
      importable_modifiers(renderer, canvas::DmabufImage::exportFormat());
  if (importable.empty()) {
    wlr_log(WLR_ERROR,
            "canvas: this renderer imports no modifier for format 0x%08x",
            canvas::DmabufImage::exportFormat());
    return nullptr;
  }
  wlr_log(WLR_INFO, "canvas: renderer imports %zu modifier(s) for this format",
          importable.size());

  const std::string root = assets_root();
  if (!std::filesystem::exists(std::filesystem::path(root) / "shaders")) {
    wlr_log(WLR_ERROR, "canvas: no shaders/ under '%s' — set LAVA_CANVAS_ASSETS",
            root.c_str());
    return nullptr;
  }

  std::unique_ptr<CanvasSurface> self(new CanvasSurface());
  self->width_ = width;
  self->height_ = height;
  if (auto r = self->engine_.openExported(root, width, height, drm_fd,
                                          importable);
      !r) {
    wlr_log(WLR_ERROR, "canvas: %s", r.error().c_str());
    return nullptr;
  }

  const canvas::DmabufImage *image = self->engine_.exportedImage();
  if (image == nullptr) {
    wlr_log(WLR_ERROR, "canvas: opened without an exported image");
    return nullptr;
  }
  self->buffer_ = DmabufBuffer::create(image);
  return self;
}

CanvasSurface::~CanvasSurface() {
  // Order matters: the scene may still hold a reference to the buffer, and the
  // buffer names descriptors the engine owns. Dropping ours first lets wlroots
  // release its import before the image behind it goes away.
  if (buffer_ != nullptr) {
    wlr_buffer_drop(&buffer_->base);
    buffer_ = nullptr;
  }
  engine_.close();
}

bool CanvasSurface::attachArena(const std::string &id) {
  // Failure is not logged here: the only caller retries on a timer until a
  // client turns up, and an error line every 16ms would bury the one that
  // matters.
  if (!engine_.attachDrawArena(id)) return false;
  wlr_log(WLR_INFO, "canvas: rendering the arena '%s'", id.c_str());
  return true;
}

int CanvasSurface::registerFont(const std::string &path, float pixelSize) {
  const int id = engine_.registerFont(path, pixelSize);
  if (id < 0) {
    wlr_log(WLR_ERROR, "canvas: could not load font '%s'", path.c_str());
  } else {
    wlr_log(WLR_INFO, "canvas: font %d = %s @ %.0fpx", id, path.c_str(),
            static_cast<double>(pixelSize));
  }
  return id;
}

bool CanvasSurface::renderFromArena() {
  // Ask before drawing. A repaint with nothing new published still redraws
  // the frame it is holding — deliberately, so a resize repaints content
  // rather than nothing — so rendering first and asking afterwards would blit
  // and re-damage sixty times a second to show pixels that never changed.
  if (!engine_.pollDrawArena()) return false;
  if (!engine_.renderFrame()) {
    wlr_log(WLR_ERROR, "canvas: the surface failed to draw");
    return false;
  }
  drawn_ = engine_.frameCounter();
  dumpIfRequested();
  return true;
}

void CanvasSurface::scrollUnclaimed(float dx, float dy) {
  engine_.scrollSceneUnclaimed(dx, dy);
}

bool CanvasSurface::capturePng(int32_t x, int32_t y, int32_t w, int32_t h,
                               int32_t maxSide, std::vector<uint8_t> &outPng,
                               uint32_t &outW, uint32_t &outH) {
  int width = 0;
  int height = 0;
  const canvas::U8Vector png =
      engine_.capturePng(x, y, w, h, maxSide, &width, &height);
  if (png.empty()) return false;
  outPng.assign(png.begin(), png.end());
  outW = static_cast<uint32_t>(width);
  outH = static_cast<uint32_t>(height);
  return true;
}

bool CanvasSurface::render(const std::vector<canvas::DrawCommand> &commands) {
  engine_.submitDrawList(commands.data(), commands.size(), nullptr, 0, nullptr,
                         0, nullptr, 0);
  if (!engine_.renderFrame()) {
    return false;
  }
  drawn_ = engine_.frameCounter();

  dumpIfRequested();
  return true;
}

void CanvasSurface::dumpIfRequested() {
  // A way to see what canvas *thinks* it drew, independent of everything
  // downstream of the blit.
  //
  // Worth keeping rather than deleting after one use: when a shared surface
  // looks wrong, the first question is always whether the renderer or the
  // handover produced it, and comparing this file with a screenshot answers
  // that in one step. Reads the same resolve target the blit copies, through
  // the staging buffer an offscreen window has anyway.
  const char *path = std::getenv("LAVA_CANVAS_DUMP");
  if (path == nullptr) return;
  const canvas::U8Vector png = engine_.capturePng(0, 0, 0, 0);
  if (png.empty()) return;
  if (FILE *f = std::fopen(path, "wb")) {
    std::fwrite(png.data(), 1, png.size(), f);
    std::fclose(f);
    wlr_log(WLR_INFO, "canvas: wrote %zu bytes of resolve to %s", png.size(),
            path);
  }
}

}  // namespace lava
