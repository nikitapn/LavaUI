#include "render/gpu_trace.hpp"

#include "render/render_device.hpp"

namespace canvas {

#ifdef TRACY_ENABLE

void GpuTrace::create(RenderDevice &device, VkQueue queue, std::mutex &queueMutex,
                      VkCommandPool pool, const std::string &name)
{
  destroy();

  // Calibrated when the device has the extension: Tracy then maps GPU ticks
  // onto its CPU clock continuously instead of from one sample at startup,
  // which drifts apart over a capture of minutes.
  PFN_vkGetPhysicalDeviceCalibrateableTimeDomainsEXT domains = nullptr;
  PFN_vkGetCalibratedTimestampsEXT calibrated = nullptr;
  if (const char *suffix = device.calibratedTimestampsSuffix()) {
    const std::string domainsName =
      std::string("vkGetPhysicalDeviceCalibrateableTimeDomains") + suffix;
    const std::string timestampsName = std::string("vkGetCalibratedTimestamps") + suffix;
    domains = reinterpret_cast<PFN_vkGetPhysicalDeviceCalibrateableTimeDomainsEXT>(
      vkGetInstanceProcAddr(device.instance(), domainsName.c_str()));
    calibrated = reinterpret_cast<PFN_vkGetCalibratedTimestampsEXT>(
      vkGetDeviceProcAddr(device.getDevice(), timestampsName.c_str()));
  }

  VkCommandBufferAllocateInfo allocInfo{
    .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
    .commandPool = pool,
    .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
    .commandBufferCount = 1,
  };
  VkCommandBuffer cmd = VK_NULL_HANDLE;
  if (vkAllocateCommandBuffers(device.getDevice(), &allocInfo, &cmd) != VK_SUCCESS) return;
  {
    // Tracy submits on the queue and idles it; the lease's mutex is what makes
    // that legal beside another window sharing the queue.
    std::lock_guard lock(queueMutex);
    ctx_ = tracy::CreateVkContext(device.physicalDevice(), device.getDevice(), queue,
                                  cmd, domains, calibrated);
  }
  vkFreeCommandBuffers(device.getDevice(), pool, 1, &cmd);
  if (ctx_ && !name.empty()) {
    ctx_->Name(name.c_str(), static_cast<uint16_t>(name.size()));
  }
}

void GpuTrace::destroy()
{
  if (ctx_) {
    tracy::DestroyVkContext(ctx_);
    ctx_ = nullptr;
  }
}

void GpuTrace::collect(VkCommandBuffer cmd)
{
  if (ctx_) ctx_->Collect(cmd);
}

#else

void GpuTrace::create(RenderDevice &, VkQueue, std::mutex &, VkCommandPool,
                      const std::string &)
{
}
void GpuTrace::destroy() {}
void GpuTrace::collect(VkCommandBuffer) {}

#endif

} // namespace canvas
