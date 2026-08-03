
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

  RenderDevice     device;
  /// The one window this Application drives. A pointer because the device is
  /// brought up first and the window attaches to it afterwards — and because
  /// the next step is for this to become a list.
  std::unique_ptr<RenderWindow> window;
  /// Owned by us, not by RenderWindow: the surface is the renderer's business,
  /// the GLFW window is the platform's.
  GLFWwindow      *glfwWindow = nullptr;


  Timer treeTimer;

  // FPS/frame bookkeeping — was local to the old run() loop; now needs to
  // persist across external tick() calls.
  int   frameCount = 0;
  int   frameCountTotal = 0;
  float fpsTimer = 0.0f;
  float currentFPS = 0.0f;

  TextureHandle shadowMapTexture;

  bool renderShadowDebug    = false;
  bool renderBricksDebug    = false;
  bool renderOctreeDebug    = false;
  bool renderNormalsDebug   = false;
  bool renderWireframeDebug = false;

  // Input state tracking
  struct InputState {
    bool keys[KEY_LAST] = {false};
    bool mouseButtons[MOUSE_BUTTON_LAST] = {false};
    double mouseX = 0.0, mouseY = 0.0;
    double lastMouseX = 0.0, lastMouseY = 0.0;
    bool firstMouse = true;
    bool mouseCaptured = false;
  } inputState;

  // Maps pixel coordinates (0,0 top-left, y-down) straight to clip space.
  // LineRenderer expects an explicit view/projection pair rather than baking
  // its own; QuadRenderer does the same mapping from a push constant.
  mat4 screenProjection_{1.0f};

  // Wall-clock time of the last repaint() call, used only to compute a
  // deltaTime for the FPS counter (nullopt on the first call).
  std::optional<std::chrono::steady_clock::time_point> lastRepaintTime;

 public:
  Impl(int w, int h)
    : width{static_cast<float>(w)}
    , height{static_cast<float>(h)}
    {

    }

  // The GLFW callback functions that used to sit here (keyCallback,
  // charCallback, mouseButtonCallback, mouseMoveCallback, scrollCallback)
  // are gone along with the window they were registered against. The
  // handle*Input methods below are what a future input bridge (fed from
  // outside this engine) should call directly instead.

  // Instance method to handle key input
  void handleKeyInput(int key, int scancode, int action, int mods)
  {
    // Update key state tracking
    if (key >= 0 && key < KEY_LAST) {
      if (action == ACTION_PRESS) {
        inputState.keys[key] = true;
      } else if (action == ACTION_RELEASE) {
        inputState.keys[key] = false;
      }
    }
  }

  // Mouse button handler
  void handleMouseButton(int button, int action, int mods)
  {
    if (button >= 0 && button < MOUSE_BUTTON_LAST) {
      if (action == ACTION_PRESS) {
        inputState.mouseButtons[button] = true;
      } else if (action == ACTION_RELEASE) {
        inputState.mouseButtons[button] = false;
      }
    }
  }

  // Mouse movement handler  
  void handleMouseMove(double xpos, double ypos)
  {
    inputState.mouseX = xpos;
    inputState.mouseY = ypos;
  }

  // Scroll handler (for zoom/FOV)
  void handleScroll(double xoffset, double yoffset)
  {
  }

  /// Resolve `<assetsRoot>/assets/<file>` without depending on process cwd.
  static std::filesystem::path assetPath(
    const std::string &assetsRoot, const std::string &relativeUnderAssets)
  {
    return std::filesystem::path(assetsRoot) / "assets" / relativeUnderAssets;
  }

  canvas::VoidResult finishInitCommon(const std::string &assetsRoot)
  {
    // Use actual Vulkan extent (may match framebuffer in windowed mode).
    const float ew = static_cast<float>(window->getExtent().width);
    const float eh = static_cast<float>(window->getExtent().height);

    TextureManager::getInstance().initialize(device);
    std::cout << "TextureManager initialized.\n";

    device.textRenderer().init();
    // No default face here — Swift owns font policy (FontStore) and calls
    // loadFont(path, size) after open so measure and draw use the same choice.
    std::cout << "Text renderer initialized (font pending from Swift).\n";

    // The window owns its renderers (quads + blur); this is where they get
    // their pipelines. Glyphs and shapes share one descriptor set, so scissor
    // is the only thing that can break a batch.
    window->initRenderers();
    window->setGlyphAtlas(device.textRenderer().atlasView(),
                          device.textRenderer().atlasSampler());
    std::cout << "Window renderers initialized.\n";

    screenProjection_ = mat4{ // column-major, top-left origin, y-down
      2.0f / ew, 0.0f, 0.0f, 0.0f,
      0.0f, 2.0f / eh, 0.0f, 0.0f,
      0.0f,  0.0f, 0.0f, 0.0f,
      -1.0f, -1.0f, 0.0f, 1.0f
    };

    shadowMapTexture = TextureManager::getInstance().registerTexture("shadowMap",
      device.getShadowImageView(), device.getShadowMapSize(), device.getShadowMapSize());

    std::cout << "Init complete.\n";
    return canvas::ok();
  }

  void installGlfwCallbacks()
  {
    GLFWwindow *win = glfwWindow;
    if (!win) return;
    glfwSetWindowUserPointer(win, this);

    glfwSetCursorPosCallback(win, [](GLFWwindow *w, double x, double y) {
      auto *self = static_cast<Impl *>(glfwGetWindowUserPointer(w));
      if (!self) return;
      self->bridgePointerMove(static_cast<float>(x), static_cast<float>(y));
    });

    glfwSetMouseButtonCallback(win, [](GLFWwindow *w, int button, int action, int mods) {
      auto *self = static_cast<Impl *>(glfwGetWindowUserPointer(w));
      if (!self) return;
      double x = 0, y = 0;
      glfwGetCursorPos(w, &x, &y);
      self->bridgePointerButton(
        button, action == GLFW_PRESS, static_cast<float>(x), static_cast<float>(y), mods);
    });

    glfwSetKeyCallback(win, [](GLFWwindow *w, int key, int /*scancode*/, int action, int mods) {
      auto *self = static_cast<Impl *>(glfwGetWindowUserPointer(w));
      if (!self) return;
      // GLFW action/mods already match our key_codes.hpp conventions.
      self->bridgeKeyEvent(key, action, mods);
    });

    glfwSetScrollCallback(win, [](GLFWwindow *w, double dx, double dy) {
      auto *self = static_cast<Impl *>(glfwGetWindowUserPointer(w));
      if (!self) return;
      self->bridgeScroll(static_cast<float>(dx), static_cast<float>(dy));
    });

    glfwSetCharCallback(win, [](GLFWwindow *w, unsigned int codepoint) {
      auto *self = static_cast<Impl *>(glfwGetWindowUserPointer(w));
      if (!self) return;
      self->bridgeCharInput(codepoint);
    });

    // Live drag-resize: notify Swift on every framebuffer change. Without this,
    // Resize was only enqueued inside repaint()→ensureFramebufferSize(), so the
    // idle loop (wait for events, no work → no repaint) never saw size changes
    // until something else dirtied the frame.
    glfwSetFramebufferSizeCallback(win, [](GLFWwindow *w, int width, int height) {
      auto *self = static_cast<Impl *>(glfwGetWindowUserPointer(w));
      if (!self || width < 1 || height < 1) return;
      canvas::InputEvent ev;
      ev.kind = static_cast<uint32_t>(canvas::InputEventKind::Resize);
      ev.x = static_cast<float>(width);
      ev.y = static_cast<float>(height);
      ev.button = 0;
      {
        std::lock_guard lock(self->inputMu_);
        // Coalesce: keep only the latest size if several arrive before poll.
        if (!self->inputEvents_.empty() &&
            self->inputEvents_.back().kind ==
              static_cast<uint32_t>(canvas::InputEventKind::Resize)) {
          self->inputEvents_.back() = ev;
        } else {
          self->inputEvents_.push_back(ev);
        }
      }
    });

    // Damage / expose: compositor asks for a redraw (also fires after some
    // un-minimize paths). Pure redraw — swapchain size is unchanged.
    glfwSetWindowRefreshCallback(win, [](GLFWwindow *w) {
      auto *self = static_cast<Impl *>(glfwGetWindowUserPointer(w));
      if (!self) return;
      self->queueRefreshEvent();
    });

    // Minimize → restore: always force a present. Refresh alone is not
    // reliable on every WM; iconify(false) is the definitive un-minimize signal.
    glfwSetWindowIconifyCallback(win, [](GLFWwindow *w, int iconified) {
      auto *self = static_cast<Impl *>(glfwGetWindowUserPointer(w));
      if (!self || iconified) return;  // ignore going to tray
      self->queueRefreshEvent();
    });

    glfwSetDropCallback(win, [](GLFWwindow *w, int count, const char **paths) {
      auto *self = static_cast<Impl *>(glfwGetWindowUserPointer(w));
      if (!self || count <= 0) return;
      double x = 0, y = 0;
      glfwGetCursorPos(w, &x, &y);
      canvas::InputEvent ev;
      ev.kind = static_cast<uint32_t>(canvas::InputEventKind::FileDrop);
      ev.x = static_cast<float>(x);
      ev.y = static_cast<float>(y);
      ev.button = count;
      {
        std::lock_guard lock(self->inputMu_);
        // Overwritten by the next drop, same as every other "pull the
        // payload while handling this event" queue in this file — nothing
        // needs more than one pending drop at a time.
        self->droppedPaths_.assign(paths, paths + count);
        self->inputEvents_.push_back(ev);
      }
    });
  }

  void queueRefreshEvent()
  {
    canvas::InputEvent ev;
    ev.kind = static_cast<uint32_t>(canvas::InputEventKind::Refresh);
    ev.x = 0.f;
    ev.y = 0.f;
    ev.button = 0;
    std::lock_guard lock(inputMu_);
    // One is enough until the app paints again.
    if (!inputEvents_.empty() &&
        inputEvents_.back().kind ==
          static_cast<uint32_t>(canvas::InputEventKind::Refresh)) {
      return;
    }
    inputEvents_.push_back(ev);
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
      window = std::make_unique<RenderWindow>(
        device, static_cast<uint32_t>(width), static_cast<uint32_t>(height));
      std::cout << "Vulkan initialized (offscreen).\n";
      return finishInitCommon(assetsRoot);
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

      // GLFW window creation lives here rather than in RenderWindow: these
      // hints are app policy (focus behaviour, WM class), and a compositor
      // handing us a surface from elsewhere should not have to go through
      // GLFW at all.
      glfwWindowHint(GLFW_CLIENT_API, GLFW_NO_API);
      glfwWindowHint(GLFW_RESIZABLE, GLFW_TRUE);
      // Prefer not stealing focus from the Swift chrome window on open.
      glfwWindowHint(GLFW_FOCUS_ON_SHOW, GLFW_FALSE);
      glfwWindowHint(GLFW_VISIBLE, GLFW_TRUE);
      glfwWindow = glfwCreateWindow(
        static_cast<int>(width), static_cast<int>(height),
        title.empty() ? "Canvas" : title.c_str(), nullptr, nullptr);
      if (!glfwWindow) {
        return canvas::fail("Application::initWithWindow: glfwCreateWindow failed");
      }

      window = std::make_unique<RenderWindow>(device, glfwWindow);
      std::cout << "Vulkan initialized (windowed).\n";
      if (auto r = finishInitCommon(assetsRoot); !r) {
        return r;
      }
      installGlfwCallbacks();
      return canvas::ok();
    } catch (const std::exception &ex) {
      return canvas::fail(std::string("Application::initWithWindow: ") + ex.what());
    } catch (...) {
      return canvas::fail("Application::initWithWindow: unknown error");
    }
  }

  bool windowShouldClose() const
  {
    return window->windowShouldClose();
  }

  void requestClose() { window->requestClose(); }

  void setWindowFrame(int x, int y, int width, int height)
  {
    window->setWindowFrame(x, y, width, height);
  }

  void setWindowVisible(bool visible)
  {
    window->setWindowVisible(visible);
  }

  void syncProjectionToExtent()
  {
    const float ew = static_cast<float>(window->getExtent().width);
    const float eh = static_cast<float>(window->getExtent().height);
    if (ew < 1.f || eh < 1.f) return;
    screenProjection_ = mat4{
      2.0f / ew, 0.0f, 0.0f, 0.0f,
      0.0f, 2.0f / eh, 0.0f, 0.0f,
      0.0f,  0.0f, 0.0f, 0.0f,
      -1.0f, -1.0f, 0.0f, 1.0f
    };
  }

  void bridgePointerMove(float x, float y)
  {
    inputState.mouseX = x;
    inputState.mouseY = y;
    // Hover highlighting needs free motion too, not just drags — but motion
    // arrives per pixel and the queue is unbounded. Coalescing keeps at most
    // one pending move: consumers only ever want the latest position, and a
    // superseded one carries no information.
    canvas::InputEvent ev;
    ev.kind = static_cast<uint32_t>(canvas::InputEventKind::MouseMove);
    ev.x = x;
    ev.y = y;
    ev.button = pointerDown_ ? 1 : 0;  // so Swift can tell drag from hover
    {
      std::lock_guard lock(inputMu_);
      if (!inputEvents_.empty() &&
          inputEvents_.back().kind ==
            static_cast<uint32_t>(canvas::InputEventKind::MouseMove)) {
        inputEvents_.back() = ev;
      } else {
        inputEvents_.push_back(ev);
      }
    }
  }

  // mods is only ever non-zero from the live GLFW callback below — injected
  // clicks (Application::pointerButton, used by Swift/agent input) have no
  // modifier source and keep the 0 default.
  void bridgePointerButton(int button, bool pressed, float x, float y, int mods = 0) {
    inputState.mouseX = x;
    inputState.mouseY = y;
    // Queue raw input for Swift hit-testing (Phase 3+).
    if (button == MOUSE_BUTTON_1) {
      pointerDown_ = pressed;
      canvas::InputEvent ev;
      ev.kind =
          static_cast<uint32_t>(pressed ? canvas::InputEventKind::MouseDown
                                        : canvas::InputEventKind::MouseUp);
      ev.x = x;
      ev.y = y;
      ev.button = button;
      ev.mods = mods;
      {
        std::lock_guard lock(inputMu_);
        inputEvents_.push_back(ev);
      }
    }

  }

  void bridgeKeyEvent(int key, int action, int mods)
  {
    // Keep legacy input-state tracking for continuous camera keys.
    if (key >= 0 && key < KEY_LAST) {
      if (action == ACTION_PRESS) {
        inputState.keys[key] = true;
      } else if (action == ACTION_RELEASE) {
        inputState.keys[key] = false;
      }
    }

    // Forward to Swift (zoom, shortcuts). Use full GLFW key range.
    if (action == ACTION_PRESS || action == ACTION_REPEAT || action == ACTION_RELEASE) {
      canvas::InputEvent ev;
      ev.kind = static_cast<uint32_t>(canvas::InputEventKind::Key);
      ev.button = key;
      ev.x = static_cast<float>(action);
      ev.y = static_cast<float>(mods);
      {
        std::lock_guard lock(inputMu_);
        inputEvents_.push_back(ev);
      }
    }

    handleKeyInput(key, 0, action, mods);
  }

  void setViewTransform(float zoom, float panX, float panY)
  {
    viewZoom_ = zoom > 0.f ? zoom : 1.f;
    viewPanX_ = panX;
    viewPanY_ = panY;
    window->setViewTransform(viewZoom_, viewPanX_, viewPanY_);
  }

  void bridgeTextInput(const std::string &utf8)
  {
    // Agent / synthetic path: expand UTF-8 into one Text event per codepoint
    // (same queue as GLFW char callback → bridgeCharInput).
    size_t i = 0;
    while (i < utf8.size()) {
      unsigned char c = static_cast<unsigned char>(utf8[i]);
      uint32_t cp = 0;
      size_t n = 0;
      if (c < 0x80) {
        cp = c;
        n = 1;
      } else if ((c & 0xE0) == 0xC0 && i + 1 < utf8.size()) {
        cp = (c & 0x1F) << 6 | (static_cast<unsigned char>(utf8[i + 1]) & 0x3F);
        n = 2;
      } else if ((c & 0xF0) == 0xE0 && i + 2 < utf8.size()) {
        cp = (c & 0x0F) << 12 |
             (static_cast<unsigned char>(utf8[i + 1]) & 0x3F) << 6 |
             (static_cast<unsigned char>(utf8[i + 2]) & 0x3F);
        n = 3;
      } else if ((c & 0xF8) == 0xF0 && i + 3 < utf8.size()) {
        cp = (c & 0x07) << 18 |
             (static_cast<unsigned char>(utf8[i + 1]) & 0x3F) << 12 |
             (static_cast<unsigned char>(utf8[i + 2]) & 0x3F) << 6 |
             (static_cast<unsigned char>(utf8[i + 3]) & 0x3F);
        n = 4;
      } else {
        ++i;
        continue;
      }
      bridgeCharInput(cp);
      i += n;
    }
  }

  void bridgeScroll(float dx, float dy)
  {
    canvas::InputEvent ev;
    ev.kind = static_cast<uint32_t>(canvas::InputEventKind::Scroll);
    ev.x = dx;
    ev.y = dy;
    // Modifiers travel with the event so Ctrl+wheel can be distinguished
    // without Swift tracking key state itself.
    int mods = 0;
    if (inputState.keys[KEY_LEFT_SHIFT]) mods |= 0x0001;
    if (inputState.keys[KEY_LEFT_CONTROL]) mods |= 0x0002;
    ev.button = mods;
    {
      std::lock_guard lock(inputMu_);
      // Coalesce: only the accumulated delta matters, and a wheel can emit
      // faster than the frame loop consumes.
      if (!inputEvents_.empty() &&
          inputEvents_.back().kind ==
            static_cast<uint32_t>(canvas::InputEventKind::Scroll)) {
        inputEvents_.back().x += ev.x;
        inputEvents_.back().y += ev.y;
      } else {
        inputEvents_.push_back(ev);
      }
    }
  }

  /// Queues one committed character for Swift. This is the only reliable
  /// source of "what did the user type": key codes are physical and say
  /// nothing about layout, dead keys, or shift state.
  void bridgeCharInput(unsigned int codepoint)
  {
    canvas::InputEvent ev;
    ev.kind = static_cast<uint32_t>(canvas::InputEventKind::Text);
    ev.button = static_cast<int32_t>(codepoint);
    {
      std::lock_guard lock(inputMu_);
      inputEvents_.push_back(ev);
    }
  }

  std::string clipboardText() const
  {
    if (!window->isWindowed() || !glfwWindow) return {};
    const char *s = glfwGetClipboardString(glfwWindow);
    return s ? std::string(s) : std::string{};
  }

  void setClipboardText(const std::string &text)
  {
    if (!window->isWindowed() || !glfwWindow) return;
    glfwSetClipboardString(glfwWindow, text.c_str());
  }

  bool repaint()
  {
    try {
      if (window->isWindowed() && window->resize()) {
        syncProjectionToExtent();
        // Notify Swift so it re-runs Yoga + resubmits the draw list.
        // Without this, C++ presents the old fixed-size command list into
        // the larger framebuffer (layout stuck at open size).
        canvas::InputEvent ev;
        ev.kind = static_cast<uint32_t>(canvas::InputEventKind::Resize);
        ev.x = static_cast<float>(window->getExtent().width);
        ev.y = static_cast<float>(window->getExtent().height);
        ev.button = 0;
        {
          std::lock_guard lock(inputMu_);
          inputEvents_.push_back(ev);
        }
      }

      auto now = std::chrono::steady_clock::now();
      float deltaTime = lastRepaintTime
        ? std::chrono::duration<float>(now - *lastRepaintTime).count()
        : 1.0f / 60.0f;
      lastRepaintTime = now;

      treeTimer.update(deltaTime);

      // FPS calculation
      ++frameCount;
      ++frameCountTotal;
      fpsTimer += deltaTime;

      // Update FPS every 0.5 seconds
      if (fpsTimer >= 0.5f) {
        currentFPS = frameCount / fpsTimer;
        frameCount = 0;
        fpsTimer = 0.0f;
      }

      // Everything from here to the swapchain belongs to the window: replay,
      // blur segmentation, submit, present. Application's remaining job is to
      // own the arena those commands were written into.
      window->render(currentDrawList());

      return true;
    } catch (std::exception &ex) {
      std::cerr << ex.what() << '\n';
      return false;
    }
  }

  /// A view over the arena Swift last committed into.
  canvas::DrawList currentDrawList() const
  {
    return canvas::DrawList{
      .commands           = drawCmds_.data(),
      .commandCount       = drawCmdCount_,
      .glyphs             = drawGlyphs_.data(),
      .glyphCount         = drawGlyphCount_,
      .meshVertices       = drawMeshVerts_.data(),
      .meshVertexCount    = drawMeshVertCount_,
      .spatialVertices    = drawSpatialVerts_.data(),
      .spatialVertexCount = drawSpatialVertCount_,
    };
  }

  void readPixels(uint8_t *dst, size_t dstSize)
  {
    window->readPixels(dst, dstSize);
  }

  // Immediate draw list (Phase 3) — authored by Swift each dirty frame.
  std::vector<canvas::DrawCommand> drawCmds_;
  std::vector<canvas::GlyphInstance> drawGlyphs_;
  std::vector<canvas::MeshVertex> drawMeshVerts_;
  std::vector<canvas::SpatialVertex> drawSpatialVerts_;
  size_t drawCmdCount_ = 0;
  size_t drawGlyphCount_ = 0;
  size_t drawMeshVertCount_ = 0;
  size_t drawSpatialVertCount_ = 0;
  /// Reused across Mesh commands to convert `MeshVertex` (Swift-facing POD)
  /// to `vec2` (the engine's internal type) without a fresh allocation
  /// every wedge, every frame.
  // GLFW callbacks (render thread, outside window mutex) vs Swift poll (under
  // window mutex) — protect the queue so Resize/Key/Mouse are not lost.
  bool pointerDown_ = false;  // gates MouseMove queueing
  std::mutex inputMu_;
  std::deque<canvas::InputEvent> inputEvents_;
  // Paths from the most recent drop, pulled by index while handling the
  // FileDrop InputEvent it was queued alongside — see the note on
  // InputEventKind::FileDrop for why this doesn't fit the event itself.
  std::vector<std::string> droppedPaths_;

  // Whole-window camera (layout stays at zoom=1; vertex shader applies this).
  float viewZoom_ = 1.f;
  float viewPanX_ = 0.f;
  float viewPanY_ = 0.f;

  void submitDrawList(const canvas::DrawCommand *cmds, size_t cmdCount,
                      const canvas::GlyphInstance *glyphs, size_t glyphCount,
                      const canvas::MeshVertex *meshVerts, size_t meshVertCount,
                      const canvas::SpatialVertex *spatialVerts, size_t spatialVertCount)
  {
    drawCmds_.assign(cmds, cmds + cmdCount);
    drawGlyphs_.assign(glyphs, glyphs + glyphCount);
    drawMeshVerts_.assign(meshVerts, meshVerts + meshVertCount);
    drawSpatialVerts_.assign(spatialVerts, spatialVerts + spatialVertCount);
    drawCmdCount_ = cmdCount;
    drawGlyphCount_ = glyphCount;
    drawMeshVertCount_ = meshVertCount;
    drawSpatialVertCount_ = spatialVertCount;
  }

  void ensureDrawListCapacity(size_t cmdCapacity, size_t glyphCapacity,
                              size_t meshVertCapacity, size_t spatialVertCapacity)
  {
    if (drawCmds_.size() < cmdCapacity) drawCmds_.resize(cmdCapacity);
    if (drawGlyphs_.size() < glyphCapacity) drawGlyphs_.resize(glyphCapacity);
    if (drawMeshVerts_.size() < meshVertCapacity) {
      drawMeshVerts_.resize(meshVertCapacity);
    }
    if (drawSpatialVerts_.size() < spatialVertCapacity) {
      drawSpatialVerts_.resize(spatialVertCapacity);
    }
  }

  void commitDrawList(size_t cmdCount, size_t glyphCount, size_t meshVertCount,
                      size_t spatialVertCount)
  {
    drawCmdCount_ = std::min(cmdCount, drawCmds_.size());
    drawGlyphCount_ = std::min(glyphCount, drawGlyphs_.size());
    drawMeshVertCount_ = std::min(meshVertCount, drawMeshVerts_.size());
    drawSpatialVertCount_ = std::min(spatialVertCount, drawSpatialVerts_.size());
  }

  bool pollInputEvent(canvas::InputEvent &out)
  {
    std::lock_guard lock(inputMu_);
    if (inputEvents_.empty()) return false;
    out = inputEvents_.front();
    inputEvents_.pop_front();
    return true;
  }

  int pendingDroppedFileCount()
  {
    std::lock_guard lock(inputMu_);
    return static_cast<int>(droppedPaths_.size());
  }

  std::string pendingDroppedFile(int index)
  {
    std::lock_guard lock(inputMu_);
    if (index < 0 || static_cast<size_t>(index) >= droppedPaths_.size()) return {};
    return droppedPaths_[index];
  }

  void framebufferSize(float &outW, float &outH) const
  {
    // Prefer the *live* GLFW size so the Swift safety net sees drag-resize
    // before ensureFramebufferSize() updates the swapchain extent.
    if (window->isWindowed() && glfwWindow) {
      int fbW = 0, fbH = 0;
      glfwGetFramebufferSize(glfwWindow, &fbW, &fbH);
      if (fbW >= 1 && fbH >= 1) {
        outW = static_cast<float>(fbW);
        outH = static_cast<float>(fbH);
        return;
      }
    }
    const auto e = window->getExtent();
    outW = static_cast<float>(e.width);
    outH = static_cast<float>(e.height);
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
    window.reset();
    device.cleanUp();
    // After glfwTerminate() inside device.cleanUp(), which already destroyed
    // every remaining GLFW window — clear the dangling handle rather than
    // double-destroying it.
    glfwWindow = nullptr;
  }
};

// Public Application interface
canvas::VoidResult Application::init(const std::string &assetsRoot) {
  return impl_->init(assetsRoot);
}

canvas::VoidResult Application::initWithWindow(
  const std::string &assetsRoot, const std::string &title)
{
  return impl_->initWithWindow(assetsRoot, title);
}

bool Application::windowShouldClose() const {
  return impl_->windowShouldClose();
}

void Application::requestClose() {
  impl_->requestClose();
}

void Application::setWindowFrame(int x, int y, int width, int height) {
  impl_->setWindowFrame(x, y, width, height);
}

void Application::setWindowVisible(bool visible) {
  impl_->setWindowVisible(visible);
}

void Application::submitDrawList(const canvas::DrawCommand *cmds, size_t cmdCount,
                                 const canvas::GlyphInstance *glyphs,
                                 size_t glyphCount,
                                 const canvas::MeshVertex *meshVerts,
                                 size_t meshVertCount,
                                 const canvas::SpatialVertex *spatialVerts,
                                 size_t spatialVertCount)
{
  impl_->submitDrawList(cmds, cmdCount, glyphs, glyphCount, meshVerts, meshVertCount,
                        spatialVerts, spatialVertCount);
}

void Application::ensureDrawListCapacity(size_t cmdCapacity,
                                         size_t glyphCapacity,
                                         size_t meshVertCapacity,
                                         size_t spatialVertCapacity)
{
  impl_->ensureDrawListCapacity(cmdCapacity, glyphCapacity, meshVertCapacity,
                                spatialVertCapacity);
}

canvas::DrawCommand *Application::drawCommandData() { return impl_->drawCmds_.data(); }
canvas::GlyphInstance *Application::drawGlyphData() { return impl_->drawGlyphs_.data(); }
canvas::MeshVertex *Application::drawMeshVertexData() { return impl_->drawMeshVerts_.data(); }
canvas::SpatialVertex *Application::drawSpatialVertexData() { return impl_->drawSpatialVerts_.data(); }
size_t Application::drawCommandCapacity() const { return impl_->drawCmds_.size(); }
size_t Application::drawGlyphCapacity() const { return impl_->drawGlyphs_.size(); }
size_t Application::drawMeshVertexCapacity() const { return impl_->drawMeshVerts_.size(); }
size_t Application::drawSpatialVertexCapacity() const { return impl_->drawSpatialVerts_.size(); }

void Application::commitDrawList(size_t cmdCount, size_t glyphCount,
                                 size_t meshVertCount, size_t spatialVertCount)
{
  impl_->commitDrawList(cmdCount, glyphCount, meshVertCount, spatialVertCount);
}

bool Application::pollInputEvent(canvas::InputEvent &out)
{
  return impl_->pollInputEvent(out);
}

int Application::pendingDroppedFileCount()
{
  return impl_->pendingDroppedFileCount();
}

std::string Application::pendingDroppedFile(int index)
{
  return impl_->pendingDroppedFile(index);
}

void Application::framebufferSize(float &outW, float &outH) const
{
  impl_->framebufferSize(outW, outH);
}

void Application::setViewTransform(float zoom, float panX, float panY)
{
  impl_->setViewTransform(zoom, panX, panY);
}

canvas::VoidResult Application::loadFont(const std::string &path, float pixelSize)
{
  return impl_->loadFont(path, pixelSize);
}

std::string Application::clipboardText() const { return impl_->clipboardText(); }

void Application::setClipboardText(const std::string &text)
{
  impl_->setClipboardText(text);
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

bool Application::repaint() {
  return impl_->repaint();
}

bool Application::isIconified() const {
  GLFWwindow *win = impl_->glfwWindow;
  return win && glfwGetWindowAttrib(win, GLFW_ICONIFIED) != 0;
}

uint32_t Application::x11WindowId() const
{
#if defined(CANVAS_HAVE_X11)
  GLFWwindow *win = impl_->glfwWindow;
  if (!win) return 0;
  if (glfwGetPlatform() != GLFW_PLATFORM_X11) return 0;
  return static_cast<uint32_t>(glfwGetX11Window(win));
#else
  return 0;
#endif
}

void Application::pointerMove(float x, float y) {
  impl_->bridgePointerMove(x, y);
}

void Application::pointerButton(int button, bool pressed, float x, float y) {
  impl_->bridgePointerButton(button, pressed, x, y);
}

void Application::keyEvent(int key, int action, int mods) {
  impl_->bridgeKeyEvent(key, action, mods);
}

void Application::textInput(const std::string &utf8) {
  impl_->bridgeTextInput(utf8);
}

void Application::scroll(float dx, float dy) {
  impl_->bridgeScroll(dx, dy);
}

void Application::readPixels(uint8_t *dst, size_t dstSize) {
  impl_->readPixels(dst, dstSize);
}

void Application::captureFrame(uint8_t *dst, size_t dstSize) {
  impl_->window->captureFrame(dst, dstSize);
}

bool Application::capturePng(std::vector<uint8_t> &outPng, int x, int y, int w,
                             int h, int maxSide, int *outW, int *outH) {
  return impl_->window->capturePng(outPng, x, y, w, h, maxSide, outW, outH);
}

std::string Application::capturePngBase64(int x, int y, int w, int h,
                                          int maxSide, int *outW, int *outH) {
  std::vector<uint8_t> png;
  if (!capturePng(png, x, y, w, h, maxSide, outW, outH) || png.empty())
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
