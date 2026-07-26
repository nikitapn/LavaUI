#include <pch.hpp>

#include <array>

#include "render/vulkan.hpp"
#include "render/shaders.hpp"
#include "render/line_renderer.hpp"

LineRenderer::LineRenderer() {
  vertices_.reserve(MAX_LINES * 2);
  lines_.reserve(MAX_LINES);
}

LineRenderer::~LineRenderer() {
  destroy();
}

void LineRenderer::initialize(Vulkan& vulkan) {
  vulkan_ = &vulkan;

  // Create vertex buffer for line data
  createVertexBuffer();
  createUniformBuffer();
  setupDescriptors();
  createPipeline();

  std::cout << "LineRenderer: Initialized\n";
}

void LineRenderer::destroy() {
  if (vulkan_) {
    if (vertexBuffer_ != VK_NULL_HANDLE) {
      vkDestroyBuffer(vulkan_->getDevice(), vertexBuffer_, nullptr);
      vertexBuffer_ = VK_NULL_HANDLE;
    }
    if (vertexBufferMemory_ != VK_NULL_HANDLE) {
      vkFreeMemory(vulkan_->getDevice(), vertexBufferMemory_, nullptr);
      vertexBufferMemory_ = VK_NULL_HANDLE;
    }
    vertexBufferSize_ = 0;

    if (uniformBuffer_ != VK_NULL_HANDLE) {
      vkDestroyBuffer(vulkan_->getDevice(), uniformBuffer_, nullptr);
      uniformBuffer_ = VK_NULL_HANDLE;
    }
    if (uniformBufferMemory_ != VK_NULL_HANDLE) {
      vkFreeMemory(vulkan_->getDevice(), uniformBufferMemory_, nullptr);
      uniformBufferMemory_ = VK_NULL_HANDLE;
    }
    pipeline_.destroy(*vulkan_);

    if (descriptorPool_) {
      vkDestroyDescriptorPool(vulkan_->getDevice(), descriptorPool_, nullptr);
      descriptorPool_ = VK_NULL_HANDLE;
    }
    if (descriptorSetLayout_) {
      vkDestroyDescriptorSetLayout(vulkan_->getDevice(), descriptorSetLayout_, nullptr);
      descriptorSetLayout_ = VK_NULL_HANDLE;
    }
    descriptorSet_ = VK_NULL_HANDLE;
  }

  clear();
  vulkan_ = nullptr;
}

void LineRenderer::addLine(const vec3& start, const vec3& end, const vec4& color) {
  if (lines_.size() >= MAX_LINES) return;

  lines_.push_back({start, end, color});
}

void LineRenderer::addBox(const vec3& center, const vec3& size, const vec4& color) {
  vec3 min = center - size * 0.5f;
  vec3 max = center + size * 0.5f;

  // Bottom face
  addLine({min.x, min.y, min.z}, {max.x, min.y, min.z}, color);
  addLine({max.x, min.y, min.z}, {max.x, min.y, max.z}, color);
  addLine({max.x, min.y, max.z}, {min.x, min.y, max.z}, color);
  addLine({min.x, min.y, max.z}, {min.x, min.y, min.z}, color);

  // Top face
  addLine({min.x, max.y, min.z}, {max.x, max.y, min.z}, color);
  addLine({max.x, max.y, min.z}, {max.x, max.y, max.z}, color);
  addLine({max.x, max.y, max.z}, {min.x, max.y, max.z}, color);
  addLine({min.x, max.y, max.z}, {min.x, max.y, min.z}, color);

  // Vertical edges
  addLine({min.x, min.y, min.z}, {min.x, max.y, min.z}, color);
  addLine({max.x, min.y, min.z}, {max.x, max.y, min.z}, color);
  addLine({max.x, min.y, max.z}, {max.x, max.y, max.z}, color);
  addLine({min.x, min.y, max.z}, {min.x, max.y, max.z}, color);
}

void LineRenderer::addOctreeCell(const vec3& position, float size, const vec4& color) {
  addBox(position + vec3(size * 0.5f), vec3(size), color);
}

void LineRenderer::clear() {
  lines_.clear();
  vertices_.clear();
}

void LineRenderer::prepare(const mat4& viewMatrix, const mat4& projMatrix) {
  if (lines_.empty()) return;

  // Update uniform buffer with view-projection matrix
  UniformData uniformData {
    .viewProjection = projMatrix * viewMatrix
  };

  void* mappedData;
  vkMapMemory(vulkan_->getDevice(), uniformBufferMemory_, 0, sizeof(UniformData), 0, &mappedData);
  memcpy(mappedData, &uniformData, sizeof(UniformData));
  vkUnmapMemory(vulkan_->getDevice(), uniformBufferMemory_);

  // Build vertex data from lines
  vertices_.clear();
  for (const auto& line : lines_) {
    vertices_.push_back({line.start, line.color});
    vertices_.push_back({line.end, line.color});
  }

  // Update vertex buffer
  updateVertexBuffer();
}

void LineRenderer::draw(VkCommandBuffer commandBuffer) {
  if (lines_.empty()) return;

  // Bind pipeline
  vkCmdBindPipeline(commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline_.pipeline);

  // Bind vertex buffer
  VkBuffer vertexBuffers[] = {vertexBuffer_};
  VkDeviceSize offsets[] = {0};
  vkCmdBindVertexBuffers(commandBuffer, 0, 1, vertexBuffers, offsets);

  // Bind descriptor set
  vkCmdBindDescriptorSets(commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS,
                         pipeline_.layout, 0, 1, &descriptorSet_, 0, nullptr);

  // Draw lines
  vkCmdDraw(commandBuffer, static_cast<uint32_t>(vertices_.size()), 1, 0, 0);
}

void LineRenderer::createVertexBuffer() {
  VkDeviceSize bufferSize = MAX_LINES * 2 * sizeof(LineVertex);

  vulkan_->createBuffer(bufferSize,
                       VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
                       VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                       vertexBuffer_,
                       vertexBufferMemory_);

  vertexBufferSize_ = bufferSize;
}

void LineRenderer::createUniformBuffer() {
  VkDeviceSize bufferSize = sizeof(UniformData);

  vulkan_->createBuffer(bufferSize,
                       VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
                       VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                       uniformBuffer_,
                       uniformBufferMemory_);
}

void LineRenderer::setupDescriptors() {
  // Create descriptor set layout
  VkDescriptorSetLayoutBinding uboLayoutBinding {
    .binding = 0,
    .descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
    .descriptorCount = 1,
    .stageFlags = VK_SHADER_STAGE_VERTEX_BIT
  };

  VkDescriptorSetLayoutCreateInfo layoutInfo {
    .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
    .bindingCount = 1,
    .pBindings = &uboLayoutBinding
  };

  VR(vkCreateDescriptorSetLayout(vulkan_->getDevice(), &layoutInfo, nullptr, &descriptorSetLayout_),
     "Failed to create descriptor set layout");

  // Create descriptor pool
  VkDescriptorPoolSize poolSize{};
  poolSize.type = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
  poolSize.descriptorCount = 1;

  VkDescriptorPoolCreateInfo poolInfo {
    .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
    .pNext = nullptr,
    .flags = 0,
    .maxSets = 1,
    .poolSizeCount = 1,
    .pPoolSizes = &poolSize,
  };

  VR(vkCreateDescriptorPool(vulkan_->getDevice(), &poolInfo, nullptr, &descriptorPool_),
     "Failed to create descriptor pool");

  // Allocate descriptor set
  VkDescriptorSetAllocateInfo allocInfo {
    .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
    .descriptorPool = descriptorPool_,
    .descriptorSetCount = 1,
    .pSetLayouts = &descriptorSetLayout_,
  };

  VR(vkAllocateDescriptorSets(vulkan_->getDevice(), &allocInfo, &descriptorSet_),
     "Failed to allocate descriptor set");

  // Update descriptor set
  VkDescriptorBufferInfo bufferInfo {
    .buffer = uniformBuffer_,
    .offset = 0,
    .range = sizeof(UniformData),
  };

  VkWriteDescriptorSet descriptorWrite {
    .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
    .pNext = nullptr,
    .dstSet = descriptorSet_,
    .dstBinding = 0,
    .dstArrayElement = 0,
    .descriptorCount = 1,
    .descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
    .pImageInfo = nullptr,
    .pBufferInfo = &bufferInfo,
    .pTexelBufferView = nullptr,
  };

  vkUpdateDescriptorSets(vulkan_->getDevice(), 1, &descriptorWrite, 0, nullptr);
}

void LineRenderer::createPipeline() {
  auto& shaders = vulkan_->getShaders();
  auto vertShader = shaders.loadShader("shaders/line.vert.bin");
  auto fragShader = shaders.loadShader("shaders/line.frag.bin");

  // Vertex input description
  VkVertexInputBindingDescription bindingDescription{};
  bindingDescription.binding = 0;
  bindingDescription.stride = sizeof(LineVertex);
  bindingDescription.inputRate = VK_VERTEX_INPUT_RATE_VERTEX;

  std::array<VkVertexInputAttributeDescription, 2> attributeDescriptions{};

  // Position attribute
  attributeDescriptions[0] = {
    .location = 0,
    .binding = 0,
    .format = VK_FORMAT_R32G32B32_SFLOAT,
    .offset = offsetof(LineVertex, position),
  };

  // Color attribute
  attributeDescriptions[1] = {
    .location = 1,
    .binding = 0,
    .format = VK_FORMAT_R32G32B32A32_SFLOAT,
    .offset = offsetof(LineVertex, color),
  };

  VkPipelineVertexInputStateCreateInfo vertexInputInfo {
    .sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
    .vertexBindingDescriptionCount = 1,
    .pVertexBindingDescriptions = &bindingDescription,
    .vertexAttributeDescriptionCount = static_cast<uint32_t>(attributeDescriptions.size()),
    .pVertexAttributeDescriptions = attributeDescriptions.data(),
  };

  // Pipeline layout
  VkPipelineLayoutCreateInfo pipelineLayoutInfo {
    .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
    .setLayoutCount = 1,
    .pSetLayouts = &descriptorSetLayout_,
    .pushConstantRangeCount = 0,
  };

  pipeline_ = PipelineBuilder()
    .setVertexShader(vertShader)
    .setFragmentShader(fragShader)
    .setPrimitiveTopology(VK_PRIMITIVE_TOPOLOGY_LINE_LIST, VK_FALSE)
    .setVertexInputState(vertexInputInfo)
    .setLayoutInfo(pipelineLayoutInfo)
    .build(*vulkan_, "line_pipeline");
}

void LineRenderer::updateVertexBuffer() {
  if (vertices_.empty()) return;

  VkDeviceSize dataSize = vertices_.size() * sizeof(LineVertex);
  assert(dataSize <= vertexBufferSize_);

  void* mappedData;
  vkMapMemory(vulkan_->getDevice(), vertexBufferMemory_, 0, dataSize, 0, &mappedData);
  memcpy(mappedData, vertices_.data(), dataSize);
  vkUnmapMemory(vulkan_->getDevice(), vertexBufferMemory_);
}
