#pragma once

#include <mutex>
#include <string>
#include <unordered_map>

#include <vulkan/vulkan.h>

class RenderDevice;
class Shaders
{
  RenderDevice                                         &device_;
  std::unordered_map<std::string, VkShaderModule> shaderModules_;
  std::mutex                                      mutex_;

 public:
  Shaders(
    RenderDevice &device)
      : device_(device)
  {
  }

  Shaders(const Shaders &)            = delete;
  Shaders(Shaders &&)                 = delete;
  Shaders &operator=(const Shaders &) = delete;
  Shaders &operator=(Shaders &&)      = delete;

  VkShaderModule loadShader(const std::string &filename);
  void           cleanUp();
};
