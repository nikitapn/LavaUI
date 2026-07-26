#include <pch.hpp>

#include "util/util.hpp"
#include "render/shaders.hpp"
#include "render/vulkan.hpp"

VkShaderModule Shaders::loadShader(
  const std::string &filename)
{
  std::lock_guard<std::mutex> lock(mutex_);

  auto it = shaderModules_.find(filename);
  if (it != std::end(shaderModules_)) {
    return it->second;
  }

  auto code = utils::readFile(filename);
  VkShaderModule shaderModule = vulkan_.createShaderModule(code);
  shaderModules_.emplace(filename, shaderModule);

  return shaderModule;
}

void Shaders::cleanUp()
{
  for (auto &shaderModule : shaderModules_) {
    vkDestroyShaderModule(vulkan_.getDevice(), shaderModule.second, nullptr);
  }
  shaderModules_.clear();
}
