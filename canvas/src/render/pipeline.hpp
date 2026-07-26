#pragma once

#include <vector>

#include <vulkan/vulkan.h>
#include <vulkan/vulkan_core.h>

#include "render/vulkan_ptr.hpp"

class Vulkan;

struct Pipeline {
  vk::Handle<VkPipeline>       pipeline;
  vk::Handle<VkPipelineLayout> layout;

  void destroy(Vulkan& vulkan);
};

class PipelineBuilder
{
  std::vector<VkPipelineShaderStageCreateInfo> shaderStages_;

  VkPipelineInputAssemblyStateCreateInfo inputAssembly_;
  VkPipelineVertexInputStateCreateInfo   vertexInputInfo_;
  VkPipelineLayoutCreateInfo             pipelineLayoutInfo_;
  VkPolygonMode                          polygonMode_;
  VkRenderPass                           customRenderPass_;
  bool                                   isShadowPipeline_;

 public:
  PipelineBuilder();

  PipelineBuilder& setVertexShader(VkShaderModule shaderModule);

  PipelineBuilder& setFragmentShader(VkShaderModule shaderModule);

  PipelineBuilder& setPrimitiveTopology(VkPrimitiveTopology topology,
                                        VkBool32            restartEnable);

  PipelineBuilder& setVertexInputState(
    const VkPipelineVertexInputStateCreateInfo& vertexInputInfo);

  PipelineBuilder& setLayoutInfo(
    const VkPipelineLayoutCreateInfo& pipelineLayoutInfo);

  PipelineBuilder& setPolygonMode(VkPolygonMode mode);

  PipelineBuilder& setRenderPass(VkRenderPass renderPass);

  PipelineBuilder& setShadowPipeline(bool isShadow = true);

  Pipeline build(Vulkan& vulkan, std::string_view debugName = "unnamed_pipeline");
};
