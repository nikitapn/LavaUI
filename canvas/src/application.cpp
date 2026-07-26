#include <pch.hpp>

#include <random>
#include <format>
#include <algorithm>

#include "application.hpp"

#include "util/constants.hpp"
#include "util/key_codes.hpp"
#include "render/vulkan.hpp"
#include "render/compute_physics.hpp"
#include "render/text_renderer.hpp"
#include "render/primitives.hpp"
#include "render/camera.hpp"
#include "render/geometry_renderer.hpp"
#include "render/mesh3d_renderer.hpp"
#include "render/texture_manager.hpp"
#include "render/line_renderer.hpp"


#include "imgui.h"
#include "imgui_impl_vulkan.h"

#include <entt/entt.hpp>

#define GLM_ENABLE_EXPERIMENTAL
#include <glm/gtx/string_cast.hpp>

std::ostream& operator<<(std::ostream& out, const vec2& v2) { return out << glm::to_string(v2); }
std::ostream& operator<<(std::ostream& out, const vec3& v3) { return out << glm::to_string(v3); }
std::ostream& operator<<(std::ostream& out, const vec4& v4) { return out << glm::to_string(v4); }

// Enable or disable the GPU-based physics system
#define VULKAN_PHYSICS 0

/*
 * Physics System Implementation:
 * 
 * 1. Forces and Impulses:
 *    - Forces are accumulated each frame and applied continuously (e.g., gravity, wind)
 *    - Impulses are applied instantaneously to change momentum (e.g., collisions)
 *    - F = ma, so acceleration = F * invMass
 * 
 * 2. Collision Resolution:
 *    - Uses impulse-based collision response
 *    - Considers mass of both objects in collisions
 *    - Separates overlapping objects to prevent penetration
 *    - Applies restitution coefficient for realistic bouncing
 * 
 * 3. Integration:
 *    - Semi-implicit Euler integration (velocity then position)
 *    - Subdivided timesteps for stability
 */

struct Position {
  vec2 position;
};

struct Velocity {
  vec2 velocity;
};

struct Mass {
  float mass;
  float invMass; // 1/mass, useful for calculations (0 for immovable objects)
};

struct Force {
  vec2 force;
};

struct Renderable {
  mat4 world;
};

struct Circle {
  vec2  position;
  float radius;
};

struct Ray {
  vec2 origin;
  vec2 direction;
};

struct Wall {
  Ray  ray;
  vec2 normal;
};

/*
 0 - no intersection
 1 - tangent
 2 - intersection
 */
int rayCircleIntersection(const Ray &ray, const Circle &circle, vec2 result[2])
{
  vec2  oc = ray.origin - circle.position;
  float a  = glm::dot(ray.direction, ray.direction);
  float b  = 2.0f * glm::dot(oc, ray.direction);
  float c  = glm::dot(oc, oc) - circle.radius * circle.radius;
  float d  = b * b - 4 * a * c;

  if (d < 0) return 0;

  if (std::abs(d) < 1e-3) {
    float t   = -b / (2.0f * a);
    result[0] = ray.origin + t * ray.direction;
    return 1;
  }

  float t1  = (-b + sqrt(d)) / (2.0f * a);
  float t2  = (-b - sqrt(d)) / (2.0f * a);
  result[0] = ray.origin + t1 * ray.direction;
  result[1] = ray.origin + t2 * ray.direction;

  return 2;
}

/*
 0 - no intersection
 1 - tangent
 2 - intersection
 */
int cirleCircleIntersection(const Circle &c1, const Circle &c2, vec2 result[2])
{
  vec2  a         = c2.position - c1.position;
  float r         = c1.radius + c2.radius;
  float d_squared = glm::dot(a, a);
  float d         = sqrt(d_squared);

  if (d > r) return 0;

  if (std::abs(r - d) < 0.001f) {
    return 0;
    result[0] = c1.position + d * (c1.radius / d);
    return 1;
  }

  float l =
    (c1.radius * c1.radius - c2.radius * c2.radius + d_squared) / (2.0f * d);
  float h = sqrt(c1.radius * c1.radius - l * l);

  vec2 p    = c1.position + l / d * a;
  result[0] = p + h * vec2 {a.y, -a.x} / d;
  result[1] = p - h * vec2 {a.y, -a.x} / d;

  return 2;
}

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
  ComputePhysics   computePhysics;
  entt::registry   registry;
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

  std::random_device randomDevice;

  TextureHandle circleTexture;
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

  // Physics parameters
  constexpr static int maxObjects = 40;
  constexpr static float restitution = 0.8f; // Bounciness factor (0 = perfectly inelastic, 1 = perfectly elastic)
  constexpr static float radius = 24.0f;
  vec2 gravity = {0.0f, -400.8f};

  // Input state tracking
  struct InputState {
    bool keys[KEY_LAST] = {false};
    bool mouseButtons[MOUSE_BUTTON_LAST] = {false};
    double mouseX = 0.0, mouseY = 0.0;
    double lastMouseX = 0.0, lastMouseY = 0.0;
    bool firstMouse = true;
    bool mouseCaptured = false;
  } inputState;

  // GPU particle data
  std::vector<GPUParticle> gpuParticles;

  Wall walls[4] = {
    {{{0.0f, 0.0f}, {1.0f, 0.0f}}, {0.0f, 1.0f}},       // bottom
    {{{width, 0.0f}, {0.0f, 1.0f}}, {-1.0f, 0.0f}},     // right
    {{{width, height}, {-1.0f, 0.0f}}, {0.0f, -1.0f}},  // top
    {{{0.0f, height}, {0.0f, -1.0f}}, {1.0f, 0.0f}},    // left
  };

 public:
  Impl(int w, int h)
    : width{static_cast<float>(w)}
    , height{static_cast<float>(h)}
    , renderer(vulkan)
    , mesh3DRenderer(vulkan, camera)
    , textRenderer(vulkan, "assets/LiberationSerif-Regular.ttf", 36)
    , computePhysics(vulkan)
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

  void initEntities()
  {
    std::uniform_real_distribution<float> w(100.0f, width - 100.f);
    std::uniform_real_distribution<float> h(100.0f, height - 100.f);
    std::uniform_real_distribution<float> vv(-400.f, 400.f);
    std::uniform_real_distribution<float> mass_dist(10.0f, 50.0f);

    auto v = [&]() { return vv(randomDevice); };

#if VULKAN_PHYSICS
    gpuParticles.clear();
    gpuParticles.reserve(maxObjects);

    // Create random particles
    for (int i = 0; i < maxObjects; ++i) {
      GPUParticle particle;
      particle.position = {w(randomDevice), h(randomDevice)};
      particle.velocity = {v(), v()};
      particle.mass = mass_dist(randomDevice);
      particle.invMass = 1.0f / particle.mass;
      particle.force = {0.0f, 0.0f};
      particle.padding = 0.0f;

      gpuParticles.push_back(particle);

      // Also create entity for rendering
      auto entity = registry.create();
      registry.emplace<Position>(entity, particle.position);
      registry.emplace<Renderable>(entity, glm::identity<mat4>());
    }
#else
    for (int i = 0; i < maxObjects; ++i) {
      auto entity   = registry.create();
      vec2 position = {w(randomDevice), h(randomDevice)};
      vec2 velocity = {v(), v()};
      float mass = mass_dist(randomDevice);

      registry.emplace<Position>(entity, position);
      registry.emplace<Velocity>(entity, velocity);
      registry.emplace<Mass>(entity, mass, 1.0f / mass);
      registry.emplace<Force>(entity, vec2{0.0f, 0.0f});
      registry.emplace<Renderable>(entity, glm::identity<mat4>());
    }

    // Very heavy ball falling on very light ball
    // {
    //   auto entity = registry.create();

    //   vec2 position = {200.f, 100.f};
    //   vec2 velocity = {0.f, 0.f};
    //   float mass = 100.f;

    //   registry.emplace<Position>(entity, position);
    //   registry.emplace<Velocity>(entity, velocity);
    //   registry.emplace<Mass>(entity, mass, 1.0f / mass);
    //   registry.emplace<Force>(entity, vec2{0.0f, 0.0f});
    //   registry.emplace<Renderable>(entity, glm::identity<mat4>());
    // }
    // {
    //   auto entity = registry.create();

    //   vec2 position = {200.f, 400.f};
    //   vec2 velocity = {0.f, 0.f};
    //   float mass = 100000000.f;

    //   registry.emplace<Position>(entity, position);
    //   registry.emplace<Velocity>(entity, velocity);
    //   registry.emplace<Mass>(entity, mass, 1.0f / mass);
    //   registry.emplace<Force>(entity, vec2{0.0f, 0.0f});
    //   registry.emplace<Renderable>(entity, glm::identity<mat4>());
    // }
#endif
  }

#if VULKAN_PHYSICS
  void doComputePhysics(float dt)
  {
    // Clamp dt to prevent huge timesteps that cause instability
    dt = std::min(dt, 0.016f); // Max 16ms timestep

    // Debug output (only occasionally to avoid spam)
    static int debugCounter = 0;
    if (0 && debugCounter++ % 60 == 0) { // Every 60 frames
      std::cout << "Physics Debug - dt: " << dt 
                << ", gravity: (" << gravity.x << ", " << gravity.y << ")"
                << ", particles: " << gpuParticles.size() << std::endl;

      // Check first few particles for anomalies
      for (size_t i = 0; i < std::min(size_t(3), gpuParticles.size()); ++i) {
        const auto& p = gpuParticles[i];
        std::cout << "  Particle " << i << ": pos(" << p.position.x << ", " << p.position.y 
                  << "), vel(" << p.velocity.x << ", " << p.velocity.y 
                  << "), mass: " << p.mass << ", invMass: " << p.invMass << std::endl;
      }
    }

    constexpr uint32_t substeps = 1;
    // Update simulation parameters
    SimulationParams params;
    params.gravity = gravity;
    params.worldSize = {width, height};
    params.deltaTime = dt / static_cast<float>(substeps);
    params.restitution = restitution;
    params.particleRadius = radius;
    params.particleCount = static_cast<uint32_t>(gpuParticles.size());
    params.maxCollisionPairs = static_cast<uint32_t>(gpuParticles.size()) * 8; // Same as in ComputePhysics::Initialize
    params.substeps = substeps;
    params.currentSubstep = 0;

    computePhysics.updateSimulationParams(params);

    for (uint32_t step = 0; step < substeps; ++step) {
      // params.currentSubstep = step;
      // computePhysics.updateSimulationParams(params);

      // Upload current particle data to GPU
      // computePhysics.setParticles(gpuParticles);

      // Run the compute shader to perform physics step
      // computePhysics.computeStep();

      // Read back results
      // gpuParticles.clear();
      // computePhysics.readParticles(gpuParticles);
    }

    // Run compute physics once
    computePhysics.computeStep();

    // Read back results
    gpuParticles.clear();
    computePhysics.readParticles(gpuParticles);

    // Update entity positions for rendering
    auto view = registry.view<Position>();
    size_t i = 0;
    view.each([&](auto entity, Position& pos) {
      if (i < gpuParticles.size()) {
        pos.position = gpuParticles[i].position;
        i++;
      }
    });
  }
#else
  void doPhysics(float dt)
  {
    auto const N    = 4;
    auto const step = dt / static_cast<float>(N);

    auto view = registry.view<Position, Velocity, Mass, Force>();

    for (int i = 0; i < N; ++i) {
      // Apply gravity and accumulated forces, then integrate position
      view.each([&](auto entity, Position& pos, Velocity& vel, Mass& mass, Force& force) {
        // Apply gravity
        vec2 totalForce = gravity * mass.mass;

        // Add accumulated forces
        totalForce += force.force;

        // F = ma, so a = F/m = F * invMass
        vec2 acceleration = totalForce * mass.invMass;

        // Integrate velocity and position
        vel.velocity += acceleration * step;
        pos.position += vel.velocity * step;

        // Clear accumulated forces for next frame
        force.force = vec2{0.0f, 0.0f};
      });

      // Handle wall collisions
      view.each([&](auto entity, Position& pos, Velocity& vel, Mass& mass, Force& force) {
        for (auto &wall : walls) {
          // moving away from the wall
          if (glm::dot(vel.velocity, wall.normal) > 0.0f) {
            continue;
          }

          vec2 result[2];
          int n = rayCircleIntersection(wall.ray, {pos.position, radius}, result);
          if (n > 0) {
            // Reflect velocity with restitution
            float velocityAlongNormal = glm::dot(vel.velocity, wall.normal);
            if (velocityAlongNormal < 0) { // Only resolve if moving towards wall
              vec2 impulse = -(1 + restitution) * velocityAlongNormal * wall.normal;
              vel.velocity += impulse;

              // Move circle out of wall to prevent penetration
              float penetration = radius - glm::dot(pos.position - wall.ray.origin, wall.normal);
              if (penetration > 0) {
                pos.position += wall.normal * penetration;
              }
            }
          }
        }
      });

      // Handle circle-circle collisions
      std::vector<entt::entity> entities;
      view.each([&entities](auto entity, const Position&, const Velocity&, const Mass&, const Force&) {
        entities.push_back(entity);
      });

      for (size_t i = 0; i < entities.size(); ++i) {
        auto entity1 = entities[i];
        auto& pos1 = view.get<Position>(entity1);
        auto& vel1 = view.get<Velocity>(entity1);
        auto& mass1 = view.get<Mass>(entity1);

        for (size_t j = i + 1; j < entities.size(); ++j) {
          auto entity2 = entities[j];
          auto& pos2 = view.get<Position>(entity2);
          auto& vel2 = view.get<Velocity>(entity2);
          auto& mass2 = view.get<Mass>(entity2);

          vec2 relativePos = pos2.position - pos1.position;
          float distance = glm::length(relativePos);
          float minDistance = 2.0f * radius;

          if (distance < minDistance && distance > 0.0f) {
            // Collision normal
            vec2 normal = relativePos / distance;

            // Relative velocity
            vec2 relativeVel = vel2.velocity - vel1.velocity;

            // Velocity along collision normal
            float velocityAlongNormal = glm::dot(relativeVel, normal);

            // Do not resolve if velocities are separating
            if (velocityAlongNormal > 0) continue;

            // Calculate impulse magnitude
            float impulseMagnitude = -(1 + restitution) * velocityAlongNormal;
            impulseMagnitude /= (mass1.invMass + mass2.invMass);

            // Apply impulse
            vec2 impulse = impulseMagnitude * normal;
            vel1.velocity -= impulse * mass1.invMass;
            vel2.velocity += impulse * mass2.invMass;

            // Separate overlapping circles
            float penetration = minDistance - distance;
            vec2 correction = normal * (penetration / (mass1.invMass + mass2.invMass)) * 0.5f;
            pos1.position -= correction * mass1.invMass;
            pos2.position += correction * mass2.invMass;
          }
        }
      }
    }
  }

  // Utility function to apply a force to an entity
  void applyForce(entt::entity entity, const vec2& force) {
    if (registry.all_of<Force>(entity)) {
      auto& forceComponent = registry.get<Force>(entity);
      forceComponent.force += force;
    }
  }

  // Apply an impulse (instantaneous change in momentum) to an entity
  void applyImpulse(entt::entity entity, const vec2& impulse) {
    if (registry.all_of<Velocity, Mass>(entity)) {
      auto& vel = registry.get<Velocity>(entity);
      auto& mass = registry.get<Mass>(entity);
      vel.velocity += impulse * mass.invMass;
    }
  }
#endif

  void update2DRenderables()
  {
    auto view = registry.view<Position, Renderable>();
    view.each([&](auto entity, Position& pos, Renderable& renderable) {
      mat4 t = glm::translate(mat4(1.0f), vec3 {pos.position.x, pos.position.y, 0.0f});
      mat4 s = glm::scale(glm::identity<mat4>(), vec3 {radius*2.0f, radius*2.0f, 0});
      renderable.world = t * s;
    });
  }

  void render2DEntities()
  {
    // Render physics balls as circles
    auto view = registry.view<Renderable>();
    view.each([&](auto entity, Renderable& renderable) {
      renderer.pushObject(
        GeometryRenderer::Type::Circle,
        renderable.world,
        GeometryRenderer::RenderParamsTextured{
          .color = {1.0f, 1.0f, 1.0f, 1.0f},
          .texture = circleTexture,
        }
      );
    });

    // Render shadow map quad
    if (renderShadowDebug) {
      const auto shadowQuadSize = 300.0f;
      auto world = glm::translate(mat4(1.0f), vec3{width - shadowQuadSize / 2.0f, height - shadowQuadSize / 2.0f, 0.0f}) *
                  glm::scale(mat4(1.0f), vec3{shadowQuadSize,shadowQuadSize, 1.0f});

      renderer.pushObject(
        GeometryRenderer::Type::Rectangle,
        world,
        GeometryRenderer::RenderParamsTextured{
          .color = {1.0f, 1.0f, 1.0f, 1.0f},
          .texture = shadowMapTexture,
        }
      );
    }
    // Test different geometry types with UI-like elements
    // renderGeometryTestElements();
  }

  void renderGeometryTestElements()
  {
    // === UI ELEMENTS USING SCREEN cOORDINATES(consistent with TextRenderer) ===

    // Create a background panel for the "Geometry Test:" text (width - 200, 10)
    {
      GeometryRenderer::ScreenParams panelParams;
      panelParams.position = {0, 50.0f};    // Just behind the text
      panelParams.size = {200.0f, 30.0f};
      panelParams.color = {0.2f, 0.2f, 0.2f, 0.7f};    // Dark semi-transparent
      renderer.pushScreenObject(GeometryRenderer::Type::Rectangle, panelParams);
    }

    // Create UI buttons aligned with text elements
    {
      GeometryRenderer::ScreenParams buttonParams;
      buttonParams.position = {width - 210.0f, 35.0f};  // Aligned with "Rectangle" text
      buttonParams.size = {80.0f, 25.0f};
      buttonParams.color = {1.0f, 0.0f, 0.0f, 0.8f};   // Red button
      renderer.pushScreenObject(GeometryRenderer::Type::Rectangle, buttonParams);
    }

    // Create a rounded rectangle button panel
    {
      GeometryRenderer::ScreenParams roundedParams;
      roundedParams.position = {width - 190.0f, 70.0f};
      roundedParams.size = {120.0f, 35.0f};
      roundedParams.color = {0.2f, 0.7f, 0.3f, 0.9f};  // Green panel
      renderer.pushScreenObject(GeometryRenderer::Type::RoundedRectangle, roundedParams);
    }

    // Create small circles as UI indicators near the FPS text
    for (int i = 0; i < 3; ++i) {
      GeometryRenderer::ScreenParams circleParams;
      circleParams.position = {5.0f, 30.0f + i * 35.0f}; // Left margin, aligned with text lines
      circleParams.size = {8.0f, 8.0f};                   // Small UI indicators
      circleParams.color = {0.8f, 0.8f, 0.2f, 1.0f};     // Yellow indicators
      renderer.pushScreenObject(GeometryRenderer::Type::Circle, circleParams);
    }

    // Create a rounded rectangle debug
    {
      GeometryRenderer::ScreenParams roundedParams;
      roundedParams.position = {width / 2.0f, height / 2.0f};
      roundedParams.size = {100.0f, 100.0f};
      roundedParams.color = {1.0f, 0.7f, 0.3f, 1.0f};  // Green panel
      renderer.pushScreenObject(GeometryRenderer::Type::RoundedRectangle, roundedParams);
    }

    // === WORLD COORDINATE eLEMENTS(for comparison and physics objects) ===

    // Keep some elements in world coordinates to show the difference
    // These will be positioned relative to world center (0,0)
    // {
    //   mat4 translation = glm::translate(mat4(1.0f), vec3{-200.0f, -150.0f, 0.0f});
    //   mat4 scale = glm::scale(mat4(1.0f), vec3{60.0f, 30.0f, 1.0f});
    //   mat4 transform = translation * scale;
    //   renderer.pushObject(GeometryRenderer::Type::Rectangle, transform);
    // }

    // Test animated elements - pulsating rounded rectangle using screen coordinates
    static float time = 0.0f;
    time += 0.016f; // Assume 60 FPS

    float pulseScale = 1.0f + 0.1f * sin(time * 3.0f);
    {
      GeometryRenderer::ScreenParams pulseParams;
      pulseParams.position = {width - 100.0f, height - 50.0f}; // Bottom-right corner
      pulseParams.size = {40.0f * pulseScale, 20.0f * pulseScale};
      pulseParams.color = {1.0f, 0.2f, 0.8f, 0.7f + 0.3f * sin(time * 2.0f)}; // Pulsating alpha
      renderer.pushScreenObject(GeometryRenderer::Type::RoundedRectangle, pulseParams);
    }
  }
  float lightTheta = PI_F / 2.0f;
  float lightAlpha = 0.0f;
  float lightRadius = 300.0f;

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
    if (inputState.keys[KEY_UP]) {
      lightRadius += 10.0f;
    }
    if (inputState.keys[KEY_DOWN]) {
      lightRadius -= 10.0f;
    }
  }

  void doSomethingWith2D(float dt)
  {
    // Process input every frame for smooth movement
    // Example: Apply a random wind force occasionally
    // static float windTimer = 0.0f;
    // windTimer += dt;
    // if (windTimer > 2.0f) { // Every 2 seconds
    //   windTimer = 0.0f;
    //   std::uniform_real_distribution<float> windForce(-500.0f, 500.0f);
    //   vec2 wind = {windForce(rd_), windForce(rd_) * 0.2f}; // Mostly horizontal wind
    //   for (auto& particle : gpuParticles) {
    //     particle.force += wind;
    //   }
    // }

#if VULKAN_PHYSICS
      // Apply wind to GPU particles
      // Update particles in compute buffer
      computePhysics.setParticles(gpuParticles);
      DoComputePhysics(dt);
#else
      // auto view = registry.view<Force>();
      // view.each([&](auto entity, Force& force) {
      //   applyForce(entity, wind);
      // });
      doPhysics(dt);
#endif

    update2DRenderables();
    render2DEntities();
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

    initEntities();

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

    cubePrimitive = Primitives::generateCube(vulkan);
    spherePrimitive = Primitives::generateSphere(vulkan, 6, 12);
    circleTexture = TextureManager::getInstance().loadTexture("assets/football-157930.svg_128.png");

    shadowMapTexture = TextureManager::getInstance().registerTexture("shadowMap",
      vulkan.getShadowImageView(), vulkan.getShadowMapSize(), vulkan.getShadowMapSize());

#if VULKAN_PHYSICS
    // Initialize compute physics
    computePhysics.initialize(static_cast<uint32_t>(gpuParticles.size()));
    computePhysics.setParticles(gpuParticles);
    std::cout << "Compute physics initialized.\n";
#endif

    std::cout << "Init complete.\n";
  }

  // Advances and renders one frame. deltaTime is supplied by the caller
  // (previously computed internally from glfwGetTime()/chrono against the
  // last iteration of an internal while(!glfwWindowShouldClose) loop; now
  // there's no window to loop against, so the caller drives timing).
  bool tick(float deltaTime)
  {
    try {
      // Update timers
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

      // 2D physics and rendering
      doSomethingWith2D(deltaTime);

      auto camPos = camera.position();
      auto camLook = camera.forward();

      auto angleRad = glm::dot(glm::normalize(-camPos), camLook);
      auto angle = acos(angleRad) * 180.0f / PI_F;

      textRenderer.beginTextRendering();

      textRenderer.renderText("Balls: " + std::to_string(maxObjects), {10.0f, 30.0f}, {1.0f, 1.0f, 1.0f});
      textRenderer.renderText(std::format("FPS: {}", currentFPS), {10.0f, 60.0f}, {0.0f, 1.0f, 0.0f});
      textRenderer.renderText(std::format("Camera: ({:.1f}, {:.1f}, {:.1f}), speed: {:.1f}", camPos.x, camPos.y, camPos.z, moveSpeed),
        {10.0f, 90.0f}, {0.0f, 1.0f, 1.0f});
      textRenderer.renderText(std::format("Angle: {:.2f}", angle),
        {10.0f, 120.0f}, {0.0f, 1.0f, 1.0f});
      textRenderer.renderText(std::format("Frame #{}", frameCountTotal), {10.0f, 150.0f}, {1.0f, 1.0f, 0.0f});

      textRenderer.endTextRendering();

      lineRenderer.clear();

      // Convert light position from spherical to Cartesian
      lightTheta += 0.3f * deltaTime; // Rotate light around Y axis
      // lightAlpha += 0.1f * deltaTime; // Slowly change elevation
      float lightX = lightRadius * cos(lightAlpha) * cos(lightTheta);
      float lightZ = lightRadius * cos(lightAlpha) * sin(lightTheta);
      float lightY = lightRadius * sin(lightAlpha) + 200.0f;

      mesh3DRenderer.setLighting(vec3{lightX, lightY, lightZ}, vec3{1.0f, 1.0f, 1.0f});

      using RP = Mesh3DRenderer::RenderParams;
      {
        // Platform cube
        auto cubeTranslation = glm::translate(glm::identity<mat4>(), vec3{0.0f, -55.0f, 0.0f});
        auto cubeScale = glm::scale(glm::identity<mat4>(), vec3{1000.0f, 10.0f, 1000.0f});
        auto cubeMatrix = cubeTranslation * cubeScale;
        if (cubePrimitive) {
          mesh3DRenderer.pushMesh(cubePrimitive->meshId, cubeMatrix, RP {
          .color = {0.7f, 0.7f, 0.7f, 1.0f},
          .useTexture = false,
          .castsShadows = false,
        });
        }
      }
      {
        auto cubeTranslation = glm::translate(glm::identity<mat4>(), vec3{300.0f, 0.0f, 0.0f});
        auto cubeScale = glm::scale(glm::identity<mat4>(), vec3{50.0f, 100.0f, 100.0f});
        auto cubeMatrix = cubeTranslation * cubeScale;
        if (cubePrimitive) {
          mesh3DRenderer.pushMesh(cubePrimitive->meshId, cubeMatrix, RP {
            .color = {.3f, 1.f, 0.3f, 1.0f},
            .useTexture = false,
            .castsShadows = true
          });
        }
      }

      vulkan.renderWithShadows(
        // Shadow pass callback - render depth-only
        [&](VkCommandBuffer commandBuffer) {
          mesh3DRenderer.drawShadowPass(commandBuffer);
        },
        // Main pass callback - render scene with shadows
        [&](VkCommandBuffer commandBuffer, u32 imageIndex) {
          renderer.draw(commandBuffer, imageIndex);
          mesh3DRenderer.draw(commandBuffer, imageIndex);
          if (true || renderOctreeDebug || renderNormalsDebug) {
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
    computePhysics.cleanup();
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

bool Application::tick(float deltaTime) {
  return impl_->tick(deltaTime);
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
