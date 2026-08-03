#include <iostream>

#include "render/pipeline.hpp"
#include "render/render_device.hpp"

/* 
Some notes about pipelines:
When Vulkan detects a pipeline-render pass incompatibility during vkCmdDrawIndexed(), it can cascade into:
- Command buffer state corruption
- Resource binding failures
- Synchronization object confusion
- Fence/semaphore state errors
- The validation layer reported the symptoms (fence reuse) rather than the cause (pipeline incompatibility).

Key takeaways:
- Pipeline-RenderPass compatibility is crucial in Vulkan
- Validation errors can be misleading - always check pipeline setup when you see synchronization issues
- Shadow passes need specialized pipelines - not just different shaders
- Color attachments, MSAA, viewport size all need to match the render pass exactly
*/

PipelineBuilder::PipelineBuilder()
  : inputAssembly_ {
        .sType    = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
        .topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
        .primitiveRestartEnable = VK_FALSE,
      }
    , polygonMode_(VK_POLYGON_MODE_FILL)  // Default to filled mode
    , customRenderPass_(VK_NULL_HANDLE)   // Default to using Vulkan's main render pass
    , isShadowPipeline_(false)            // Default to regular pipeline
{
}

PipelineBuilder& PipelineBuilder::setVertexShader(
  VkShaderModule shaderModule)
{
  shaderStages_.emplace_back(VkPipelineShaderStageCreateInfo {
    .sType  = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
    .stage  = VK_SHADER_STAGE_VERTEX_BIT,
    .module = shaderModule,
    .pName  = "main",
  });
  return *this;
}

PipelineBuilder& PipelineBuilder::setFragmentShader(
  VkShaderModule shaderModule)
{
  shaderStages_.emplace_back(VkPipelineShaderStageCreateInfo {
    .sType  = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
    .stage  = VK_SHADER_STAGE_FRAGMENT_BIT,
    .module = shaderModule,
    .pName  = "main",
  });
  return *this;
}

PipelineBuilder& PipelineBuilder::setPrimitiveTopology(
  VkPrimitiveTopology topology, VkBool32 restartEnable)
{
  inputAssembly_.topology               = topology;
  inputAssembly_.primitiveRestartEnable = restartEnable;
  return *this;
}

PipelineBuilder& PipelineBuilder::setVertexInputState(
  const VkPipelineVertexInputStateCreateInfo& vertexInputInfo)
{
  vertexInputInfo_ = vertexInputInfo;
  return *this;
}

PipelineBuilder& PipelineBuilder::setLayoutInfo(
  const VkPipelineLayoutCreateInfo& pipelineLayoutInfo)
{
  pipelineLayoutInfo_ = pipelineLayoutInfo;
  return *this;
}

PipelineBuilder& PipelineBuilder::setPolygonMode(VkPolygonMode mode)
{
  polygonMode_ = mode;
  return *this;
}

PipelineBuilder& PipelineBuilder::setRenderPass(VkRenderPass renderPass)
{
  customRenderPass_ = renderPass;
  return *this;
}

PipelineBuilder& PipelineBuilder::setShadowPipeline(bool isShadow)
{
  isShadowPipeline_ = isShadow;
  return *this;
}

Pipeline PipelineBuilder::build(
  RenderDevice& device, std::string_view debugName)
{
  std::vector<VkDynamicState> dynamicStates = {VK_DYNAMIC_STATE_VIEWPORT,
                                               VK_DYNAMIC_STATE_SCISSOR};

  VkPipelineDynamicStateCreateInfo dynamicState {
    .sType             = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
    .dynamicStateCount = static_cast<uint32_t>(dynamicStates.size()),
    .pDynamicStates    = dynamicStates.data(),
  };

  // Both viewport and scissor are dynamic state (see above), so what is baked
  // in here is overwritten by vkCmdSetViewport/Scissor before every draw and
  // only has to be non-degenerate. It used to read the window's extent, which
  // is not something a pipeline can know now that a device serves several
  // windows of different sizes — and never actually mattered.
  uint32_t pipelineWidth  = isShadowPipeline_ ? device.getShadowMapSize() : 1;
  uint32_t pipelineHeight = pipelineWidth;

  VkViewport viewport {
    .x        = 0.0f,
    .y        = 0.0f,
    .width    = static_cast<float>(pipelineWidth),
    .height   = static_cast<float>(pipelineHeight),
    .minDepth = 0.0f,
    .maxDepth = 1.0f,
  };

  VkRect2D scissor {
    .offset = {0, 0}, 
    .extent = {pipelineWidth, pipelineHeight}
  };

  VkPipelineViewportStateCreateInfo viewportState {
    .sType         = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
    .viewportCount = 1,
    .pViewports    = &viewport,
    .scissorCount  = 1,
    .pScissors     = &scissor,
  };

  VkPipelineRasterizationStateCreateInfo rasterizer {
    .sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
    .depthClampEnable        = VK_FALSE,
    .polygonMode             = polygonMode_,
    .cullMode                = VK_CULL_MODE_BACK_BIT,
    .frontFace               = VK_FRONT_FACE_COUNTER_CLOCKWISE,
    .depthBiasEnable         = VK_FALSE,
    .depthBiasConstantFactor = 0.0f,  // Optional
    .depthBiasClamp          = 0.0f,  // Optional
    .depthBiasSlopeFactor    = 0.0f,  // Optional
    .lineWidth               = 1.0f,
  };

  VkPipelineMultisampleStateCreateInfo multisampling {
    .sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
    .rasterizationSamples  = isShadowPipeline_ ? VK_SAMPLE_COUNT_1_BIT : device.getMSAASamples(),
    .sampleShadingEnable   = VK_FALSE,
    .minSampleShading      = 1.0f,      // Optional
    .pSampleMask           = nullptr,   // Optional
    .alphaToCoverageEnable = VK_FALSE,  // Optional
    .alphaToOneEnable      = VK_FALSE,  // Optional
  };

  // Shadow pipelines don't need color attachments (depth-only)
  VkPipelineColorBlendAttachmentState colorBlendAttachment {};
  VkPipelineColorBlendStateCreateInfo colorBlending {};
  
  if (!isShadowPipeline_) {
    colorBlendAttachment = {
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

    colorBlending = {
      .sType           = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
      .logicOpEnable   = VK_FALSE,
      .logicOp         = VK_LOGIC_OP_COPY,
      .attachmentCount = 1,
      .pAttachments    = &colorBlendAttachment,
      .blendConstants  = {.0f, .0f, .0f, .0f},
    };
  } else {
    // Shadow pipeline: no color attachments
    colorBlending = {
      .sType           = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
      .logicOpEnable   = VK_FALSE,
      .logicOp         = VK_LOGIC_OP_COPY,
      .attachmentCount = 0,  // No color attachments for shadow pass
      .pAttachments    = nullptr,
      .blendConstants  = {.0f, .0f, .0f, .0f},
    };
  }

  VkPipelineDepthStencilStateCreateInfo depthStencil {
    .sType = VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
    .depthTestEnable = VK_TRUE,
    .depthWriteEnable = VK_TRUE,
    .depthCompareOp = VK_COMPARE_OP_LESS,
    .depthBoundsTestEnable = VK_FALSE,
    .stencilTestEnable = VK_FALSE,
    .front = {},
    .back = {},
    .minDepthBounds = 0.0f,
    .maxDepthBounds = 1.0f
  };

  VkGraphicsPipelineCreateInfo pipelineInfo {
    .sType               = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
    .stageCount          = 2,
    .pStages             = shaderStages_.data(),
    .pVertexInputState   = &vertexInputInfo_,
    .pInputAssemblyState = &inputAssembly_,
    .pViewportState      = &viewportState,
    .pRasterizationState = &rasterizer,
    .pMultisampleState   = &multisampling,
    .pDepthStencilState  = &depthStencil,
    .pColorBlendState    = &colorBlending,
    .pDynamicState       = &dynamicState,
  };

  VkPipelineLayout pipelineLayout;
  VkPipeline       pipeline;

  VR(vkCreatePipelineLayout(
       device.getDevice(), &pipelineLayoutInfo_, nullptr, &pipelineLayout),
     "failed to create pipeline layout!");

  pipelineInfo.layout             = pipelineLayout;
  pipelineInfo.renderPass         = customRenderPass_ != VK_NULL_HANDLE 
                                      ? customRenderPass_ 
                                      : device.getRenderPass();
  pipelineInfo.subpass            = 0;
  pipelineInfo.basePipelineHandle = VK_NULL_HANDLE;  // Optional
  pipelineInfo.basePipelineIndex  = -1;              // Optional

  VR(
    vkCreateGraphicsPipelines(
      device.getDevice(), VK_NULL_HANDLE, 1, &pipelineInfo, nullptr, &pipeline),
    "failed to create graphics pipeline!");

  std::cout << "Created pipeline '" << debugName << "' with handle " << pipeline
            << " (layout " << pipelineLayout << ")\n";

  return {pipeline, pipelineLayout};
}

void Pipeline::destroy(RenderDevice& device)
{
  pipeline.destroy(device.getDevice());
  layout.destroy(device.getDevice());
}
