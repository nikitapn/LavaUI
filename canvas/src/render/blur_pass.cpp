#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <mutex>
#include <string>
#include <unordered_map>

#include "render/blur_pass.hpp"
#include "render/shaders.hpp"
#include "render/vulkan.hpp"

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

}  // namespace

void BlurPass::init()
{
  // Match the main resolve format so blit/composite never hit a format-class
  // edge case (SRGB resolve ↔ UNORM blur looked like garbage on some paths).
  format_ = vulkan_.colorFormat();
  createPipeline();
  createSampler();
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
  VR(vkCreateSampler(vulkan_.getDevice(), &si, nullptr, &sampler_),
     "blur sampler");
}

void BlurPass::cleanUp()
{
  destroyImages();
  VkDevice device = vulkan_.getDevice();
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
    setA_ = setB_ = VK_NULL_HANDLE;
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
  VkDevice device = vulkan_.getDevice();
  auto kill = [&](VkFramebuffer &fb, VkImageView &v, VkImage &img,
                  VkDeviceMemory &mem) {
    if (fb != VK_NULL_HANDLE) {
      vkDestroyFramebuffer(device, fb, nullptr);
      fb = VK_NULL_HANDLE;
    }
    if (v != VK_NULL_HANDLE) {
      vkDestroyImageView(device, v, nullptr);
      v = VK_NULL_HANDLE;
    }
    if (img != VK_NULL_HANDLE) {
      vkDestroyImage(device, img, nullptr);
      img = VK_NULL_HANDLE;
    }
    if (mem != VK_NULL_HANDLE) {
      vkFreeMemory(device, mem, nullptr);
      mem = VK_NULL_HANDLE;
    }
  };
  kill(fbA_, viewA_, imageA_, memoryA_);
  kill(fbB_, viewB_, imageB_, memoryB_);
  width_ = height_ = 0;
}

void BlurPass::createImages(uint32_t width, uint32_t height)
{
  destroyImages();
  width_ = width;
  height_ = height;

  auto make = [&](VkImage &img, VkDeviceMemory &mem, VkImageView &view,
                  VkFramebuffer &fb) {
    vulkan_.createImage(
      width, height, 1, VK_SAMPLE_COUNT_1_BIT, format_, VK_IMAGE_TILING_OPTIMAL,
      VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT |
        VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
      VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT, img, mem);
    view = vulkan_.createImageView(img, format_, VK_IMAGE_ASPECT_COLOR_BIT, 1);

    VkFramebufferCreateInfo fbi{
      .sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
      .renderPass = renderPass_,
      .attachmentCount = 1,
      .pAttachments = &view,
      .width = width,
      .height = height,
      .layers = 1,
    };
    VR(vkCreateFramebuffer(vulkan_.getDevice(), &fbi, nullptr, &fb),
       "blur framebuffer");
  };

  make(imageA_, memoryA_, viewA_, fbA_);
  make(imageB_, memoryB_, viewB_, fbB_);

  auto writeSet = [&](VkDescriptorSet set, VkImageView view) {
    VkDescriptorImageInfo ii{
      .sampler = sampler_,
      .imageView = view,
      .imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
    };
    VkWriteDescriptorSet w{
      .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
      .dstSet = set,
      .dstBinding = 0,
      .descriptorCount = 1,
      .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
      .pImageInfo = &ii,
    };
    vkUpdateDescriptorSets(vulkan_.getDevice(), 1, &w, 0, nullptr);
  };
  writeSet(setA_, viewA_);
  writeSet(setB_, viewB_);
}

uint32_t BlurPass::downscaleFor(float radius)
{
  // One H+V pass of the sigma-2 kernel at one texel of spacing blurs by two
  // texels, so a texel worth radius/2 screen pixels lands the target width in
  // a single pass with spacing still inside (0.5, 1].
  const float r = std::clamp(radius, 0.5f, kMaxRadius);
  return static_cast<uint32_t>(std::clamp(std::ceil(r / 2.f), 1.f, 8.f));
}

void BlurPass::ensureSize(uint32_t width, uint32_t height, float maxRadius)
{
  if (width < 1 || height < 1) return;
  const uint32_t scale = downscaleFor(maxRadius);
  const uint32_t w = std::max(1u, width / scale);
  const uint32_t h = std::max(1u, height / scale);
  if (w == width_ && h == height_ && width == fullWidth_ &&
      height == fullHeight_ && imageA_ != VK_NULL_HANDLE) {
    return;
  }
  vulkan_.waitForAllFramesInFlight();
  fullWidth_ = width;
  fullHeight_ = height;
  scale_ = scale;
  createImages(w, h);
}

void BlurPass::createPipeline()
{
  VkDevice device = vulkan_.getDevice();

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
  // External → color write (covers transfer→sample→write for the H pass, and
  // previous pass → write for the V pass).
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
    .descriptorCount = 2,
  };
  VkDescriptorPoolCreateInfo dpi{
    .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
    .maxSets = 2,
    .poolSizeCount = 1,
    .pPoolSizes = &poolSize,
  };
  VR(vkCreateDescriptorPool(device, &dpi, nullptr, &pool_), "blur pool");

  VkDescriptorSetLayout layouts[2] = {setLayout_, setLayout_};
  VkDescriptorSetAllocateInfo dai{
    .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
    .descriptorPool = pool_,
    .descriptorSetCount = 2,
    .pSetLayouts = layouts,
  };
  VkDescriptorSet sets[2]{};
  VR(vkAllocateDescriptorSets(device, &dai, sets), "blur sets");
  setA_ = sets[0];
  setB_ = sets[1];

  struct Push {
    float direction[2];
    float spacing;
    float pad;
  };
  VkPushConstantRange pcr{
    .stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT,
    .offset = 0,
    .size = sizeof(Push),
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

  Shaders &shaders = vulkan_.getShaders();
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

void BlurPass::blurPass(VkCommandBuffer cmd, VkFramebuffer dstFb,
                        VkDescriptorSet srcSet, vec2 direction, float spacing)
{
  VkRenderPassBeginInfo bi{
    .sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
    .renderPass = renderPass_,
    .framebuffer = dstFb,
    .renderArea = {{0, 0}, {width_, height_}},
  };
  vkCmdBeginRenderPass(cmd, &bi, VK_SUBPASS_CONTENTS_INLINE);

  VkViewport viewport{0, 0, float(width_), float(height_), 0, 1};
  VkRect2D scissor{{0, 0}, {width_, height_}};
  vkCmdSetViewport(cmd, 0, 1, &viewport);
  vkCmdSetScissor(cmd, 0, 1, &scissor);
  vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline_);
  vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, pipelineLayout_,
                          0, 1, &srcSet, 0, nullptr);

  struct Push {
    float direction[2];
    float spacing;
    float pad;
  } pc{{direction.x, direction.y}, spacing, 0.f};
  vkCmdPushConstants(cmd, pipelineLayout_, VK_SHADER_STAGE_FRAGMENT_BIT, 0,
                     sizeof(pc), &pc);
  vkCmdDraw(cmd, 3, 1, 0, 0);
  vkCmdEndRenderPass(cmd);
}

void BlurPass::captureAndBlur(VkCommandBuffer cmd, VkImage src,
                              VkImageLayout srcLayout, float radius)
{
  if (!ready() || width_ < 1 || height_ < 1) return;

  const float r = std::clamp(radius, 0.5f, kMaxRadius);

  // The 9-tap kernel is a sigma-2 Gaussian *in texels*, and `scale_` was chosen
  // so that r/2 screen pixels is one texel — so a single H+V pass reaches the
  // requested width with spacing at or under a texel, which is the condition
  // for it to blur rather than stamp offset copies. Anything asking for a wider
  // blur gets bigger texels, not wider spacing.
  //
  // `scale_` follows the *widest* radius in the frame, so a narrow glass panel
  // sharing a frame with a wide one is blurred on the coarser grid: correct
  // width, but coarser than it would be on its own.
  const float spacing = std::clamp(r / (2.f * float(scale_)), 0.05f, 1.f);

  // blurA: UNDEFINED → TRANSFER_DST. The source scope covers the *previous*
  // frame's sampling of this image: one image pair serves both frames in
  // flight, so without it frame N+1's capture can overwrite what frame N is
  // still reading.
  imageBarrier(cmd, imageA_, VK_IMAGE_LAYOUT_UNDEFINED,
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

  // Full frame → blur image. A linear blit only averages 2×2 of however many
  // pixels it steps over, so at scale 3 and up this is not a box filter; the
  // Gaussian that follows hides it on static UI, and it is the reason the
  // capture is a blit rather than a mip chain.
  VkImageBlit blit{
    .srcSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1},
    .srcOffsets = {{0, 0, 0},
                   {static_cast<int32_t>(fullWidth_),
                    static_cast<int32_t>(fullHeight_), 1}},
    .dstSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1},
    .dstOffsets = {{0, 0, 0},
                   {static_cast<int32_t>(width_), static_cast<int32_t>(height_),
                    1}},
  };
  vkCmdBlitImage(cmd, src, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, imageA_,
                 VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &blit,
                 VK_FILTER_LINEAR);

  // A: TRANSFER_DST → SHADER_READ for H pass
  imageBarrier(cmd, imageA_, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
               VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
               VK_ACCESS_TRANSFER_WRITE_BIT, VK_ACCESS_SHADER_READ_BIT,
               VK_PIPELINE_STAGE_TRANSFER_BIT,
               VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT);

  const float texW = 1.f / float(width_);
  const float texH = 1.f / float(height_);

  // A →H→ B →V→ A. Chaining needs no extra barriers: the pass declares both an
  // EXTERNAL→colour-write and a colour-write→EXTERNAL dependency.
  blurPass(cmd, fbB_, setA_, {texW, 0.f}, spacing);
  blurPass(cmd, fbA_, setB_, {0.f, texH}, spacing);

  resultIsA_ = true;
  // A is SHADER_READ_ONLY (render pass finalLayout).
}

