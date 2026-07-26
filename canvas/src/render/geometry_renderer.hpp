#pragma once

#include <cstring>
#include <memory>
#include <variant>

#include <vulkan/vulkan.h>

#include "render/pipeline.hpp"
#include "render/texture_manager.hpp"
#include "util/types.hpp"
#include "util/util.hpp"

class Vulkan;
class GeometryRenderer {
public:
  enum class Type { Circle, Rectangle, RoundedRectangle };
  
  // Screen coordinate parameters (matches TextRenderer coordinate system)
  // Uses: (0,0) = top-left, X+ = right, Y+ = down
  struct ScreenParams {
    vec2 position;      // Screen position
    vec2 size;          // Width/height in pixels
    vec4 color;         // RGBA color
    bool useTexture;    // Whether to use texture

    ScreenParams() : position{0,0}, size{10,10}, color{1,1,1,1}, useTexture{false} {}
    ScreenParams(vec2 pos, vec2 sz, vec4 col = {1,1,1,1}) 
      : position{pos}, size{sz}, color{col}, useTexture{false} {}
  };

  // World coordinate parameters (for physics objects)
  struct RenderParamsSolid {
    vec4 color;
  };
  
  struct RenderParamsTextured {
    vec4 color;
    TextureHandle texture;
  };
  
  using RenderParams = std::variant<RenderParamsSolid, RenderParamsTextured>;

  // World matrix-based rendering (for physics objects)
  void pushObject(Type type, const mat4& world, const RenderParams& params = RenderParamsSolid{.color = {1.0f,1.0f,1.0f,1.0f}})
  {
    assert(uboDataDynamic_.count < OBJECT_INSTANCES);
    auto ix = uboDataDynamic_.count++;

    auto ptr = uboDataDynamic_.model.get();
    std::memcpy(reinterpret_cast<std::byte*>(ptr) + ix * dynamicAlignment_,
               glm::value_ptr(world), sizeof(mat4));

    auto& obj = objects_[static_cast<size_t>(type)];
    auto index = obj.count++;
    obj.mappings[index] = ix;
    obj.renderParams[index] = params;
  }
  
  // Screen coordinate-based rendering (for UI elements)
  void pushScreenObject(Type type, const ScreenParams& params);
  
  // Set the viewport size for screen coordinate calculations
  void setViewportSize(vec2 size);
  
  // Toggle between wireframe and filled rendering
  void toggleWireframe();
  
  void init();
  void draw(VkCommandBuffer commandBuffer, u32 imageIndex);
  void cleanUp();

  GeometryRenderer(Vulkan& vulkan)
      : vulkan_ {vulkan}
  {
  }

private:
  struct Geometry {
    vk::Buffer vertexBuffer;
    vk::Buffer indexBuffer;
  };

  // One big uniform buffer that contains all matrices
  // Note that we need to manually allocate the data to cope for GPU-specific
  // uniform buffer offset alignments
  constexpr static size_t OBJECT_INSTANCES = 2048;
  struct BufferDeleter {
    void operator()(
      void* ptr) const
    {
      utils::alignedFree(ptr);
    }
  };
  struct UboDataDynamic {
    VkBuffer                                    buffer;
    VkDeviceMemory                              bufferMemory;
    void*                                       mapped;
    std::unique_ptr<glm::mat4[], BufferDeleter> model;
    size_t                                      count = 0;
  } uboDataDynamic_;

  struct Objects {
    std::array<u16, OBJECT_INSTANCES>          mappings;
    std::array<RenderParams, OBJECT_INSTANCES> renderParams;
    u16                                        count = 0;
  };

  Vulkan&                           vulkan_;
  Pipeline                          fanPipeline_;          // For circles and rounded rectangles
  Pipeline                          indexedPipeline_;      // For rectangles
  Pipeline                          fanWireframePipeline_;     // Wireframe fan pipeline
  Pipeline                          indexedWireframePipeline_; // Wireframe indexed pipeline
  bool                              wireframeMode_ = false;
  vk::Handle<VkDescriptorPool>      descriptorPool_;
  vk::Handle<VkDescriptorSetLayout> descriptorSetLayout_;
  // destroyed with pool
  VkDescriptorSet            descriptorSet_;
  vk::Buffer                 uboStatic_;
  vk::Handle<VkSampler>      textureSampler_;

  u32                        dynamicAlignment_;
  std::array<Geometry, 3>    vbs_;
  std::array<Objects, 3>     objects_;

  void setupDescriptors();
  void createPipeline();
  vec2 viewportSize_ = {800.0f, 600.0f};
};
