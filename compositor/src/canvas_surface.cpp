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

// ─── CanvasRenderer ────────────────────────────────────────────────────────

std::unique_ptr<CanvasRenderer> CanvasRenderer::create(wlr_renderer *renderer) {
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

  std::unique_ptr<CanvasRenderer> self(new CanvasRenderer());
  if (auto r = self->engine_.openExported(root, drm_fd, importable); !r) {
    wlr_log(WLR_ERROR, "canvas: %s", r.error().c_str());
    return nullptr;
  }
  return self;
}

CanvasRenderer::~CanvasRenderer() { engine_.close(); }

std::unique_ptr<CanvasSurface> CanvasRenderer::createSurface(uint32_t width,
                                                             uint32_t height) {
  const uint32_t windowId = engine_.openExportedWindow(width, height);
  if (windowId == 0) {
    wlr_log(WLR_ERROR, "canvas: could not open a %ux%u surface", width, height);
    return nullptr;
  }
  const canvas::DmabufImage *image = engine_.exportedImage(windowId);
  if (image == nullptr) {
    wlr_log(WLR_ERROR, "canvas: surface %u opened without an exported image",
            windowId);
    engine_.closeWindow(windowId);
    return nullptr;
  }
  return std::make_unique<CanvasSurface>(*this, windowId,
                                         DmabufBuffer::create(image), width,
                                         height);
}

int CanvasRenderer::registerFont(const std::string &path, float pixelSize) {
  return engine_.registerFont(path, pixelSize);
}

// ─── CanvasSurface ─────────────────────────────────────────────────────────

CanvasSurface::CanvasSurface(CanvasRenderer &renderer, uint32_t windowId,
                             DmabufBuffer *buffer, uint32_t width,
                             uint32_t height)
    : renderer_(renderer),
      windowId_(windowId),
      buffer_(buffer),
      width_(width),
      height_(height) {}

CanvasSurface::~CanvasSurface() {
  // Order matters: the scene may still hold a reference to the buffer, and the
  // buffer names descriptors the image owns. Dropping ours first lets wlroots
  // release its import before the window — and with it the image — goes away.
  if (buffer_ != nullptr) {
    wlr_buffer_drop(&buffer_->base);
    buffer_ = nullptr;
  }
  renderer_.engine().closeWindow(windowId_);
}

bool CanvasSurface::attachArena(const std::string &id) {
  // Failure is not logged: a caller may retry on a timer until a client turns
  // up, and an error line per attempt would bury the one that matters.
  return renderer_.engine().attachDrawArena(id, windowId_);
}

bool CanvasSurface::renderFromArena() {
  // Ask before drawing. A repaint with nothing new published still redraws the
  // frame it is holding — deliberately, so a resize repaints content rather
  // than nothing — so rendering first and asking afterwards would blit and
  // re-damage to show pixels that never changed.
  if (!renderer_.engine().pollDrawArena(windowId_)) return false;
  if (!renderer_.engine().renderFrame(windowId_)) {
    wlr_log(WLR_ERROR, "canvas: surface %u failed to draw", windowId_);
    return false;
  }
  drawn_ = renderer_.engine().frameCounter(windowId_);
  dumpIfRequested();
  return true;
}

void CanvasSurface::scrollUnclaimed(float dx, float dy) {
  renderer_.engine().scrollSceneUnclaimed(dx, dy, windowId_);
}

bool CanvasSurface::capturePng(int32_t x, int32_t y, int32_t w, int32_t h,
                               int32_t maxSide, std::vector<uint8_t> &outPng,
                               uint32_t &outW, uint32_t &outH) {
  int width = 0;
  int height = 0;
  const canvas::U8Vector png = renderer_.engine().capturePng(
      x, y, w, h, maxSide, &width, &height, windowId_);
  if (png.empty()) return false;
  outPng.assign(png.begin(), png.end());
  outW = static_cast<uint32_t>(width);
  outH = static_cast<uint32_t>(height);
  return true;
}

void CanvasSurface::dumpIfRequested() {
  // A way to see what canvas *thinks* it drew, independent of everything
  // downstream of the blit.
  //
  // Worth keeping rather than deleting after one use: when a shared surface
  // looks wrong, the first question is always whether the renderer or the
  // handover produced it, and comparing this file with a screenshot answers
  // that in one step.
  const char *path = std::getenv("LAVA_CANVAS_DUMP");
  if (path == nullptr) return;
  const canvas::U8Vector png =
      renderer_.engine().capturePng(0, 0, 0, 0, 0, nullptr, nullptr, windowId_);
  if (png.empty()) return;
  if (FILE *f = std::fopen(path, "wb")) {
    std::fwrite(png.data(), 1, png.size(), f);
    std::fclose(f);
    wlr_log(WLR_INFO, "canvas: wrote %zu bytes of surface %u to %s", png.size(),
            windowId_, path);
  }
}

}  // namespace lava
