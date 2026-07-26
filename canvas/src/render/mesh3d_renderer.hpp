#pragma once

#include <array>
#include <memory>

#include <vulkan/vulkan.h>

#include "util/types.hpp"
#include "render/mesh3d.hpp"
#include "render/pipeline.hpp"
#include "render/vulkan_ptr.hpp"

class Camera;
class LineRenderer;

class Vulkan;
class Mesh3DRenderer {
public:

  // Render parameters for 3D meshes. Passed via PushConstants per object
  struct alignas (16) RenderParams {
    vec4 color;
    int useTexture;
    int receiveShadows;  // Whether this object receives shadows
    int castsShadows;    // Whether this object casts shadows
    float metallic;
    float roughness;
  };

  void pushMesh(int meshId, const mat4& modelMatrix, 
               const RenderParams& params);

  void setCamera(Camera& camera);
  void setLighting(const vec3& lightDir, const vec3& lightColor);

  void init();
  void draw(VkCommandBuffer commandBuffer, u32 imageIndex);
  void drawShadowPass(VkCommandBuffer commandBuffer); // New: shadow-only rendering
  void cleanUp();

  Mesh3DRenderer(Vulkan& vulkan, Camera& camera);

  void setNormalDebugRenderer(LineRenderer* renderer);
  void setDrawNormals(bool enabled);
  void setNormalDebugLength(float length);
  void setNormalDebugSampleStep(u32 step);
  void setNormalDebugColor(const vec4& color);

  void setWireframe(bool enabled);
private:
  // 3D-specific uniform data structure
  struct alignas(16) Transform3D {
    mat4 modelMatrix;
    mat4 normalMatrix;
  };

  static_assert(alignof(Transform3D) == 16, "Transform3D must be 16-byte aligned");

  // Similar to 2D renderer's approach but for 3D objects
  constexpr static size_t OBJECT_INSTANCES = 8192 * 3; // Fewer than 2D since 3D objects are typically heavier
  
  struct BufferDeleter {
    void operator()(void* ptr) const;
  };
  
  struct UboDataDynamic {
    VkBuffer                                          buffer;
    VkDeviceMemory                                    bufferMemory;
    void*                                             mapped;
    std::unique_ptr<Transform3D[], BufferDeleter>     transforms;
    std::array<RenderParams, OBJECT_INSTANCES>        renderParams;
    std::array<int, OBJECT_INSTANCES>                 meshIds; // To know which mesh to draw
    size_t                                            objectCount = 0;
  } uboDataDynamic_;

  Vulkan&                           vulkan_;
  Camera&                           camera_;

  // Pipelines
  Pipeline                          meshPipeline_;      // Main rendering pipeline
  Pipeline                          shadowPipeline_;    // Shadow pass pipeline
  Pipeline                          wireframePipeline_; // Wireframe pipeline
  
  // Main pass descriptor resources
  vk::Handle<VkDescriptorPool>      descriptorPool_;
  vk::Handle<VkDescriptorSetLayout> descriptorSetLayout_;
  VkDescriptorSet                   descriptorSet_;
  
  // Shadow pass descriptor resources (optimized - only dynamic UBO)
  vk::Handle<VkDescriptorPool>      shadowDescriptorPool_;
  vk::Handle<VkDescriptorSetLayout> shadowDescriptorSetLayout_;
  VkDescriptorSet                   shadowDescriptorSet_;
  
  // Static uniform buffer for view/projection matrices
  vk::Handle<VkBuffer>              uboStatic_;
  vk::Handle<VkDeviceMemory>        uboStaticMemory_;
  // Static UBO structure
  struct alignas(16) StaticUbo {
    alignas(16) mat4 viewProjection;
    alignas(16) mat4 shadowViewProjection;
    alignas(16) vec3 lightPosition;
    alignas(16) vec3 lightColor;
  };

  // Lighting
  vec3 lightPosition_  = normalize(vec3(-1000.0f, -1.0f, -1.0f));
  vec3 lightColor_     = vec3(1.0f, 1.0f, 1.0f);
  
  u32                               dynamicAlignment_;

  LineRenderer*                     normalDebugRenderer_ = nullptr;
  bool                              drawNormals_ = false;
  float                             normalLength_ = 15.0f;
  u32                               normalSampleStride_ = 16;
  vec4                              normalColor_ = vec4(0.0f, 0.6f, 1.0f, 1.0f);

  bool                              wireframeEnabled_ = false;

  void setupDescriptors();
  void createPipelines();
  void updateStaticUniforms();

  mat4 getShadowViewProjection() const;
};
