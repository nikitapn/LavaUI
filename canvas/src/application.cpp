
#include <chrono>
#include <format>
#include <algorithm>
#include <optional>
#include <filesystem>

#include "application.hpp"

#include "util/constants.hpp"
#include "util/key_codes.hpp"
#include "render/render_device.hpp"
#include "render/render_window.hpp"
#include "window/app_window.hpp"
#include "render/text_renderer.hpp"
#include "render/quad_renderer.hpp"
#include "render/texture_manager.hpp"
#include "render/blur_pass.hpp"

#include "render/draw_command.hpp"

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
  RenderDevice device;

  /// Open windows, in creation order. `windows[0]` is the one every
  /// window-less overload of the public API means, which keeps single-window
  /// callers from having to care that this is a list.
  std::vector<std::unique_ptr<AppWindow>> windows;
  /// Ids are never reused, so a stale handle from a closed window fails to
  /// resolve instead of quietly addressing whatever opened next.
  uint32_t nextWindowId = 1;

  TextureHandle shadowMapTexture;

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

    shadowMapTexture = TextureManager::getInstance().registerTexture("shadowMap",
      device.getShadowImageView(), device.getShadowMapSize(), device.getShadowMapSize());

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

  canvas::VoidResult initWithWindow(
    const std::string &assetsRoot, const std::string &title)
  {
    try {
      if (!assetsRoot.empty()) {
        std::filesystem::current_path(assetsRoot);
      }
      device.init("2d shenanigans!", /*presentCapable=*/true);
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
      return;
    }
  }

  int registerFont(const std::string &path, float pixelSize)
  {
    return device.textRenderer().registerFont(path, pixelSize);
  }

  canvas::VoidResult loadFont(const std::string &path, float pixelSize)
  {
    return device.textRenderer().loadFont(path, static_cast<int>(pixelSize));
  }

  int loadTexture(const std::string &path)
  {
    auto h = TextureManager::getInstance().loadTexture(path);
    return h.isValid() ? static_cast<int>(h.id) : -1;
  }

  void unloadTexture(const std::string &path)
  {
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
    TextureManager::getInstance().cleanUp();
    // Windows before the device: they hold attachments and sync objects made
    // from resources cleanUp is about to destroy, and the device asserts on
    // any still registered.
    windows.clear();
    device.cleanUp();
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

bool Application::isIconified(uint32_t windowId) const {
  const AppWindow *w = impl_->win(windowId);
  return w && w->isIconified();
}

uint32_t Application::x11WindowId(uint32_t windowId) const {
  const AppWindow *w = impl_->win(windowId);
  return w ? w->x11WindowId() : 0;
}

bool Application::repaint(uint32_t windowId) {
  AppWindow *w = impl_->win(windowId);
  return w && w->repaint();
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

int Application::registerFont(const std::string &path, float pixelSize)
{
  return impl_->registerFont(path, pixelSize);
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
