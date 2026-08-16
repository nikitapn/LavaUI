#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>

#include "render/blur_pass.hpp"
#include "render/shaders.hpp"
#include "render/render_device.hpp"
#include "render/render_window.hpp"

namespace {

void imageBarrier(VkCommandBuffer cmd, VkImage image, VkImageLayout oldL,
                  VkImageLayout newL, VkAccessFlags srcA, VkAccessFlags dstA,
                  VkPipelineStageFlags srcS, VkPipelineStageFlags dstS)
{
  VkImageMemoryBarrier b{
    .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
    .srcAccessMask = srcA,
    .dstAccessMask = dstA,
    .oldLayout = oldL,
    .newLayout = newL,
    .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
    .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
    .image = image,
    .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1},
  };
  vkCmdPipelineBarrier(cmd, srcS, dstS, 0, 0, nullptr, 0, nullptr, 1, &b);
}

struct KawasePush {
  float halfpixel[2];
  float offset;
  float upsample;
};
static_assert(sizeof(KawasePush) == 16, "must match blur.frag push block");

}  // namespace

void BlurPass::init()
{
  format_ = device_.colorFormat();
  createPipeline();
  createSampler();
  createSceneRenderPass();
}

void BlurPass::createSceneRenderPass()
{
  VkAttachmentDescription att{
    .format = format_,
    .samples = VK_SAMPLE_COUNT_1_BIT,
    .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR,
    .storeOp = VK_ATTACHMENT_STORE_OP_STORE,
    .stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE,
    .stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE,
    .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
    .finalLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
  };
  VkAttachmentReference ref{.attachment = 0,
                            .layout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL};
  VkSubpassDescription sub{
    .pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS,
    .colorAttachmentCount = 1,
    .pColorAttachments = &ref,
  };
  std::array<VkSubpassDependency, 2> deps{{
    {
      .srcSubpass = VK_SUBPASS_EXTERNAL,
      .dstSubpass = 0,
      .srcStageMask = VK_PIPELINE_STAGE_TRANSFER_BIT,
      .dstStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
      .srcAccessMask = VK_ACCESS_TRANSFER_READ_BIT,
      .dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
    },
    {
      .srcSubpass = 0,
      .dstSubpass = VK_SUBPASS_EXTERNAL,
      .srcStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
      .dstStageMask = VK_PIPELINE_STAGE_TRANSFER_BIT,
      .srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
      .dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT,
    },
  }};
  VkRenderPassCreateInfo rp{
    .sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
    .attachmentCount = 1,
    .pAttachments = &att,
    .subpassCount = 1,
    .pSubpasses = &sub,
    .dependencyCount = static_cast<uint32_t>(deps.size()),
    .pDependencies = deps.data(),
  };
  VR(vkCreateRenderPass(device_.getDevice(), &rp, nullptr, &sceneRenderPass_),
     "content blur scene render pass");
}

void BlurPass::destroySceneTarget()
{
  VkDevice device = device_.getDevice();
  if (sceneFb_ != VK_NULL_HANDLE) {
    vkDestroyFramebuffer(device, sceneFb_, nullptr);
    sceneFb_ = VK_NULL_HANDLE;
  }
  if (sceneView_ != VK_NULL_HANDLE) {
    vkDestroyImageView(device, sceneView_, nullptr);
    sceneView_ = VK_NULL_HANDLE;
  }
  device_.destroyImage(sceneImage_, sceneAlloc_);
}

void BlurPass::createSceneTarget(uint32_t width, uint32_t height)
{
  destroySceneTarget();
  device_.createImage(
    width, height, 1, VK_SAMPLE_COUNT_1_BIT, format_, VK_IMAGE_TILING_OPTIMAL,
    VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT,
    VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT, sceneImage_, sceneAlloc_);
  sceneView_ =
    device_.createImageView(sceneImage_, format_, VK_IMAGE_ASPECT_COLOR_BIT, 1);

  VkFramebufferCreateInfo fbi{
    .sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
    .renderPass = sceneRenderPass_,
    .attachmentCount = 1,
    .pAttachments = &sceneView_,
    .width = width,
    .height = height,
    .layers = 1,
  };
  VR(vkCreateFramebuffer(device_.getDevice(), &fbi, nullptr, &sceneFb_),
     "content blur scene framebuffer");
}

void BlurPass::beginSceneCapture(VkCommandBuffer cmd)
{
  if (!sceneReady()) return;

  VkClearValue clear{};
  clear.color = {{0.f, 0.f, 0.f, 0.f}};
  VkRenderPassBeginInfo bi{
    .sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
    .renderPass = sceneRenderPass_,
    .framebuffer = sceneFb_,
    .renderArea = {{0, 0}, {fullWidth_, fullHeight_}},
    .clearValueCount = 1,
    .pClearValues = &clear,
  };
  vkCmdBeginRenderPass(cmd, &bi, VK_SUBPASS_CONTENTS_INLINE);

  VkViewport vp{0.f, 0.f, float(fullWidth_), float(fullHeight_), 0.f, 1.f};
  VkRect2D scissor{{0, 0}, {fullWidth_, fullHeight_}};
  vkCmdSetViewport(cmd, 0, 1, &vp);
  vkCmdSetScissor(cmd, 0, 1, &scissor);
}

void BlurPass::endSceneCapture(VkCommandBuffer cmd)
{
  if (!sceneReady()) return;
  vkCmdEndRenderPass(cmd);
}

void BlurPass::createSampler()
{
  VkSamplerCreateInfo si{
    .sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
    .magFilter = VK_FILTER_LINEAR,
    .minFilter = VK_FILTER_LINEAR,
    .mipmapMode = VK_SAMPLER_MIPMAP_MODE_NEAREST,
    .addressModeU = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
    .addressModeV = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
    .addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
    .mipLodBias = 0.f,
    .anisotropyEnable = VK_FALSE,
    .maxAnisotropy = 1.f,
    .compareEnable = VK_FALSE,
    .minLod = 0.f,
    .maxLod = 0.f,
    .borderColor = VK_BORDER_COLOR_FLOAT_OPAQUE_BLACK,
    .unnormalizedCoordinates = VK_FALSE,
  };
  VR(vkCreateSampler(device_.getDevice(), &si, nullptr, &sampler_),
     "blur sampler");
}

void BlurPass::cleanUp()
{
  destroyImages();
  destroySceneTarget();
  VkDevice device = device_.getDevice();
  if (sceneRenderPass_ != VK_NULL_HANDLE) {
    vkDestroyRenderPass(device, sceneRenderPass_, nullptr);
    sceneRenderPass_ = VK_NULL_HANDLE;
  }
  if (pipeline_ != VK_NULL_HANDLE) {
    vkDestroyPipeline(device, pipeline_, nullptr);
    pipeline_ = VK_NULL_HANDLE;
  }
  if (pipelineLayout_ != VK_NULL_HANDLE) {
    vkDestroyPipelineLayout(device, pipelineLayout_, nullptr);
    pipelineLayout_ = VK_NULL_HANDLE;
  }
  if (pool_ != VK_NULL_HANDLE) {
    vkDestroyDescriptorPool(device, pool_, nullptr);
    pool_ = VK_NULL_HANDLE;
  }
  if (setLayout_ != VK_NULL_HANDLE) {
    vkDestroyDescriptorSetLayout(device, setLayout_, nullptr);
    setLayout_ = VK_NULL_HANDLE;
  }
  if (renderPass_ != VK_NULL_HANDLE) {
    vkDestroyRenderPass(device, renderPass_, nullptr);
    renderPass_ = VK_NULL_HANDLE;
  }
  if (sampler_ != VK_NULL_HANDLE) {
    vkDestroySampler(device, sampler_, nullptr);
    sampler_ = VK_NULL_HANDLE;
  }
}

void BlurPass::destroyImages()
{
  VkDevice device = device_.getDevice();
  for (auto &lv : levels_) {
    if (lv.fb != VK_NULL_HANDLE) {
      vkDestroyFramebuffer(device, lv.fb, nullptr);
      lv.fb = VK_NULL_HANDLE;
    }
    if (lv.view != VK_NULL_HANDLE) {
      vkDestroyImageView(device, lv.view, nullptr);
      lv.view = VK_NULL_HANDLE;
    }
    device_.destroyImage(lv.image, lv.alloc);
    lv.w = lv.h = 0;
    // Descriptor sets live on the pool; they are rewritten on the next
    // createImages, not freed here.
  }
  levelCount_ = 0;
}

void BlurPass::createImages(uint32_t width, uint32_t height)
{
  destroyImages();

  uint32_t w = width;
  uint32_t h = height;
  for (uint32_t i = 0; i < kMaxLevels; ++i) {
    Level &lv = levels_[i];
    lv.w = std::max(1u, w);
    lv.h = std::max(1u, h);
    device_.createImage(
      lv.w, lv.h, 1, VK_SAMPLE_COUNT_1_BIT, format_, VK_IMAGE_TILING_OPTIMAL,
      VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT |
        VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
      VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT, lv.image, lv.alloc);
    lv.view =
      device_.createImageView(lv.image, format_, VK_IMAGE_ASPECT_COLOR_BIT, 1);

    VkFramebufferCreateInfo fbi{
      .sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
      .renderPass = renderPass_,
      .attachmentCount = 1,
      .pAttachments = &lv.view,
      .width = lv.w,
      .height = lv.h,
      .layers = 1,
    };
    VR(vkCreateFramebuffer(device_.getDevice(), &fbi, nullptr, &lv.fb),
       "blur framebuffer");

    VkDescriptorImageInfo ii{
      .sampler = sampler_,
      .imageView = lv.view,
      .imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
    };
    VkWriteDescriptorSet wr{
      .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
      .dstSet = lv.set,
      .dstBinding = 0,
      .descriptorCount = 1,
      .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
      .pImageInfo = &ii,
    };
    vkUpdateDescriptorSets(device_.getDevice(), 1, &wr, 0, nullptr);

    ++levelCount_;
    if (lv.w == 1 && lv.h == 1) break;
    w = std::max(1u, w / 2);
    h = std::max(1u, h / 2);
  }
}

uint32_t BlurPass::iterationsFor(float radius)
{
  const float r = std::clamp(radius, 0.5f, kMaxRadius);
  uint32_t n = 1;
  float reach = 8.f;
  while (n + 1 < kMaxLevels && reach < r) {
    reach *= 2.f;
    ++n;
  }
  return n;
}

uint32_t BlurPass::downscaleFor(float)
{
  return 1;
}

vec2 BlurPass::uvScaleFor(float) const
{
  return {1.f, 1.f};
}

void BlurPass::ensureSize(uint32_t width, uint32_t height, float)
{
  if (width < 1 || height < 1) return;
  if (width == fullWidth_ && height == fullHeight_ &&
      levels_[0].image != VK_NULL_HANDLE) {
    return;
  }
  owner_->waitForAllFrames();
  const bool extentChanged = width != fullWidth_ || height != fullHeight_;
  fullWidth_ = width;
  fullHeight_ = height;
  createImages(width, height);
  if (extentChanged || !sceneReady()) {
    createSceneTarget(width, height);
  }
}

void BlurPass::createPipeline()
{
  VkDevice device = device_.getDevice();

  VkAttachmentDescription att{
    .format = format_,
    .samples = VK_SAMPLE_COUNT_1_BIT,
    .loadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE,
    .storeOp = VK_ATTACHMENT_STORE_OP_STORE,
    .stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE,
    .stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE,
    .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
    .finalLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
  };
  VkAttachmentReference ref{.attachment = 0,
                            .layout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL};
  VkSubpassDescription sub{
    .pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS,
    .colorAttachmentCount = 1,
    .pColorAttachments = &ref,
  };
  std::array<VkSubpassDependency, 2> deps{{
    {
      .srcSubpass = VK_SUBPASS_EXTERNAL,
      .dstSubpass = 0,
      .srcStageMask = VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT |
                      VK_PIPELINE_STAGE_TRANSFER_BIT,
      .dstStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
      .srcAccessMask = VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_TRANSFER_WRITE_BIT,
      .dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
    },
    {
      .srcSubpass = 0,
      .dstSubpass = VK_SUBPASS_EXTERNAL,
      .srcStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
      .dstStageMask = VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT |
                      VK_PIPELINE_STAGE_TRANSFER_BIT,
      .srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
      .dstAccessMask = VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_TRANSFER_READ_BIT,
    },
  }};
  VkRenderPassCreateInfo rp{
    .sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
    .attachmentCount = 1,
    .pAttachments = &att,
    .subpassCount = 1,
    .pSubpasses = &sub,
    .dependencyCount = static_cast<uint32_t>(deps.size()),
    .pDependencies = deps.data(),
  };
  VR(vkCreateRenderPass(device, &rp, nullptr, &renderPass_), "blur render pass");

  VkDescriptorSetLayoutBinding binding{
    .binding = 0,
    .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
    .descriptorCount = 1,
    .stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT,
  };
  VkDescriptorSetLayoutCreateInfo dsl{
    .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
    .bindingCount = 1,
    .pBindings = &binding,
  };
  VR(vkCreateDescriptorSetLayout(device, &dsl, nullptr, &setLayout_),
     "blur set layout");

  VkDescriptorPoolSize poolSize{
    .type = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
    .descriptorCount = kMaxLevels,
  };
  VkDescriptorPoolCreateInfo dpi{
    .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
    .maxSets = kMaxLevels,
    .poolSizeCount = 1,
    .pPoolSizes = &poolSize,
  };
  VR(vkCreateDescriptorPool(device, &dpi, nullptr, &pool_), "blur pool");

  std::array<VkDescriptorSetLayout, kMaxLevels> layouts{};
  layouts.fill(setLayout_);
  VkDescriptorSetAllocateInfo dai{
    .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
    .descriptorPool = pool_,
    .descriptorSetCount = kMaxLevels,
    .pSetLayouts = layouts.data(),
  };
  std::array<VkDescriptorSet, kMaxLevels> sets{};
  VR(vkAllocateDescriptorSets(device, &dai, sets.data()), "blur sets");
  for (uint32_t i = 0; i < kMaxLevels; ++i) levels_[i].set = sets[i];

  VkPushConstantRange pcr{
    .stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT,
    .offset = 0,
    .size = sizeof(KawasePush),
  };
  VkPipelineLayoutCreateInfo pli{
    .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
    .setLayoutCount = 1,
    .pSetLayouts = &setLayout_,
    .pushConstantRangeCount = 1,
    .pPushConstantRanges = &pcr,
  };
  VR(vkCreatePipelineLayout(device, &pli, nullptr, &pipelineLayout_),
     "blur pipeline layout");

  Shaders &shaders = device_.getShaders();
  VkShaderModule vert = shaders.loadShader("shaders/blur.vert.bin");
  VkShaderModule frag = shaders.loadShader("shaders/blur.frag.bin");
  std::array<VkPipelineShaderStageCreateInfo, 2> stages{{
    {.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
     .stage = VK_SHADER_STAGE_VERTEX_BIT,
     .module = vert,
     .pName = "main"},
    {.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
     .stage = VK_SHADER_STAGE_FRAGMENT_BIT,
     .module = frag,
     .pName = "main"},
  }};

  VkPipelineVertexInputStateCreateInfo vi{
    .sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
  };
  VkPipelineInputAssemblyStateCreateInfo ia{
    .sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
    .topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
  };
  VkPipelineViewportStateCreateInfo vp{
    .sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
    .viewportCount = 1,
    .scissorCount = 1,
  };
  VkPipelineRasterizationStateCreateInfo rs{
    .sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
    .polygonMode = VK_POLYGON_MODE_FILL,
    .cullMode = VK_CULL_MODE_NONE,
    .frontFace = VK_FRONT_FACE_COUNTER_CLOCKWISE,
    .lineWidth = 1.f,
  };
  VkPipelineMultisampleStateCreateInfo ms{
    .sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
    .rasterizationSamples = VK_SAMPLE_COUNT_1_BIT,
  };
  VkPipelineColorBlendAttachmentState blend{
    .blendEnable = VK_FALSE,
    .colorWriteMask = 0xf,
  };
  VkPipelineColorBlendStateCreateInfo cb{
    .sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
    .attachmentCount = 1,
    .pAttachments = &blend,
  };
  std::array<VkDynamicState, 2> dyn{VK_DYNAMIC_STATE_VIEWPORT,
                                    VK_DYNAMIC_STATE_SCISSOR};
  VkPipelineDynamicStateCreateInfo dsi{
    .sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
    .dynamicStateCount = 2,
    .pDynamicStates = dyn.data(),
  };

  VkGraphicsPipelineCreateInfo gpi{
    .sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
    .stageCount = 2,
    .pStages = stages.data(),
    .pVertexInputState = &vi,
    .pInputAssemblyState = &ia,
    .pViewportState = &vp,
    .pRasterizationState = &rs,
    .pMultisampleState = &ms,
    .pColorBlendState = &cb,
    .pDynamicState = &dsi,
    .layout = pipelineLayout_,
    .renderPass = renderPass_,
    .subpass = 0,
  };
  VR(vkCreateGraphicsPipelines(device, VK_NULL_HANDLE, 1, &gpi, nullptr,
                               &pipeline_),
     "blur pipeline");
}

void BlurPass::kawasePass(VkCommandBuffer cmd, VkDescriptorSet srcSet,
                          VkFramebuffer dstFb, uint32_t destW, uint32_t destH,
                          float offset, bool upsample)
{
  VkRenderPassBeginInfo bi{
    .sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
    .renderPass = renderPass_,
    .framebuffer = dstFb,
    .renderArea = {{0, 0}, {destW, destH}},
  };
  vkCmdBeginRenderPass(cmd, &bi, VK_SUBPASS_CONTENTS_INLINE);

  VkViewport viewport{0, 0, float(destW), float(destH), 0, 1};
  VkRect2D scissor{{0, 0}, {destW, destH}};
  vkCmdSetViewport(cmd, 0, 1, &viewport);
  vkCmdSetScissor(cmd, 0, 1, &scissor);
  vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline_);
  vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, pipelineLayout_,
                          0, 1, &srcSet, 0, nullptr);

  KawasePush pc{
    {0.5f / float(destW), 0.5f / float(destH)},
    offset,
    upsample ? 1.f : 0.f,
  };
  vkCmdPushConstants(cmd, pipelineLayout_, VK_SHADER_STAGE_FRAGMENT_BIT, 0,
                     sizeof(pc), &pc);
  vkCmdDraw(cmd, 3, 1, 0, 0);
  vkCmdEndRenderPass(cmd);
}

void BlurPass::captureAndBlur(VkCommandBuffer cmd, VkImage src,
                              VkImageLayout srcLayout, float radius)
{
  if (!ready() || levelCount_ < 2) return;

  const uint32_t iters =
    std::min(iterationsFor(radius), levelCount_ > 0 ? levelCount_ - 1 : 0);
  if (iters < 1) return;

  imageBarrier(cmd, levels_[0].image, VK_IMAGE_LAYOUT_UNDEFINED,
               VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
               VK_ACCESS_SHADER_READ_BIT, VK_ACCESS_TRANSFER_WRITE_BIT,
               VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
               VK_PIPELINE_STAGE_TRANSFER_BIT);

  if (srcLayout != VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL) {
    imageBarrier(cmd, src, srcLayout, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                 VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
                 VK_ACCESS_TRANSFER_READ_BIT,
                 VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
                 VK_PIPELINE_STAGE_TRANSFER_BIT);
  }

  VkImageBlit blit{
    .srcSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1},
    .srcOffsets = {{0, 0, 0},
                   {static_cast<int32_t>(fullWidth_),
                    static_cast<int32_t>(fullHeight_), 1}},
    .dstSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1},
    .dstOffsets = {{0, 0, 0},
                   {static_cast<int32_t>(levels_[0].w),
                    static_cast<int32_t>(levels_[0].h), 1}},
  };
  vkCmdBlitImage(cmd, src, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                 levels_[0].image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1,
                 &blit, VK_FILTER_LINEAR);

  imageBarrier(cmd, levels_[0].image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
               VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
               VK_ACCESS_TRANSFER_WRITE_BIT, VK_ACCESS_SHADER_READ_BIT,
               VK_PIPELINE_STAGE_TRANSFER_BIT,
               VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT);

  constexpr float kOffset = 1.f;
  for (uint32_t i = 0; i < iters; ++i) {
    kawasePass(cmd, levels_[i].set, levels_[i + 1].fb, levels_[i + 1].w,
               levels_[i + 1].h, kOffset, false);
  }
  for (uint32_t i = iters; i > 0; --i) {
    kawasePass(cmd, levels_[i].set, levels_[i - 1].fb, levels_[i - 1].w,
               levels_[i - 1].h, kOffset, true);
  }
  // levels_[0] is SHADER_READ_ONLY (render pass finalLayout).
}
