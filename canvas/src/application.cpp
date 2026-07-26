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

  struct DebugGeometry {
    struct Point {
      mat4 transform;
      vec4 color;
    };
    struct Line {
      vec3 start;
      vec3 end;
      vec4 color;
    };
    struct Triangle {
      vec3 v0;
      vec3 v1;
      vec3 v2;
      vec4 color;
    };

    std::vector<Point>    points;
    std::vector<Line>     lines;
    std::vector<Triangle> triangles;

    void draw(Impl& app) {
      for (const auto& p : points) {
        app.mesh3DRenderer.pushMesh(app.spherePrimitive->meshId, p.transform, {p.color});
      }
      for (const auto& l : lines) {
        app.lineRenderer.addLine(l.start, l.end, l.color);
      }
      for (const auto& t : triangles) {
        app.lineRenderer.addLine(t.v0, t.v1, t.color);
        app.lineRenderer.addLine(t.v1, t.v2, t.color);
        app.lineRenderer.addLine(t.v2, t.v0, t.color);
      }
    }
  } debugGeometry;

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

  // Retained 2D rectangle scene, populated by add/update/removeRect and
  // replayed into the (per-frame-immediate-mode) GeometryRenderer on every
  // repaint(). x/y is the top-left corner (GeometryRenderer::pushScreenObject
  // itself takes a center point, converted in repaint()).
  struct RectShape {
    float x, y, width, height;
    float r, g, b, a;
  };
  std::unordered_map<int, RectShape> rects;
  int nextRectId = 1;

  // Wall-clock time of the last repaint() call, used only to compute a
  // deltaTime for the FPS counter/Dear ImGui (nullopt on the first call).
  std::optional<std::chrono::steady_clock::time_point> lastRepaintTime;

 public:
  Impl(int w, int h)
    : width{static_cast<float>(w)}
    , height{static_cast<float>(h)}
    , renderer(vulkan)
    , mesh3DRenderer(vulkan, camera)
    , textRenderer(vulkan, "assets/LiberationSerif-Regular.ttf", 36)
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

  void init(const std::string &assetsRoot)
  {
    // Previously main.cpp set this relative to argv[0] before Application
    // existed at all; now it's an explicit parameter since there's no
    // meaningful argv[0] when embedded in another process. Everything else
    // (TextureManager, shader/font loading) still loads "assets/..." paths
    // relative to the current directory, unchanged.
    if (!assetsRoot.empty()) {
      std::filesystem::current_path(assetsRoot);
    }

    vulkan.init("2d shenanigans!", static_cast<int>(width), static_cast<int>(height));
    std::cout << "Vulkan initialized.\n";

    // Initialize TextureManager
    TextureManager::getInstance().initialize(vulkan);
    std::cout << "TextureManager initialized.\n";

    camera.setAspectRatio(width / height);

    renderer.init();
    // Set viewport size for consistent coordinate system
    renderer.setViewportSize({width, height});
    std::cout << "Renderer initialized.\n";

    textRenderer.init();
    std::cout << "Text renderer initialized.\n";

    mesh3DRenderer.init();
    std::cout << "3D Mesh renderer initialized.\n";

    lineRenderer.initialize(vulkan);
    std::cout << "Line renderer initialized.\n";
    mesh3DRenderer.setNormalDebugRenderer(&lineRenderer);

    shadowMapTexture = TextureManager::getInstance().registerTexture("shadowMap",
      vulkan.getShadowImageView(), vulkan.getShadowMapSize(), vulkan.getShadowMapSize());

    std::cout << "Init complete.\n";
  }

  int addRect(float x, float y, float w, float h, float r, float g, float b, float a)
  {
    int id = nextRectId++;
    rects[id] = RectShape{x, y, w, h, r, g, b, a};
    return id;
  }

  void updateRect(int id, float x, float y, float w, float h, float r, float g, float b, float a)
  {
    auto it = rects.find(id);
    if (it != rects.end()) {
      it->second = RectShape{x, y, w, h, r, g, b, a};
    }
  }

  void removeRect(int id)
  {
    rects.erase(id);
  }

  void clearRects()
  {
    rects.clear();
  }

  // Renders one frame of the retained scene (currently just `rects`) and
  // reports it back via readPixels(). There's no fixed-timestep loop driving
  // this anymore — callers (Swift) call it whenever they want a new frame,
  // e.g. right after changing the scene. deltaTime for the FPS counter/Dear
  // ImGui is computed from wall-clock time between calls instead of being
  // passed in.
  bool repaint()
  {
    try {
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

      ImDrawData* imguiDrawData = renderDebugUI(currentFPS, deltaTime);

      processContinuousInput(deltaTime);

      // Replay the retained rectangles into the GeometryRenderer, which is
      // itself immediate-mode per frame (see GeometryRenderer::draw — it
      // resets its own counts after every draw call). x/y here is the
      // top-left corner; pushScreenObject wants a center point.
      for (const auto &[id, rect] : rects) {
        renderer.pushScreenObject(
          GeometryRenderer::Type::Rectangle,
          GeometryRenderer::ScreenParams{
            {rect.x + rect.width / 2.0f, rect.y + rect.height / 2.0f},
            {rect.width, rect.height},
            {rect.r, rect.g, rect.b, rect.a}
          }
        );
      }

      textRenderer.beginTextRendering();
      textRenderer.renderText(std::format("FPS: {:.1f}", currentFPS), {10.0f, 30.0f}, {0.0f, 1.0f, 0.0f});
      textRenderer.renderText(std::format("Rects: {}", rects.size()), {10.0f, 60.0f}, {1.0f, 1.0f, 1.0f});
      textRenderer.renderText(std::format("Frame #{}", frameCountTotal), {10.0f, 90.0f}, {1.0f, 1.0f, 0.0f});
      textRenderer.endTextRendering();

      lineRenderer.clear();

      vulkan.renderWithShadows(
        // Shadow pass callback - render depth-only (nothing pushes meshes
        // into mesh3DRenderer right now, so this is a no-op; kept so the
        // shadow-mapping infrastructure stays available for later).
        [&](VkCommandBuffer commandBuffer) {
          mesh3DRenderer.drawShadowPass(commandBuffer);
        },
        // Main pass callback - render scene with shadows
        [&](VkCommandBuffer commandBuffer, u32 imageIndex) {
          renderer.draw(commandBuffer, imageIndex);
          mesh3DRenderer.draw(commandBuffer, imageIndex);
          if (renderOctreeDebug || renderNormalsDebug) {
            lineRenderer.draw(commandBuffer);
          }
          textRenderer.draw(commandBuffer, {width, height});
          if (imguiDrawData && imguiDrawData->Valid) {
            ImGui_ImplVulkan_RenderDrawData(imguiDrawData, commandBuffer);
          }
        }
      );

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

  ImDrawData* renderDebugUI(float currentFPS, float deltaTime)
  {
    ImGui_ImplVulkan_NewFrame();
    // No platform backend (imgui_impl_glfw) — feed the bits of ImGuiIO a
    // platform backend would normally set. Mouse/keyboard IO stays at
    // whatever handle*Input() last wrote to it; a future input bridge is
    // expected to keep updating ImGuiIO itself as part of forwarding events
    // in.
    ImGuiIO &io = ImGui::GetIO();
    io.DisplaySize = ImVec2(width, height);
    io.DeltaTime = std::max(deltaTime, 0.0001f); // Dear ImGui asserts DeltaTime > 0.
    ImGui::NewFrame();

    if (ImGui::Begin("Debug Controls")) {
      ImGui::Text("FPS: %.1f", currentFPS);
      ImGui::Separator();

      ImGui::Checkbox("Show shadow map", &renderShadowDebug);
      ImGui::Checkbox("Show octree debug", &renderOctreeDebug);
      ImGui::Checkbox("Show bricks debug", &renderBricksDebug);
      ImGui::Checkbox("Show mesh normals", &renderNormalsDebug);
      ImGui::Checkbox("Show wireframe", &renderWireframeDebug);

      if (renderNormalsDebug) {
        ImGui::SliderFloat("Normal length", &normalDebugLength, 1.0f, 200.0f, "%.1f");
        if (ImGui::DragInt("Normal stride", &normalDebugSampleStride, 1.0f, 1, 512)) {
          normalDebugSampleStride = std::max(normalDebugSampleStride, 1);
        } else {
          normalDebugSampleStride = std::max(normalDebugSampleStride, 1);
        }
        ImGui::ColorEdit4("Normal color", &normalDebugColor.x);
      }

      ImGui::Separator();
      ImGui::Text("Hello");
    }
    ImGui::End();

    if (showImGuiDemo) {
      ImGui::ShowDemoWindow(&showImGuiDemo);
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
void Application::init(const std::string &assetsRoot) {
  impl_->init(assetsRoot);
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

void Application::removeRect(int id) {
  impl_->removeRect(id);
}

void Application::clearRects() {
  impl_->clearRects();
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
