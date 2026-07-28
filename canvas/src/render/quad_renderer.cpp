#include <pch.hpp>

#include <array>
#include <cmath>
#include <cstring>

#include "render/quad_renderer.hpp"
#include "render/shaders.hpp"
#include "render/vulkan.hpp"

namespace {

// Growth headroom so a frame that adds a few quads doesn't reallocate.
constexpr size_t kInitialVertexCapacity = 4096;  // 1024 quads

}  // namespace

// ─── Lifetime ──────────────────────────────────────────────────────────────

void QuadRenderer::init() {
  createWhiteTexture();
  setupDescriptors();
  createPipeline();
  ensureBufferCapacity(kInitialVertexCapacity);
}

void QuadRenderer::cleanUp() {
  VkDevice device = vulkan_.getDevice();

  if (vertexMapped_ != nullptr) {
    vkUnmapMemory(device, vertexBufferMemory_);
    vertexMapped_ = nullptr;
  }
  if (indexMapped_ != nullptr) {
    vkUnmapMemory(device, indexBufferMemory_);
    indexMapped_ = nullptr;
  }
  if (vertexBuffer_ != VK_NULL_HANDLE) {
    vkDestroyBuffer(device, vertexBuffer_, nullptr);
    vkFreeMemory(device, vertexBufferMemory_, nullptr);
    vertexBuffer_       = VK_NULL_HANDLE;
    vertexBufferMemory_ = VK_NULL_HANDLE;
  }
  if (indexBuffer_ != VK_NULL_HANDLE) {
    vkDestroyBuffer(device, indexBuffer_, nullptr);
    vkFreeMemory(device, indexBufferMemory_, nullptr);
    indexBuffer_       = VK_NULL_HANDLE;
    indexBufferMemory_ = VK_NULL_HANDLE;
  }

  if (whiteImageView_ != VK_NULL_HANDLE) {
    vkDestroyImageView(device, whiteImageView_, nullptr);
    whiteImageView_ = VK_NULL_HANDLE;
  }
  if (whiteImage_ != VK_NULL_HANDLE) {
    vkDestroyImage(device, whiteImage_, nullptr);
    vkFreeMemory(device, whiteImageMemory_, nullptr);
    whiteImage_       = VK_NULL_HANDLE;
    whiteImageMemory_ = VK_NULL_HANDLE;
  }
  if (sampler_ != VK_NULL_HANDLE) {
    vkDestroySampler(device, sampler_, nullptr);
    sampler_ = VK_NULL_HANDLE;
  }

  pipeline_.destroy(device);
  pipelineLayout_.destroy(device);
  descriptorPool_.destroy(device);
  descriptorSetLayout_.destroy(device);
}

// ─── Setup ─────────────────────────────────────────────────────────────────

void QuadRenderer::createWhiteTexture() {
  VkDevice device = vulkan_.getDevice();

  vulkan_.createImage(1, 1, 1, VK_SAMPLE_COUNT_1_BIT, VK_FORMAT_R8_UNORM,
                      VK_IMAGE_TILING_OPTIMAL,
                      VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT,
                      VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT, whiteImage_,
                      whiteImageMemory_);

  const uint8_t white = 0xff;
  VkBuffer       staging{};
  VkDeviceMemory stagingMemory{};
  vulkan_.createBuffer(sizeof(white), VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
                       VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT |
                         VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                       staging, stagingMemory);

  void *mapped = nullptr;
  vkMapMemory(device, stagingMemory, 0, sizeof(white), 0, &mapped);
  std::memcpy(mapped, &white, sizeof(white));
  vkUnmapMemory(device, stagingMemory);

  vulkan_.transitionImageLayout(whiteImage_, VK_FORMAT_R8_UNORM,
                                VK_IMAGE_LAYOUT_UNDEFINED,
                                VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL);
  vulkan_.copyBufferToImage(staging, whiteImage_, 1, 1);
  vulkan_.transitionImageLayout(whiteImage_, VK_FORMAT_R8_UNORM,
                                VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                                VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL);

  vkDestroyBuffer(device, staging, nullptr);
  vkFreeMemory(device, stagingMemory, nullptr);

  whiteImageView_ =
    vulkan_.createImageView(whiteImage_, VK_FORMAT_R8_UNORM,
                            VK_IMAGE_ASPECT_COLOR_BIT, 1);
  sampler_ = vulkan_.createTextureSampler();
}

void QuadRenderer::setupDescriptors() {
  VkDevice device = vulkan_.getDevice();

  VkDescriptorSetLayoutBinding samplerBinding{
    .binding         = 0,
    .descriptorType  = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
    .descriptorCount = 1,
    .stageFlags      = VK_SHADER_STAGE_FRAGMENT_BIT,
  };

  VkDescriptorSetLayoutCreateInfo layoutInfo{
    .sType        = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
    .bindingCount = 1,
    .pBindings    = &samplerBinding,
  };
  VR(vkCreateDescriptorSetLayout(device, &layoutInfo, nullptr,
                                 &descriptorSetLayout_),
     "Failed to create quad descriptor set layout");

  VkDescriptorPoolSize poolSize{
    .type            = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
    .descriptorCount = 1,
  };
  VkDescriptorPoolCreateInfo poolInfo{
    .sType         = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
    .maxSets       = 1,
    .poolSizeCount = 1,
    .pPoolSizes    = &poolSize,
  };
  VR(vkCreateDescriptorPool(device, &poolInfo, nullptr, &descriptorPool_),
     "Failed to create quad descriptor pool");

  VkDescriptorSetLayout    setLayout = descriptorSetLayout_;
  VkDescriptorSetAllocateInfo allocInfo{
    .sType              = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
    .descriptorPool     = descriptorPool_,
    .descriptorSetCount = 1,
    .pSetLayouts        = &setLayout,
  };
  VR(vkAllocateDescriptorSets(device, &allocInfo, &descriptorSet_),
     "Failed to allocate quad descriptor set");

  setAtlas(whiteImageView_, sampler_);
}

void QuadRenderer::setAtlas(VkImageView view, VkSampler sampler) {
  VkDescriptorImageInfo imageInfo{
    .sampler     = sampler,
    .imageView   = view,
    .imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
  };
  VkWriteDescriptorSet write{
    .sType           = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
    .dstSet          = descriptorSet_,
    .dstBinding      = 0,
    .descriptorCount = 1,
    .descriptorType  = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
    .pImageInfo      = &imageInfo,
  };
  vkUpdateDescriptorSets(vulkan_.getDevice(), 1, &write, 0, nullptr);
}

void QuadRenderer::createPipeline() {
  VkDevice device = vulkan_.getDevice();
  Shaders &shaders = vulkan_.getShaders();

  VkShaderModule vertModule = shaders.loadShader("shaders/quad.vert.bin");
  VkShaderModule fragModule = shaders.loadShader("shaders/quad.frag.bin");

  std::array<VkPipelineShaderStageCreateInfo, 2> stages{
    VkPipelineShaderStageCreateInfo{
      .sType  = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
      .stage  = VK_SHADER_STAGE_VERTEX_BIT,
      .module = vertModule,
      .pName  = "main",
    },
    VkPipelineShaderStageCreateInfo{
      .sType  = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
      .stage  = VK_SHADER_STAGE_FRAGMENT_BIT,
      .module = fragModule,
      .pName  = "main",
    },
  };

  VkVertexInputBindingDescription binding{
    .binding   = 0,
    .stride    = sizeof(Vertex),
    .inputRate = VK_VERTEX_INPUT_RATE_VERTEX,
  };

  // RGBA8 is fetched as R8G8B8A8_UNORM so the shader receives a normalised
  // vec4 without any unpack maths.
  std::array<VkVertexInputAttributeDescription, 6> attributes{
    VkVertexInputAttributeDescription{0, 0, VK_FORMAT_R32G32_SFLOAT,
                                      offsetof(Vertex, pos)},
    VkVertexInputAttributeDescription{1, 0, VK_FORMAT_R32G32_SFLOAT,
                                      offsetof(Vertex, local)},
    VkVertexInputAttributeDescription{2, 0, VK_FORMAT_R32G32_SFLOAT,
                                      offsetof(Vertex, halfSize)},
    VkVertexInputAttributeDescription{3, 0, VK_FORMAT_R32_SFLOAT,
                                      offsetof(Vertex, radius)},
    VkVertexInputAttributeDescription{4, 0, VK_FORMAT_R8G8B8A8_UNORM,
                                      offsetof(Vertex, color)},
    VkVertexInputAttributeDescription{5, 0, VK_FORMAT_R32_UINT,
                                      offsetof(Vertex, kind)},
  };

  VkPipelineVertexInputStateCreateInfo vertexInput{
    .sType                           = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
    .vertexBindingDescriptionCount   = 1,
    .pVertexBindingDescriptions      = &binding,
    .vertexAttributeDescriptionCount = static_cast<uint32_t>(attributes.size()),
    .pVertexAttributeDescriptions    = attributes.data(),
  };

  VkPipelineInputAssemblyStateCreateInfo inputAssembly{
    .sType    = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
    .topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
  };

  VkPipelineViewportStateCreateInfo viewportState{
    .sType         = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
    .viewportCount = 1,
    .scissorCount  = 1,
  };

  VkPipelineRasterizationStateCreateInfo rasterizer{
    .sType       = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
    .polygonMode = VK_POLYGON_MODE_FILL,
    // Culling off: line quads are emitted rotated, so winding depends on the
    // segment direction and would otherwise drop half of them.
    .cullMode    = VK_CULL_MODE_NONE,
    .frontFace   = VK_FRONT_FACE_COUNTER_CLOCKWISE,
    .lineWidth   = 1.0f,
  };

  VkPipelineMultisampleStateCreateInfo multisampling{
    .sType                = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
    .rasterizationSamples = vulkan_.getMSAASamples(),
  };

  VkPipelineColorBlendAttachmentState blendAttachment{
    .blendEnable         = VK_TRUE,
    .srcColorBlendFactor = VK_BLEND_FACTOR_SRC_ALPHA,
    .dstColorBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
    .colorBlendOp        = VK_BLEND_OP_ADD,
    .srcAlphaBlendFactor = VK_BLEND_FACTOR_ONE,
    .dstAlphaBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
    .alphaBlendOp        = VK_BLEND_OP_ADD,
    .colorWriteMask      = VK_COLOR_COMPONENT_R_BIT | VK_COLOR_COMPONENT_G_BIT |
                           VK_COLOR_COMPONENT_B_BIT | VK_COLOR_COMPONENT_A_BIT,
  };

  VkPipelineColorBlendStateCreateInfo colorBlending{
    .sType           = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
    .attachmentCount = 1,
    .pAttachments    = &blendAttachment,
  };

  std::array<VkDynamicState, 2> dynamicStates{VK_DYNAMIC_STATE_VIEWPORT,
                                              VK_DYNAMIC_STATE_SCISSOR};
  VkPipelineDynamicStateCreateInfo dynamicState{
    .sType             = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
    .dynamicStateCount = static_cast<uint32_t>(dynamicStates.size()),
    .pDynamicStates    = dynamicStates.data(),
  };

  VkPushConstantRange pushRange{
    .stageFlags = VK_SHADER_STAGE_VERTEX_BIT,
    .offset     = 0,
    .size       = sizeof(vec2),
  };

  VkDescriptorSetLayout    setLayout = descriptorSetLayout_;
  VkPipelineLayoutCreateInfo layoutInfo{
    .sType                  = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
    .setLayoutCount         = 1,
    .pSetLayouts            = &setLayout,
    .pushConstantRangeCount = 1,
    .pPushConstantRanges    = &pushRange,
  };
  VR(vkCreatePipelineLayout(device, &layoutInfo, nullptr, &pipelineLayout_),
     "Failed to create quad pipeline layout");

  VkGraphicsPipelineCreateInfo pipelineInfo{
    .sType               = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
    .stageCount          = static_cast<uint32_t>(stages.size()),
    .pStages             = stages.data(),
    .pVertexInputState   = &vertexInput,
    .pInputAssemblyState = &inputAssembly,
    .pViewportState      = &viewportState,
    .pRasterizationState = &rasterizer,
    .pMultisampleState   = &multisampling,
    .pColorBlendState    = &colorBlending,
    .pDynamicState       = &dynamicState,
    .layout              = pipelineLayout_,
    .renderPass          = vulkan_.getRenderPass(),
    .subpass             = 0,
  };
  VR(vkCreateGraphicsPipelines(device, VK_NULL_HANDLE, 1, &pipelineInfo, nullptr,
                               &pipeline_),
     "Failed to create quad pipeline");
}

void QuadRenderer::ensureBufferCapacity(size_t vertexCount) {
  if (vertexCount <= bufferCapacity_) {
    return;
  }

  VkDevice device = vulkan_.getDevice();
  vkDeviceWaitIdle(device);

  size_t newCapacity = bufferCapacity_ == 0 ? kInitialVertexCapacity : bufferCapacity_;
  while (newCapacity < vertexCount) {
    newCapacity *= 2;
  }

  if (vertexMapped_ != nullptr) {
    vkUnmapMemory(device, vertexBufferMemory_);
    vkDestroyBuffer(device, vertexBuffer_, nullptr);
    vkFreeMemory(device, vertexBufferMemory_, nullptr);
  }
  if (indexMapped_ != nullptr) {
    vkUnmapMemory(device, indexBufferMemory_);
    vkDestroyBuffer(device, indexBuffer_, nullptr);
    vkFreeMemory(device, indexBufferMemory_, nullptr);
  }

  const VkDeviceSize vertexBytes = newCapacity * sizeof(Vertex);
  // 6 indices per 4 vertices.
  const VkDeviceSize indexBytes = (newCapacity / 4) * 6 * sizeof(uint32_t);

  vulkan_.createBuffer(vertexBytes, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
                       VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT |
                         VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                       vertexBuffer_, vertexBufferMemory_);
  vulkan_.createBuffer(indexBytes, VK_BUFFER_USAGE_INDEX_BUFFER_BIT,
                       VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT |
                         VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                       indexBuffer_, indexBufferMemory_);

  vkMapMemory(device, vertexBufferMemory_, 0, vertexBytes, 0, &vertexMapped_);
  vkMapMemory(device, indexBufferMemory_, 0, indexBytes, 0, &indexMapped_);

  bufferCapacity_ = newCapacity;
}

// ─── Frame recording ───────────────────────────────────────────────────────

void QuadRenderer::begin(vec2 viewportSize) {
  viewportSize_ = viewportSize;
  vertices_.clear();
  indices_.clear();
  batches_.clear();
  scissorStack_.clear();
  batchStartIndex_ = 0;
  currentScissor_  = VkRect2D{
    {0, 0},
    {static_cast<uint32_t>(viewportSize.x), static_cast<uint32_t>(viewportSize.y)},
  };
}

void QuadRenderer::appendQuad(const vec2 corners[4], const vec2 locals[4],
                              vec2 halfSize, float radius, uint32_t rgba,
                              Kind kind) {
  const uint32_t base = static_cast<uint32_t>(vertices_.size());
  for (int i = 0; i < 4; ++i) {
    vertices_.push_back(Vertex{
      .pos      = corners[i],
      .local    = locals[i],
      .halfSize = halfSize,
      .radius   = radius,
      .color    = rgba,
      .kind     = static_cast<uint32_t>(kind),
    });
  }
  // 0-1-2, 0-2-3
  indices_.push_back(base + 0);
  indices_.push_back(base + 1);
  indices_.push_back(base + 2);
  indices_.push_back(base + 0);
  indices_.push_back(base + 2);
  indices_.push_back(base + 3);
}

void QuadRenderer::pushBox(vec2 topLeft, vec2 size, uint32_t rgba, float radius) {
  if (size.x <= 0.0f || size.y <= 0.0f) {
    return;
  }
  // One pixel of bleed so the SDF has room to antialias the outer edge instead
  // of it being clipped by the quad boundary.
  constexpr float kPad = 1.0f;

  const vec2 half{size.x * 0.5f, size.y * 0.5f};
  const vec2 center{topLeft.x + half.x, topLeft.y + half.y};
  const vec2 ext{half.x + kPad, half.y + kPad};
  const float r = std::min(radius, std::min(half.x, half.y));

  const vec2 corners[4] = {
    {center.x - ext.x, center.y - ext.y},
    {center.x + ext.x, center.y - ext.y},
    {center.x + ext.x, center.y + ext.y},
    {center.x - ext.x, center.y + ext.y},
  };
  const vec2 locals[4] = {
    {-ext.x, -ext.y}, {ext.x, -ext.y}, {ext.x, ext.y}, {-ext.x, ext.y},
  };
  appendQuad(corners, locals, half, r, rgba, Kind::Sdf);
}

void QuadRenderer::pushCircle(vec2 center, float radius, uint32_t rgba) {
  pushBox({center.x - radius, center.y - radius}, {radius * 2.0f, radius * 2.0f},
          rgba, radius);
}

void QuadRenderer::pushLine(vec2 p0, vec2 p1, float width, uint32_t rgba) {
  const float dx  = p1.x - p0.x;
  const float dy  = p1.y - p0.y;
  const float len = std::sqrt(dx * dx + dy * dy);
  if (len <= 0.0001f) {
    return;
  }

  // A stroked segment with round caps is a capsule, which is a rounded box in
  // the segment's local frame — so this reuses the SDF path with no shader
  // special case. Rotation is baked here to keep the vertex shader a
  // pass-through.
  const float halfW  = width * 0.5f;
  const float halfL  = len * 0.5f;
  constexpr float kPad = 1.0f;
  const float extL   = halfL + halfW + kPad;
  const float extW   = halfW + kPad;

  const vec2 dir{dx / len, dy / len};
  const vec2 nrm{-dir.y, dir.x};
  const vec2 center{(p0.x + p1.x) * 0.5f, (p0.y + p1.y) * 0.5f};

  const vec2 corners[4] = {
    {center.x - dir.x * extL - nrm.x * extW, center.y - dir.y * extL - nrm.y * extW},
    {center.x + dir.x * extL - nrm.x * extW, center.y + dir.y * extL - nrm.y * extW},
    {center.x + dir.x * extL + nrm.x * extW, center.y + dir.y * extL + nrm.y * extW},
    {center.x - dir.x * extL + nrm.x * extW, center.y - dir.y * extL + nrm.y * extW},
  };
  const vec2 locals[4] = {
    {-extL, -extW}, {extL, -extW}, {extL, extW}, {-extL, extW},
  };
  // halfSize spans the segment body; radius == halfW rounds the caps.
  appendQuad(corners, locals, {halfL, halfW}, halfW, rgba, Kind::Sdf);
}

void QuadRenderer::pushGlyph(vec2 topLeft, vec2 size, vec2 uv0, vec2 uv1,
                             uint32_t rgba) {
  if (size.x <= 0.0f || size.y <= 0.0f) {
    return;
  }
  const vec2 corners[4] = {
    {topLeft.x, topLeft.y},
    {topLeft.x + size.x, topLeft.y},
    {topLeft.x + size.x, topLeft.y + size.y},
    {topLeft.x, topLeft.y + size.y},
  };
  // `local` carries atlas UV for the glyph path.
  const vec2 locals[4] = {
    {uv0.x, uv0.y}, {uv1.x, uv0.y}, {uv1.x, uv1.y}, {uv0.x, uv1.y},
  };
  appendQuad(corners, locals, {0.0f, 0.0f}, 0.0f, rgba, Kind::Glyph);
}

void QuadRenderer::flushBatch() {
  const uint32_t end = static_cast<uint32_t>(indices_.size());
  if (end > batchStartIndex_) {
    batches_.push_back(Batch{
      .firstIndex = batchStartIndex_,
      .indexCount = end - batchStartIndex_,
      .scissor    = currentScissor_,
    });
  }
  batchStartIndex_ = end;
}

void QuadRenderer::pushScissor(vec2 topLeft, vec2 size) {
  flushBatch();
  scissorStack_.push_back(currentScissor_);

  if (size.x <= 0.0f || size.y <= 0.0f) {
    currentScissor_ = VkRect2D{{0, 0},
                               {static_cast<uint32_t>(viewportSize_.x),
                                static_cast<uint32_t>(viewportSize_.y)}};
    return;
  }

  // Intersect with the enclosing rect so nested clips behave.
  const int32_t x0 = std::max(static_cast<int32_t>(topLeft.x), currentScissor_.offset.x);
  const int32_t y0 = std::max(static_cast<int32_t>(topLeft.y), currentScissor_.offset.y);
  const int32_t x1 = std::min(static_cast<int32_t>(topLeft.x + size.x),
                              currentScissor_.offset.x +
                                static_cast<int32_t>(currentScissor_.extent.width));
  const int32_t y1 = std::min(static_cast<int32_t>(topLeft.y + size.y),
                              currentScissor_.offset.y +
                                static_cast<int32_t>(currentScissor_.extent.height));

  currentScissor_ = VkRect2D{
    {x0, y0},
    {static_cast<uint32_t>(std::max(x1 - x0, 0)),
     static_cast<uint32_t>(std::max(y1 - y0, 0))},
  };
}

void QuadRenderer::popScissor() {
  flushBatch();
  if (!scissorStack_.empty()) {
    currentScissor_ = scissorStack_.back();
    scissorStack_.pop_back();
  }
}

void QuadRenderer::end() {
  flushBatch();

  if (vertices_.empty()) {
    return;
  }
  ensureBufferCapacity(vertices_.size());

  std::memcpy(vertexMapped_, vertices_.data(), vertices_.size() * sizeof(Vertex));
  std::memcpy(indexMapped_, indices_.data(), indices_.size() * sizeof(uint32_t));
}

void QuadRenderer::draw(VkCommandBuffer commandBuffer) {
  if (batches_.empty() || vertices_.empty()) {
    return;
  }

  vkCmdBindPipeline(commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline_);
  vkCmdBindDescriptorSets(commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS,
                          pipelineLayout_, 0, 1, &descriptorSet_, 0, nullptr);
  vkCmdPushConstants(commandBuffer, pipelineLayout_, VK_SHADER_STAGE_VERTEX_BIT,
                     0, sizeof(vec2), &viewportSize_);

  VkViewport viewport{
    .x = 0.0f, .y = 0.0f,
    .width = viewportSize_.x, .height = viewportSize_.y,
    .minDepth = 0.0f, .maxDepth = 1.0f,
  };
  vkCmdSetViewport(commandBuffer, 0, 1, &viewport);

  VkDeviceSize offset = 0;
  VkBuffer     vb     = vertexBuffer_;
  vkCmdBindVertexBuffers(commandBuffer, 0, 1, &vb, &offset);
  vkCmdBindIndexBuffer(commandBuffer, indexBuffer_, 0, VK_INDEX_TYPE_UINT32);

  for (const auto &batch : batches_) {
    if (batch.scissor.extent.width == 0 || batch.scissor.extent.height == 0) {
      continue;  // fully clipped away
    }
    vkCmdSetScissor(commandBuffer, 0, 1, &batch.scissor);
    vkCmdDrawIndexed(commandBuffer, batch.indexCount, 1, batch.firstIndex, 0, 0);
  }
}
