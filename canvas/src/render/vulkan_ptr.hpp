#pragma once

#include <cassert>
#include <iostream>
#include <type_traits>
#include <utility>

#include <vulkan/vulkan_core.h>

namespace vk {

template <typename T>
class Handle
{
  T handle_;
public:
  Handle() : handle_(VK_NULL_HANDLE) {}
  Handle(T handle) : handle_(handle) { }
  Handle(const Handle& other) = delete;
  Handle(Handle&& other) : handle_(std::exchange(other.handle_, VK_NULL_HANDLE)) {}
  ~Handle() {
    if (handle_ != VK_NULL_HANDLE)
      std::cerr << "Handle not destroyed: " << handle_ << std::endl;
  }
  Handle& operator=(Handle&& other) {
    handle_ = std::exchange(other.handle_, VK_NULL_HANDLE);
    return *this;
  }
  Handle& operator=(T handle) {
    assert(handle_ == VK_NULL_HANDLE);
    handle_ = handle;
    return *this;
  }
  operator bool() const noexcept { return handle_ != VK_NULL_HANDLE; }
  operator T() const { return handle_; }
  T* operator&() noexcept { return &handle_; }
  const T* operator&() const noexcept { return &handle_; }
  T& getAddressOf() noexcept { return handle_; }
  T operator->() noexcept { return handle_; }
  bool operator==(T other) const noexcept { return handle_ == other; }
  bool operator!=(T other) const noexcept {return handle_ != other; }
  void destroy(VkDevice device) {
    if (handle_ == VK_NULL_HANDLE) return;
    if constexpr (std::is_same_v<T, VkBuffer>) {
      vkDestroyBuffer(device, handle_, nullptr);
    } else if constexpr (std::is_same_v<T, VkDeviceMemory>) {
      vkFreeMemory(device, handle_, nullptr);
    } else if constexpr (std::is_same_v<T, VkDescriptorPool>) {
      vkDestroyDescriptorPool(device, handle_, nullptr);
    } else if constexpr (std::is_same_v<T, VkDescriptorSetLayout>) {
      vkDestroyDescriptorSetLayout(device, handle_, nullptr);
    } else if constexpr (std::is_same_v<T, VkPipeline>) {
      vkDestroyPipeline(device, handle_, nullptr);
    } else if constexpr (std::is_same_v<T, VkPipelineLayout>) {
      vkDestroyPipelineLayout(device, handle_, nullptr);
    } else if constexpr (std::is_same_v<T, VkRenderPass>) {
      vkDestroyRenderPass(device, handle_, nullptr);
    } else if constexpr (std::is_same_v<T, VkSampler>) {
      vkDestroySampler(device, handle_, nullptr);
    } else if constexpr (std::is_same_v<T, VkShaderModule>) {
      vkDestroyShaderModule(device, handle_, nullptr);
    } else if constexpr (std::is_same_v<T, VkSwapchainKHR>) {
      vkDestroySwapchainKHR(device, handle_, nullptr);
    } else if constexpr (std::is_same_v<T, VkImage>) {
      vkDestroyImage(device, handle_, nullptr);
    } else if constexpr (std::is_same_v<T, VkImageView>) {
      vkDestroyImageView(device, handle_, nullptr);
    } else {
      static_assert(!sizeof(T), "Unknown handle type");
    }
    handle_ = VK_NULL_HANDLE;
  }
};
}  // namespace vk
