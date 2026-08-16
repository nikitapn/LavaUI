#include "canvas_surface.hpp"

#include <unistd.h>

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <filesystem>

#include "application.hpp"
#include "frame_probe.hpp"
#include "render/dmabuf_image.hpp"
#include "render/draw_command.hpp"
#include "render/imported_dmabuf.hpp"

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
  self->drmFd_ = drm_fd;

  // Whether a frame can be handed over with a fence rather than a stall, which
  // is a question about the *consumer*: this renderer has to be able to wait on
  // a timeline before it samples, or canvas has to go on blocking until every
  // frame is finished. Asked once, here, because it is a property of the
  // renderer and not of any surface.
  self->fencedHandover_ = renderer->features.timeline;
  self->engine_.setExportFenceHonoured(self->fencedHandover_);
  wlr_log(WLR_INFO, "canvas: frame handover is %s",
          self->fencedHandover_ ? "fenced (scene waits on a timeline)"
                                : "a CPU wait (renderer has no timelines)");
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

int CanvasRenderer::registerFont(const std::string &path,
                                 uint32_t pixelSize26_6, uint32_t faceIndex,
                                 uint32_t rasterFlags) {
  return engine_.registerFace(path, pixelSize26_6, faceIndex, rasterFlags);
}

namespace {

/// Uploads an already-decoded image, or -1. Shared by both entry points,
/// which differ only in where the pixels came from.
int upload_decoded(canvas::Engine &engine, const std::string &key,
                   const canvas::DecodedImage &decoded, uint32_t &outWidth,
                   uint32_t &outHeight) {
  if (!decoded.valid()) return -1;
  const int id = engine.uploadTexture(key, decoded.pixels, decoded.width,
                                      decoded.height);
  if (id <= 0) return -1;
  outWidth = decoded.width;
  outHeight = decoded.height;
  return id;
}

}  // namespace

int CanvasRenderer::registerImage(const std::string &key,
                                  const std::string &path,
                                  uint32_t maxPixelSize, uint32_t &outWidth,
                                  uint32_t &outHeight) {
  // Already resident — including dormant, which reuses the id and the pixels
  // already on the GPU — so skip the decode entirely.
  if (const int id = engine_.reviveTexture(key, outWidth, outHeight); id > 0)
    return id;
  // Decoded here rather than in the client, which is the point of the call:
  // the renderer knows the size it will be drawn at, owns the atlas that
  // decides whether it fits a cell, and already has the codec. A client that
  // sent pixels would have to have all three.
  return upload_decoded(engine_, key,
                        canvas::Engine::decodeImage(path, maxPixelSize),
                        outWidth, outHeight);
}

int CanvasRenderer::registerImageData(const std::string &key,
                                      const uint8_t *bytes, size_t byteCount,
                                      uint32_t maxPixelSize,
                                      uint32_t &outWidth, uint32_t &outHeight) {
  if (const int id = engine_.reviveTexture(key, outWidth, outHeight); id > 0)
    return id;
  return upload_decoded(
      engine_, key,
      canvas::Engine::decodeImageData(bytes, byteCount, maxPixelSize),
      outWidth, outHeight);
}

void CanvasRenderer::releaseImage(const std::string &key) {
  engine_.unloadTexture(key);
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
  // `closeWindow` waits for this window's frames before it takes the buffer
  // back, so nothing is still writing whatever the timeline was tracking.
  renderer_.engine().closeWindow(windowId_);
  if (fenceTimeline_ != nullptr) {
    wlr_drm_syncobj_timeline_unref(fenceTimeline_);
    fenceTimeline_ = nullptr;
  }
}

void CanvasSurface::captureFence() {
  const int fence = renderer_.engine().takeFrameFence(windowId_);
  if (fence < 0) {
    // No fence for this frame, which means canvas waited for it instead: what
    // the surface is holding is finished, and the point already on the
    // timeline is finished with it.
    return;
  }
  if (fenceTimeline_ == nullptr && renderer_.drmFd() >= 0) {
    fenceTimeline_ = wlr_drm_syncobj_timeline_create(renderer_.drmFd());
  }
  if (fenceTimeline_ == nullptr ||
      !wlr_drm_syncobj_timeline_import_sync_file(fenceTimeline_,
                                                 fencePoint_ + 1, fence)) {
    // The frame is in flight and nothing can be told to wait for it. Waiting
    // here is the same stall this exists to avoid, but it is a stall on a path
    // that should never run rather than a torn frame on one that does.
    wlr_log(WLR_ERROR, "canvas: surface %u could not publish its frame fence",
            windowId_);
    close(fence);
    renderer_.engine().waitForFrames(windowId_);
    return;
  }
  close(fence);
  ++fencePoint_;

}

bool CanvasSurface::resize(uint32_t width, uint32_t height) {
  if (width < 1 || height < 1) return false;
  if (width == width_ && height == height_) return false;
  if (!renderer_.engine().resizeExportedWindow(windowId_, width, height)) {
    return false;
  }
  const canvas::DmabufImage *image = renderer_.engine().exportedImage(windowId_);
  if (image == nullptr) return false;

  // Usually the same image, and that is the point of the check: exported
  // buffers are allocated in steps, so most of a drag's resizes land inside the
  // buffer already here. A new `wlr_buffer` means the renderer on the other
  // side imports a dmabuf again, and an import is not free — see
  // `Application::exportCapacity`.
  if (buffer_ == nullptr || buffer_->image != image) {
    // The old one is dropped *after* the new one exists, so the scene never
    // holds a reference to nothing.
    DmabufBuffer *replacement = DmabufBuffer::create(image);
    if (buffer_ != nullptr) wlr_buffer_drop(&buffer_->base);
    buffer_ = replacement;
  }
  width_ = width;
  height_ = height;

  // The `Resize` the client needs is queued by the engine as part of the
  // resize, and reaches it on the caller's next drain. Until it arrives and the
  // client republishes, the window shows its old frame in a differently-sized
  // space — which is why the frame clears to nothing rather than to whatever
  // happened to be there.
  //
  // The caller still has work to do either way: `buffer()` has to go back to
  // the scene (cheap when it is the same one), and the crop has to follow the
  // new size — see `CanvasSurface::buffer`.
  return true;
}

void CanvasSurface::setCornerRadius(float radius, bool top, bool bottom) {
  renderer_.engine().setWindowCornerRadius(radius, top, bottom, windowId_);
}

bool CanvasSurface::frostWithTexture(int id, float radius, float cornerRadius) {
  if (id <= 0) return false;

  canvas::DrawCommand begin{};
  begin.kind = static_cast<uint32_t>(canvas::DrawCommandKind::BeginContentBlur);
  begin.w = static_cast<float>(width_);
  begin.h = static_cast<float>(height_);
  begin.aux = radius;
  // Same slot backdrop blur uses: the composite has to know the outline,
  // or it paints a square tab behind a rounded window.
  begin.param = static_cast<uint32_t>(std::max(0.f, cornerRadius) + 0.5f);

  canvas::DrawCommand image{};
  image.kind = static_cast<uint32_t>(canvas::DrawCommandKind::Image);
  image.w = static_cast<float>(width_);
  image.h = static_cast<float>(height_);
  image.param = static_cast<uint32_t>(id);
  image.color = 0xffffffffu;

  canvas::DrawCommand end{};
  end.kind = static_cast<uint32_t>(canvas::DrawCommandKind::EndContentBlur);

  const std::vector<canvas::DrawCommand> commands{begin, image, end};
  const std::vector<canvas::GlyphInstance> glyphs;
  return renderList(commands, glyphs);
}

bool CanvasSurface::frostFromRgba(const uint8_t *rgba, uint32_t srcW,
                                  uint32_t srcH, float radius,
                                  const std::string &key, float cornerRadius) {
  if (rgba == nullptr || srcW < 1 || srcH < 1 || key.empty()) return false;
  const int id =
      renderer_.engine().uploadTexture(key, rgba, srcW, srcH);
  return frostWithTexture(id, radius, cornerRadius);
}

bool CanvasSurface::frostFromDmabuf(const wlr_dmabuf_attributes &src, int srcX,
                                    int srcY, int srcW, int srcH, float radius,
                                    const std::string &key,
                                    float cornerRadius) {
  if (srcW < 1 || srcH < 1 || key.empty() || src.n_planes < 1) return false;
  Application *app = renderer_.engine().application();
  if (app == nullptr) return false;

  canvas::DmabufImport desc{};
  desc.width = static_cast<uint32_t>(src.width);
  desc.height = static_cast<uint32_t>(src.height);
  desc.drmFormat = src.format;
  desc.modifier = src.modifier;
  desc.planeCount = src.n_planes;
  const int planes = std::min(src.n_planes, 4);
  for (int i = 0; i < planes; ++i) {
    desc.fd[i] = src.fd[i];
    desc.offset[i] = src.offset[i];
    desc.stride[i] = src.stride[i];
  }
  const int id = app->importDmabufTexture(
      key, desc, srcX, srcY, static_cast<uint32_t>(srcW),
      static_cast<uint32_t>(srcH));
  return frostWithTexture(id, radius, cornerRadius);
}

bool CanvasSurface::renderList(
    const std::vector<canvas::DrawCommand> &commands,
    const std::vector<canvas::GlyphInstance> &glyphs) {
  renderer_.engine().submitDrawList(commands.data(), commands.size(),
                                    glyphs.data(), glyphs.size(), nullptr, 0,
                                    nullptr, 0, windowId_);
  if (!renderer_.engine().renderFrame(windowId_)) return false;
  captureFence();
  drawn_ = renderer_.engine().frameCounter(windowId_);
  return true;
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
  const int64_t startedArena = FrameProbe::on() ? FrameProbe::now() : 0;
  const bool published = renderer_.engine().pollDrawArena(windowId_);
  FrameProbe::record(reportedId(), FrameProbe::Stage::Arena, startedArena);
  if (!published) return false;

  const int64_t startedRender = FrameProbe::on() ? FrameProbe::now() : 0;
  if (!renderer_.engine().renderFrame(windowId_)) {
    wlr_log(WLR_ERROR, "canvas: surface %u failed to draw", windowId_);
    return false;
  }
  captureFence();
  FrameProbe::record(reportedId(), FrameProbe::Stage::Render, startedRender);
  drawn_ = renderer_.engine().frameCounter(windowId_);
  dumpIfRequested();
  return true;
}

bool CanvasSurface::opaqueBounds(float &x, float &y, float &w,
                                 float &h) const {
  return renderer_.engine().opaqueBounds(windowId_, x, y, w, h);
}

void CanvasSurface::pointerMove(float x, float y) {
  renderer_.engine().pointerMove(x, y, windowId_);
}

void CanvasSurface::pointerButton(int button, bool pressed, float x, float y,
                                  int mods) {
  renderer_.engine().pointerButton(button, pressed, x, y, windowId_);
  (void)mods;  // The engine takes modifiers on keys, not on buttons.
}

void CanvasSurface::pointerScroll(float dx, float dy) {
  renderer_.engine().pointerScroll(dx, dy, windowId_);
}

void CanvasSurface::keyEvent(int key, int action, int mods) {
  renderer_.engine().keyEvent(key, action, mods, windowId_);
}

void CanvasSurface::textInput(const std::string &utf8) {
  renderer_.engine().textInput(utf8, windowId_);
}

bool CanvasSurface::pollEvent(canvas::InputEvent &out) {
  return renderer_.engine().pollInputEvent(out, windowId_);
}

bool CanvasSurface::takeInternalRepaint() {
  return renderer_.engine().takeInternalRepaint(windowId_);
}

bool CanvasSurface::redraw() {
  const int64_t started = FrameProbe::on() ? FrameProbe::now() : 0;
  if (!renderer_.engine().renderFrame(windowId_)) return false;
  captureFence();
  FrameProbe::record(reportedId(), FrameProbe::Stage::Redraw, started);
  drawn_ = renderer_.engine().frameCounter(windowId_);
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
