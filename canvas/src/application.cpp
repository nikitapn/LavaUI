#include <pch.hpp>

#include <chrono>
#include <format>
#include <algorithm>
#include <optional>

#include "application.hpp"

#include "util/constants.hpp"
#include "util/key_codes.hpp"
#include "render/vulkan.hpp"
#include "render/text_renderer.hpp"
#include "render/primitives.hpp"
#include "render/camera.hpp"
#include "render/geometry_renderer.hpp"
#include "render/mesh3d_renderer.hpp"
#include "render/texture_manager.hpp"
#include "render/line_renderer.hpp"

#include "imgui.h"
#include "imgui_impl_vulkan.h"
#include "imgui_impl_glfw.h"
#include "render/text_widget.hpp"
#include "render/draw_command.hpp"
#include "shell/layout.hpp"
#include "shell/model.hpp"
#include "shell/widget.hpp"

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
  Vulkan           vulkan;
  GeometryRenderer renderer;
  Mesh3DRenderer   mesh3DRenderer;
  TextRenderer     textRenderer;
  LineRenderer     lineRenderer;
  Camera           camera;

  Mesh3D* cubePrimitive = nullptr;
  Mesh3D* spherePrimitive = nullptr;

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

  // Camera control
  float moveSpeed = 100.0f;

  const float width;
  const float height;

  float  normalDebugLength = 15.0f;
  int    normalDebugSampleStride = 1;
  ImVec4 normalDebugColor = ImVec4(0.0f, 0.6f, 1.0f, 1.0f);
  bool   showImGuiDemo = false;

  // Input state tracking
  struct InputState {
    bool keys[KEY_LAST] = {false};
    bool mouseButtons[MOUSE_BUTTON_LAST] = {false};
    double mouseX = 0.0, mouseY = 0.0;
    double lastMouseX = 0.0, lastMouseY = 0.0;
    bool firstMouse = true;
    bool mouseCaptured = false;
  } inputState;

  // Retained 2D shape scene, populated by add/update/removeShape and
  // replayed into the (per-frame-immediate-mode) GeometryRenderer on every
  // repaint(). x/y is the top-left corner (GeometryRenderer::pushScreenObject
  // itself takes a center point, converted in repaint()). One id space
  // shared by every GeometryRenderer::Type since removal/clearing doesn't
  // need to know the kind.
  struct Shape {
    GeometryRenderer::Type kind;
    float x, y, width, height;
    float r, g, b, a;
  };
  std::unordered_map<int, Shape> shapes;
  int nextShapeId = 1;

  // Retained 2D line scene (wires), in the same screen-pixel coordinate
  // system as shapes above. Replayed into LineRenderer every repaint(),
  // using a screen-space orthographic projection (see screenProjection_)
  // instead of the 3D camera LineRenderer was originally written for.
  struct LineShape {
    float x1, y1, x2, y2;
    float r, g, b, a;
  };
  std::unordered_map<int, LineShape> lines;
  int nextLineId = 1;

  // Retained 2D text labels (block/slot names etc.), replayed into
  // TextRenderer every repaint() alongside the FPS/debug overlay text.
  struct LabelShape {
    std::string text;
    float x, y;
    float r, g, b;
  };
  std::unordered_map<int, LabelShape> labels;
  int nextLabelId = 1;

  // Retained ImGui-frame text editors (syntax-highlighted fields).
  std::unordered_map<int, CanvasTextWidget> textWidgets;
  int nextTextWidgetId = 1;
  int focusedTextWidgetId = -1;

  // Maps pixel coordinates (0,0 top-left, y-down) straight to clip space —
  // the same matrix GeometryRenderer builds internally for its own static
  // UBO (see GeometryRenderer's init()), duplicated here so LineRenderer
  // (which expects an explicit view/projection pair rather than baking its
  // own) draws wires in the identical coordinate system as shapes/text.
  mat4 screenProjection_{1.0f};

  // Wall-clock time of the last repaint() call, used only to compute a
  // deltaTime for the FPS counter/Dear ImGui (nullopt on the first call).
  std::optional<std::chrono::steady_clock::time_point> lastRepaintTime;

 public:
  Impl(int w, int h)
    : width{static_cast<float>(w)}
    , height{static_cast<float>(h)}
    , renderer(vulkan)
    , mesh3DRenderer(vulkan, camera)
    , textRenderer(vulkan)
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
    ImGuiIO& io = ImGui::GetIO();
    // Update key state tracking
    if (key >= 0 && key < KEY_LAST) {
      if (action == ACTION_PRESS) {
        inputState.keys[key] = true;
      } else if (action == ACTION_RELEASE) {
        inputState.keys[key] = false;
      }
    }

    if (io.WantCaptureKeyboard) {
      return;
    }

    // Handle one-time key presses (toggles, etc.)
    if (action == ACTION_PRESS) {
      switch (key) {
        case KEY_V:
          renderer.toggleWireframe();
          break;
        case KEY_1:
          renderShadowDebug = !renderShadowDebug;
          break;
        case KEY_2:
          renderOctreeDebug = !renderOctreeDebug;
          break;
        case KEY_3:
          renderBricksDebug = !renderBricksDebug;
          break;
        case KEY_4:
          renderNormalsDebug = !renderNormalsDebug;
          break;
        case KEY_5:
          renderWireframeDebug = !renderWireframeDebug;
          break;
        case KEY_TAB:
          toggleMouseCapture();
          break;
        case KEY_ESCAPE:
          if (inputState.mouseCaptured) {
            toggleMouseCapture();
          }
          break;
      }
    }
  }

  // Mouse button handler
  void handleMouseButton(int button, int action, int mods)
  {
    ImGuiIO& io = ImGui::GetIO();
    if (button >= 0 && button < MOUSE_BUTTON_LAST) {
      if (action == ACTION_PRESS) {
        inputState.mouseButtons[button] = true;

        // Capture mouse on first click if not already captured
        if (!inputState.mouseCaptured && !io.WantCaptureMouse) {
          toggleMouseCapture();
        }
      } else if (action == ACTION_RELEASE) {
        inputState.mouseButtons[button] = false;
      }
    }

    if (io.WantCaptureMouse) {
      return;
    }
  }

  // Mouse movement handler  
  void handleMouseMove(double xpos, double ypos)
  {
    ImGuiIO& io = ImGui::GetIO();
    inputState.mouseX = xpos;
    inputState.mouseY = ypos;

    if (io.WantCaptureMouse || !inputState.mouseCaptured) {
      return;
    }

    if (inputState.mouseCaptured) {
      if (inputState.firstMouse) {
        inputState.lastMouseX = xpos;
        inputState.lastMouseY = ypos;
        inputState.firstMouse = false;
      }

      double deltaX = xpos - inputState.lastMouseX;
      double deltaY = inputState.lastMouseY - ypos; // Y is flipped

      inputState.lastMouseX = xpos;
      inputState.lastMouseY = ypos;

      // Mouse sensitivity
      const float sensitivity = 0.002f; // Adjust as needed
      camera.rotateYaw(static_cast<float>(-deltaX * sensitivity));
      camera.rotatePitch(static_cast<float>(deltaY * sensitivity));
    }
  }

  // Scroll handler (for zoom/FOV)
  void handleScroll(double xoffset, double yoffset)
  {
    ImGuiIO& io = ImGui::GetIO();
    if (io.WantCaptureMouse)
      return;

    // Camera move speed adjustment
    const float sensitivity = inputState.keys[KEY_LEFT_ALT] ? 50.f : 5.f;
    moveSpeed = std::clamp(moveSpeed + static_cast<float>(yoffset) * sensitivity, 1.f, 1000.f);
  }

  // Toggle mouse capture for camera control
  void toggleMouseCapture()
  {
    // No real cursor to hide/show headlessly — a future input bridge decides
    // what "captured" (relative-mouse-look) mode means on its end.
    inputState.mouseCaptured = !inputState.mouseCaptured;

    if (inputState.mouseCaptured) {
      inputState.firstMouse = true;
      std::cout << "Mouse captured for camera control (TAB to release)\n";
    } else {
      std::cout << "Mouse released\n";
    }
  }


  // Process continuous input (called every frame)
  void processContinuousInput(float deltaTime)
  {
    // Camera movement speed (units per second)
    const float rotateSpeed = 2.0f;

    const float speedMultiplier = inputState.keys[KEY_LEFT_SHIFT] ? 5.0f : 1.0f; 

    // Calculate movement amount for this frame
    float frameMove = speedMultiplier * moveSpeed * deltaTime;
    float frameRotate = rotateSpeed * deltaTime;

    // WASD movement (smooth, frame-rate independent)
    if (inputState.keys[KEY_W]) {
      camera.moveForward(frameMove);
    }
    if (inputState.keys[KEY_S]) {
      camera.moveForward(-frameMove);
    }
    if (inputState.keys[KEY_A]) {
      camera.moveRight(-frameMove);
    }
    if (inputState.keys[KEY_D]) {
      camera.moveRight(frameMove);
    }

    // Vertical movement
    if (inputState.keys[KEY_SPACE]) {
      camera.moveUp(frameMove);
    }
    if (inputState.keys[KEY_LEFT_CONTROL]) {
      camera.moveUp(-frameMove);
    }

    // Rotation with Q/E keys
    if (inputState.keys[KEY_Q]) {
      camera.rotateRoll(-frameRotate);
    }
    if (inputState.keys[KEY_E]) {
      camera.rotateRoll(frameRotate);
    }

    // Arrow keys for additional camera control
    if (inputState.keys[KEY_LEFT]) {
      camera.rotateYaw(-frameRotate);
    }
    if (inputState.keys[KEY_RIGHT]) {
      camera.rotateYaw(frameRotate);
    }
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

    camera.setAspectRatio(ew / eh);

    renderer.init();
    renderer.setViewportSize({ew, eh});
    std::cout << "Renderer initialized.\n";

    textRenderer.init();
    {
      // Font must load after assetsRoot is known — Application's member
      // constructors run long before init*, so the path cannot live there.
      const auto font = assetPath(assetsRoot, "LiberationSerif-Regular.ttf");
      if (auto r = textRenderer.loadFont(font.string(), 36); !r) {
        return r;
      }
    }
    std::cout << "Text renderer initialized.\n";

    mesh3DRenderer.init();
    std::cout << "3D Mesh renderer initialized.\n";

    lineRenderer.initialize(vulkan);
    std::cout << "Line renderer initialized.\n";
    mesh3DRenderer.setNormalDebugRenderer(&lineRenderer);

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

    glfwSetCharCallback(win, [](GLFWwindow *w, unsigned int codepoint) {
      auto *self = static_cast<Impl *>(glfwGetWindowUserPointer(w));
      if (!self) return;
      // Encode as UTF-8 (BMP only for simplicity; enough for ST).
      char buf[5] = {};
      if (codepoint < 0x80) {
        buf[0] = static_cast<char>(codepoint);
      } else if (codepoint < 0x800) {
        buf[0] = static_cast<char>(0xC0 | (codepoint >> 6));
        buf[1] = static_cast<char>(0x80 | (codepoint & 0x3F));
      } else {
        buf[0] = static_cast<char>(0xE0 | (codepoint >> 12));
        buf[1] = static_cast<char>(0x80 | ((codepoint >> 6) & 0x3F));
        buf[2] = static_cast<char>(0x80 | (codepoint & 0x3F));
      }
      self->bridgeTextInput(buf);
    });
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
      // App callbacks first, then ImGui chains on top (install_callbacks=true).
      installGlfwCallbacks();
      vulkan.initImGuiGlfwBackend();
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
    renderer.setViewportSize({ew, eh});
    camera.setAspectRatio(ew / eh);
    screenProjection_ = mat4{
      2.0f / ew, 0.0f, 0.0f, 0.0f,
      0.0f, 2.0f / eh, 0.0f, 0.0f,
      0.0f,  0.0f, 0.0f, 0.0f,
      -1.0f, -1.0f, 0.0f, 1.0f
    };
  }

  int addRect(float x, float y, float w, float h, float r, float g, float b, float a)
  {
    int id = nextShapeId++;
    shapes[id] = Shape{GeometryRenderer::Type::Rectangle, x, y, w, h, r, g, b, a};
    return id;
  }

  void updateRect(int id, float x, float y, float w, float h, float r, float g, float b, float a)
  {
    auto it = shapes.find(id);
    if (it != shapes.end()) {
      it->second = Shape{GeometryRenderer::Type::Rectangle, x, y, w, h, r, g, b, a};
    }
  }

  int addRoundedRect(float x, float y, float w, float h, float r, float g, float b, float a)
  {
    int id = nextShapeId++;
    shapes[id] = Shape{GeometryRenderer::Type::RoundedRectangle, x, y, w, h, r, g, b, a};
    return id;
  }

  int addCircle(float centerX, float centerY, float radius, float r, float g, float b, float a)
  {
    int id = nextShapeId++;
    float diameter = radius * 2.0f;
    shapes[id] = Shape{
      GeometryRenderer::Type::Circle,
      centerX - radius, centerY - radius, diameter, diameter,
      r, g, b, a
    };
    return id;
  }

  void removeShape(int id)
  {
    shapes.erase(id);
  }

  void clearShapes()
  {
    shapes.clear();
  }

  int addLine(float x1, float y1, float x2, float y2, float r, float g, float b, float a)
  {
    int id = nextLineId++;
    lines[id] = LineShape{x1, y1, x2, y2, r, g, b, a};
    return id;
  }

  void removeLine(int id)
  {
    lines.erase(id);
  }

  void clearLines()
  {
    lines.clear();
  }

  int addLabel(const std::string &text, float x, float y, float r, float g, float b)
  {
    int id = nextLabelId++;
    labels[id] = LabelShape{text, x, y, r, g, b};
    return id;
  }

  void removeLabel(int id)
  {
    labels.erase(id);
  }

  void clearLabels()
  {
    labels.clear();
  }

  int addTextWidget(float x, float y, float width, float height,
                    const std::string &text, bool multiline)
  {
    int id = nextTextWidgetId++;
    CanvasTextWidget widget;
    widget.x = x;
    widget.y = y;
    widget.w = width;
    widget.h = height;
    widget.multiline = multiline;
    widget.setText(text);
    textWidgets.emplace(id, std::move(widget));
    return id;
  }

  void setTextWidgetRect(int id, float x, float y, float width, float height)
  {
    auto it = textWidgets.find(id);
    if (it == textWidgets.end()) return;
    it->second.x = x;
    it->second.y = y;
    it->second.w = width;
    it->second.h = height;
  }

  void setTextWidgetText(int id, const std::string &text)
  {
    auto it = textWidgets.find(id);
    if (it == textWidgets.end()) return;
    it->second.setText(text);
  }

  std::string getTextWidgetText(int id) const
  {
    auto it = textWidgets.find(id);
    if (it == textWidgets.end()) return {};
    return it->second.text();
  }

  bool setTextWidgetHighlightRules(int id, const std::vector<TextHighlightRule> &rules)
  {
    auto it = textWidgets.find(id);
    if (it == textWidgets.end()) return false;
    return it->second.setHighlightRules(rules);
  }

  void setTextWidgetFocused(int id, bool focused)
  {
    if (focused) {
      for (auto &[wid, w] : textWidgets) {
        w.focused = (wid == id);
      }
      focusedTextWidgetId = textWidgets.count(id) ? id : -1;
    } else {
      auto it = textWidgets.find(id);
      if (it != textWidgets.end()) it->second.focused = false;
      if (focusedTextWidgetId == id) focusedTextWidgetId = -1;
    }
  }

  bool isTextWidgetFocused(int id) const
  {
    auto it = textWidgets.find(id);
    return it != textWidgets.end() && it->second.focused;
  }

  bool textWidgetChanged(int id)
  {
    auto it = textWidgets.find(id);
    if (it == textWidgets.end()) return false;
    return it->second.consumeChanged();
  }

  void removeTextWidget(int id)
  {
    textWidgets.erase(id);
    if (focusedTextWidgetId == id) focusedTextWidgetId = -1;
  }

  bool wantsAnimation() const
  {
    // Focused text fields need continuous frames for caret blink (and
    // selection drag while the pointer moves — still focused).
    if (focusedTextWidgetId >= 0) {
      auto it = textWidgets.find(focusedTextWidgetId);
      if (it != textWidgets.end() && it->second.focused) return true;
    }
    for (const auto &[id, w] : textWidgets) {
      (void)id;
      if (w.focused) return true;
    }
    return false;
  }

  void bridgePointerMove(float x, float y)
  {
    inputState.mouseX = x;
    inputState.mouseY = y;
    ImGuiIO &io = ImGui::GetIO();
    io.AddMousePosEvent(x, y);

    if (focusedTextWidgetId >= 0) {
      auto it = textWidgets.find(focusedTextWidgetId);
      if (it != textWidgets.end()) {
        it->second.onMouseDrag(x, y);
      }
    }
  }

  void bridgePointerButton(int button, bool pressed, float x, float y)
  {
    inputState.mouseX = x;
    inputState.mouseY = y;
    ImGuiIO &io = ImGui::GetIO();
    if (button >= 0 && button < 5) {
      io.AddMouseButtonEvent(button, pressed);
    }

    // Queue raw input for Swift hit-testing (Phase 3+).
    if (button == MOUSE_BUTTON_1) {
      canvas::InputEvent ev;
      ev.kind = static_cast<uint32_t>(
        pressed ? canvas::InputEventKind::MouseDown
                : canvas::InputEventKind::MouseUp);
      ev.x = x;
      ev.y = y;
      ev.button = button;
      inputEvents_.push_back(ev);
    }

    // Primary button: legacy C++ UI hits first, then text-widget focus/caret.
    if (button == MOUSE_BUTTON_1) {
      if (pressed) {
        if (uiTree_.hasRoot()) {
          const float localY = y - uiBodyOriginY_;
          const int uiHit = uiTree_.hitTest(x, localY);
          if (uiHit > 0) {
            uiTree_.enqueueClick(uiHit);
            // Click consumed by chrome; blur text editors.
            if (focusedTextWidgetId >= 0) {
              auto it = textWidgets.find(focusedTextWidgetId);
              if (it != textWidgets.end()) it->second.focused = false;
              focusedTextWidgetId = -1;
            }
            return;
          }
        }

        int hitId = -1;
        for (auto &[id, w] : textWidgets) {
          if (w.hitTest(x, y)) {
            hitId = id;
            break;
          }
        }
        for (auto &[id, w] : textWidgets) {
          if (id == hitId) {
            w.onMouseDown(x, y);
          } else {
            w.focused = false;
          }
        }
        focusedTextWidgetId = hitId;
      } else if (focusedTextWidgetId >= 0) {
        auto it = textWidgets.find(focusedTextWidgetId);
        if (it != textWidgets.end()) {
          it->second.onMouseUp(x, y);
        }
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

    if (focusedTextWidgetId >= 0) {
      auto it = textWidgets.find(focusedTextWidgetId);
      if (it != textWidgets.end() && it->second.focused) {
        it->second.onKey(key, action, mods);
        if (!it->second.focused) {
          focusedTextWidgetId = -1;
        }
        return;
      }
    }

    // Fall through to debug toggles when no text field is focused.
    handleKeyInput(key, 0, action, mods);
  }

  void bridgeTextInput(const std::string &utf8)
  {
    if (focusedTextWidgetId < 0) return;
    auto it = textWidgets.find(focusedTextWidgetId);
    if (it == textWidgets.end() || !it->second.focused) return;
    it->second.onTextInput(utf8.c_str());
  }

  // Renders one frame of the retained scene (shapes/lines/labels) and
  // reports it back via readPixels(). There's no fixed-timestep loop driving
  // this anymore — callers (Swift) call it whenever they want a new frame,
  // e.g. right after changing the scene. deltaTime for the FPS counter/Dear
  // ImGui is computed from wall-clock time between calls instead of being
  // passed in.
  bool repaint()
  {
    try {
      if (vulkan.isWindowed() && vulkan.ensureFramebufferSize()) {
        syncProjectionToExtent();
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

      ImDrawData* imguiDrawData = renderImGuiOverlay(currentFPS, deltaTime);

      processContinuousInput(deltaTime);

      // Diagram content is authored in viewport-local coordinates (0,0 =
      // top-left of the diagram panel). Offset into window space for draw.
      const float ox = diagramViewport_.x;
      const float oy = diagramViewport_.y;

      const bool useDrawList = drawListActive_;

      // Clip stack for draw-list (window pixels). Intersect geometry against
      // the current clip so pushClip/popClip actually discard content even
      // though GeometryRenderer is a single batch (GPU multi-scissor later).
      struct ClipRect { float x, y, w, h; };
      std::vector<ClipRect> clipStack;
      auto currentClip = [&]() -> std::optional<ClipRect> {
        if (clipStack.empty()) return std::nullopt;
        return clipStack.back();
      };
      auto intersects = [](const ClipRect &c, float x, float y, float w, float h) {
        return !(x + w <= c.x || y + h <= c.y || x >= c.x + c.w || y >= c.y + c.h);
      };
      auto intersectRect = [](const ClipRect &c, float &x, float &y, float &w, float &h) {
        const float x1 = std::max(c.x, x);
        const float y1 = std::max(c.y, y);
        const float x2 = std::min(c.x + c.w, x + w);
        const float y2 = std::min(c.y + c.h, y + h);
        x = x1; y = y1; w = std::max(0.f, x2 - x1); h = std::max(0.f, y2 - y1);
      };

      auto unpackColor = [](uint32_t c) {
        return std::array<float, 4>{
          float(c & 0xff) / 255.f,
          float((c >> 8) & 0xff) / 255.f,
          float((c >> 16) & 0xff) / 255.f,
          float((c >> 24) & 0xff) / 255.f,
        };
      };

      if (!useDrawList) {
        for (const auto &[id, shape] : shapes) {
          (void)id;
          renderer.pushScreenObject(
            shape.kind,
            GeometryRenderer::ScreenParams{
              {shape.x + ox + shape.width / 2.0f, shape.y + oy + shape.height / 2.0f},
              {shape.width, shape.height},
              {shape.r, shape.g, shape.b, shape.a}
            }
          );
        }
      } else {
        for (const auto &cmd : drawCmds_) {
          const auto kind = static_cast<canvas::DrawCommandKind>(cmd.kind);
          if (kind == canvas::DrawCommandKind::PushClip) {
            ClipRect r{cmd.x, cmd.y, cmd.w, cmd.h};
            if (auto cur = currentClip()) {
              intersectRect(*cur, r.x, r.y, r.w, r.h);
            }
            clipStack.push_back(r);
            continue;
          }
          if (kind == canvas::DrawCommandKind::PopClip) {
            if (!clipStack.empty()) clipStack.pop_back();
            continue;
          }

          const auto rgba = unpackColor(cmd.color);
          switch (kind) {
          case canvas::DrawCommandKind::Rect:
          case canvas::DrawCommandKind::RoundedRect: {
            float x = cmd.x, y = cmd.y, w = cmd.w, h = cmd.h;
            if (auto c = currentClip()) {
              if (!intersects(*c, x, y, w, h)) break;
              intersectRect(*c, x, y, w, h);
              if (w <= 0.f || h <= 0.f) break;
            }
            renderer.pushScreenObject(
              kind == canvas::DrawCommandKind::RoundedRect
                ? GeometryRenderer::Type::RoundedRectangle
                : GeometryRenderer::Type::Rectangle,
              GeometryRenderer::ScreenParams{
                {x + w / 2.f, y + h / 2.f},
                {w, h},
                {rgba[0], rgba[1], rgba[2], rgba[3]}
              }
            );
            break;
          }
          case canvas::DrawCommandKind::Circle: {
            const float r = cmd.aux;
            if (auto c = currentClip()) {
              if (!intersects(*c, cmd.x - r, cmd.y - r, r * 2.f, r * 2.f)) break;
            }
            renderer.pushScreenObject(
              GeometryRenderer::Type::Circle,
              GeometryRenderer::ScreenParams{
                {cmd.x, cmd.y},
                {r * 2.f, r * 2.f},
                {rgba[0], rgba[1], rgba[2], rgba[3]}
              }
            );
            break;
          }
          default:
            break;
          }
        }
      }

      // FreeType text
      textRenderer.beginTextRendering();
      if (!useDrawList) {
        for (const auto &[id, label] : labels) {
          (void)id;
          textRenderer.renderText(
            label.text, {label.x + ox, label.y + oy}, {label.r, label.g, label.b});
        }
        {
          const float lineH = textRenderer.getLineHeight();
          for (const auto &n : uiTree_.nodes()) {
            if (n.kind != shell::WidgetKind::Text || n.text.empty()) continue;
            const float tx = n.rect.x + 4.f;
            const float ty = n.rect.y + uiBodyOriginY_ + lineH * 0.85f;
            textRenderer.renderText(n.text, {tx, ty}, {n.r, n.g, n.b});
          }
        }
      } else {
        const float lineH = textRenderer.getLineHeight();
        clipStack.clear();
        for (const auto &cmd : drawCmds_) {
          const auto kind = static_cast<canvas::DrawCommandKind>(cmd.kind);
          if (kind == canvas::DrawCommandKind::PushClip) {
            ClipRect r{cmd.x, cmd.y, cmd.w, cmd.h};
            if (auto cur = currentClip()) {
              intersectRect(*cur, r.x, r.y, r.w, r.h);
            }
            clipStack.push_back(r);
            continue;
          }
          if (kind == canvas::DrawCommandKind::PopClip) {
            if (!clipStack.empty()) clipStack.pop_back();
            continue;
          }
          if (kind != canvas::DrawCommandKind::Text) continue;
          if (cmd.param >= drawStrings_.size()) continue;
          // Approximate text box for clip test (glyph extent is Phase 4).
          if (auto c = currentClip()) {
            if (!intersects(*c, cmd.x, cmd.y, cmd.w, cmd.h)) continue;
          }
          const auto rgba = std::array<float, 3>{
            float(cmd.color & 0xff) / 255.f,
            float((cmd.color >> 8) & 0xff) / 255.f,
            float((cmd.color >> 16) & 0xff) / 255.f,
          };
          const float tx = cmd.x + 4.f;
          const float ty = cmd.y + lineH * 0.85f;
          textRenderer.renderText(drawStrings_[cmd.param], {tx, ty},
                                  {rgba[0], rgba[1], rgba[2]});
        }
      }
      textRenderer.endTextRendering();

      lineRenderer.clear();
      if (!useDrawList) {
        for (const auto &[id, line] : lines) {
          (void)id;
          lineRenderer.addLine(
            {line.x1 + ox, line.y1 + oy, 0.0f},
            {line.x2 + ox, line.y2 + oy, 0.0f},
            {line.r, line.g, line.b, line.a}
          );
        }
      } else {
        clipStack.clear();
        for (const auto &cmd : drawCmds_) {
          const auto kind = static_cast<canvas::DrawCommandKind>(cmd.kind);
          if (kind == canvas::DrawCommandKind::PushClip) {
            ClipRect r{cmd.x, cmd.y, cmd.w, cmd.h};
            if (auto cur = currentClip()) {
              intersectRect(*cur, r.x, r.y, r.w, r.h);
            }
            clipStack.push_back(r);
            continue;
          }
          if (kind == canvas::DrawCommandKind::PopClip) {
            if (!clipStack.empty()) clipStack.pop_back();
            continue;
          }
          if (kind != canvas::DrawCommandKind::Line) continue;
          // Drop line if both endpoints outside (rough).
          if (auto c = currentClip()) {
            const bool aIn = intersects(*c, cmd.x, cmd.y, 1.f, 1.f);
            const bool bIn = intersects(*c, cmd.w, cmd.h, 1.f, 1.f);
            if (!aIn && !bIn) continue;
          }
          const auto rgba = unpackColor(cmd.color);
          lineRenderer.addLine(
            {cmd.x, cmd.y, 0.f}, {cmd.w, cmd.h, 0.f},
            {rgba[0], rgba[1], rgba[2], rgba[3]}
          );
        }
      }
      lineRenderer.prepare(mat4{1.0f}, screenProjection_);

      // Text widgets: also offset if they use diagram-local coords. Keep
      // absolute for now by not offsetting widget positions here — Swift
      // can place them in diagram-local space and we offset at draw time.
      for (auto &[id, widget] : textWidgets) {
        (void)id;
        widget.x += ox;
        widget.y += oy;
      }

      vulkan.renderWithShadows(
        [&](VkCommandBuffer commandBuffer) {
          mesh3DRenderer.drawShadowPass(commandBuffer);
        },
        [&](VkCommandBuffer commandBuffer, u32 imageIndex) {
          const auto extent = vulkan.getExtent();
          VkViewport fullVp {
            .x = 0.f, .y = 0.f,
            .width = static_cast<float>(extent.width),
            .height = static_cast<float>(extent.height),
            .minDepth = 0.f, .maxDepth = 1.f,
          };
          vkCmdSetViewport(commandBuffer, 0, 1, &fullVp);

          // Draw-list commands are already window-absolute (Phase 3). Legacy
          // shapes stay scissored to the diagram panel.
          VkRect2D fullScissor {.offset = {0, 0}, .extent = extent};
          if (useDrawList) {
            vkCmdSetScissor(commandBuffer, 0, 1, &fullScissor);
          } else {
            VkRect2D scissor {
              .offset = {
                static_cast<int32_t>(std::max(0.f, diagramViewport_.x)),
                static_cast<int32_t>(std::max(0.f, diagramViewport_.y))
              },
              .extent = {
                static_cast<uint32_t>(std::max(1.f, diagramViewport_.w)),
                static_cast<uint32_t>(std::max(1.f, diagramViewport_.h))
              },
            };
            vkCmdSetScissor(commandBuffer, 0, 1, &scissor);
          }

          lineRenderer.draw(commandBuffer);
          renderer.draw(commandBuffer, imageIndex);
          mesh3DRenderer.draw(commandBuffer, imageIndex);

          // Full-window scissor for FreeType text + ImGui chrome.
          vkCmdSetScissor(commandBuffer, 0, 1, &fullScissor);

          textRenderer.draw(
            commandBuffer,
            {static_cast<float>(extent.width), static_cast<float>(extent.height)});

          if (imguiDrawData && imguiDrawData->Valid) {
            ImGui_ImplVulkan_RenderDrawData(imguiDrawData, commandBuffer);
          }
        }
      );

      // Undo temporary widget offset so next frame's layout is stable.
      for (auto &[id, widget] : textWidgets) {
        (void)id;
        widget.x -= ox;
        widget.y -= oy;
      }

      return true;
    } catch (std::exception &ex) {
      std::cerr << ex.what() << '\n';
      return false;
    }
  }

  void readPixels(uint8_t *dst, size_t dstSize)
  {
    vulkan.readPixels(dst, dstSize);
  }

  float shellLeftWidth_ = 220.f;
  float shellRightWidth_ = 260.f;
  shell::Rect diagramViewport_{0, 0, 800, 600};
  shell::Node workspaceRoot_ =
    shell::defaultWorkspace(shellLeftWidth_, shellRightWidth_);

  // Declarative Swift UI tree (replaces ImGui side panels when present).
  shell::WidgetBuilder uiBuilder_;
  shell::WidgetTree uiTree_;
  float uiBodyOriginY_ = 0.f; // menu bar height; body layout is below

  // Immediate draw list (Phase 3) — authored by Swift each dirty frame.
  std::vector<canvas::DrawCommand> drawCmds_;
  std::vector<std::string> drawStrings_;
  bool drawListActive_ = false; // explicit; empty list must not fall back to legacy
  std::deque<canvas::InputEvent> inputEvents_;

  std::vector<canvas::TreeItem> projectTree_;
  std::vector<canvas::PropertyItem> properties_;
  std::string selectedTreeId_;

  void setProjectTree(std::vector<canvas::TreeItem> items)
  {
    projectTree_ = std::move(items);
    // Keep selection if still present.
    bool found = false;
    for (const auto &it : projectTree_) {
      if (it.id == selectedTreeId_) {
        found = true;
        break;
      }
    }
    if (!found) {
      selectedTreeId_.clear();
      for (const auto &it : projectTree_) {
        if (it.selected) {
          selectedTreeId_ = it.id;
          break;
        }
      }
      if (selectedTreeId_.empty() && !projectTree_.empty()) {
        selectedTreeId_ = projectTree_.front().id;
      }
    }
  }

  void setProperties(std::vector<canvas::PropertyItem> items)
  {
    properties_ = std::move(items);
  }

  std::string selectedTreeId() const { return selectedTreeId_; }
  shell::Rect diagramViewport() const { return diagramViewport_; }

  void setWorkspaceLayout(shell::Node root)
  {
    workspaceRoot_ = std::move(root);
  }

  void setWorkspaceColumns(shell::PanelKind left, shell::PanelKind center,
                           shell::PanelKind right,
                           float leftWidth, float rightWidth)
  {
    shellLeftWidth_ = leftWidth;
    shellRightWidth_ = rightWidth;
    workspaceRoot_ = shell::columns(left, center, right, leftWidth, rightWidth);
  }

  void layoutDeclarativeUI(float ew, float bodyH, float menuH)
  {
    uiBodyOriginY_ = menuH;
    auto measure = [this](const std::string &text, float &outW, float &outH) {
      const auto m = textRenderer.getTextMetrics(text);
      outW = static_cast<float>(std::max(m.w, 1));
      outH = std::max(static_cast<float>(m.h), textRenderer.getLineHeight());
    };
    uiTree_.layout(ew, bodyH, measure);
    if (auto d = uiTree_.diagramHostRect()) {
      diagramViewport_ = {d->x, d->y + menuH, d->w, d->h};
    }
  }

  void drawAppShell(float ew, float eh)
  {
    const float menuH = ImGui::GetFrameHeight();
    const float bodyH = std::max(1.f, eh - menuH);

    ImGuiWindowFlags hostFlags =
      ImGuiWindowFlags_NoDecoration |
      ImGuiWindowFlags_NoMove |
      ImGuiWindowFlags_NoResize |
      ImGuiWindowFlags_NoBringToFrontOnFocus |
      ImGuiWindowFlags_NoNavFocus |
      ImGuiWindowFlags_MenuBar |
      ImGuiWindowFlags_NoBackground;

    ImGui::SetNextWindowPos(ImVec2(0, 0));
    ImGui::SetNextWindowSize(ImVec2(ew, eh));
    ImGui::PushStyleVar(ImGuiStyleVar_WindowRounding, 0.f);
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(0, 0));
    ImGui::Begin("##ShellHost", nullptr, hostFlags);
    ImGui::PopStyleVar(2);

    if (ImGui::BeginMenuBar()) {
      if (ImGui::BeginMenu("File")) {
        ImGui::MenuItem("New diagram", nullptr, false, false);
        ImGui::MenuItem("Open…", nullptr, false, false);
        ImGui::MenuItem("Save", nullptr, false, false);
        ImGui::Separator();
        if (ImGui::MenuItem("Quit")) {
          if (auto *w = vulkan.window()) {
            glfwSetWindowShouldClose(w, GLFW_TRUE);
          }
        }
        ImGui::EndMenu();
      }
      if (ImGui::BeginMenu("View")) {
        if (!uiTree_.hasRoot()) {
          if (ImGui::SliderFloat("Left panel", &shellLeftWidth_, 140.f, 400.f) ||
              ImGui::SliderFloat("Right panel", &shellRightWidth_, 160.f, 480.f)) {
            workspaceRoot_ = shell::columns(
              shell::PanelKind::ProjectTree, shell::PanelKind::Diagram,
              shell::PanelKind::Properties, shellLeftWidth_, shellRightWidth_);
          }
        } else {
          ImGui::TextDisabled("Layout driven by Swift UI tree");
        }
        ImGui::EndMenu();
      }
      ImGui::TextDisabled(
        uiTree_.hasRoot()
          ? "  FBD Editor  ·  Swift UI + Yoga  ·  TextRenderer"
          : "  FBD Editor  ·  Yoga + ImGui  ·  C++/Swift");
      ImGui::EndMenuBar();
    }

    // Draw-list shell (Phase 3): menu only — chrome is painted by submitDrawList.
    if (drawListActive_) {
      uiBodyOriginY_ = menuH;
      ImGui::End();
      return;
    }

    // Prefer legacy declarative C++ UI tree when committed.
    if (uiTree_.hasRoot()) {
      layoutDeclarativeUI(ew, bodyH, menuH);
      ImGui::End();
      return;
    }

    // Legacy ImGui chrome (project tree | diagram hole | properties).
    auto placements = shell::calculateLayout(workspaceRoot_, ew, bodyH);

    shell::Rect leftR{0, menuH, shellLeftWidth_, bodyH};
    shell::Rect centerR{shellLeftWidth_, menuH, ew - shellLeftWidth_ - shellRightWidth_, bodyH};
    shell::Rect rightR{ew - shellRightWidth_, menuH, shellRightWidth_, bodyH};
    for (const auto &p : placements) {
      shell::Rect r = p.rect;
      r.y += menuH;
      switch (p.panel) {
      case shell::PanelKind::ProjectTree: leftR = r; break;
      case shell::PanelKind::Diagram: centerR = r; break;
      case shell::PanelKind::Properties: rightR = r; break;
      default: break;
      }
    }
    diagramViewport_ = centerR;
    uiBodyOriginY_ = menuH;

    auto panelChild = [&](const char *id, const shell::Rect &r, bool border) {
      ImGui::SetCursorScreenPos(ImVec2(r.x, r.y));
      ImGui::BeginChild(id, ImVec2(r.w, r.h), border,
                        border ? 0 : ImGuiWindowFlags_NoBackground);
    };

    panelChild("##Left", leftR, true);
    ImGui::TextUnformatted("Project");
    ImGui::Separator();
    if (projectTree_.empty()) {
      ImGui::TextDisabled("(no items — push from Swift)");
    } else {
      for (auto &it : projectTree_) {
        ImGui::Dummy(ImVec2(static_cast<float>(it.depth) * 12.f, 0));
        ImGui::SameLine(0, 0);
        const bool sel = (it.id == selectedTreeId_);
        if (ImGui::Selectable(it.label.c_str(), sel)) {
          selectedTreeId_ = it.id;
        }
      }
    }
    ImGui::EndChild();

    panelChild("##Center", centerR, false);
    ImGui::EndChild();

    panelChild("##Right", rightR, true);
    ImGui::TextUnformatted("Properties");
    ImGui::Separator();
    if (!selectedTreeId_.empty()) {
      ImGui::Text("Selected: %s", selectedTreeId_.c_str());
    } else {
      ImGui::TextDisabled("No selection");
    }
    ImGui::Spacing();
    if (properties_.empty()) {
      ImGui::TextDisabled("(no properties)");
    } else {
      for (const auto &p : properties_) {
        ImGui::Text("%s", p.key.c_str());
        ImGui::SameLine(rightR.w * 0.45f);
        ImGui::TextUnformatted(p.value.c_str());
      }
    }
    ImGui::EndChild();

    ImGui::End();
  }

  // ─── Declarative UI builder (Swift interop) ─────────────────────────────

  void uiReset() { uiBuilder_.reset(); }

  void uiBegin(int kind, int id, float flexGrow, float flexShrink,
               float width, float height, float padding)
  {
    uiBuilder_.begin(static_cast<shell::WidgetKind>(kind), id,
                     flexGrow, flexShrink, width, height, padding);
  }

  void uiText(int id, const char *text, float r, float g, float b, bool clickable)
  {
    uiBuilder_.text(id, text, r, g, b, clickable);
  }

  void uiEnd() { uiBuilder_.end(); }

  void uiCommit()
  {
    uiTree_.setRoot(uiBuilder_.takeRoot());
    uiBuilder_.reset();
  }

  bool uiPollEvent(int &outWidgetId, int &outKind)
  {
    shell::UIEvent e;
    if (!uiTree_.pollEvent(e)) return false;
    outWidgetId = e.widgetId;
    outKind = static_cast<int>(e.kind);
    return true;
  }

  void submitDrawList(const canvas::DrawCommand *cmds, size_t cmdCount,
                      const uint8_t *stringBlob, size_t blobSize,
                      const uint32_t *stringOffsets, size_t stringCount)
  {
    drawListActive_ = true;
    drawCmds_.assign(cmds, cmds + cmdCount);
    drawStrings_.clear();
    drawStrings_.reserve(stringCount);
    for (size_t i = 0; i < stringCount; ++i) {
      const uint32_t off = stringOffsets[i];
      if (!stringBlob || off >= blobSize) {
        drawStrings_.emplace_back();
        continue;
      }
      // NUL-terminated slices packed by Swift.
      drawStrings_.emplace_back(
        reinterpret_cast<const char *>(stringBlob + off));
    }
  }

  bool pollInputEvent(canvas::InputEvent &out)
  {
    if (inputEvents_.empty()) return false;
    out = inputEvents_.front();
    inputEvents_.pop_front();
    return true;
  }

  void setDiagramViewport(float x, float y, float w, float h)
  {
    diagramViewport_ = {x, y, w, h};
  }

  // ImGui frame: app shell (windowed) + text widgets.
  ImDrawData* renderImGuiOverlay(float /*currentFPS*/, float deltaTime)
  {
    if (vulkan.isWindowed()) {
      ImGui_ImplGlfw_NewFrame();
    }
    ImGui_ImplVulkan_NewFrame();
    ImGuiIO &io = ImGui::GetIO();
    const float ew = static_cast<float>(vulkan.getExtent().width);
    const float eh = static_cast<float>(vulkan.getExtent().height);
    io.DisplaySize = ImVec2(ew, eh);
    io.DeltaTime = std::max(deltaTime, 0.0001f);
    io.IniFilename = nullptr;
    ImGui::NewFrame();

    if (vulkan.isWindowed()) {
      drawAppShell(ew, eh);
    }

    // Text widgets share ImGui's font atlas / Vulkan backend.
    ImDrawList *fg = ImGui::GetForegroundDrawList();
    ImFont *font = ImGui::GetFont();
    const float fontSize = ImGui::GetFontSize();
    for (auto &[id, widget] : textWidgets) {
      (void)id;
      widget.draw(fg, font, fontSize, deltaTime);
    }

    mesh3DRenderer.setDrawNormals(renderNormalsDebug);
    mesh3DRenderer.setNormalDebugLength(normalDebugLength);
    mesh3DRenderer.setNormalDebugSampleStep(static_cast<u32>(std::max(normalDebugSampleStride, 1)));
    mesh3DRenderer.setNormalDebugColor(vec4(normalDebugColor.x, normalDebugColor.y, normalDebugColor.z, normalDebugColor.w));
    mesh3DRenderer.setWireframe(renderWireframeDebug);

    ImGui::Render();
    return ImGui::GetDrawData();
  }

  void shutdown()
  {
    renderer.cleanUp();
    mesh3DRenderer.cleanUp();
    textRenderer.cleanUp();
    lineRenderer.destroy();
    Mesh3DRegistry::getInstance().cleanUp(vulkan.getDevice());
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

void Application::setProjectTree(std::vector<canvas::TreeItem> items) {
  impl_->setProjectTree(std::move(items));
}

void Application::setProperties(std::vector<canvas::PropertyItem> items) {
  impl_->setProperties(std::move(items));
}

std::string Application::selectedTreeId() const {
  return impl_->selectedTreeId();
}

shell::Rect Application::diagramViewport() const {
  return impl_->diagramViewport();
}

void Application::setWorkspaceLayout(shell::Node root) {
  impl_->setWorkspaceLayout(std::move(root));
}

void Application::setWorkspaceColumns(
  shell::PanelKind left, shell::PanelKind center, shell::PanelKind right,
  float leftWidth, float rightWidth)
{
  impl_->setWorkspaceColumns(left, center, right, leftWidth, rightWidth);
}

void Application::uiReset() { impl_->uiReset(); }

void Application::uiBegin(int kind, int id, float flexGrow, float flexShrink,
                          float width, float height, float padding)
{
  impl_->uiBegin(kind, id, flexGrow, flexShrink, width, height, padding);
}

void Application::uiText(int id, const char *text, float r, float g, float b,
                         bool clickable)
{
  impl_->uiText(id, text, r, g, b, clickable);
}

void Application::uiEnd() { impl_->uiEnd(); }

void Application::uiCommit() { impl_->uiCommit(); }

bool Application::uiPollEvent(int &outWidgetId, int &outKind)
{
  return impl_->uiPollEvent(outWidgetId, outKind);
}

void Application::submitDrawList(const canvas::DrawCommand *cmds, size_t cmdCount,
                                 const uint8_t *stringBlob, size_t blobSize,
                                 const uint32_t *stringOffsets, size_t stringCount)
{
  impl_->submitDrawList(cmds, cmdCount, stringBlob, blobSize, stringOffsets,
                        stringCount);
}

bool Application::pollInputEvent(canvas::InputEvent &out)
{
  return impl_->pollInputEvent(out);
}

void Application::setDiagramViewport(float x, float y, float w, float h)
{
  impl_->setDiagramViewport(x, y, w, h);
}

bool Application::repaint() {
  return impl_->repaint();
}

int Application::addRect(float x, float y, float w, float h, float r, float g, float b, float a) {
  return impl_->addRect(x, y, w, h, r, g, b, a);
}

void Application::updateRect(int id, float x, float y, float w, float h, float r, float g, float b, float a) {
  impl_->updateRect(id, x, y, w, h, r, g, b, a);
}

int Application::addRoundedRect(float x, float y, float w, float h, float r, float g, float b, float a) {
  return impl_->addRoundedRect(x, y, w, h, r, g, b, a);
}

int Application::addCircle(float centerX, float centerY, float radius, float r, float g, float b, float a) {
  return impl_->addCircle(centerX, centerY, radius, r, g, b, a);
}

void Application::removeShape(int id) {
  impl_->removeShape(id);
}

void Application::clearShapes() {
  impl_->clearShapes();
}

int Application::addLine(float x1, float y1, float x2, float y2, float r, float g, float b, float a) {
  return impl_->addLine(x1, y1, x2, y2, r, g, b, a);
}

void Application::removeLine(int id) {
  impl_->removeLine(id);
}

void Application::clearLines() {
  impl_->clearLines();
}

int Application::addLabel(const std::string &text, float x, float y, float r, float g, float b) {
  return impl_->addLabel(text, x, y, r, g, b);
}

void Application::removeLabel(int id) {
  impl_->removeLabel(id);
}

void Application::clearLabels() {
  impl_->clearLabels();
}

int Application::addTextWidget(float x, float y, float width, float height,
                               const std::string &text, bool multiline) {
  return impl_->addTextWidget(x, y, width, height, text, multiline);
}

void Application::setTextWidgetRect(int id, float x, float y, float width, float height) {
  impl_->setTextWidgetRect(id, x, y, width, height);
}

void Application::setTextWidgetText(int id, const std::string &text) {
  impl_->setTextWidgetText(id, text);
}

std::string Application::getTextWidgetText(int id) const {
  return impl_->getTextWidgetText(id);
}

bool Application::setTextWidgetHighlightRules(
  int id, const std::vector<TextHighlightRule> &rules)
{
  return impl_->setTextWidgetHighlightRules(id, rules);
}

void Application::setTextWidgetFocused(int id, bool focused) {
  impl_->setTextWidgetFocused(id, focused);
}

bool Application::isTextWidgetFocused(int id) const {
  return impl_->isTextWidgetFocused(id);
}

bool Application::textWidgetChanged(int id) {
  return impl_->textWidgetChanged(id);
}

void Application::removeTextWidget(int id) {
  impl_->removeTextWidget(id);
}

bool Application::wantsAnimation() const {
  return impl_->wantsAnimation();
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
