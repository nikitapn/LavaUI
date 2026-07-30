
#include <chrono>
#include <format>
#include <algorithm>
#include <optional>
#include <filesystem>

#include "application.hpp"

#include "util/constants.hpp"
#include "util/key_codes.hpp"
#include "render/vulkan.hpp"
#include "render/text_renderer.hpp"
#include "render/quad_renderer.hpp"
#include "render/texture_manager.hpp"
#include "render/blur_pass.hpp"

#include "render/draw_command.hpp"

#include <deque>
#include <mutex>

#define GLFW_INCLUDE_VULKAN
#include <GLFW/glfw3.h>

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

  Vulkan           vulkan;
  TextRenderer     textRenderer;
  QuadRenderer     quadRenderer;
  BlurPass         blurPass;


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
    , textRenderer(vulkan)
    , quadRenderer(vulkan)
    , blurPass(vulkan)
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
    const float ew = static_cast<float>(vulkan.getExtent().width);
    const float eh = static_cast<float>(vulkan.getExtent().height);

    TextureManager::getInstance().initialize(vulkan);
    std::cout << "TextureManager initialized.\n";

    textRenderer.init();
    // No default face here — Swift owns font policy (FontStore) and calls
    // loadFont(path, size) after open so measure and draw use the same choice.
    std::cout << "Text renderer initialized (font pending from Swift).\n";

    // Sole 2D pipeline: replays the draw list in index order, so paint order
    // is emission order rather than the old lines < geometry < text z-split.
    quadRenderer.init();
    // Glyphs and shapes share one descriptor set, so scissor is the only
    // thing that can break a batch.
    quadRenderer.setAtlas(textRenderer.atlasView(), textRenderer.atlasSampler());
    std::cout << "Quad renderer initialized.\n";

    blurPass.init();
    // Needs BlurPass's scene render pass, hence after its init rather than
    // inside quadRenderer.init().
    quadRenderer.createSceneTargetPipeline(blurPass.sceneRenderPass());
    std::cout << "Blur pass initialized.\n";

    screenProjection_ = mat4{ // column-major, top-left origin, y-down
      2.0f / ew, 0.0f, 0.0f, 0.0f,
      0.0f, 2.0f / eh, 0.0f, 0.0f,
      0.0f,  0.0f, 0.0f, 0.0f,
      -1.0f, -1.0f, 0.0f, 1.0f
    };

    shadowMapTexture = TextureManager::getInstance().registerTexture("shadowMap",
      vulkan.getShadowImageView(), vulkan.getShadowMapSize(), vulkan.getShadowMapSize());

    std::cout << "Init complete.\n";
    return canvas::ok();
  }

  void installGlfwCallbacks()
  {
    GLFWwindow *win = vulkan.window();
    if (!win) return;
    glfwSetWindowUserPointer(win, this);

    glfwSetCursorPosCallback(win, [](GLFWwindow *w, double x, double y) {
      auto *self = static_cast<Impl *>(glfwGetWindowUserPointer(w));
      if (!self) return;
      self->bridgePointerMove(static_cast<float>(x), static_cast<float>(y));
    });

    glfwSetMouseButtonCallback(win, [](GLFWwindow *w, int button, int action, int /*mods*/) {
      auto *self = static_cast<Impl *>(glfwGetWindowUserPointer(w));
      if (!self) return;
      double x = 0, y = 0;
      glfwGetCursorPos(w, &x, &y);
      self->bridgePointerButton(
        button, action == GLFW_PRESS, static_cast<float>(x), static_cast<float>(y));
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
      vulkan.init("2d shenanigans!", static_cast<int>(width), static_cast<int>(height));
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
      vulkan.initWithWindow(
        "2d shenanigans!", static_cast<int>(width), static_cast<int>(height),
        title.c_str());
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
    return vulkan.windowShouldClose();
  }

  void setWindowFrame(int x, int y, int width, int height)
  {
    vulkan.setWindowFrame(x, y, width, height);
  }

  void setWindowVisible(bool visible)
  {
    vulkan.setWindowVisible(visible);
  }

  void syncProjectionToExtent()
  {
    const float ew = static_cast<float>(vulkan.getExtent().width);
    const float eh = static_cast<float>(vulkan.getExtent().height);
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

  void bridgePointerButton(int button, bool pressed, float x, float y) {
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
    quadRenderer.setViewTransform(viewZoom_, viewPanX_, viewPanY_);
  }

  void bridgeTextInput(const std::string &utf8)
  {
    // Retained for the old bridge signature; character input now goes through
    // bridgeCharInput, which keeps the scalar rather than round-tripping UTF-8.
    (void)utf8;
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
    if (!vulkan.isWindowed() || !vulkan.window()) return {};
    const char *s = glfwGetClipboardString(vulkan.window());
    return s ? std::string(s) : std::string{};
  }

  void setClipboardText(const std::string &text)
  {
    if (!vulkan.isWindowed() || !vulkan.window()) return;
    glfwSetClipboardString(vulkan.window(), text.c_str());
  }

  bool repaint()
  {
    try {
      if (vulkan.isWindowed() && vulkan.ensureFramebufferSize()) {
        syncProjectionToExtent();
        // Notify Swift so it re-runs Yoga + resubmits the draw list.
        // Without this, C++ presents the old fixed-size command list into
        // the larger framebuffer (layout stuck at open size).
        canvas::InputEvent ev;
        ev.kind = static_cast<uint32_t>(canvas::InputEventKind::Resize);
        ev.x = static_cast<float>(vulkan.getExtent().width);
        ev.y = static_cast<float>(vulkan.getExtent().height);
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

      // Wait for *this* frame slot only (2-in-flight). The other slot may
      // still be on the GPU while we fill host-visible buffers for this one.
      vulkan.waitForInFlightFrame();

      // Atlas is shared — wait every slot before replacing the image.
      if (textRenderer.atlasNeedsGrow()) {
        vulkan.waitForAllFramesInFlight();
      }
      if (textRenderer.growAtlasIfNeeded()) {
        quadRenderer.setAtlas(textRenderer.atlasView(),
                              textRenderer.atlasSampler());
      }
      const auto ext = vulkan.getExtent();
      // Each boundary is a point where the GPU has to stop drawing the frame
      // and do something else. Segment i is drawn, boundaries[i] runs, then
      // segment i+1 — whose first quad is usually the composite of whatever the
      // boundary produced. (Backdrop compositing must land in MSAA, not just the
      // resolve, or the next pass's resolve wipes it.)
      // Sizing has to happen *before* replay, not after: replay bakes the
      // composite quads' UVs, and those depend on the allocation. Reallocating
      // also waits on every frame in flight, so it cannot happen mid-recording
      // either. Hence a cheap pre-scan for the radii.
      //
      // The *finest* radius drives the allocation, since that is the one needing
      // the most resolution; wider blurs then take a sub-region at their own
      // coarser grid rather than forcing the fine one down to theirs.
      float finestRadius = BlurPass::kMaxRadius;
      bool anyBlur = false;
      for (const auto &cmd : drawCmds_) {
        const auto kind = static_cast<canvas::DrawCommandKind>(cmd.kind);
        if (kind != canvas::DrawCommandKind::BeginBackdropBlur &&
            kind != canvas::DrawCommandKind::BeginContentBlur) {
          continue;
        }
        anyBlur = true;
        finestRadius = std::min(finestRadius, cmd.aux > 0.f ? cmd.aux : 8.f);
      }
      if (anyBlur) {
        blurPass.ensureSize(ext.width, ext.height, finestRadius);
      }

      std::vector<Boundary> boundaries;
      replayDrawListUnified(static_cast<float>(ext.width),
                            static_cast<float>(ext.height), boundaries);

      vulkan.renderWithShadows(
          // Shadow pass kept only because renderWithShadows is Vulkan's sole
          // render entry point; nothing 3D draws into it any more.
          [&](VkCommandBuffer) {},
          [&](VkCommandBuffer commandBuffer, u32 /*imageIndex*/) {
            const auto extent = vulkan.getExtent();

            // Always open the clear pass so an empty first segment still
            // clears the framebuffer before a leading blur.
            vulkan.beginMainRenderPass(commandBuffer, /*clear=*/true);
            quadRenderer.drawSegment(commandBuffer, 0);

            uint32_t segment = 0;
            for (const auto &b : boundaries) {
              ++segment;
              if (!blurPass.ready() || !blurPass.sceneReady()) {
                // No blur resources: draw the segment unblurred rather than
                // half-executing a boundary and leaving passes unbalanced.
                quadRenderer.drawSegment(commandBuffer, segment);
                continue;
              }

              switch (b.kind) {
              case Boundary::Kind::Backdrop:
                // The frame so far *is* the source, so it has to be resolved
                // before it can be read.
                vulkan.endMainRenderPass(commandBuffer);
                blurPass.captureAndBlur(
                  commandBuffer, vulkan.resolveImage(),
                  VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, b.radius);
                quadRenderer.setBlurResultView(blurPass.resultView(),
                                               blurPass.sampler());
                vulkan.beginMainRenderPass(commandBuffer, /*clear=*/false);
                quadRenderer.drawSegment(commandBuffer, segment);
                break;

              case Boundary::Kind::ContentBegin:
                // The subtree is the source, so it is drawn on its own into a
                // cleared target rather than on top of the frame.
                vulkan.endMainRenderPass(commandBuffer);
                blurPass.beginSceneCapture(commandBuffer);
                quadRenderer.drawSegment(commandBuffer, segment,
                                         /*intoSceneTarget=*/true);
                break;

              case Boundary::Kind::ContentEnd:
                blurPass.endSceneCapture(commandBuffer);
                blurPass.captureAndBlur(
                  commandBuffer, blurPass.sceneImage(),
                  VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, b.radius);
                quadRenderer.setBlurResultView(blurPass.resultView(),
                                               blurPass.sampler());
                vulkan.beginMainRenderPass(commandBuffer, /*clear=*/false);
                quadRenderer.drawSegment(commandBuffer, segment);
                break;
              }
            }

            vulkan.endMainRenderPass(commandBuffer);

            // Full-window scissor restored for anything that might follow
            // (present blit path does not need it, but keep consistent).
            VkRect2D fullScissor{.offset = {0, 0}, .extent = extent};
            vkCmdSetScissor(commandBuffer, 0, 1, &fullScissor);
          });

      return true;
    } catch (std::exception &ex) {
      std::cerr << ex.what() << '\n';
      return false;
    }
  }

  /// A point where the frame's recording has to be interrupted.
  ///
  /// `boundaries[i]` sits between segment i and segment i+1. Only the radius
  /// travels with it — the rect is already baked into the composite quad that
  /// opens the following segment.
  struct Boundary {
    enum class Kind { Backdrop, ContentBegin, ContentEnd };
    Kind kind = Kind::Backdrop;
    float radius = 8.f;
  };

  /// Quad that samples the blur result over `x,y,w,h`.
  ///
  /// UVs are the rect's own window position over the viewport, which makes the
  /// interpolated coordinate at any pixel equal that pixel's position — so the
  /// blur image lines up one-to-one with the frame whatever the rect is. Scaled
  /// by the fraction of the image this radius occupies, since each blur gets its
  /// own resolution out of one allocation.
  void pushBlurComposite(float x, float y, float w, float h, float viewW,
                         float viewH, float radius)
  {
    if (w <= 0.f || h <= 0.f || viewW <= 0.f || viewH <= 0.f) return;
    const vec2 uv = blurPass.uvScaleFor(radius);
    quadRenderer.pushBlurResultImage(
      {x, y}, {w, h},
      {x / viewW * uv.x, y / viewH * uv.y},
      {(x + w) / viewW * uv.x, (y + h) / viewH * uv.y}, 0xffffffffu);
  }

  /// Phase 3.5 — replays the draw list through the unified quad pipeline in
  /// *index order*, so a rect emitted after another shape actually covers it.
  ///
  /// Blur commands close the current segment and record a boundary; the GPU work
  /// between segments happens in repaint's mainCallback.
  void replayDrawListUnified(float viewW, float viewH,
                             std::vector<Boundary> &outBoundaries)
  {
    outBoundaries.clear();
    // Rect + radius of each open content-blur scope, so End knows what region
    // to composite. A stack even though DrawList forbids nesting today, because
    // an unbalanced End must not pop something that was never pushed.
    std::vector<canvas::DrawCommand> contentScopes;
    // Must match the slot waitForInFlightFrame() just freed / submit will use.
    quadRenderer.begin({viewW, viewH}, vulkan.currentFrameSlot());
    for (const auto &cmd : drawCmds_) {
      switch (static_cast<canvas::DrawCommandKind>(cmd.kind)) {
      case canvas::DrawCommandKind::Rect:
        quadRenderer.pushBox({cmd.x, cmd.y}, {cmd.w, cmd.h}, cmd.color, 0.f);
        break;
      case canvas::DrawCommandKind::RoundedRect:
        quadRenderer.pushBox({cmd.x, cmd.y}, {cmd.w, cmd.h}, cmd.color, cmd.aux);
        break;
      case canvas::DrawCommandKind::Circle:
        quadRenderer.pushCircle({cmd.x, cmd.y}, cmd.aux, cmd.color);
        break;
      case canvas::DrawCommandKind::Line:
        // x,y = p0 and w,h = p1 (see draw_command.hpp). aux carries stroke
        // width when the emitter sets it; 1.5px is the wire default.
        quadRenderer.pushLine({cmd.x, cmd.y}, {cmd.w, cmd.h},
                              cmd.aux > 0.f ? cmd.aux : 1.5f, cmd.color);
        break;
      case canvas::DrawCommandKind::PushClip:
        quadRenderer.pushScissor({cmd.x, cmd.y}, {cmd.w, cmd.h});
        break;
      case canvas::DrawCommandKind::PopClip:
        quadRenderer.popScissor();
        break;
      case canvas::DrawCommandKind::Text: {
        // Swift shaped this run and positioned every glyph; all the renderer
        // does is resolve glyph ids to atlas rects. No shaping here means a
        // drawn run cannot drift from the run that was measured for layout.
        const uint32_t first = cmd.param;
        const uint32_t count = static_cast<uint32_t>(cmd.w);
        for (uint32_t g = 0; g < count; ++g) {
          const size_t idx = first + g;
          if (idx >= drawGlyphs_.size()) break;
          const auto &gi = drawGlyphs_[idx];
          TextRenderer::GlyphQuad q;
          if (!textRenderer.glyphQuad(gi.fontId, gi.glyphId, q)) continue;
          if (q.size.x <= 0.f || q.size.y <= 0.f) continue;  // e.g. space
          quadRenderer.pushGlyph({gi.x + q.bearing.x, gi.y - q.bearing.y},
                                 q.size, q.uv0, q.uv1, cmd.color);
        }
        break;
      }
      case canvas::DrawCommandKind::Image: {
        const uint32_t texId = cmd.param;
        VkImageView view = TextureManager::getInstance().getTextureView(texId);
        if (view == VK_NULL_HANDLE) break;
        quadRenderer.pushImage({cmd.x, cmd.y}, {cmd.w, cmd.h},
                               {0.f, 0.f}, {1.f, 1.f}, cmd.color, view);
        break;
      }
      case canvas::DrawCommandKind::BeginBackdropBlur: {
        // Split so GPU can end pass → blur → continue. Next segment opens with
        // a full-frame-UV composite of the glass rect (bound at draw time).
        quadRenderer.closeSegment();
        const float radius = cmd.aux > 0.f ? cmd.aux : 8.f;
        outBoundaries.push_back({Boundary::Kind::Backdrop, radius});
        pushBlurComposite(cmd.x, cmd.y, cmd.w, cmd.h, viewW, viewH, radius);
        break;
      }
      case canvas::DrawCommandKind::EndBackdropBlur:
        // Bookkeeping / future nesting — no GPU work.
        break;

      case canvas::DrawCommandKind::BeginContentBlur: {
        // The subtree lands in its own segment, drawn into the offscreen target
        // rather than the frame, so nothing is composited here.
        quadRenderer.closeSegment();
        outBoundaries.push_back(
          {Boundary::Kind::ContentBegin, cmd.aux > 0.f ? cmd.aux : 8.f});
        contentScopes.push_back(cmd);
        break;
      }
      case canvas::DrawCommandKind::EndContentBlur: {
        if (contentScopes.empty()) break;
        const canvas::DrawCommand open = contentScopes.back();
        contentScopes.pop_back();
        quadRenderer.closeSegment();
        const float radius = open.aux > 0.f ? open.aux : 8.f;
        outBoundaries.push_back({Boundary::Kind::ContentEnd, radius});

        // Grown by three sigma on every side: a blurred view's edge fades
        // *outward*, and clipping the composite to the layout rect would slice
        // that falloff off square, which is the one artefact that makes a blur
        // read as a bug rather than as softness.
        const float pad = std::ceil(radius * 3.f);
        const float x0 = std::max(0.f, open.x - pad);
        const float y0 = std::max(0.f, open.y - pad);
        const float x1 = std::min(viewW, open.x + open.w + pad);
        const float y1 = std::min(viewH, open.y + open.h + pad);
        pushBlurComposite(x0, y0, x1 - x0, y1 - y0, viewW, viewH, radius);
        break;
      }
      }
    }
    quadRenderer.end();
  }

  void readPixels(uint8_t *dst, size_t dstSize)
  {
    vulkan.readPixels(dst, dstSize);
  }

  // Immediate draw list (Phase 3) — authored by Swift each dirty frame.
  std::vector<canvas::DrawCommand> drawCmds_;
  std::vector<canvas::GlyphInstance> drawGlyphs_;
  // GLFW callbacks (render thread, outside window mutex) vs Swift poll (under
  // window mutex) — protect the queue so Resize/Key/Mouse are not lost.
  bool pointerDown_ = false;  // gates MouseMove queueing
  std::mutex inputMu_;
  std::deque<canvas::InputEvent> inputEvents_;

  // Whole-window camera (layout stays at zoom=1; vertex shader applies this).
  float viewZoom_ = 1.f;
  float viewPanX_ = 0.f;
  float viewPanY_ = 0.f;

  void submitDrawList(const canvas::DrawCommand *cmds, size_t cmdCount,
                      const canvas::GlyphInstance *glyphs, size_t glyphCount)
  {
    drawCmds_.assign(cmds, cmds + cmdCount);
    drawGlyphs_.assign(glyphs, glyphs + glyphCount);
  }

  bool pollInputEvent(canvas::InputEvent &out)
  {
    std::lock_guard lock(inputMu_);
    if (inputEvents_.empty()) return false;
    out = inputEvents_.front();
    inputEvents_.pop_front();
    return true;
  }

  void framebufferSize(float &outW, float &outH) const
  {
    // Prefer the *live* GLFW size so the Swift safety net sees drag-resize
    // before ensureFramebufferSize() updates the swapchain extent.
    if (vulkan.isWindowed() && vulkan.window()) {
      int fbW = 0, fbH = 0;
      glfwGetFramebufferSize(vulkan.window(), &fbW, &fbH);
      if (fbW >= 1 && fbH >= 1) {
        outW = static_cast<float>(fbW);
        outH = static_cast<float>(fbH);
        return;
      }
    }
    const auto e = vulkan.getExtent();
    outW = static_cast<float>(e.width);
    outH = static_cast<float>(e.height);
  }

  int registerFont(const std::string &path, float pixelSize)
  {
    return textRenderer.registerFont(path, pixelSize);
  }

  canvas::VoidResult loadFont(const std::string &path, float pixelSize)
  {
    return textRenderer.loadFont(path, static_cast<int>(pixelSize));
  }

  int loadTexture(const std::string &path)
  {
    auto h = TextureManager::getInstance().loadTexture(path);
    return h.isValid() ? static_cast<int>(h.id) : -1;
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
    blurPass.cleanUp();
    quadRenderer.cleanUp();
    textRenderer.cleanUp();
    TextureManager::getInstance().cleanUp();
    vulkan.cleanUp();
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

void Application::setWindowFrame(int x, int y, int width, int height) {
  impl_->setWindowFrame(x, y, width, height);
}

void Application::setWindowVisible(bool visible) {
  impl_->setWindowVisible(visible);
}

void Application::submitDrawList(const canvas::DrawCommand *cmds, size_t cmdCount,
                                 const canvas::GlyphInstance *glyphs,
                                 size_t glyphCount)
{
  impl_->submitDrawList(cmds, cmdCount, glyphs, glyphCount);
}

bool Application::pollInputEvent(canvas::InputEvent &out)
{
  return impl_->pollInputEvent(out);
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

bool Application::textureSize(uint32_t textureId, float &outW, float &outH) const
{
  return impl_->textureSize(textureId, outW, outH);
}

bool Application::repaint() {
  return impl_->repaint();
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

void Application::readPixels(uint8_t *dst, size_t dstSize) {
  impl_->readPixels(dst, dstSize);
}

void Application::shutdown() {
  impl_->shutdown();
}

Application::Application(int w, int h) {
  impl_ = std::make_unique<Application::Impl>(w, h);
}

Application::~Application() = default;
