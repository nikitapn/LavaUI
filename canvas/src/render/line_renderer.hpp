#pragma once

#include <vector>
#include <memory>

#include <vulkan/vulkan.h>

#include "util/types.hpp"
#include "render/pipeline.hpp"
#include "render/vulkan_ptr.hpp"

#include <array>

class Vulkan;

class LineRenderer {
public:
  struct LineVertex {
    vec3 position;
    vec4 color;
  };

  struct Line {
    vec3 start;
    vec3 end;
    vec4 color;
  };

private:
  static constexpr u32 MAX_LINES = 1000000;

  Vulkan* vulkan_ = nullptr;

  // CPU data
  std::vector<LineVertex> vertices_;
  std::vector<Line> lines_;

  struct UniformData {
    mat4 viewProjection;
  };

  VkBuffer vertexBuffer_ = VK_NULL_HANDLE;
  VkDeviceMemory vertexBufferMemory_ = VK_NULL_HANDLE;
  VkDeviceSize vertexBufferSize_ = 0;

  VkBuffer uniformBuffer_ = VK_NULL_HANDLE;
  VkDeviceMemory uniformBufferMemory_ = VK_NULL_HANDLE;

  Pipeline pipeline_;

  VkDescriptorSet descriptorSet_ = VK_NULL_HANDLE;
  VkDescriptorSetLayout descriptorSetLayout_ = VK_NULL_HANDLE;
  VkDescriptorPool descriptorPool_ = VK_NULL_HANDLE;

public:
  LineRenderer();
  ~LineRenderer();

  void initialize(Vulkan& vulkan);
  void destroy();

  // Add a single line
  void addLine(const vec3& start, const vec3& end, const vec4& color = {1.0f, 1.0f, 1.0f, 1.0f});

  // Add a wireframe box
  void addBox(const vec3& center, const vec3& size, const vec4& color = {1.0f, 1.0f, 1.0f, 1.0f});

  // Add octree cell wireframe
  void addOctreeCell(const vec3& position, float size, const vec4& color = {0.0f, 1.0f, 0.0f, 1.0f});

  // Clear all lines
  void clear();

  // Update uniform buffer and vertex buffer
  void prepare(const mat4& viewMatrix, const mat4& projMatrix);

  // Render all lines
  void draw(VkCommandBuffer commandBuffer);

private:
  void createPipeline();
  void createVertexBuffer();
  void createUniformBuffer();
  void setupDescriptors();
  void updateVertexBuffer();
};
