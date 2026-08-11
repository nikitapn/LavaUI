
#include <chrono>
#include <format>
#include <algorithm>
#include <optional>
#include <filesystem>

#include "application.hpp"

#include "util/constants.hpp"
#include "util/key_codes.hpp"
#include "render/dmabuf_image.hpp"
#include "render/render_device.hpp"
#include "render/render_window.hpp"
#include "window/app_window.hpp"
#include "render/font.hpp"
#include "render/text_renderer.hpp"
#include "render/quad_renderer.hpp"
#include "render/texture_manager.hpp"
#include "render/blur_pass.hpp"

#include "render/draw_command.hpp"

#include <atomic>
#include <deque>
#include <mutex>

#define GLFW_INCLUDE_VULKAN
#include <GLFW/glfw3.h>
#if defined(CANVAS_HAVE_X11)
#define GLFW_EXPOSE_NATIVE_X11
#include <GLFW/glfw3native.h>
#endif

#define GLM_ENABLE_EXPERIMENTAL
#include <glm/gtx/string_cast.hpp>

std::ostream& operator<<(std::ostream& out, const vec2& v2) { return out << glm::to_string(v2); }
std::ostream& operator<<(std::ostream& out, const vec3& v3) { return out << glm::to_string(v3); }
std::ostream& operator<<(std::ostream& out, const vec4& v4) { return out << glm::to_string(v4); }

class Timer {
  float currentTime = 0.0f;
public:
  void update(float delta) { currentTime += delta; }
  void reset() { currentTime = 0.0f; }
  float getTime() const { return currentTime; }
};

struct Application::Impl
{
  const float width;
  const float height;

  /// The GPU, shared by every window. Brought up once, before any window
  /// exists, and outlives all of them.
  ///
  /// Default-constructed but only *initialized* by `init`/`initWithWindow`.
  /// A client never brings it up, which is what `deviceUp` records — tearing
  /// down a device that was never created is not a no-op, it is a crash.
  RenderDevice device;
  bool deviceUp = false;

  /// The buffer another driver reads, per surface. Empty in every other mode.
  ///
  /// Declared here, above `windows`, for its destruction order: members die in
  /// reverse, so a window that blits into its image is gone before the image
  /// is. Below `device`, for the same reason in the other direction.
  std::unordered_map<uint32_t, std::unique_ptr<canvas::DmabufImage>> exportImages;
  /// What the consumer said it can import. Settled once, at `initExported`,
  /// because it describes the consumer and not any one surface.
  std::vector<uint64_t> exportModifiers;

  /// True between `beginFrameGroup` and `endFrameGroup`. Written on the main
  /// thread while nothing is drawing and read by every render worker, so the
  /// release/acquire pair is what publishes the prepare step's effects — the
  /// resized swapchain, the regrown atlas — to the threads about to draw.
  std::atomic<bool> frameGroup{false};

  /// Client-mode font numbering, standing in for the atlas the device would
  /// own. Same contract as `TextRenderer::registerFont`: an index, stable per
  /// `canvas::FontKey`, -1 if the file will not load.
  ///
  /// Provisional by construction. These ids are stamped into every
  /// `GlyphInstance` and mean nothing to a renderer in another process — a
  /// client's real font ids have to come back from whoever owns the atlas.
  /// Loading the face anyway is not waste: it fails here, at registration,
  /// rather than as missing text in a frame nobody can debug.
  std::vector<canvas::FontKey> clientFontKeys;
  std::vector<canvas::Font>    clientFonts;

  /// Open windows, in creation order. `windows[0]` is the one every
  /// window-less overload of the public API means, which keeps single-window
  /// callers from having to care that this is a list.
  std::vector<std::unique_ptr<AppWindow>> windows;
  /// Ids are never reused, so a stale handle from a closed window fails to
  /// resolve instead of quietly addressing whatever opened next.
  uint32_t nextWindowId = 1;

  // Wall-clock time of the last repaint() call, used only to compute a
  // deltaTime for the FPS counter (nullopt on the first call).
  std::optional<std::chrono::steady_clock::time_point> lastRepaintTime;
  int   frameCount = 0;
  float fpsTimer = 0.0f;
  float currentFPS = 0.0f;

 public:
  Impl(int w, int h)
    : width{static_cast<float>(w)}
    , height{static_cast<float>(h)}
    {

    }

  AppWindow *win(uint32_t windowId)
  {
    if (windows.empty()) return nullptr;
    if (windowId == 0) return windows.front().get();
    for (auto &w : windows) {
      if (w->id() == windowId) return w.get();
    }
    return nullptr;
  }

  const AppWindow *win(uint32_t windowId) const
  {
    return const_cast<Impl *>(this)->win(windowId);
  }

  /// Resolve `<assetsRoot>/assets/<file>` without depending on process cwd.
  static std::filesystem::path assetPath(
    const std::string &assetsRoot, const std::string &relativeUnderAssets)
  {
    return std::filesystem::path(assetsRoot) / "assets" / relativeUnderAssets;
  }

  /// Everything shared between windows. Runs once, after the device is up and
  /// before any window renders.
  canvas::VoidResult finishInitCommon(const std::string &assetsRoot)
  {
    TextureManager::getInstance().initialize(device);
    std::cout << "TextureManager initialized.\n";

    device.textRenderer().init();
    // No default face here — Swift owns font policy (FontStore) and calls
    // loadFont(path, size) after open so measure and draw use the same choice.
    std::cout << "Text renderer initialized (font pending from Swift).\n";

    std::cout << "Init complete.\n";
    return canvas::ok();
  }

  /// Compiles a window's pipelines and binds it to the shared glyph atlas.
  void bringUpWindow(AppWindow &w)
  {
    w.initRenderers();
    w.renderWindow().setGlyphAtlas(device.textRenderer().atlasView(),
                                   device.textRenderer().atlasSampler());
  }

  canvas::VoidResult init(const std::string &assetsRoot)
  {
    try {
      // Still chdir for any remaining relative loads (shaders, textures).
      // Prefer absolute asset paths from assetsRoot for new code.
      if (!assetsRoot.empty()) {
        std::filesystem::current_path(assetsRoot);
      }
      device.init("2d shenanigans!", /*presentCapable=*/false);
      deviceUp = true;
      std::cout << "Vulkan initialized (offscreen).\n";
      if (auto r = finishInitCommon(assetsRoot); !r) return r;
      auto w = std::make_unique<AppWindow>(
        device, nextWindowId++, static_cast<int>(width), static_cast<int>(height));
      bringUpWindow(*w);
      windows.push_back(std::move(w));
      return canvas::ok();
    } catch (const std::exception &ex) {
      return canvas::fail(std::string("Application::init: ") + ex.what());
    } catch (...) {
      return canvas::fail("Application::init: unknown error");
    }
  }

  /// Offscreen, and able to render into buffers another driver reads.
  ///
  /// Brings up the device and nothing else. Deliberately no window: a
  /// compositor has one device and as many surfaces as it has clients, and
  /// creating the first surface at device time would make the device's
  /// lifetime hostage to a window that may not exist yet — and would leave no
  /// way to say what the *second* one costs.
  ///
  /// The two agreements a shared buffer needs are settled here, because both
  /// are properties of the consumer rather than of any one surface: the GPU is
  /// pinned to the one behind `drmFd` (told to the device *before* it comes
  /// up, since it decides which card is chosen), and the modifiers it may
  /// export with are the ones the consumer said it can read.
  canvas::VoidResult initExported(const std::string &assetsRoot, int drmFd,
                                  const std::vector<uint64_t> &importable)
  {
    try {
      if (!assetsRoot.empty()) {
        std::filesystem::current_path(assetsRoot);
      }
      exportModifiers = importable;
      device.exportToDrmDevice(drmFd);
      device.init("2d shenanigans!", /*presentCapable=*/false);
      deviceUp = true;
      std::cout << "Vulkan initialized (exported, no surfaces yet).\n";
      return finishInitCommon(assetsRoot);
    } catch (const std::exception &ex) {
      return canvas::fail(std::string("Application::initExported: ") + ex.what());
    } catch (...) {
      return canvas::fail("Application::initExported: unknown error");
    }
  }

  /// How large a buffer a window `size` pixels across is exported into.
  ///
  /// Exported buffers are allocated in steps rather than at the window's exact
  /// size, because a resize cannot reuse one: a dmabuf's stride is settled when
  /// it is allocated, so every new size would otherwise be a new buffer — and a
  /// drag is a new size every frame. Stepping makes a drag allocate once per
  /// step it crosses instead of once per frame, at the cost of a window
  /// occupying the corner of a buffer that is usually slightly larger than it
  /// is. See `RenderWindow::setExportTarget`, which is what allows the two to
  /// differ, and the consumer's crop, which is what hides the difference.
  static uint32_t exportCapacity(uint32_t size)
  {
    constexpr uint32_t kStep = 128;
    return ((size + kStep - 1) / kStep) * kStep;
  }

  /// Opens one more surface on the device `initExported` brought up.
  ///
  /// Everything expensive and shared — the device, the pipelines, the glyph
  /// atlas, the texture cache — already exists and is not paid for again. A
  /// second surface costs its own attachments, its own sync objects and its
  /// own exported image, which is exactly what a second window should cost.
  uint32_t openExportedWindow(uint32_t w, uint32_t h)
  {
    if (!deviceUp) {
      std::cerr << "openExportedWindow: no device — call initExported first\n";
      return 0;
    }
    try {
      auto image = canvas::DmabufImage::create(
        device, exportCapacity(w), exportCapacity(h), exportModifiers);
      if (!image) return 0;

      const uint32_t id = nextWindowId++;
      auto window = std::make_unique<AppWindow>(
        device, id, static_cast<int>(w), static_cast<int>(h));
      bringUpWindow(*window);
      // Composited by whoever imports the buffer, so the frame clears to
      // nothing rather than to black — see `RenderWindow::setTransparent`.
      window->renderWindow().setTransparent(true);
      window->renderWindow().setExportTarget(image.get());
      exportImages.emplace(id, std::move(image));
      windows.push_back(std::move(window));
      return id;
    } catch (const std::exception &ex) {
      std::cerr << "openExportedWindow: " << ex.what() << '\n';
      return 0;
    }
  }

  /// Resizes an exported surface, reusing its buffer where it can.
  ///
  /// A dmabuf's size and stride are settled when it is allocated, so a window
  /// that has outgrown its buffer needs a new one. A window that has not does
  /// not: it renders at its new size into the same image and occupies less of
  /// it, which is why the buffer usually survives a resize and why a drag no
  /// longer allocates sixty buffers a second. `exportedImage` is how a caller
  /// tells the two cases apart — the pointer only changes in the first.
  ///
  /// Grow-only, deliberately. Giving memory back when a window shrinks would
  /// mean allocating on the way down as well as on the way up, which is the
  /// cost this exists to avoid, and the most a window can hold on to is one
  /// step in each direction.
  ///
  /// The client is told separately, by whoever owns the window, with a
  /// `Resize`. It has to re-lay-out before its next frame means anything.
  bool resizeExportedWindow(uint32_t windowId, uint32_t w, uint32_t h)
  {
    AppWindow *window = win(windowId);
    if (window == nullptr || !window->hasRenderer()) return false;
    auto it = exportImages.find(windowId);
    if (it == exportImages.end()) return false;

    // Allocated before anything is torn down, so a failure here leaves the
    // window exactly as it was rather than half resized with nowhere to draw.
    std::unique_ptr<canvas::DmabufImage> replacement;
    if (it->second == nullptr || it->second->width() < w ||
        it->second->height() < h) {
      replacement = canvas::DmabufImage::create(
        device, exportCapacity(w), exportCapacity(h), exportModifiers);
      if (!replacement) {
        std::cerr << "resizeExportedWindow: could not export " << w << "x" << h
                  << '\n';
        return false;
      }
    }

    if (!window->renderWindow().resizeTo(w, h)) return false;

    if (replacement) {
      // The old image is released only after the window points at the new one,
      // so nothing is still able to name it.
      window->renderWindow().setExportTarget(replacement.get());
      it->second = std::move(replacement);
    } else {
      // `resizeTo` drops the target rather than keep pointing at an image the
      // window no longer matches, so even the buffer being kept is handed back.
      window->renderWindow().setExportTarget(it->second.get());
    }

    // The producer has no surface to measure and learns its size only by being
    // told. Queued here rather than by the caller so no exported resize can
    // happen without the client hearing about it.
    window->queueResize(static_cast<float>(w), static_cast<float>(h));
    return true;
  }

  canvas::VoidResult initClient()
  {
    try {
      // No chdir either: the only reason the other two do it is to resolve
      // shaders and textures relatively, and a client loads neither.
      auto w = std::make_unique<AppWindow>(
        nextWindowId++, static_cast<int>(width), static_cast<int>(height));
      windows.push_back(std::move(w));
      std::cout << "Client mode: no device, no window, no renderer.\n";
      return canvas::ok();
    } catch (const std::exception &ex) {
      return canvas::fail(std::string("Application::initClient: ") + ex.what());
    } catch (...) {
      return canvas::fail("Application::initClient: unknown error");
    }
  }

  canvas::VoidResult initWithWindow(
    const std::string &assetsRoot, const std::string &title)
  {
    try {
      if (!assetsRoot.empty()) {
        std::filesystem::current_path(assetsRoot);
      }
      device.init("2d shenanigans!", /*presentCapable=*/true);
      deviceUp = true;
      std::cout << "Vulkan initialized (windowed).\n";
      if (auto r = finishInitCommon(assetsRoot); !r) {
        return r;
      }
      if (openWindow(static_cast<int>(width), static_cast<int>(height), title) == 0) {
        return canvas::fail("Application::initWithWindow: openWindow failed");
      }
      windows.front()->setWindowVisible(true);
      return canvas::ok();
    } catch (const std::exception &ex) {
      return canvas::fail(std::string("Application::initWithWindow: ") + ex.what());
    } catch (...) {
      return canvas::fail("Application::initWithWindow: unknown error");
    }
  }

  /// Opens an additional window on the same device. Returns its id, or 0.
  ///
  /// The window starts hidden: showing it before the producer has drawn a
  /// frame into it means presenting an undefined swapchain image, which reads
  /// as a flash of garbage. The caller shows it after the first repaint.
  uint32_t openWindow(int w, int h, const std::string &title)
  {
    // A client has no device, and every step below needs one: `AppWindow`
    // builds a real GLFW window and a swapchain, and `bringUpWindow` reaches
    // straight into `device.textRenderer()`. Without this the call gets far
    // enough to open a window in the *client's* process before dying on an
    // uninitialised device — a crash that looks like a renderer bug.
    //
    // 0 is what a failed open already means, so callers need no new case.
    // Opening a second window as a client needs a surface from the
    // compositor; see docs/client-server-gaps.md.
    if (!deviceUp) {
      std::cerr << "Application::openWindow: no device — a client cannot open "
                   "\"" << title << "\" itself\n";
      return 0;
    }
    try {
      auto window = std::make_unique<AppWindow>(device, nextWindowId, w, h, title);
      bringUpWindow(*window);
      const uint32_t id = window->id();
      windows.push_back(std::move(window));
      ++nextWindowId;
      std::cout << "Window " << id << " open: " << w << "x" << h
                << " \"" << title << "\"\n";
      return id;
    } catch (const std::exception &ex) {
      std::cerr << "Application::openWindow: " << ex.what() << '\n';
      return 0;
    }
  }

  /// Closes one window. The device and every other window survive it — which
  /// is the property that makes this a multi-window app rather than an app
  /// that happens to have opened twice.
  void closeWindow(uint32_t windowId)
  {
    for (auto it = windows.begin(); it != windows.end(); ++it) {
      if ((*it)->id() != windowId) continue;
      // Its GPU work has to be done before its attachments go, and a sibling
      // may be mid-frame against the same queue.
      device.waitForAllFramesInFlight();
      windows.erase(it);
      // After the window, so nothing is still blitting into it. A no-op for
      // any window that was not exporting.
      exportImages.erase(windowId);
      return;
    }
  }

  int registerFont(const std::string &path, uint32_t pixelSize26_6,
                   uint32_t faceIndex, uint32_t rasterFlags)
  {
    if (deviceUp) {
      return device.textRenderer().registerFont(path, pixelSize26_6, faceIndex,
                                                rasterFlags);
    }

    // The same key the device path uses, for the same reason: two names for
    // one file must not become two ids, and a file whose bytes changed must
    // not keep the old one.
    std::vector<uint8_t> bytes;
    if (!canvas::readFontFile(path, bytes)) return -1;
    const canvas::FontKey key{
      .contentHash = canvas::sha256(bytes),
      .faceIndex = faceIndex,
      .pixelSize26_6 = pixelSize26_6,
      .variationsHash = canvas::FontDigest{},
      .rasterFlags = rasterFlags,
    };
    for (size_t i = 0; i < clientFontKeys.size(); ++i) {
      if (clientFontKeys[i] == key) return static_cast<int>(i);
    }

    canvas::Font font;
    if (!font.loadFaceFromMemory(bytes.data(), bytes.size(), pixelSize26_6,
                                 faceIndex, rasterFlags)) {
      return -1;
    }
    clientFonts.push_back(std::move(font));
    clientFontKeys.push_back(key);
    return static_cast<int>(clientFonts.size() - 1);
  }

  canvas::VoidResult loadFont(const std::string &path, float pixelSize)
  {
    if (!deviceUp) {
      return registerFont(path, canvas::pixelSizeTo26_6(pixelSize), 0,
                          canvas::RasterFlags::of(canvas::FontHinting::Normal))
                 >= 0
               ? canvas::ok()
               : canvas::fail("Application::loadFont: " + path);
    }
    return device.textRenderer().loadFont(path, static_cast<int>(pixelSize));
  }

  int loadTexture(const std::string &path)
  {
    // No device, no texture. Callers already handle a failed load (a missing
    // file does the same thing), so this reads as "that image is not
    // available here" rather than as a new failure mode.
    if (!deviceUp) return -1;
    auto h = TextureManager::getInstance().loadTexture(path);
    return h.isValid() ? static_cast<int>(h.id) : -1;
  }

  void unloadTexture(const std::string &path)
  {
    if (!deviceUp) return;
    TextureManager::getInstance().unloadTexture(path);
  }

  int uploadTexture(const std::string &key, const uint8_t *rgba,
                    uint32_t width, uint32_t height)
  {
    auto h = TextureManager::getInstance().uploadTexture(key, rgba, width, height);
    return h.isValid() ? static_cast<int>(h.id) : -1;
  }

  bool hasTexture(const std::string &key) const
  {
    return TextureManager::getInstance().hasTexture(key);
  }

  bool textureSize(uint32_t textureId, float &outW, float &outH) const
  {
    auto [w, h] = TextureManager::getInstance().getTextureDimensions(textureId);
    if (w == 0 || h == 0) return false;
    outW = static_cast<float>(w);
    outH = static_cast<float>(h);
    return true;
  }

  void shutdown()
  {
    if (!deviceUp) {
      // Client: nothing was ever created on the GPU, so there is nothing to
      // tear down. Calling through would destroy handles that were never
      // made.
      windows.clear();
      return;
    }
    TextureManager::getInstance().cleanUp();
    // Windows before the device: they hold attachments and sync objects made
    // from resources cleanUp is about to destroy, and the device asserts on
    // any still registered.
    windows.clear();
    device.cleanUp();
    deviceUp = false;
  }
};

// Public Application interface
//
// Every per-window call resolves its id first and no-ops (or returns a zero
// value) when the window is gone. A stale handle from a closed window is a
// normal thing for a caller to hold for one more frame; it must not be a crash,
// and because ids are never reused it cannot silently address a different
// window either.

canvas::VoidResult Application::init(const std::string &assetsRoot) {
  return impl_->init(assetsRoot);
}

canvas::VoidResult Application::initExported(
  const std::string &assetsRoot, int drmFd,
  const std::vector<uint64_t> &importableModifiers)
{
  return impl_->initExported(assetsRoot, drmFd, importableModifiers);
}

uint32_t Application::openExportedWindow(uint32_t width, uint32_t height)
{
  return impl_->openExportedWindow(width, height);
}

bool Application::resizeExportedWindow(uint32_t windowId, uint32_t width,
                                       uint32_t height)
{
  return impl_->resizeExportedWindow(windowId, width, height);
}

const canvas::DmabufImage *Application::exportedImage(uint32_t windowId) const
{
  auto it = impl_->exportImages.find(windowId);
  return it == impl_->exportImages.end() ? nullptr : it->second.get();
}

canvas::VoidResult Application::initClient() { return impl_->initClient(); }

void Application::setClientSize(float width, float height, uint32_t windowId)
{
  if (AppWindow *w = impl_->win(windowId)) w->setClientSize(width, height);
}

void Application::postInputEvent(uint32_t kind, float x, float y, int32_t button,
                                 int32_t mods, uint32_t windowId)
{
  if (AppWindow *w = impl_->win(windowId)) {
    w->postInputEvent(kind, x, y, button, mods);
  }
}

canvas::VoidResult Application::initWithWindow(
  const std::string &assetsRoot, const std::string &title)
{
  return impl_->initWithWindow(assetsRoot, title);
}

uint32_t Application::openWindow(int width, int height, const std::string &title)
{
  return impl_->openWindow(width, height, title);
}

void Application::closeWindow(uint32_t windowId) { impl_->closeWindow(windowId); }

size_t Application::windowCount() const { return impl_->windows.size(); }

bool Application::pollDrawArena(uint32_t windowId)
{
  AppWindow *w = impl_->win(windowId);
  return w != nullptr && w->pollDrawArena();
}

uint64_t Application::frameCounter(uint32_t windowId) const
{
  AppWindow *w = impl_->win(windowId);
  if (w == nullptr || !w->hasRenderer()) return 0;
  return w->renderWindow().frameCounter();
}

uint32_t Application::windowIdAt(size_t index) const
{
  if (index >= impl_->windows.size()) return 0;
  return impl_->windows[index]->id();
}

bool Application::windowShouldClose(uint32_t windowId) const {
  // False for a window that no longer exists: it has not been *asked* to
  // close, it is simply gone, and conflating the two makes a caller holding a
  // stale id try to close it on every iteration forever. Existence is what
  // `windowCount` answers.
  const AppWindow *w = impl_->win(windowId);
  return w && w->windowShouldClose();
}

bool Application::takeInternalRepaint(uint32_t windowId) {
  AppWindow *w = impl_->win(windowId);
  return w && w->takeInternalRepaint();
}

bool Application::scrollSceneUnclaimed(float dx, float dy, uint32_t windowId) {
  AppWindow *w = impl_->win(windowId);
  return w && w->scrollSceneUnclaimed(dx, dy);
}

void Application::requestClose(uint32_t windowId) {
  if (AppWindow *w = impl_->win(windowId)) w->requestClose();
}

void Application::setWindowFrame(int x, int y, int width, int height,
                                 uint32_t windowId) {
  if (AppWindow *w = impl_->win(windowId)) w->setWindowFrame(x, y, width, height);
}

void Application::setWindowVisible(bool visible, uint32_t windowId) {
  if (AppWindow *w = impl_->win(windowId)) w->setWindowVisible(visible);
}

void Application::setWindowCornerRadius(float radius, bool top, bool bottom,
                                        uint32_t windowId) {
  if (AppWindow *w = impl_->win(windowId)) {
    w->setCornerRadius(radius, top, bottom);
  }
}

bool Application::isIconified(uint32_t windowId) const {
  const AppWindow *w = impl_->win(windowId);
  return w && w->isIconified();
}

uint32_t Application::x11WindowId(uint32_t windowId) const {
  const AppWindow *w = impl_->win(windowId);
  return w ? w->x11WindowId() : 0;
}

/// The device-wide half of a frame. See `Application::beginFrameGroup`.
void Application::prepareFrames()
{
  // Resize first: growing the atlas waits on frames in flight, and a window
  // whose swapchain is about to be rebuilt has just had its idled anyway.
  for (auto &w : impl_->windows) w->prepare();
  if (impl_->deviceUp) impl_->device.syncGlyphAtlas();
}

void Application::retireFrames()
{
  if (impl_->deviceUp) impl_->device.collectGarbage();
}

void Application::beginFrameGroup()
{
  impl_->frameGroup.store(true, std::memory_order_release);
  prepareFrames();
}

void Application::endFrameGroup()
{
  retireFrames();
  impl_->frameGroup.store(false, std::memory_order_release);
}

bool Application::repaint(uint32_t windowId) {
  // Inside a group the caller has already prepared, and will retire when
  // every window is done. Doing either here would be the exact cross-window
  // reach the group exists to keep out of a running frame.
  if (impl_->frameGroup.load(std::memory_order_acquire)) {
    AppWindow *w = impl_->win(windowId);
    return w && w->repaint();
  }
  prepareFrames();
  AppWindow *w = impl_->win(windowId);
  const bool ok = w && w->repaint();
  retireFrames();
  return ok;
}

bool Application::attachDrawArena(const std::string &id, uint32_t windowId)
{
  AppWindow *w = impl_->win(windowId);
  return w && w->attachDrawArena(id);
}

void Application::detachDrawArena(uint32_t windowId)
{
  if (AppWindow *w = impl_->win(windowId)) w->detachDrawArena();
}

void Application::submitDrawList(const canvas::DrawCommand *cmds, size_t cmdCount,
                                 const canvas::GlyphInstance *glyphs,
                                 size_t glyphCount,
                                 const canvas::MeshVertex *meshVerts,
                                 size_t meshVertCount,
                                 const canvas::SpatialVertex *spatialVerts,
                                 size_t spatialVertCount,
                                 uint32_t windowId)
{
  if (AppWindow *w = impl_->win(windowId)) {
    w->submitDrawList(cmds, cmdCount, glyphs, glyphCount, meshVerts,
                      meshVertCount, spatialVerts, spatialVertCount);
  }
}

void Application::ensureDrawListCapacity(size_t cmdCapacity,
                                         size_t glyphCapacity,
                                         size_t meshVertCapacity,
                                         size_t spatialVertCapacity,
                                         uint32_t windowId)
{
  if (AppWindow *w = impl_->win(windowId)) {
    w->ensureDrawListCapacity(cmdCapacity, glyphCapacity, meshVertCapacity,
                              spatialVertCapacity);
  }
}

canvas::DrawCommand *Application::drawCommandData(uint32_t windowId) {
  AppWindow *w = impl_->win(windowId);
  return w ? w->drawCommandData() : nullptr;
}
canvas::GlyphInstance *Application::drawGlyphData(uint32_t windowId) {
  AppWindow *w = impl_->win(windowId);
  return w ? w->drawGlyphData() : nullptr;
}
canvas::MeshVertex *Application::drawMeshVertexData(uint32_t windowId) {
  AppWindow *w = impl_->win(windowId);
  return w ? w->drawMeshVertexData() : nullptr;
}
canvas::SpatialVertex *Application::drawSpatialVertexData(uint32_t windowId) {
  AppWindow *w = impl_->win(windowId);
  return w ? w->drawSpatialVertexData() : nullptr;
}
size_t Application::drawCommandCapacity(uint32_t windowId) const {
  const AppWindow *w = impl_->win(windowId);
  return w ? w->drawCommandCapacity() : 0;
}
size_t Application::drawGlyphCapacity(uint32_t windowId) const {
  const AppWindow *w = impl_->win(windowId);
  return w ? w->drawGlyphCapacity() : 0;
}
size_t Application::drawMeshVertexCapacity(uint32_t windowId) const {
  const AppWindow *w = impl_->win(windowId);
  return w ? w->drawMeshVertexCapacity() : 0;
}
size_t Application::drawSpatialVertexCapacity(uint32_t windowId) const {
  const AppWindow *w = impl_->win(windowId);
  return w ? w->drawSpatialVertexCapacity() : 0;
}

void Application::commitDrawList(size_t cmdCount, size_t glyphCount,
                                 size_t meshVertCount, size_t spatialVertCount,
                                 uint32_t windowId)
{
  if (AppWindow *w = impl_->win(windowId)) {
    w->commitDrawList(cmdCount, glyphCount, meshVertCount, spatialVertCount);
  }
}

bool Application::pollInputEvent(canvas::InputEvent &out, uint32_t windowId)
{
  AppWindow *w = impl_->win(windowId);
  return w && w->pollInputEvent(out);
}

int Application::pendingDroppedFileCount(uint32_t windowId)
{
  AppWindow *w = impl_->win(windowId);
  return w ? w->pendingDroppedFileCount() : 0;
}

std::string Application::pendingDroppedFile(int index, uint32_t windowId)
{
  AppWindow *w = impl_->win(windowId);
  return w ? w->pendingDroppedFile(index) : std::string{};
}

void Application::framebufferSize(float &outW, float &outH, uint32_t windowId) const
{
  outW = 0.f;
  outH = 0.f;
  if (const AppWindow *w = impl_->win(windowId)) w->framebufferSize(outW, outH);
}

void Application::setViewTransform(float zoom, float panX, float panY,
                                   uint32_t windowId)
{
  if (AppWindow *w = impl_->win(windowId)) w->setViewTransform(zoom, panX, panY);
}

canvas::VoidResult Application::loadFont(const std::string &path, float pixelSize)
{
  return impl_->loadFont(path, pixelSize);
}

std::string Application::clipboardText() const {
  const AppWindow *w = impl_->win(0);
  return w ? w->clipboardText() : std::string{};
}

void Application::setClipboardText(const std::string &text)
{
  if (AppWindow *w = impl_->win(0)) w->setClipboardText(text);
}

int Application::registerFont(const std::string &path, uint32_t pixelSize26_6,
                              uint32_t faceIndex, uint32_t rasterFlags)
{
  return impl_->registerFont(path, pixelSize26_6, faceIndex, rasterFlags);
}

int Application::loadTexture(const std::string &path)
{
  return impl_->loadTexture(path);
}

void Application::unloadTexture(const std::string &path)
{
  impl_->unloadTexture(path);
}

int Application::uploadTexture(const std::string &key, const uint8_t *rgba,
                               uint32_t width, uint32_t height)
{
  return impl_->uploadTexture(key, rgba, width, height);
}

bool Application::hasTexture(const std::string &key) const
{
  return impl_->hasTexture(key);
}

bool Application::textureSize(uint32_t textureId, float &outW, float &outH) const
{
  return impl_->textureSize(textureId, outW, outH);
}

void Application::pointerMove(float x, float y, uint32_t windowId) {
  if (AppWindow *w = impl_->win(windowId)) w->pointerMove(x, y);
}

void Application::pointerButton(int button, bool pressed, float x, float y,
                                uint32_t windowId) {
  if (AppWindow *w = impl_->win(windowId)) w->pointerButton(button, pressed, x, y);
}

void Application::keyEvent(int key, int action, int mods, uint32_t windowId) {
  if (AppWindow *w = impl_->win(windowId)) w->keyEvent(key, action, mods);
}

void Application::textInput(const std::string &utf8, uint32_t windowId) {
  if (AppWindow *w = impl_->win(windowId)) w->textInput(utf8);
}

void Application::scroll(float dx, float dy, uint32_t windowId) {
  if (AppWindow *w = impl_->win(windowId)) w->scroll(dx, dy);
}

void Application::readPixels(uint8_t *dst, size_t dstSize, uint32_t windowId) {
  if (AppWindow *w = impl_->win(windowId)) w->readPixels(dst, dstSize);
}

void Application::captureFrame(uint8_t *dst, size_t dstSize, uint32_t windowId) {
  if (AppWindow *w = impl_->win(windowId)) w->captureFrame(dst, dstSize);
}

bool Application::capturePng(std::vector<uint8_t> &outPng, int x, int y, int w,
                             int h, int maxSide, int *outW, int *outH,
                             uint32_t windowId) {
  AppWindow *win = impl_->win(windowId);
  return win && win->capturePng(outPng, x, y, w, h, maxSide, outW, outH);
}

std::string Application::capturePngBase64(int x, int y, int w, int h,
                                          int maxSide, int *outW, int *outH,
                                          uint32_t windowId) {
  std::vector<uint8_t> png;
  if (!capturePng(png, x, y, w, h, maxSide, outW, outH, windowId) || png.empty())
    return {};
  // Local base64 (same table as device.cpp helper).
  static constexpr char kTable[] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  std::string out;
  out.reserve(((png.size() + 2) / 3) * 4);
  size_t i = 0;
  const uint8_t *data = png.data();
  const size_t len = png.size();
  while (i + 2 < len) {
    const uint32_t n = (uint32_t(data[i]) << 16) | (uint32_t(data[i + 1]) << 8) |
                       uint32_t(data[i + 2]);
    out.push_back(kTable[(n >> 18) & 63]);
    out.push_back(kTable[(n >> 12) & 63]);
    out.push_back(kTable[(n >> 6) & 63]);
    out.push_back(kTable[n & 63]);
    i += 3;
  }
  if (i < len) {
    uint32_t n = uint32_t(data[i]) << 16;
    out.push_back(kTable[(n >> 18) & 63]);
    if (i + 1 < len) {
      n |= uint32_t(data[i + 1]) << 8;
      out.push_back(kTable[(n >> 12) & 63]);
      out.push_back(kTable[(n >> 6) & 63]);
      out.push_back('=');
    } else {
      out.push_back(kTable[(n >> 12) & 63]);
      out.push_back('=');
      out.push_back('=');
    }
  }
  return out;
}

void Application::shutdown() {
  impl_->shutdown();
}

Application::Application(int w, int h) {
  impl_ = std::make_unique<Application::Impl>(w, h);
}

Application::~Application() = default;
