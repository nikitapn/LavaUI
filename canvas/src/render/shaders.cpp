#include <filesystem>

#include "util/util.hpp"
#include "render/shaders.hpp"
#include "render/render_device.hpp"

VkShaderModule Shaders::loadShader(
  const std::string &filename)
{
  std::lock_guard<std::mutex> lock(mutex_);

  auto it = shaderModules_.find(filename);
  if (it != std::end(shaderModules_)) {
    return it->second;
  }

  auto code = utils::readFile(filename);
  VkShaderModule shaderModule = device_.createShaderModule(code);
  shaderModules_.emplace(filename, shaderModule);

  return shaderModule;
}

void Shaders::cleanUp()
{
  for (auto &shaderModule : shaderModules_) {
    vkDestroyShaderModule(device_.getDevice(), shaderModule.second, nullptr);
  }
  shaderModules_.clear();
}
