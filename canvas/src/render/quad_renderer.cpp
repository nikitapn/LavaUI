#include <array>
#include <cmath>
#include <cstring>
#include <iostream>
#include <mutex>

#include "render/quad_renderer.hpp"
#include "render/shaders.hpp"
#include "render/render_device.hpp"
#include "render/render_window.hpp"

namespace {

// Growth headroom so a frame that adds a few quads doesn't reallocate.
constexpr size_t kInitialVertexCapacity = 4096;  // 1024 quads

}  // namespace

// ─── Lifetime ──────────────────────────────────────────────────────────────

void QuadRenderer::init() {
  createWhiteTexture();
  setupDescriptors();
  createPipelineLayout();
  createPipeline(device_.getRenderPass(), device_.getMSAASamples(), pipeline_);
  // Same shaders, same geometry, opposite job: this one multiplies what is
  // already in the target by the shape's coverage instead of drawing over it.
  // See `Blend::Mask` and `pushCornerMask`.
  createPipeline(device_.getRenderPass(), device_.getMSAASamples(),
                 maskPipeline_, Blend::Mask);
  createLinePipeline(device_.getRenderPass(), device_.getMSAASamples(),
                     linePipeline_);
  createSpatialPipeline(device_.getRenderPass(), device_.getMSAASamples(),
                        spatialPipeline_, true);
  ensureBufferCapacity(kInitialVertexCapacity, (kInitialVertexCapacity / 4) * 6);
}

void QuadRenderer::destroyFrameBuffers(FrameResources &fr) {
  if (fr.vertexMapped != nullptr) {
    if (fr.vertexAlloc != VK_NULL_HANDLE) device_.unmapBuffer(fr.vertexAlloc);
    fr.vertexMapped = nullptr;
  }
  if (fr.indexMapped != nullptr) {
    if (fr.indexAlloc != VK_NULL_HANDLE) device_.unmapBuffer(fr.indexAlloc);
    fr.indexMapped = nullptr;
  }
  device_.destroyBuffer(fr.vertexBuffer, fr.vertexAlloc);
  device_.destroyBuffer(fr.indexBuffer, fr.indexAlloc);
  fr.capacity = 0;
  fr.indexCapacity = 0;
}

void QuadRenderer::cleanUp() {
  VkDevice device = device_.getDevice();

  for (auto &fr : frames_) {
    destroyFrameBuffers(fr);
    fr.descriptorSets.clear();
  }

  if (whiteImageView_ != VK_NULL_HANDLE) {
    vkDestroyImageView(device, whiteImageView_, nullptr);
    whiteImageView_ = VK_NULL_HANDLE;
  }
  device_.destroyImage(whiteImage_, whiteImageAlloc_);
  if (sampler_ != VK_NULL_HANDLE) {
    vkDestroySampler(device, sampler_, nullptr);
    sampler_ = VK_NULL_HANDLE;
  }

  pipeline_.destroy(device);
  maskPipeline_.destroy(device);
  pipelineScene_.destroy(device);
  linePipeline_.destroy(device);
  linePipelineScene_.destroy(device);
  spatialPipeline_.destroy(device);
  spatialPipelineScene_.destroy(device);
  pipelineLayout_.destroy(device);
  for (auto &pool : extraDescriptorPools_) {
    pool.destroy(device);
  }
  extraDescriptorPools_.clear();
  descriptorPool_.destroy(device);
  descriptorSetLayout_.destroy(device);
}

QuadRenderer::FrameResources &QuadRenderer::activeFrame() {
  return frames_[activeFrameSlot_];
}

// ─── Setup ─────────────────────────────────────────────────────────────────

void QuadRenderer::createWhiteTexture() {
  device_.createImage(1, 1, 1, VK_SAMPLE_COUNT_1_BIT, VK_FORMAT_R8_UNORM,
                      VK_IMAGE_TILING_OPTIMAL,
                      VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT,
                      VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT, whiteImage_,
                      whiteImageAlloc_);

  const uint8_t white = 0xff;
  VkBuffer      staging{};
  VmaAllocation stagingAlloc{};
  device_.createBuffer(sizeof(white), VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
                       VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT |
                         VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                       staging, stagingAlloc);

  void *mapped = device_.mapBuffer(stagingAlloc);
  std::memcpy(mapped, &white, sizeof(white));
  device_.unmapBuffer(stagingAlloc);

  device_.transitionImageLayout(whiteImage_, VK_FORMAT_R8_UNORM,
                                VK_IMAGE_LAYOUT_UNDEFINED,
                                VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL);
  device_.copyBufferToImage(staging, whiteImage_, 1, 1);
  device_.transitionImageLayout(whiteImage_, VK_FORMAT_R8_UNORM,
                                VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                                VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL);

  device_.destroyBuffer(staging, stagingAlloc);

  whiteImageView_ =
    device_.createImageView(whiteImage_, VK_FORMAT_R8_UNORM,
                            VK_IMAGE_ASPECT_COLOR_BIT, 1);
  sampler_ = device_.createTextureSampler();
}

bool QuadRenderer::growDescriptorSets(FrameResources &fr)
{
  if (extraDescriptorPools_.size() >= kMaxDescriptorChunks) return false;

  VkDevice device = device_.getDevice();
  VkDescriptorPoolSize poolSize{
    .type            = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
    .descriptorCount = kDescriptorSetsPerChunk,
  };
  VkDescriptorPoolCreateInfo poolInfo{
    .sType         = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
    .maxSets       = kDescriptorSetsPerChunk,
    .poolSizeCount = 1,
    .pPoolSizes    = &poolSize,
  };
  VkDescriptorPool pool = VK_NULL_HANDLE;
  if (vkCreateDescriptorPool(device, &poolInfo, nullptr, &pool) != VK_SUCCESS) {
    return false;
  }

  std::vector<VkDescriptorSetLayout> layouts(kDescriptorSetsPerChunk,
                                             descriptorSetLayout_);
  std::vector<VkDescriptorSet> sets(kDescriptorSetsPerChunk, VK_NULL_HANDLE);
  VkDescriptorSetAllocateInfo allocInfo{
    .sType              = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
    .descriptorPool     = pool,
    .descriptorSetCount = kDescriptorSetsPerChunk,
    .pSetLayouts        = layouts.data(),
  };
  if (vkAllocateDescriptorSets(device, &allocInfo, sets.data()) != VK_SUCCESS) {
    vkDestroyDescriptorPool(device, pool, nullptr);
    return false;
  }

  // The pool outlives every frame that will bind out of it: it is released in
  // cleanUp with the rest, never per frame, so a set handed out here stays
  // valid for as long as any recorded command buffer can reference it.
  extraDescriptorPools_.emplace_back();
  extraDescriptorPools_.back() = pool;
  fr.descriptorSets.insert(fr.descriptorSets.end(), sets.begin(), sets.end());
  return true;
}

void QuadRenderer::setupDescriptors() {
  VkDevice device = device_.getDevice();

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

  const uint32_t totalSets = kMaxFramesInFlight * kDescriptorSetsPerChunk;
  VkDescriptorPoolSize poolSize{
    .type            = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
    .descriptorCount = totalSets,
  };
  VkDescriptorPoolCreateInfo poolInfo{
    .sType         = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
    .maxSets       = totalSets,
    .poolSizeCount = 1,
    .pPoolSizes    = &poolSize,
  };
  VR(vkCreateDescriptorPool(device, &poolInfo, nullptr, &descriptorPool_),
     "Failed to create quad descriptor pool");

  // One ring of sets per frame slot so in-flight frames never rewrite each
  // other's descriptors.
  for (uint32_t f = 0; f < kMaxFramesInFlight; ++f) {
    auto &fr = frames_[f];
    fr.descriptorSets.resize(kDescriptorSetsPerChunk);
    std::vector<VkDescriptorSetLayout> layouts(kDescriptorSetsPerChunk,
                                               descriptorSetLayout_);
    VkDescriptorSetAllocateInfo allocInfo{
      .sType              = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
      .descriptorPool     = descriptorPool_,
      .descriptorSetCount = kDescriptorSetsPerChunk,
      .pSetLayouts        = layouts.data(),
    };
    VR(vkAllocateDescriptorSets(device, &allocInfo, fr.descriptorSets.data()),
       "Failed to allocate quad descriptor sets");
    fr.descriptorWriteIndex = 0;
  }

  setAtlas(whiteImageView_, sampler_);
}

void QuadRenderer::setAtlas(VkImageView view, VkSampler sampler) {
  glyphAtlasView_    = view;
  glyphAtlasSampler_ = sampler != VK_NULL_HANDLE ? sampler : sampler_;
  currentBatchTexture_ = glyphAtlasView_;
}

void QuadRenderer::createSceneTargetPipeline(VkRenderPass sceneRenderPass) {
  if (sceneRenderPass == VK_NULL_HANDLE) return;
  // Single sample: the result is about to be blurred, so MSAA would only buy a
  // resolve attachment and the coverage it recovers is gone a pass later.
  createPipeline(sceneRenderPass, VK_SAMPLE_COUNT_1_BIT, pipelineScene_);
  createLinePipeline(sceneRenderPass, VK_SAMPLE_COUNT_1_BIT,
                     linePipelineScene_);
  createSpatialPipeline(sceneRenderPass, VK_SAMPLE_COUNT_1_BIT,
                        spatialPipelineScene_, false);
}

void QuadRenderer::createLinePipeline(VkRenderPass renderPass,
                                      VkSampleCountFlagBits samples,
                                      vk::Handle<VkPipeline> &out) {
  VkDevice device = device_.getDevice();
  Shaders &shaders = device_.getShaders();
  VkShaderModule vertModule = shaders.loadShader("shaders/polyline.vert.bin");
  VkShaderModule fragModule = shaders.loadShader("shaders/polyline.frag.bin");
  std::array<VkPipelineShaderStageCreateInfo, 2> stages{
    VkPipelineShaderStageCreateInfo{.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
      .stage = VK_SHADER_STAGE_VERTEX_BIT, .module = vertModule, .pName = "main"},
    VkPipelineShaderStageCreateInfo{.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
      .stage = VK_SHADER_STAGE_FRAGMENT_BIT, .module = fragModule, .pName = "main"},
  };
  VkVertexInputBindingDescription binding{.binding = 0, .stride = sizeof(Vertex),
                                           .inputRate = VK_VERTEX_INPUT_RATE_VERTEX};
  std::array<VkVertexInputAttributeDescription, 2> attributes{
    VkVertexInputAttributeDescription{0, 0, VK_FORMAT_R32G32_SFLOAT, offsetof(Vertex, pos)},
    VkVertexInputAttributeDescription{1, 0, VK_FORMAT_R8G8B8A8_UNORM, offsetof(Vertex, color)},
  };
  VkPipelineVertexInputStateCreateInfo vertexInput{
    .sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
    .vertexBindingDescriptionCount = 1, .pVertexBindingDescriptions = &binding,
    .vertexAttributeDescriptionCount = static_cast<uint32_t>(attributes.size()),
    .pVertexAttributeDescriptions = attributes.data()};
  VkPipelineInputAssemblyStateCreateInfo inputAssembly{
    .sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
    .topology = VK_PRIMITIVE_TOPOLOGY_LINE_STRIP,
    .primitiveRestartEnable = VK_FALSE};
  VkPipelineViewportStateCreateInfo viewportState{
    .sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
    .viewportCount = 1, .scissorCount = 1};
  VkPipelineRasterizationStateCreateInfo rasterizer{
    .sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
    .polygonMode = VK_POLYGON_MODE_FILL, .cullMode = VK_CULL_MODE_NONE,
    .frontFace = VK_FRONT_FACE_COUNTER_CLOCKWISE, .lineWidth = 1.0f};
  VkPipelineMultisampleStateCreateInfo multisampling{
    .sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
    .rasterizationSamples = samples};
  VkPipelineDepthStencilStateCreateInfo depthStencil{
    .sType = VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
    .depthTestEnable = VK_FALSE, .depthWriteEnable = VK_FALSE,
    .depthCompareOp = VK_COMPARE_OP_ALWAYS};
  VkPipelineColorBlendAttachmentState blendAttachment{
    .blendEnable = VK_TRUE, .srcColorBlendFactor = VK_BLEND_FACTOR_ONE,
    .dstColorBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
    .colorBlendOp = VK_BLEND_OP_ADD, .srcAlphaBlendFactor = VK_BLEND_FACTOR_ONE,
    .dstAlphaBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
    .alphaBlendOp = VK_BLEND_OP_ADD,
    .colorWriteMask = VK_COLOR_COMPONENT_R_BIT | VK_COLOR_COMPONENT_G_BIT |
                      VK_COLOR_COMPONENT_B_BIT | VK_COLOR_COMPONENT_A_BIT};
  VkPipelineColorBlendStateCreateInfo colorBlending{
    .sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
    .attachmentCount = 1, .pAttachments = &blendAttachment};
  std::array<VkDynamicState, 2> dynamicStates{VK_DYNAMIC_STATE_VIEWPORT,
                                              VK_DYNAMIC_STATE_SCISSOR};
  VkPipelineDynamicStateCreateInfo dynamicState{
    .sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
    .dynamicStateCount = static_cast<uint32_t>(dynamicStates.size()),
    .pDynamicStates = dynamicStates.data()};
  VkGraphicsPipelineCreateInfo info{
    .sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
    .stageCount = static_cast<uint32_t>(stages.size()), .pStages = stages.data(),
    .pVertexInputState = &vertexInput, .pInputAssemblyState = &inputAssembly,
    .pViewportState = &viewportState, .pRasterizationState = &rasterizer,
    .pMultisampleState = &multisampling, .pDepthStencilState = &depthStencil,
    .pColorBlendState = &colorBlending, .pDynamicState = &dynamicState,
    .layout = pipelineLayout_, .renderPass = renderPass, .subpass = 0};
  VR(vkCreateGraphicsPipelines(device, VK_NULL_HANDLE, 1, &info, nullptr, &out),
     "Failed to create polyline pipeline");
}

void QuadRenderer::createSpatialPipeline(VkRenderPass renderPass,
                                         VkSampleCountFlagBits samples,
                                         vk::Handle<VkPipeline> &out,
                                         bool depthEnabled) {
  VkDevice device = device_.getDevice();
  Shaders &shaders = device_.getShaders();
  VkShaderModule vert = shaders.loadShader("shaders/spatial.vert.bin");
  VkShaderModule frag = shaders.loadShader("shaders/spatial.frag.bin");
  std::array<VkPipelineShaderStageCreateInfo, 2> stages{
    VkPipelineShaderStageCreateInfo{.sType=VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
      .stage=VK_SHADER_STAGE_VERTEX_BIT,.module=vert,.pName="main"},
    VkPipelineShaderStageCreateInfo{.sType=VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
      .stage=VK_SHADER_STAGE_FRAGMENT_BIT,.module=frag,.pName="main"}};
  VkVertexInputBindingDescription binding{0, sizeof(Vertex), VK_VERTEX_INPUT_RATE_VERTEX};
  std::array<VkVertexInputAttributeDescription, 4> attrs{
    VkVertexInputAttributeDescription{0,0,VK_FORMAT_R32G32_SFLOAT,offsetof(Vertex,pos)},
    VkVertexInputAttributeDescription{1,0,VK_FORMAT_R32G32_SFLOAT,offsetof(Vertex,local)},
    VkVertexInputAttributeDescription{2,0,VK_FORMAT_R8G8B8A8_UNORM,offsetof(Vertex,color)},
    VkVertexInputAttributeDescription{3,0,VK_FORMAT_R32G32_SFLOAT,offsetof(Vertex,halfSize)}};
  VkPipelineVertexInputStateCreateInfo vi{.sType=VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
    .vertexBindingDescriptionCount=1,.pVertexBindingDescriptions=&binding,
    .vertexAttributeDescriptionCount=static_cast<uint32_t>(attrs.size()),.pVertexAttributeDescriptions=attrs.data()};
  VkPipelineInputAssemblyStateCreateInfo ia{.sType=VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
    .topology=VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST};
  VkPipelineViewportStateCreateInfo vp{.sType=VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
    .viewportCount=1,.scissorCount=1};
  VkPipelineRasterizationStateCreateInfo rs{.sType=VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
    .polygonMode=VK_POLYGON_MODE_FILL,.cullMode=VK_CULL_MODE_NONE,
    .frontFace=VK_FRONT_FACE_COUNTER_CLOCKWISE,.lineWidth=1.f};
  VkPipelineMultisampleStateCreateInfo ms{.sType=VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
    .rasterizationSamples=samples};
  VkPipelineDepthStencilStateCreateInfo ds{.sType=VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
    .depthTestEnable=depthEnabled ? VK_TRUE : VK_FALSE,
    .depthWriteEnable=depthEnabled ? VK_TRUE : VK_FALSE,
    .depthCompareOp=depthEnabled ? VK_COMPARE_OP_LESS_OR_EQUAL : VK_COMPARE_OP_ALWAYS};
  VkPipelineColorBlendAttachmentState ba{.blendEnable=VK_TRUE,
    .srcColorBlendFactor=VK_BLEND_FACTOR_SRC_ALPHA,.dstColorBlendFactor=VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
    .colorBlendOp=VK_BLEND_OP_ADD,.srcAlphaBlendFactor=VK_BLEND_FACTOR_ONE,
    .dstAlphaBlendFactor=VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,.alphaBlendOp=VK_BLEND_OP_ADD,
    .colorWriteMask=VK_COLOR_COMPONENT_R_BIT|VK_COLOR_COMPONENT_G_BIT|VK_COLOR_COMPONENT_B_BIT|VK_COLOR_COMPONENT_A_BIT};
  VkPipelineColorBlendStateCreateInfo cb{.sType=VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
    .attachmentCount=1,.pAttachments=&ba};
  std::array<VkDynamicState,2> dyns{VK_DYNAMIC_STATE_VIEWPORT,VK_DYNAMIC_STATE_SCISSOR};
  VkPipelineDynamicStateCreateInfo dyn{.sType=VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
    .dynamicStateCount=2,.pDynamicStates=dyns.data()};
  VkGraphicsPipelineCreateInfo info{.sType=VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
    .stageCount=2,.pStages=stages.data(),.pVertexInputState=&vi,.pInputAssemblyState=&ia,
    .pViewportState=&vp,.pRasterizationState=&rs,.pMultisampleState=&ms,.pDepthStencilState=&ds,
    .pColorBlendState=&cb,.pDynamicState=&dyn,.layout=pipelineLayout_,.renderPass=renderPass,.subpass=0};
  VR(vkCreateGraphicsPipelines(device,VK_NULL_HANDLE,1,&info,nullptr,&out),
     "Failed to create spatial pipeline");
}

void QuadRenderer::createPipeline(VkRenderPass renderPass,
                                  VkSampleCountFlagBits samples,
                                  vk::Handle<VkPipeline> &out, Blend blend) {
  VkDevice device = device_.getDevice();
  Shaders &shaders = device_.getShaders();

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
  std::array<VkVertexInputAttributeDescription, 8> attributes{
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
    VkVertexInputAttributeDescription{6, 0, VK_FORMAT_R32_SFLOAT,
                                      offsetof(Vertex, aux)},
    VkVertexInputAttributeDescription{7, 0, VK_FORMAT_R32G32_SFLOAT,
                                      offsetof(Vertex, uv)},
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
    .rasterizationSamples = samples,
  };

  // Main UI render pass has a depth attachment, so the spec requires a valid
  // pDepthStencilState even though 2D UI paints in draw-list order and never
  // tests or writes depth. Required by VUID-VkGraphicsPipelineCreateInfo-renderPass-09028.
  VkPipelineDepthStencilStateCreateInfo depthStencil{
    .sType                 = VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
    .depthTestEnable       = VK_FALSE,
    .depthWriteEnable      = VK_FALSE,
    .depthCompareOp        = VK_COMPARE_OP_ALWAYS,
    .depthBoundsTestEnable = VK_FALSE,
    .stencilTestEnable     = VK_FALSE,
  };

  // Premultiplied source (see quad.frag): ONE rather than SRC_ALPHA. Over an
  // opaque target this is the same image as straight alpha; over the
  // transparent target that content blur renders into, it is the only form the
  // Gaussian can then average without dragging transparent black into edges.
  VkPipelineColorBlendAttachmentState blendAttachment{
    .blendEnable         = VK_TRUE,
    .srcColorBlendFactor = VK_BLEND_FACTOR_ONE,
    .dstColorBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
    .colorBlendOp        = VK_BLEND_OP_ADD,
    .srcAlphaBlendFactor = VK_BLEND_FACTOR_ONE,
    .dstAlphaBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
    .alphaBlendOp        = VK_BLEND_OP_ADD,
    .colorWriteMask      = VK_COLOR_COMPONENT_R_BIT | VK_COLOR_COMPONENT_G_BIT |
                           VK_COLOR_COMPONENT_B_BIT | VK_COLOR_COMPONENT_A_BIT,
  };

  // `dst *= src.a`, which is the one thing `over` cannot do: it can add
  // coverage but never take it away, so nothing drawn with the pipeline above
  // could cut a corner out of a finished window. Both factors are ZERO/SRC so
  // colour and alpha are scaled together — the target holds premultiplied
  // colour, and scaling one without the other would leave a bright fringe
  // where the alpha faded but the colour did not.
  if (blend == Blend::Mask) {
    blendAttachment.srcColorBlendFactor = VK_BLEND_FACTOR_ZERO;
    blendAttachment.dstColorBlendFactor = VK_BLEND_FACTOR_SRC_ALPHA;
    blendAttachment.srcAlphaBlendFactor = VK_BLEND_FACTOR_ZERO;
    blendAttachment.dstAlphaBlendFactor = VK_BLEND_FACTOR_SRC_ALPHA;
  }

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

  VkGraphicsPipelineCreateInfo pipelineInfo{
    .sType               = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
    .stageCount          = static_cast<uint32_t>(stages.size()),
    .pStages             = stages.data(),
    .pVertexInputState   = &vertexInput,
    .pInputAssemblyState = &inputAssembly,
    .pViewportState      = &viewportState,
    .pRasterizationState = &rasterizer,
    .pMultisampleState   = &multisampling,
    .pDepthStencilState  = &depthStencil,
    .pColorBlendState    = &colorBlending,
    .pDynamicState       = &dynamicState,
    .layout              = pipelineLayout_,
    .renderPass          = renderPass,
    .subpass             = 0,
  };
  VR(vkCreateGraphicsPipelines(device, VK_NULL_HANDLE, 1, &pipelineInfo, nullptr,
                               &out),
     "Failed to create quad pipeline");
}

void QuadRenderer::createPipelineLayout() {
  // Must match quad.vert Push { vec2 viewport; vec2 pan; float zoom; float pad; }
  struct ViewPush {
    float viewport[2];
    float pan[2];
    float zoom;
    float pad;
  };
  static_assert(sizeof(ViewPush) == 24, "ViewPush must match shader std140");

  VkPushConstantRange pushRange{
    .stageFlags = VK_SHADER_STAGE_VERTEX_BIT,
    .offset     = 0,
    .size       = sizeof(ViewPush),
  };

  VkDescriptorSetLayout      setLayout = descriptorSetLayout_;
  VkPipelineLayoutCreateInfo layoutInfo{
    .sType                  = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
    .setLayoutCount         = 1,
    .pSetLayouts            = &setLayout,
    .pushConstantRangeCount = 1,
    .pPushConstantRanges    = &pushRange,
  };
  VR(vkCreatePipelineLayout(device_.getDevice(), &layoutInfo, nullptr,
                            &pipelineLayout_),
     "Failed to create quad pipeline layout");
}

/// Grows this frame slot's vertex and index buffers to hold what was recorded.
///
/// The two are sized independently, and that is the whole point. The index
/// count used to be derived from the vertex count as `vertices / 4 * 6` — the
/// ratio a quad has, six indices per four vertices. Anything that is not a
/// quad has a different one: a triangle fan of N vertices needs 3(N-2)
/// indices, approaching *three* per vertex, and `pushMesh`, `pushPolyline` and
/// `pushSpatialTriangles` all produce those.
///
/// So a frame with enough mesh content overran the index buffer, and the
/// `memcpy` in `end()` wrote past the mapped allocation. The visible result was
/// a frame truncated partway through — the last text on screen cut off
/// mid-word, appearing and disappearing as scrolling brought a chart into
/// view and took it out again. Nothing reported it: no Vulkan error, no
/// dropped draw, just missing content.
void QuadRenderer::ensureBufferCapacity(size_t vertexCount, size_t indexCount) {
  auto &fr = activeFrame();
  if (vertexCount <= fr.capacity && indexCount <= fr.indexCapacity) {
    return;
  }

  // Growing destroys mapped buffers; both slots may need the same capacity
  // later, and any in-flight use of the *other* slot is unrelated — but this
  // slot was waited on before begin(). Still wait all if we ever grow shared
  // pipeline resources; for this buffer only this slot is rewritten.
  //
  // This window's frames, not the device's. These buffers are the owner's
  // alone, so no other window's submission can name them — and this runs
  // mid-frame, where reading another window's fences would collide with the
  // thread driving it.
  owner_->waitForAllFrames();

  size_t newCapacity = fr.capacity == 0 ? kInitialVertexCapacity : fr.capacity;
  while (newCapacity < vertexCount) {
    newCapacity *= 2;
  }

  // Never below what that many quads would need, so an all-quad frame still
  // grows in one step rather than twice.
  size_t newIndexCapacity = std::max<size_t>(
    fr.indexCapacity, (newCapacity / 4) * 6);
  while (newIndexCapacity < indexCount) {
    newIndexCapacity *= 2;
  }

  // Grow every frame slot to the same size so slot switches stay cheap.
  for (uint32_t s = 0; s < kMaxFramesInFlight; ++s) {
    auto &slot = frames_[s];
    if (slot.capacity >= newCapacity && slot.indexCapacity >= newIndexCapacity) {
      continue;
    }

    destroyFrameBuffers(slot);

    const VkDeviceSize vertexBytes = newCapacity * sizeof(Vertex);
    const VkDeviceSize indexBytes  = newIndexCapacity * sizeof(uint32_t);

    device_.createBuffer(vertexBytes, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
                         VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT |
                           VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                         slot.vertexBuffer, slot.vertexAlloc);
    device_.createBuffer(indexBytes, VK_BUFFER_USAGE_INDEX_BUFFER_BIT,
                         VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT |
                           VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                         slot.indexBuffer, slot.indexAlloc);

    slot.vertexMapped = device_.mapBuffer(slot.vertexAlloc);
    slot.indexMapped = device_.mapBuffer(slot.indexAlloc);
    slot.capacity = newCapacity;
    slot.indexCapacity = newIndexCapacity;
  }
}

// ─── Frame recording ───────────────────────────────────────────────────────

void QuadRenderer::begin(vec2 viewportSize, uint32_t frameSlot) {
  activeFrameSlot_ = frameSlot % kMaxFramesInFlight;
  activeFrame().descriptorWriteIndex = 0;

  viewportSize_ = viewportSize;
  vertices_.clear();
  indices_.clear();
  batches_.clear();
  segmentEnds_.clear();
  scissorStack_.clear();
  batchStartIndex_ = 0;
  blurResultView_ = VK_NULL_HANDLE;
  blurResultSampler_ = VK_NULL_HANDLE;
  currentScissor_  = VkRect2D{
    {0, 0},
    {static_cast<uint32_t>(viewportSize.x), static_cast<uint32_t>(viewportSize.y)},
  };
  // Default open batch samples the glyph atlas (SDF ignores it).
  currentBatchTexture_ =
    glyphAtlasView_ != VK_NULL_HANDLE ? glyphAtlasView_ : whiteImageView_;
}

void QuadRenderer::appendQuad(const vec2 corners[4], const vec2 locals[4],
                              vec2 halfSize, float radius, uint32_t rgba,
                              Kind kind, float aux, const vec2 *uvs) {
  const uint32_t base = static_cast<uint32_t>(vertices_.size());
  for (int i = 0; i < 4; ++i) {
    vertices_.push_back(Vertex{
      .pos      = corners[i],
      .local    = locals[i],
      .halfSize = halfSize,
      .radius   = radius,
      .color    = rgba,
      .kind     = static_cast<uint32_t>(kind),
      .aux      = aux,
      .uv       = uvs != nullptr ? uvs[i] : vec2{0.f, 0.f},
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

void QuadRenderer::ensureBatchTexture(VkImageView view)
{
  if (view == VK_NULL_HANDLE) {
    view = glyphAtlasView_ != VK_NULL_HANDLE ? glyphAtlasView_ : whiteImageView_;
  }
  if (view != currentBatchTexture_) {
    flushBatch();
    currentBatchTexture_ = view;
  }
}

void QuadRenderer::pushBox(vec2 topLeft, vec2 size, uint32_t rgba, float radius) {
  if (size.x <= 0.0f || size.y <= 0.0f) {
    return;
  }
  ensureBatchTexture(glyphAtlasView_);
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

void QuadRenderer::pushCornerMask(vec2 topLeft, vec2 size, float radius) {
  if (size.x <= 0.0f || size.y <= 0.0f || radius <= 0.0f) {
    return;
  }
  // Its own batch, before and after: this one geometry is drawn with a
  // different pipeline, and a batch is a run sharing one.
  flushBatch();
  ensureBatchTexture(glyphAtlasView_);

  const vec2 half{size.x * 0.5f, size.y * 0.5f};
  const vec2 center{topLeft.x + half.x, topLeft.y + half.y};
  const float r = std::min(radius, std::min(half.x, half.y));

  // No bleed, unlike `pushBox`. The quad is the region being *cleared* rather
  // than a shape being drawn, and a pixel of overhang would put it outside the
  // surface where there is nothing to clear.
  const vec2 corners[4] = {
    {center.x - half.x, center.y - half.y},
    {center.x + half.x, center.y - half.y},
    {center.x + half.x, center.y + half.y},
    {center.x - half.x, center.y + half.y},
  };
  const vec2 locals[4] = {
    {-half.x, -half.y}, {half.x, -half.y}, {half.x, half.y}, {-half.x, half.y},
  };
  appendQuad(corners, locals, half, r, 0xffffffffu, Kind::Mask);

  flushBatch();
  if (!batches_.empty()) batches_.back().mask = true;
}

void QuadRenderer::pushShadow(vec2 topLeft, vec2 size, float radius,
                              float blur, uint32_t rgba) {
  if (size.x <= 0.0f || size.y <= 0.0f) {
    return;
  }
  ensureBatchTexture(glyphAtlasView_);
  const float spread = blur > 0.f ? blur : 0.f;

  const vec2 half{size.x * 0.5f, size.y * 0.5f};
  const vec2 center{topLeft.x + half.x, topLeft.y + half.y};
  // The quad has to hold the whole falloff, not just the shape: a shadow that
  // stopped at the rect's own edge would be a hard-edged rectangle with a
  // gradient painted inside it.
  const vec2 ext{half.x + spread + 1.f, half.y + spread + 1.f};
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
  appendQuad(corners, locals, half, r, rgba, Kind::Shadow, spread);
}

void QuadRenderer::pushCircle(vec2 center, float radius, uint32_t rgba) {
  pushBox({center.x - radius, center.y - radius}, {radius * 2.0f, radius * 2.0f},
          rgba, radius);
}

void QuadRenderer::pushLine(vec2 p0, vec2 p1, float width, uint32_t rgba) {
  ensureBatchTexture(glyphAtlasView_);
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

void QuadRenderer::pushPolyline(const vec2 *points, uint32_t count,
                                uint32_t rgba) {
  if (points == nullptr || count < 2) return;
  // A direct-draw batch must sit between the indexed batches on either side.
  flushBatch();
  const uint32_t first = static_cast<uint32_t>(vertices_.size());
  vertices_.reserve(vertices_.size() + count);
  for (uint32_t i = 0; i < count; ++i) {
    vertices_.push_back(Vertex{.pos = points[i], .local = {0.f, 0.f},
      .halfSize = {0.f, 0.f}, .radius = 0.f, .color = rgba,
      .kind = static_cast<uint32_t>(Kind::Mesh)});
  }
  batches_.push_back(Batch{.geometry = Batch::Geometry::LineStrip,
    .firstVertex = first, .vertexCount = count, .scissor = currentScissor_});
}

void QuadRenderer::pushSpatialTriangles(const canvas::SpatialVertex *points,
                                        uint32_t count, VkImageView textureView,
                                        vec2 uv0, vec2 uv1, vec2 offset,
                                        float opacity) {
  if (points == nullptr || count < 3 || count % 3 != 0) return;
  flushBatch();
  const uint32_t first = static_cast<uint32_t>(vertices_.size());
  vertices_.reserve(vertices_.size() + count);
  // x/y are window pixels — projection happened in the producer — so the
  // node's transform is a plain translation of the projected result. Only
  // x/y: `z` is Vulkan depth and belongs to the scene's own ordering, which
  // moving the node across the screen does not change.
  const bool faded = opacity < 1.f;
  for (uint32_t i = 0; i < count; ++i) {
    vertices_.push_back(Vertex{
      .pos={points[i].x + offset.x, points[i].y + offset.y},
      .local={points[i].z,uv0.x+points[i].u*(uv1.x-uv0.x)},
      .halfSize={points[i].textured,uv0.y+points[i].v*(uv1.y-uv0.y)},.radius=0.f,
      .color=faded ? withScaledAlpha(points[i].color, opacity) : points[i].color,
      .kind=static_cast<uint32_t>(Kind::Mesh)});
  }
  batches_.push_back(Batch{.geometry=Batch::Geometry::SpatialTriangles,
    .firstVertex=first,.vertexCount=count,.scissor=currentScissor_,
    .textureView=textureView});
}

void QuadRenderer::pushSpatialBegin(vec2 topLeft, vec2 size) {
  flushBatch();
  const int32_t x = std::max(0, static_cast<int32_t>(topLeft.x));
  const int32_t y = std::max(0, static_cast<int32_t>(topLeft.y));
  const uint32_t w = static_cast<uint32_t>(std::max(0.f, size.x));
  const uint32_t h = static_cast<uint32_t>(std::max(0.f, size.y));
  batches_.push_back(Batch{.geometry=Batch::Geometry::SpatialBegin,
    .scissor=VkRect2D{{x,y},{w,h}}});
}

void QuadRenderer::pushGlyph(vec2 topLeft, vec2 size, vec2 uv0, vec2 uv1,
                             uint32_t rgba) {
  if (size.x <= 0.0f || size.y <= 0.0f) {
    return;
  }
  ensureBatchTexture(glyphAtlasView_);
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

void QuadRenderer::pushImage(vec2 topLeft, vec2 size, vec2 uv0, vec2 uv1,
                             uint32_t rgba, VkImageView textureView)
{
  if (size.x <= 0.0f || size.y <= 0.0f || textureView == VK_NULL_HANDLE) {
    return;
  }
  ensureBatchTexture(textureView);
  const vec2 corners[4] = {
    {topLeft.x, topLeft.y},
    {topLeft.x + size.x, topLeft.y},
    {topLeft.x + size.x, topLeft.y + size.y},
    {topLeft.x, topLeft.y + size.y},
  };
  const vec2 locals[4] = {
    {uv0.x, uv0.y}, {uv1.x, uv0.y}, {uv1.x, uv1.y}, {uv0.x, uv1.y},
  };
  appendQuad(corners, locals, {0.0f, 0.0f}, 0.0f, rgba, Kind::Image);
}

void QuadRenderer::pushMesh(const vec2 *points, uint32_t count, uint32_t rgba,
                            bool isRing) {
  if (points == nullptr) {
    return;
  }
  // Ring needs an even count (inner/outer pairs) and at least two pairs to
  // form one quad; fan needs at least a triangle.
  if (isRing ? (count < 4 || (count % 2) != 0) : count < 3) {
    return;
  }
  ensureBatchTexture(glyphAtlasView_);
  const uint32_t base = static_cast<uint32_t>(vertices_.size());
  for (uint32_t i = 0; i < count; ++i) {
    vertices_.push_back(Vertex{
      .pos      = points[i],
      .local    = {0.0f, 0.0f},
      .halfSize = {0.0f, 0.0f},
      .radius   = 0.0f,
      .color    = rgba,
      .kind     = static_cast<uint32_t>(Kind::Mesh),
    });
  }
  if (isRing) {
    // Alternating inner[i], outer[i]: two triangles per step, the usual
    // zig-zag strip-to-list expansion.
    for (uint32_t i = 0; i + 3 < count; i += 2) {
      indices_.push_back(base + i);
      indices_.push_back(base + i + 1);
      indices_.push_back(base + i + 2);
      indices_.push_back(base + i + 1);
      indices_.push_back(base + i + 3);
      indices_.push_back(base + i + 2);
    }
  } else {
    // Fan around vertex 0 — correct wherever the shape is star-shaped from
    // its first point (any convex polygon, or a wedge fanned from centre).
    for (uint32_t i = 1; i + 1 < count; ++i) {
      indices_.push_back(base);
      indices_.push_back(base + i);
      indices_.push_back(base + i + 1);
    }
  }
}

void QuadRenderer::flushBatch() {
  const uint32_t end = static_cast<uint32_t>(indices_.size());
  if (end > batchStartIndex_) {
    batches_.push_back(Batch{
      .geometry            = Batch::Geometry::Quads,
      .firstIndex          = batchStartIndex_,
      .indexCount          = end - batchStartIndex_,
      .scissor             = currentScissor_,
      .textureView         = currentBatchTexture_,
      .sampleBlurResult  = false,
    });
  }
  batchStartIndex_ = end;
}

void QuadRenderer::closeSegment() {
  flushBatch();
  segmentEnds_.push_back(static_cast<uint32_t>(batches_.size()));
}

void QuadRenderer::pushBlurResultImage(vec2 topLeft, vec2 size, vec2 uv0,
                                         vec2 uv1, float cornerRadius,
                                         uint32_t rgba)
{
  if (size.x <= 0.0f || size.y <= 0.0f) {
    return;
  }
  // Force a dedicated batch so we can flip sampleBlurResult without mixing
  // atlas/SDF geometry into the same descriptor bind.
  flushBatch();
  currentBatchTexture_ = whiteImageView_;  // unused when sampleBlurResult

  const vec2 half{size.x * 0.5f, size.y * 0.5f};
  const float r = std::min(std::max(cornerRadius, 0.f), std::min(half.x, half.y));

  if (r <= 0.f) {
    const vec2 corners[4] = {
      {topLeft.x, topLeft.y},
      {topLeft.x + size.x, topLeft.y},
      {topLeft.x + size.x, topLeft.y + size.y},
      {topLeft.x, topLeft.y + size.y},
    };
    const vec2 locals[4] = {
      {uv0.x, uv0.y}, {uv1.x, uv0.y}, {uv1.x, uv1.y}, {uv0.x, uv1.y},
    };
    appendQuad(corners, locals, {0.0f, 0.0f}, 0.0f, rgba, Kind::Image);
  } else {
    // A pixel of bleed for the SDF to antialias into, exactly as `pushBox`
    // takes. The UV rect is extended by the same pixel in texture units so
    // that a texel still lands where its pixel is — the sample there is
    // discarded by coverage, but a UV that did not follow the geometry would
    // shear the whole composite by a texel.
    constexpr float kPad = 1.0f;
    const vec2 center{topLeft.x + half.x, topLeft.y + half.y};
    const vec2 ext{half.x + kPad, half.y + kPad};
    const vec2 uvPerPx{(uv1.x - uv0.x) / size.x, (uv1.y - uv0.y) / size.y};
    const vec2 u0{uv0.x - uvPerPx.x * kPad, uv0.y - uvPerPx.y * kPad};
    const vec2 u1{uv1.x + uvPerPx.x * kPad, uv1.y + uvPerPx.y * kPad};

    const vec2 corners[4] = {
      {center.x - ext.x, center.y - ext.y},
      {center.x + ext.x, center.y - ext.y},
      {center.x + ext.x, center.y + ext.y},
      {center.x - ext.x, center.y + ext.y},
    };
    const vec2 locals[4] = {
      {-ext.x, -ext.y}, {ext.x, -ext.y}, {ext.x, ext.y}, {-ext.x, ext.y},
    };
    const vec2 uvs[4] = {
      {u0.x, u0.y}, {u1.x, u0.y}, {u1.x, u1.y}, {u0.x, u1.y},
    };
    appendQuad(corners, locals, half, r, rgba, Kind::BlurComposite, 0.f, uvs);
  }
  flushBatch();
  if (!batches_.empty()) {
    batches_.back().sampleBlurResult = true;
    batches_.back().textureView = VK_NULL_HANDLE;
  }
  currentBatchTexture_ =
    glyphAtlasView_ != VK_NULL_HANDLE ? glyphAtlasView_ : whiteImageView_;
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
  // Close the trailing open segment so multiphase always has a range.
  if (segmentEnds_.empty() || segmentEnds_.back() != batches_.size()) {
    segmentEnds_.push_back(static_cast<uint32_t>(batches_.size()));
  }

  if (vertices_.empty()) {
    return;
  }
  ensureBufferCapacity(vertices_.size(), indices_.size());

  auto &fr = activeFrame();
  std::memcpy(fr.vertexMapped, vertices_.data(),
              vertices_.size() * sizeof(Vertex));
  if (!indices_.empty()) {
    std::memcpy(fr.indexMapped, indices_.data(),
                indices_.size() * sizeof(uint32_t));
  }
}

void QuadRenderer::setViewTransform(float zoom, float panX, float panY)
{
  viewZoom_ = zoom > 0.f ? zoom : 1.f;
  viewPanX_ = panX;
  viewPanY_ = panY;
}

void QuadRenderer::draw(VkCommandBuffer commandBuffer) {
  drawBatchRange(commandBuffer, 0, static_cast<uint32_t>(batches_.size()), false);
}

void QuadRenderer::drawSegment(VkCommandBuffer commandBuffer,
                               uint32_t segmentIndex, bool intoSceneTarget) {
  if (segmentIndex >= segmentEnds_.size()) return;
  const uint32_t end = segmentEnds_[segmentIndex];
  const uint32_t start =
    segmentIndex == 0 ? 0u : segmentEnds_[segmentIndex - 1];
  if (end <= start) return;
  drawBatchRange(commandBuffer, start, end - start, intoSceneTarget);
}

void QuadRenderer::drawBatchRange(VkCommandBuffer commandBuffer,
                                  uint32_t firstBatch, uint32_t batchCount,
                                  bool intoSceneTarget) {
  if (batchCount == 0 || vertices_.empty() || firstBatch >= batches_.size()) {
    return;
  }
  const uint32_t last =
    std::min(firstBatch + batchCount, static_cast<uint32_t>(batches_.size()));

  auto &fr = activeFrame();

  VkPipeline bound = VK_NULL_HANDLE;

  struct ViewPush {
    float viewport[2];
    float pan[2];
    float zoom;
    float pad;
  };
  ViewPush pc{
    {viewportSize_.x, viewportSize_.y},
    {viewPanX_, viewPanY_},
    viewZoom_,
    0.f,
  };
  vkCmdPushConstants(commandBuffer, pipelineLayout_, VK_SHADER_STAGE_VERTEX_BIT,
                     0, sizeof(ViewPush), &pc);

  VkViewport viewport{
    .x = 0.0f, .y = 0.0f,
    .width = viewportSize_.x, .height = viewportSize_.y,
    .minDepth = 0.0f, .maxDepth = 1.0f,
  };
  vkCmdSetViewport(commandBuffer, 0, 1, &viewport);

  VkDeviceSize offset = 0;
  VkBuffer     vb     = fr.vertexBuffer;
  vkCmdBindVertexBuffers(commandBuffer, 0, 1, &vb, &offset);
  vkCmdBindIndexBuffer(commandBuffer, fr.indexBuffer, 0, VK_INDEX_TYPE_UINT32);

  // Scissors were recorded in layout space; map them through the same
  // center-zoom + pan used by the vertex shader.
  const float cx = viewportSize_.x * 0.5f;
  const float cy = viewportSize_.y * 0.5f;
  const float z  = viewZoom_;
  auto mapScissor = [&](VkRect2D s) -> VkRect2D {
    const float x0 = (static_cast<float>(s.offset.x) - cx) * z + cx + viewPanX_;
    const float y0 = (static_cast<float>(s.offset.y) - cy) * z + cy + viewPanY_;
    const float x1 = (static_cast<float>(s.offset.x + static_cast<int32_t>(s.extent.width)) - cx) * z
                     + cx + viewPanX_;
    const float y1 = (static_cast<float>(s.offset.y + static_cast<int32_t>(s.extent.height)) - cy) * z
                     + cy + viewPanY_;
    const int32_t ix0 = static_cast<int32_t>(std::floor(std::min(x0, x1)));
    const int32_t iy0 = static_cast<int32_t>(std::floor(std::min(y0, y1)));
    const int32_t ix1 = static_cast<int32_t>(std::ceil(std::max(x0, x1)));
    const int32_t iy1 = static_cast<int32_t>(std::ceil(std::max(y0, y1)));
    const int32_t cx0 = std::max(0, ix0);
    const int32_t cy0 = std::max(0, iy0);
    const int32_t cx1 = std::min(static_cast<int32_t>(viewportSize_.x), ix1);
    const int32_t cy1 = std::min(static_cast<int32_t>(viewportSize_.y), iy1);
    return VkRect2D{
      {cx0, cy0},
      {static_cast<uint32_t>(std::max(0, cx1 - cx0)),
       static_cast<uint32_t>(std::max(0, cy1 - cy0))},
    };
  };

  // Do not reset descriptorWriteIndex here — multiphase drawSegment calls
  // share one begin() and must not rewrite sets already bound earlier in the CB.
  VkImageView boundView = VK_NULL_HANDLE;
  VkSampler boundSampler = VK_NULL_HANDLE;
  VkDescriptorSet boundSet = VK_NULL_HANDLE;

  auto bindTexture = [&](VkImageView view, VkSampler overrideSamp) {
    if (view == VK_NULL_HANDLE) {
      view = glyphAtlasView_ != VK_NULL_HANDLE ? glyphAtlasView_ : whiteImageView_;
    }
    VkSampler samp = overrideSamp;
    if (samp == VK_NULL_HANDLE) {
      samp = (view == glyphAtlasView_ && glyphAtlasSampler_ != VK_NULL_HANDLE)
               ? glyphAtlasSampler_
               : sampler_;
    }
    if (view == boundView && samp == boundSampler && boundSet != VK_NULL_HANDLE)
      return;
    boundView = view;
    boundSampler = samp;

    if (fr.descriptorWriteIndex >= fr.descriptorSets.size() &&
        !growDescriptorSets(fr)) {
      // Only reachable once the frame is pathological or the device refused
      // to allocate. Past here every further bind rewrites the *same* set, so
      // all of them sample whichever texture was written last: the visible
      // result is the wrong picture, not a missing one. Nothing else in the
      // pipeline reports it — no Vulkan error, no dropped draw — so say it out
      // loud, once, or it reads as a mysterious content bug.
      //
      // Each texture *change* costs a set, and batches are emitted in tree
      // order with no sorting, so an image grid alternating art and labels
      // burns roughly two per card. Atlasing is what keeps the count down:
      // images sharing a page share one binding. See ImageAtlas and
      // `Engine::decodeImage`'s size cap.
      static bool warned = false;
      if (!warned) {
        warned = true;
        std::cerr << "QuadRenderer: more than " << fr.descriptorSets.size()
                  << " texture binds in one frame and no more sets available; "
                     "further textures will draw the wrong image. Reduce "
                     "distinct textures per frame or make them small enough "
                     "to atlas.\n";
      }
      fr.descriptorWriteIndex =
        static_cast<uint32_t>(fr.descriptorSets.size()) - 1;
    }
    VkDescriptorSet set = fr.descriptorSets[fr.descriptorWriteIndex++];
    VkDescriptorImageInfo imageInfo{
      .sampler     = samp,
      .imageView   = view,
      .imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
    };
    VkWriteDescriptorSet write{
      .sType           = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
      .dstSet          = set,
      .dstBinding      = 0,
      .descriptorCount = 1,
      .descriptorType  = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
      .pImageInfo      = &imageInfo,
    };
    vkUpdateDescriptorSets(device_.getDevice(), 1, &write, 0, nullptr);
    vkCmdBindDescriptorSets(commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS,
                            pipelineLayout_, 0, 1, &set, 0, nullptr);
    boundSet = set;
  };

  for (uint32_t bi = firstBatch; bi < last; ++bi) {
    const auto &batch = batches_[bi];
    if (batch.scissor.extent.width == 0 || batch.scissor.extent.height == 0) {
      continue;
    }
    VkRect2D sc = (z == 1.f && viewPanX_ == 0.f && viewPanY_ == 0.f)
                    ? batch.scissor
                    : mapScissor(batch.scissor);
    if (sc.extent.width == 0 || sc.extent.height == 0) continue;
    if (batch.geometry == Batch::Geometry::SpatialBegin) {
      VkClearAttachment attachment{.aspectMask=VK_IMAGE_ASPECT_DEPTH_BIT,
        .colorAttachment=0,.clearValue={.depthStencil={1.f,0}}};
      VkClearRect rect{.rect=sc,.baseArrayLayer=0,.layerCount=1};
      vkCmdClearAttachments(commandBuffer,1,&attachment,1,&rect);
      continue;
    }
    VkPipeline wanted = VK_NULL_HANDLE;
    if (batch.geometry == Batch::Geometry::LineStrip) {
      wanted = intoSceneTarget ? static_cast<VkPipeline>(linePipelineScene_)
                               : static_cast<VkPipeline>(linePipeline_);
    } else if (batch.geometry == Batch::Geometry::SpatialTriangles) {
      wanted = intoSceneTarget ? static_cast<VkPipeline>(spatialPipelineScene_)
                               : static_cast<VkPipeline>(spatialPipeline_);
    } else if (batch.mask) {
      // Never in the scene target: the mask shapes the *window*, and the
      // content-blur pass renders a subtree that has no corners of its own.
      wanted = intoSceneTarget ? VK_NULL_HANDLE
                               : static_cast<VkPipeline>(maskPipeline_);
    } else {
      wanted = intoSceneTarget ? static_cast<VkPipeline>(pipelineScene_)
                               : static_cast<VkPipeline>(pipeline_);
    }
    if (wanted == VK_NULL_HANDLE) continue;
    if (wanted != bound) {
      bound = wanted;
      vkCmdBindPipeline(commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS, bound);
      vkCmdPushConstants(commandBuffer, pipelineLayout_, VK_SHADER_STAGE_VERTEX_BIT,
                         0, sizeof(ViewPush), &pc);
    }
    if (batch.geometry == Batch::Geometry::Quads) {
      if (batch.sampleBlurResult) {
        if (blurResultView_ == VK_NULL_HANDLE) continue;
        bindTexture(blurResultView_, blurResultSampler_);
      } else {
        bindTexture(batch.textureView, VK_NULL_HANDLE);
      }
    } else if (batch.geometry == Batch::Geometry::SpatialTriangles) {
      bindTexture(batch.textureView, VK_NULL_HANDLE);
    }
    vkCmdSetScissor(commandBuffer, 0, 1, &sc);
    if (batch.geometry != Batch::Geometry::Quads) {
      vkCmdDraw(commandBuffer, batch.vertexCount, 1, batch.firstVertex, 0);
    } else {
      vkCmdDrawIndexed(commandBuffer, batch.indexCount, 1, batch.firstIndex, 0, 0);
    }
  }
}
