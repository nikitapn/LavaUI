#include <algorithm>
#include <array>
#include <cassert>
#include <cstdlib>
#include <cmath>
#include <cstring>
#include <iostream>
#include <stdexcept>
#include <string>

#include <vulkan/vulkan_core.h>

#define GLFW_INCLUDE_VULKAN
#include <GLFW/glfw3.h>

#ifdef INCLUDE_IMGUI
# include "imgui_impl_vulkan.h"
# include "imgui_impl_glfw.h"
#endif

#include "render/render_window.hpp"
#include "render/render_device.hpp"
#include "render/text_renderer.hpp"
#include "render/texture_manager.hpp"

RenderWindow::RenderWindow(RenderDevice &device, GLFWwindow *window)
  : dev_{device}
  , quads_{device}
  , blur_{device}
  , windowed_{true}
  , window_{window}
{
  if (!window_) throw std::runtime_error("RenderWindow: null GLFW window");

  createWindowSurface();

  // A surface the device's queue family cannot present to would fail later
  // as an obscure present error, so say it here. In practice every surface
  // from one platform behaves the same, but "in practice" is not a guarantee
  // the spec makes, and a second window is exactly where it could bite.
  VkBool32 presentSupport = VK_FALSE;
  vkGetPhysicalDeviceSurfaceSupportKHR(
    dev_.physicalDevice(), dev_.graphicsQueueFamily(), surface_, &presentSupport);
  if (!presentSupport) {
    vkDestroySurfaceKHR(dev_.instance(), surface_, nullptr);
    surface_ = VK_NULL_HANDLE;
    throw std::runtime_error(
      "RenderWindow: graphics queue family cannot present to this surface");
  }

  int fbW = 0, fbH = 0;
  glfwGetFramebufferSize(window_, &fbW, &fbH);
  extent_ = {static_cast<uint32_t>(fbW < 1 ? 1 : fbW),
             static_cast<uint32_t>(fbH < 1 ? 1 : fbH)};

  createSwapchain(); // may adjust extent_ to the surface's idea of the size
  createSizedResources();
  createCommandBuffer();
  createSyncObjects();
  createPresentSyncObjects();

  dev_.registerWindow(this);
}

RenderWindow::RenderWindow(RenderDevice &device, uint32_t width, uint32_t height)
  : dev_{device}
  , quads_{device}
  , blur_{device}
  , windowed_{false}
{
  extent_ = {width < 1 ? 1 : width, height < 1 ? 1 : height};

  createSizedResources();
  createCommandBuffer();
  createSyncObjects();

  dev_.registerWindow(this);
}

RenderWindow::~RenderWindow()
{
  dev_.unregisterWindow(this);

  const VkDevice dev = dev_.getDevice();
  if (dev == VK_NULL_HANDLE) return;

  // A device-wide idle, not this window's fences.
  //
  // `waitForAllFrames()` waits on the frame fences, which signal when a
  // *submission* completes. The last present is not covered by them: it waits
  // on `renderFinishedSemaphores_` and hands the image to the presentation
  // engine, which is still using both the semaphore and the swapchain image
  // when the fence goes green. Destroying either there is what the validation
  // layer reports as VUID-vkDestroySemaphore-semaphore-05149 and
  // VUID-vkDestroySwapchainKHR-swapchain-01282 — and closing one window of
  // several is exactly when it happens, because the app carries on rather than
  // exiting straight afterwards.
  //
  // Device-wide rather than queue-wide because a sibling window may have work
  // queued against the same queue right now. This is rare and slow and both of
  // those are fine: a window closes once.
  if (dev_.getDevice() != VK_NULL_HANDLE) {
    vkDeviceWaitIdle(dev_.getDevice());
  }

  // Renderers first: their vertex buffers and blur targets are this window's,
  // and the attachments below are what they were drawing into.
  if (renderersReady_) {
    blur_.cleanUp();
    quads_.cleanUp();
    renderersReady_ = false;
  }

  for (uint32_t i = 0; i < kMaxFramesInFlight; ++i) {
    if (imageAvailableSemaphores_[i] != VK_NULL_HANDLE) {
      vkDestroySemaphore(dev, imageAvailableSemaphores_[i], nullptr);
      imageAvailableSemaphores_[i] = VK_NULL_HANDLE;
    }
    if (inFlightFences_[i] != VK_NULL_HANDLE) {
      vkDestroyFence(dev, inFlightFences_[i], nullptr);
      inFlightFences_[i] = VK_NULL_HANDLE;
    }
  }
  if (commandBuffers_[0] != VK_NULL_HANDLE) {
    vkFreeCommandBuffers(dev, dev_.getCommandPool(), kMaxFramesInFlight,
                         commandBuffers_);
    for (auto &cb : commandBuffers_) cb = VK_NULL_HANDLE;
  }

  destroySizedResources();
  cleanupSwapchain();

  if (surface_ != VK_NULL_HANDLE) {
    vkDestroySurfaceKHR(dev_.instance(), surface_, nullptr);
    surface_ = VK_NULL_HANDLE;
  }
}

void RenderWindow::createWindowSurface()
{
  VR(glfwCreateWindowSurface(dev_.instance(), window_, nullptr, &surface_),
     "failed to create window surface");
}

/// Everything whose size is the window's size. Split out because `resize()`
/// and the destructor both need exactly this set, and the two drifting apart
/// is how a resize leaks an attachment.
void RenderWindow::createSizedResources()
{
  createColorResources();
  createResolveResources();
  createDepthResources();
  createStagingBuffer();
  createFramebuffer();
}

void RenderWindow::destroySizedResources()
{
  const VkDevice dev = dev_.getDevice();

  if (framebuffer_ != VK_NULL_HANDLE) {
    vkDestroyFramebuffer(dev, framebuffer_, nullptr);
    framebuffer_ = VK_NULL_HANDLE;
  }
  if (framebufferContinue_ != VK_NULL_HANDLE) {
    vkDestroyFramebuffer(dev, framebufferContinue_, nullptr);
    framebufferContinue_ = VK_NULL_HANDLE;
  }

  if (stagingBufferMapped_) {
    if (stagingBufferAlloc_ != VK_NULL_HANDLE) dev_.unmapBuffer(stagingBufferAlloc_);
    stagingBufferMapped_ = nullptr;
  }
  dev_.destroyBuffer(stagingBuffer_, stagingBufferAlloc_);

  if (colorImageView_ != VK_NULL_HANDLE) {
    vkDestroyImageView(dev, colorImageView_, nullptr);
    colorImageView_ = VK_NULL_HANDLE;
  }
  dev_.destroyImage(colorImage_, colorImageAlloc_);

  if (resolveImageView_ != VK_NULL_HANDLE) {
    vkDestroyImageView(dev, resolveImageView_, nullptr);
    resolveImageView_ = VK_NULL_HANDLE;
  }
  dev_.destroyImage(resolveImage_, resolveImageAlloc_);

  if (depthImageView_ != VK_NULL_HANDLE) {
    vkDestroyImageView(dev, depthImageView_, nullptr);
    depthImageView_ = VK_NULL_HANDLE;
  }
  dev_.destroyImage(depthImage_, depthImageAlloc_);
}

void RenderWindow::createSwapchain()
{
  VkSurfaceCapabilitiesKHR caps {};
  vkGetPhysicalDeviceSurfaceCapabilitiesKHR(dev_.physicalDevice(), surface_, &caps);

  uint32_t formatCount = 0;
  vkGetPhysicalDeviceSurfaceFormatsKHR(dev_.physicalDevice(), surface_, &formatCount, nullptr);
  std::vector<VkSurfaceFormatKHR> formats(formatCount);
  vkGetPhysicalDeviceSurfaceFormatsKHR(
    dev_.physicalDevice(), surface_, &formatCount, formats.data());

  VkSurfaceFormatKHR chosen = formats[0];
  for (const auto &f : formats) {
    if (f.format == VK_FORMAT_B8G8R8A8_SRGB &&
        f.colorSpace == VK_COLOR_SPACE_SRGB_NONLINEAR_KHR) {
      chosen = f;
      break;
    }
  }
  swapchainImageFormat_ = chosen.format;

  if (caps.currentExtent.width != UINT32_MAX) {
    swapchainExtent_ = caps.currentExtent;
  } else {
    int fbW = 0, fbH = 0;
    glfwGetFramebufferSize(window_, &fbW, &fbH);
    swapchainExtent_.width = std::clamp(
      static_cast<uint32_t>(fbW), caps.minImageExtent.width, caps.maxImageExtent.width);
    swapchainExtent_.height = std::clamp(
      static_cast<uint32_t>(fbH), caps.minImageExtent.height, caps.maxImageExtent.height);
  }

  // Keep offscreen target size in sync with the window framebuffer.
  extent_ = swapchainExtent_;

  uint32_t imageCount = caps.minImageCount + 1;
  if (caps.maxImageCount > 0 && imageCount > caps.maxImageCount) {
    imageCount = caps.maxImageCount;
  }

  uint32_t presentModeCount = 0;
  vkGetPhysicalDeviceSurfacePresentModesKHR(
    dev_.physicalDevice(), surface_, &presentModeCount, nullptr);
  std::vector<VkPresentModeKHR> presentModes(presentModeCount);
  vkGetPhysicalDeviceSurfacePresentModesKHR(
    dev_.physicalDevice(), surface_, &presentModeCount, presentModes.data());

  // MAILBOX preferred, FIFO as the fallback.
  //
  // The history is worth keeping, because two of these were tried in anger:
  //
  //   FIFO      classic vsync, the only mode the spec guarantees. Correct and
  //             non-tearing, but presenting blocks until the next refresh, and
  //             that latency is felt directly in pointer work — dragging a
  //             boundary in TraceLoom (button down + move) visibly trailed the
  //             cursor. That is what drove us off it.
  //   IMMEDIATE no blocking and no queue, so the lowest latency available, at
  //             the cost of tearing. Ran this for a while; no tearing was
  //             actually observed, but it is a real risk we were simply
  //             getting away with.
  //   MAILBOX   non-tearing like FIFO, but present replaces the queued image
  //             instead of blocking, so a drag does not acquire FIFO's lag.
  //             Best of both, and where we settled.
  //
  // Only FIFO is guaranteed by the spec, and asking for a mode the surface did
  // not report is a validation error (VUID-VkSwapchainCreateInfoKHR-
  // presentMode-01281), not a silent downgrade — so this picks from what was
  // actually queried rather than naming a constant and hoping. That is what
  // makes the code portable to a driver without MAILBOX (MoltenVK being the
  // obvious question mark) without anyone having to know in advance.
  //
  // LAVA_PRESENT_MODE=fifo|mailbox|immediate forces one, for measuring the
  // latency trade above without a rebuild. An unsupported request still falls
  // back rather than crashing.
  auto hasMode = [&presentModes](VkPresentModeKHR m) {
    return std::find(presentModes.begin(), presentModes.end(), m) != presentModes.end();
  };

  // FIFO is the guaranteed floor; each branch below is an upgrade on it,
  // preferred in order.
  VkPresentModeKHR presentMode = VK_PRESENT_MODE_FIFO_KHR;
  const char *presentName = "FIFO";
  if (hasMode(VK_PRESENT_MODE_MAILBOX_KHR)) {
    presentMode = VK_PRESENT_MODE_MAILBOX_KHR;
    presentName = "MAILBOX";
  } else if (dev_.fifoLatestReadyEnabled() && hasMode(VK_PRESENT_MODE_FIFO_LATEST_READY_KHR)) {
    // Same guarantee as MAILBOX, different spelling.
    presentMode = VK_PRESENT_MODE_FIFO_LATEST_READY_KHR;
    presentName = "FIFO_LATEST_READY";
  } else if (hasMode(VK_PRESENT_MODE_IMMEDIATE_KHR)) {
    // Ranked above plain FIFO deliberately. FIFO's blocking present is the
    // lag that drove this app off it for pointer work, and IMMEDIATE ran for
    // a long stretch here without tearing being observed. A surface offering
    // neither MAILBOX nor latest-ready leaves this as the only low-latency
    // option, and latency is the property this UI cares about most.
    presentMode = VK_PRESENT_MODE_IMMEDIATE_KHR;
    presentName = "IMMEDIATE";
  }

  if (const char *forced = std::getenv("LAVA_PRESENT_MODE")) {
    const std::string want(forced);
    VkPresentModeKHR requested = presentMode;
    const char *requestedName = nullptr;
    if (want == "fifo") {
      requested = VK_PRESENT_MODE_FIFO_KHR;
      requestedName = "FIFO";
    } else if (want == "mailbox") {
      requested = VK_PRESENT_MODE_MAILBOX_KHR;
      requestedName = "MAILBOX";
    } else if (want == "immediate") {
      requested = VK_PRESENT_MODE_IMMEDIATE_KHR;
      requestedName = "IMMEDIATE";
    } else if (want == "latest") {
      requested = VK_PRESENT_MODE_FIFO_LATEST_READY_KHR;
      requestedName = "FIFO_LATEST_READY";
    }
    if (requestedName != nullptr) {
      if (requested == VK_PRESENT_MODE_FIFO_LATEST_READY_KHR
          && !dev_.fifoLatestReadyEnabled()) {
        std::cout << "Present mode FIFO_LATEST_READY needs "
                  << VK_KHR_PRESENT_MODE_FIFO_LATEST_READY_EXTENSION_NAME
                  << ", which this device does not expose; using " << presentName << "\n";
      } else if (hasMode(requested)) {
        presentMode = requested;
        presentName = requestedName;
      } else {
        std::cout << "Present mode " << requestedName
                  << " not supported by this surface; using " << presentName << "\n";
      }
    }
  }

  // MAILBOX needs a spare image to swap in, or it degrades to FIFO's pacing
  // with none of the latency benefit that is the whole reason for choosing it.
  if (presentMode == VK_PRESENT_MODE_MAILBOX_KHR && imageCount < 3) {
    imageCount = 3;
    if (caps.maxImageCount > 0 && imageCount > caps.maxImageCount) {
      imageCount = caps.maxImageCount;
    }
  }

  VkSwapchainCreateInfoKHR sci {
    .sType = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
    .surface = surface_,
    .minImageCount = imageCount,
    .imageFormat = swapchainImageFormat_,
    .imageColorSpace = chosen.colorSpace,
    .imageExtent = swapchainExtent_,
    .imageArrayLayers = 1,
    .imageUsage = VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
    .imageSharingMode = VK_SHARING_MODE_EXCLUSIVE,
    .preTransform = caps.currentTransform,
    .compositeAlpha = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
    .presentMode = presentMode,
    .clipped = VK_TRUE,
    .oldSwapchain = VK_NULL_HANDLE,
  };

  VR(vkCreateSwapchainKHR(dev_.getDevice(), &sci, nullptr, &swapchain_),
     "failed to create swapchain");

  uint32_t actualCount = 0;
  vkGetSwapchainImagesKHR(dev_.getDevice(), swapchain_, &actualCount, nullptr);
  swapchainImages_.resize(actualCount);
  vkGetSwapchainImagesKHR(dev_.getDevice(), swapchain_, &actualCount, swapchainImages_.data());

  swapchainImageViews_.resize(actualCount);
  for (uint32_t i = 0; i < actualCount; ++i) {
    swapchainImageViews_[i] = dev_.createImageView(
      swapchainImages_[i], swapchainImageFormat_, VK_IMAGE_ASPECT_COLOR_BIT, 1);
  }

  // One present-wait semaphore per swapchain image. Index by acquired image
  // index so a semaphore is only reused after that image is re-acquired
  // (which means the previous present that waited on it has finished).
  VkSemaphoreCreateInfo semInfo {VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};
  renderFinishedSemaphores_.assign(actualCount, VK_NULL_HANDLE);
  for (uint32_t i = 0; i < actualCount; ++i) {
    VR(vkCreateSemaphore(dev_.getDevice(), &semInfo, nullptr, &renderFinishedSemaphores_[i]),
       "renderFinished semaphore");
  }

  std::cout << "Swapchain: " << swapchainExtent_.width << "x"
            << swapchainExtent_.height << " (" << actualCount
            << " images, present=" << presentName
            << ", framesInFlight=" << kMaxFramesInFlight << ")\n";
}

void RenderWindow::cleanupSwapchain()
{
  for (auto sem : renderFinishedSemaphores_) {
    if (sem != VK_NULL_HANDLE) vkDestroySemaphore(dev_.getDevice(), sem, nullptr);
  }
  renderFinishedSemaphores_.clear();

  for (auto view : swapchainImageViews_) {
    if (view != VK_NULL_HANDLE) vkDestroyImageView(dev_.getDevice(), view, nullptr);
  }
  swapchainImageViews_.clear();
  swapchainImages_.clear();
  if (swapchain_ != VK_NULL_HANDLE) {
    vkDestroySwapchainKHR(dev_.getDevice(), swapchain_, nullptr);
    swapchain_ = VK_NULL_HANDLE;
  }
}

void RenderWindow::createColorResources()
{
  dev_.createImage(extent_.width,
              extent_.height,
              1,
              dev_.getMSAASamples(),
              dev_.colorFormat(),
              VK_IMAGE_TILING_OPTIMAL,
              // Not TRANSIENT any more: a backdrop blur ends the main pass and
              // reopens it with LOAD_OP_LOAD, and the contents of a transient
              // attachment are undefined between render pass instances.
              VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
              VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
              colorImage_,
              colorImageAlloc_);

  colorImageView_ = dev_.createImageView(
    colorImage_, dev_.colorFormat(), VK_IMAGE_ASPECT_COLOR_BIT, 1);
}

void RenderWindow::createResolveResources()
{
  // Single-sample target the MSAA color attachment resolves into. Unlike
  // colorImage_ (TRANSIENT_ATTACHMENT_BIT, MSAA scratch), this one needs
  // TRANSFER_SRC (readPixels / present blit / blur capture) and TRANSFER_DST
  // (composite blurred region back under glass panels).
  dev_.createImage(extent_.width,
              extent_.height,
              1,
              VK_SAMPLE_COUNT_1_BIT,
              dev_.colorFormat(),
              VK_IMAGE_TILING_OPTIMAL,
              VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT |
                VK_IMAGE_USAGE_TRANSFER_SRC_BIT |
                VK_IMAGE_USAGE_TRANSFER_DST_BIT,
              VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
              resolveImage_,
              resolveImageAlloc_);

  resolveImageView_ = dev_.createImageView(
    resolveImage_, dev_.colorFormat(), VK_IMAGE_ASPECT_COLOR_BIT, 1);
}

void RenderWindow::createDepthResources()
{
  VkFormat depthFormat = dev_.findDepthFormat();

  dev_.createImage(extent_.width,
              extent_.height,
              1,
              dev_.getMSAASamples(),
              depthFormat,
              VK_IMAGE_TILING_OPTIMAL,
              VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT,
              VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
              depthImage_,
              depthImageAlloc_);

  depthImageView_ = dev_.createImageView(depthImage_, depthFormat, VK_IMAGE_ASPECT_DEPTH_BIT, 1);

  // Transition depth image to depth-stencil attachment optimal layout
  dev_.transitionImageLayout(depthImage_, depthFormat, VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL);
}

void RenderWindow::createStagingBuffer()
{
  stagingBufferSize_ =
    static_cast<VkDeviceSize>(extent_.width) * extent_.height * 4;

  dev_.createBuffer(stagingBufferSize_,
               VK_BUFFER_USAGE_TRANSFER_DST_BIT,
               VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT |
                 VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
               stagingBuffer_,
               stagingBufferAlloc_);

  stagingBufferMapped_ = dev_.mapBuffer(stagingBufferAlloc_);
  if (!stagingBufferMapped_) {
    throw std::runtime_error("failed to map staging buffer memory!");
  }
}

void RenderWindow::createFramebuffer()
{
  VkImageView attachments[] = {colorImageView_, depthImageView_, resolveImageView_};

  auto makeFb = [&](VkRenderPass rp, VkFramebuffer *out) {
    VkFramebufferCreateInfo framebufferInfo {
      .sType           = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
      .renderPass      = rp,
      .attachmentCount = 3,
      .pAttachments    = attachments,
      .width           = extent_.width,
      .height          = extent_.height,
      .layers          = 1,
    };
    VR(vkCreateFramebuffer(dev_.getDevice(), &framebufferInfo, nullptr, out),
       "failed to create framebuffer!");
  };
  makeFb(dev_.getRenderPass(), &framebuffer_);
  makeFb(dev_.renderPassContinue(), &framebufferContinue_);
}

void RenderWindow::createCommandBuffer()
{
  VkCommandBufferAllocateInfo allocInfo {
    .sType              = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
    .commandPool        = dev_.getCommandPool(),
    .level              = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
    .commandBufferCount = kMaxFramesInFlight,
  };
  VR(vkAllocateCommandBuffers(dev_.getDevice(), &allocInfo, commandBuffers_),
     "failed to allocate command buffers!");
}

void RenderWindow::createSyncObjects()
{
  VkFenceCreateInfo fenceInfo {
    .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
    .flags = VK_FENCE_CREATE_SIGNALED_BIT,  // first use of each slot is free
  };
  for (uint32_t i = 0; i < kMaxFramesInFlight; ++i) {
    VR(vkCreateFence(dev_.getDevice(), &fenceInfo, nullptr, &inFlightFences_[i]),
       "vkCreateFence failed.");
  }
  currentFrame_ = 0;
}

void RenderWindow::createPresentSyncObjects()
{
  // Acquire semaphores are per frames-in-flight (safe: tied to the frame fence).
  // Present-wait (renderFinished) semaphores live with the swapchain images —
  // see createSwapchain / cleanupSwapchain.
  VkSemaphoreCreateInfo semInfo {VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};
  for (uint32_t i = 0; i < kMaxFramesInFlight; ++i) {
    VR(vkCreateSemaphore(dev_.getDevice(), &semInfo, nullptr, &imageAvailableSemaphores_[i]),
       "imageAvailable semaphore");
  }
}

void RenderWindow::beginMainRenderPass(VkCommandBuffer commandBuffer, bool clear)
{
  if (!clear) {
    // After a blur segment, resolve is TRANSFER_SRC; continue pass needs it
    // as a color attachment with LOAD.
    VkImageMemoryBarrier toColor{
      .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
      .srcAccessMask = VK_ACCESS_TRANSFER_READ_BIT | VK_ACCESS_SHADER_READ_BIT,
      .dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_READ_BIT |
                       VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
      .oldLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
      .newLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
      .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
      .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
      .image = resolveImage_,
      .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1},
    };
    // Both source stages, since the resolve was read by the capture blit
    // (TRANSFER) and SHADER_READ is in the access mask.
    vkCmdPipelineBarrier(
      commandBuffer,
      VK_PIPELINE_STAGE_TRANSFER_BIT | VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
      VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, 0, 0, nullptr, 0, nullptr,
      1, &toColor);
  }

  std::array<VkClearValue, 2> clearValues {};
  clearValues[0].color = {{0.0f, 0.0f, 0.0f, 1.0f}};
  clearValues[1].depthStencil = {1.0f, 0};

  VkRenderPassBeginInfo renderPassInfo {
    .sType           = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
    .renderPass      = clear ? dev_.getRenderPass() : dev_.renderPassContinue(),
    .framebuffer     = clear ? framebuffer_ : framebufferContinue_,
    .renderArea      = {.offset = {0, 0}, .extent = extent_},
    .clearValueCount = static_cast<uint32_t>(clearValues.size()),
    .pClearValues    = clearValues.data(),
  };

  vkCmdBeginRenderPass(
    commandBuffer, &renderPassInfo, VK_SUBPASS_CONTENTS_INLINE);

  VkViewport viewport {
    .x        = 0.0f,
    .y        = 0.0f,
    .width    = static_cast<float>(extent_.width),
    .height   = static_cast<float>(extent_.height),
    .minDepth = 0.0f,
    .maxDepth = 1.0f,
  };

  vkCmdSetViewport(commandBuffer, 0, 1, &viewport);

  VkRect2D scissor {
    .offset = {0, 0},
    .extent = extent_,
  };

  vkCmdSetScissor(commandBuffer, 0, 1, &scissor);
}

void RenderWindow::endMainRenderPass(VkCommandBuffer commandBuffer)
{
  vkCmdEndRenderPass(commandBuffer);
}

void RenderWindow::waitForInFlightFrame()
{
  if (inFlightFences_[currentFrame_] == VK_NULL_HANDLE) return;
  vkWaitForFences(dev_.getDevice(), 1, &inFlightFences_[currentFrame_], VK_TRUE,
                  UINT64_MAX);
}

void RenderWindow::waitForAllFrames()
{
  // Gather non-null fences (init order may leave some unset during teardown).
  VkFence fences[kMaxFramesInFlight];
  uint32_t n = 0;
  for (uint32_t i = 0; i < kMaxFramesInFlight; ++i) {
    if (inFlightFences_[i] != VK_NULL_HANDLE) {
      fences[n++] = inFlightFences_[i];
    }
  }
  if (n == 0) return;
  vkWaitForFences(dev_.getDevice(), n, fences, VK_TRUE, UINT64_MAX);
}

uint64_t RenderWindow::oldestUnretiredSubmission() const
{
  uint64_t oldest = UINT64_MAX;
  for (uint32_t i = 0; i < kMaxFramesInFlight; ++i) {
    if (slotSubmission_[i] == 0) continue;  // slot never submitted
    if (inFlightFences_[i] == VK_NULL_HANDLE) continue;
    // Signalled means that submission has completed and nothing it referenced
    // is live any more.
    if (vkGetFenceStatus(dev_.getDevice(), inFlightFences_[i]) == VK_SUCCESS) {
      continue;
    }
    if (slotSubmission_[i] < oldest) oldest = slotSubmission_[i];
  }
  return oldest;
}

void RenderWindow::submitFrame(
  std::function<void(VkCommandBuffer)> shadowCallback,
  std::function<void(VkCommandBuffer, u32)> mainCallback)
{
  // Wait only for *this* slot. The other slot may still be on the GPU — that
  // is the whole point of frames-in-flight. Application should already have
  // waited this slot before rewriting its host-visible buffers.
  //
  // Fence is reset only after we know we will submit: an early return with a
  // reset fence leaves the slot stuck unsignalled forever.
  waitForInFlightFrame();

  const uint32_t frame = currentFrame_;
  VkCommandBuffer cmd = commandBuffers_[frame];
  VkFence fence = inFlightFences_[frame];

  uint32_t swapImageIndex = 0;
  if (windowed_) {
    VkResult acq = vkAcquireNextImageKHR(
      dev_.getDevice(), swapchain_, UINT64_MAX, imageAvailableSemaphores_[frame],
      VK_NULL_HANDLE, &swapImageIndex);
    if (acq == VK_ERROR_OUT_OF_DATE_KHR) {
      // Swapchain is stale; ensureFramebufferSize() rebuilds it. Fence stays
      // signalled so the next attempt on this slot is free.
      return;
    }
    if (acq != VK_SUCCESS && acq != VK_SUBOPTIMAL_KHR) {
      VR(acq, "vkAcquireNextImageKHR failed");
    }
  }

  vkResetFences(dev_.getDevice(), 1, &fence);

  const u32 imageIndex = 0; // offscreen framebuffer index (single target)

  vkResetCommandBuffer(cmd, 0);

  VkCommandBufferBeginInfo beginInfo {
    VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO
  };

  VR(vkBeginCommandBuffer(cmd, &beginInfo),
     "failed to begin recording command buffer!");

  // 1. Shadow Pass
  dev_.beginShadowPass(cmd);
  shadowCallback(cmd);
  vkCmdEndRenderPass(cmd);

  // 2. Main UI — callback owns begin/end of main pass(es) for blur interrupts.
  mainCallback(cmd, imageIndex);

  if (windowed_) {
    // 3a. Blit offscreen resolve → swapchain image, then present.
    VkImage swapImage = swapchainImages_[swapImageIndex];

    VkImageMemoryBarrier toDst {
      .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
      .srcAccessMask = 0,
      .dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
      .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED,
      .newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
      .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
      .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
      .image = swapImage,
      .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1},
    };
    vkCmdPipelineBarrier(
      cmd,
      VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
      VK_PIPELINE_STAGE_TRANSFER_BIT,
      0, 0, nullptr, 0, nullptr, 1, &toDst);

    VkImageBlit blit {
      .srcSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1},
      .srcOffsets = {{0, 0, 0},
                     {static_cast<int32_t>(extent_.width),
                      static_cast<int32_t>(extent_.height), 1}},
      .dstSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1},
      .dstOffsets = {{0, 0, 0},
                     {static_cast<int32_t>(swapchainExtent_.width),
                      static_cast<int32_t>(swapchainExtent_.height), 1}},
    };
    vkCmdBlitImage(
      cmd,
      resolveImage_, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
      swapImage, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
      1, &blit, VK_FILTER_LINEAR);

    VkImageMemoryBarrier toPresent {
      .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
      .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
      .dstAccessMask = 0,
      .oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
      .newLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
      .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
      .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
      .image = swapImage,
      .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1},
    };
    vkCmdPipelineBarrier(
      cmd,
      VK_PIPELINE_STAGE_TRANSFER_BIT,
      VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,
      0, 0, nullptr, 0, nullptr, 1, &toPresent);
  } else {
    // 3b. Offscreen: copy resolve → staging for readPixels().
    VkBufferImageCopy copyRegion {
      .bufferOffset      = 0,
      .bufferRowLength    = 0,
      .bufferImageHeight = 0,
      .imageSubresource =
        {
          .aspectMask     = VK_IMAGE_ASPECT_COLOR_BIT,
          .mipLevel       = 0,
          .baseArrayLayer = 0,
          .layerCount     = 1,
        },
      .imageOffset = {0, 0, 0},
      .imageExtent = {extent_.width, extent_.height, 1},
    };

    vkCmdCopyImageToBuffer(cmd,
                          resolveImage_,
                          VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                          stagingBuffer_,
                          1,
                          &copyRegion);
  }

  VR(vkEndCommandBuffer(cmd), "failed to record command buffer!");

  VkSubmitInfo submitInfo {
    .sType              = VK_STRUCTURE_TYPE_SUBMIT_INFO,
    .commandBufferCount = 1,
    .pCommandBuffers    = &cmd,
  };

  VkPipelineStageFlags waitStage = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
  // Present-wait semaphore is keyed by swapchain image index, not frame slot.
  VkSemaphore renderFinished = VK_NULL_HANDLE;
  if (windowed_) {
    assert(swapImageIndex < renderFinishedSemaphores_.size());
    renderFinished = renderFinishedSemaphores_[swapImageIndex];
    submitInfo.waitSemaphoreCount = 1;
    submitInfo.pWaitSemaphores = &imageAvailableSemaphores_[frame];
    submitInfo.pWaitDstStageMask = &waitStage;
    submitInfo.signalSemaphoreCount = 1;
    submitInfo.pSignalSemaphores = &renderFinished;
  }

  // Claimed before the submit and paired with this slot's fence, so
  // `oldestUnretiredSubmission()` can tell the device exactly how far this
  // window's GPU work has got.
  slotSubmission_[frame] = dev_.nextSubmission();

  VR(vkQueueSubmit(dev_.graphicsQueue(), 1, &submitInfo, fence),
     "failed to submit draw command buffer!");

  if (windowed_) {
    VkPresentInfoKHR presentInfo {
      .sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
      .waitSemaphoreCount = 1,
      .pWaitSemaphores = &renderFinished,
      .swapchainCount = 1,
      .pSwapchains = &swapchain_,
      .pImageIndices = &swapImageIndex,
    };
    VkResult pr = vkQueuePresentKHR(dev_.graphicsQueue(), &presentInfo);
    if (pr != VK_SUCCESS && pr != VK_SUBOPTIMAL_KHR &&
        pr != VK_ERROR_OUT_OF_DATE_KHR) {
      VR(pr, "vkQueuePresentKHR failed");
    }
  } else {
    // Offscreen readback needs the staging copy finished.
    vkDeviceWaitIdle(dev_.getDevice());
  }

  // Next record/submit uses the other slot (CPU can overlap with this GPU work).
  currentFrame_ = (currentFrame_ + 1) % kMaxFramesInFlight;
  ++frameCounter_;
  dev_.collectGarbage();

  // Presented content changed — any prior capture cache is stale.
  invalidateCaptureCache();
}

void RenderWindow::readPixels(uint8_t *dst, size_t dstSize)
{
  size_t n = std::min(dstSize, static_cast<size_t>(stagingBufferSize_));
  memcpy(dst, stagingBufferMapped_, n);
}

void RenderWindow::captureFrame(uint8_t *dst, size_t dstSize)
{
  assert(resolveImage_ != VK_NULL_HANDLE);
  assert(stagingBuffer_ != VK_NULL_HANDLE);
  assert(stagingBufferMapped_ != nullptr);

  // Main pass finalLayout leaves resolve as TRANSFER_SRC (also the present blit source).
  waitForAllFrames();

  VkCommandBuffer cmd = dev_.beginSingleTimeCommands();

  VkBufferImageCopy copyRegion{
    .bufferOffset = 0,
    .bufferRowLength = 0,
    .bufferImageHeight = 0,
    .imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1},
    .imageOffset = {0, 0, 0},
    .imageExtent = {extent_.width, extent_.height, 1},
  };
  vkCmdCopyImageToBuffer(cmd, resolveImage_,
                         VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, stagingBuffer_, 1,
                         &copyRegion);

  VkBufferMemoryBarrier bufBarrier{
    .sType = VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER,
    .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
    .dstAccessMask = VK_ACCESS_HOST_READ_BIT,
    .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
    .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
    .buffer = stagingBuffer_,
    .offset = 0,
    .size = VK_WHOLE_SIZE,
  };
  vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT,
                       VK_PIPELINE_STAGE_HOST_BIT, 0, 0, nullptr, 1,
                       &bufBarrier, 0, nullptr);

  dev_.endSingleTimeCommands(cmd);
  readPixels(dst, dstSize);

  // Refresh shared cache for subsequent region crops.
  const size_t need =
    static_cast<size_t>(extent_.width) * extent_.height * 4;
  if (dstSize >= need) {
    captureCache_.assign(dst, dst + need);
    captureCacheW_ = extent_.width;
    captureCacheH_ = extent_.height;
    captureCacheValid_ = true;
  } else {
    captureCacheValid_ = false;
  }
}

namespace {

struct PngWriteCtx {
  std::vector<uint8_t> *out = nullptr;
};

void pngWriteFunc(void *context, void *data, int size)
{
  auto *ctx = static_cast<PngWriteCtx *>(context);
  auto *bytes = static_cast<const uint8_t *>(data);
  ctx->out->insert(ctx->out->end(), bytes, bytes + size);
}

}  // namespace

#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"

bool RenderWindow::capturePng(std::vector<uint8_t> &outPng, int x, int y, int w, int h,
                        int maxSide, int *outW, int *outH)
{
  const int fullW = static_cast<int>(extent_.width);
  const int fullH = static_cast<int>(extent_.height);
  if (fullW < 1 || fullH < 1) return false;

  if (w <= 0 || h <= 0) {
    x = 0;
    y = 0;
    w = fullW;
    h = fullH;
  }

  // Clamp to framebuffer.
  if (x < 0) {
    w += x;
    x = 0;
  }
  if (y < 0) {
    h += y;
    y = 0;
  }
  if (x >= fullW || y >= fullH) return false;
  w = std::min(w, fullW - x);
  h = std::min(h, fullH - y);
  if (w < 1 || h < 1) return false;

  // One GPU readback per settled frame; further crops are pure CPU.
  if (!captureCacheValid_ || captureCacheW_ != extent_.width ||
      captureCacheH_ != extent_.height ||
      captureCache_.size() !=
        static_cast<size_t>(fullW) * static_cast<size_t>(fullH) * 4) {
    captureCache_.resize(static_cast<size_t>(fullW) * static_cast<size_t>(fullH) *
                         4);
    captureFrame(captureCache_.data(), captureCache_.size());
  }

  std::vector<uint8_t> region(static_cast<size_t>(w) * static_cast<size_t>(h) * 4);
  for (int row = 0; row < h; ++row) {
    const uint8_t *src =
      captureCache_.data() + (static_cast<size_t>(y + row) * fullW + x) * 4;
    uint8_t *dst = region.data() + static_cast<size_t>(row) * w * 4;
    std::memcpy(dst, src, static_cast<size_t>(w) * 4);
  }

  // Optional box downsample: longer side ≤ maxSide (agent overview budget).
  int encW = w;
  int encH = h;
  const uint8_t *pngPixels = region.data();
  std::vector<uint8_t> scaled;
  if (maxSide > 0) {
    const int longSide = std::max(w, h);
    if (longSide > maxSide) {
      encW = std::max(1, (w * maxSide + longSide / 2) / longSide);
      encH = std::max(1, (h * maxSide + longSide / 2) / longSide);
      scaled.resize(static_cast<size_t>(encW) * static_cast<size_t>(encH) * 4);
      // Box filter: average each dest pixel's source footprint.
      for (int dy = 0; dy < encH; ++dy) {
        const int y0 = dy * h / encH;
        const int y1 = std::max(y0 + 1, (dy + 1) * h / encH);
        for (int dx = 0; dx < encW; ++dx) {
          const int x0 = dx * w / encW;
          const int x1 = std::max(x0 + 1, (dx + 1) * w / encW);
          uint32_t sum[4] = {0, 0, 0, 0};
          uint32_t count = 0;
          for (int sy = y0; sy < y1; ++sy) {
            const uint8_t *row =
              region.data() + (static_cast<size_t>(sy) * w + x0) * 4;
            for (int sx = x0; sx < x1; ++sx) {
              sum[0] += row[0];
              sum[1] += row[1];
              sum[2] += row[2];
              sum[3] += row[3];
              row += 4;
              ++count;
            }
          }
          uint8_t *out =
            scaled.data() + (static_cast<size_t>(dy) * encW + dx) * 4;
          if (count == 0) {
            out[0] = out[1] = out[2] = out[3] = 0;
          } else {
            out[0] = static_cast<uint8_t>(sum[0] / count);
            out[1] = static_cast<uint8_t>(sum[1] / count);
            out[2] = static_cast<uint8_t>(sum[2] / count);
            out[3] = static_cast<uint8_t>(sum[3] / count);
          }
        }
      }
      pngPixels = scaled.data();
    }
  }

  outPng.clear();
  PngWriteCtx ctx{&outPng};
  const int ok =
    stbi_write_png_to_func(pngWriteFunc, &ctx, encW, encH, 4, pngPixels, encW * 4);
  if (ok == 0 || outPng.empty()) return false;
  if (outW) *outW = encW;
  if (outH) *outH = encH;
  return true;
}

bool RenderWindow::windowShouldClose() const
{
  return window_ && glfwWindowShouldClose(window_);
}

void RenderWindow::requestClose()
{
  if (window_) glfwSetWindowShouldClose(window_, GLFW_TRUE);
}

#ifdef INCLUDE_IMGUI
void RenderWindow::initImGuiGlfwBackend()
{
  if (windowed_ && window_ && dev_.imguiInitialized()) {
    ImGui_ImplGlfw_InitForVulkan(window_, true);
  }
}
#endif

void RenderWindow::setWindowFrame(int x, int y, int width, int height)
{
  if (!windowed_ || !window_) return;
  if (width < 1) width = 1;
  if (height < 1) height = 1;

  glfwSetWindowPos(window_, x, y);

  int curW = 0, curH = 0;
  glfwGetWindowSize(window_, &curW, &curH);
  if (curW != width || curH != height) {
    glfwSetWindowSize(window_, width, height);
  }
  // Framebuffer size may lag a frame; resize() in the render loop rebuilds
  // swapchain/targets when it changes.
}

void RenderWindow::setWindowVisible(bool visible)
{
  if (!windowed_ || !window_) return;
  if (visible) {
    glfwShowWindow(window_);
  } else {
    glfwHideWindow(window_);
  }
}

bool RenderWindow::resize()
{
  if (!windowed_ || !window_) return false;

  int fbW = 0, fbH = 0;
  glfwGetFramebufferSize(window_, &fbW, &fbH);
  if (fbW < 1 || fbH < 1) return false;

  if (static_cast<uint32_t>(fbW) == extent_.width &&
      static_cast<uint32_t>(fbH) == extent_.height &&
      static_cast<uint32_t>(fbW) == swapchainExtent_.width &&
      static_cast<uint32_t>(fbH) == swapchainExtent_.height) {
    return false;
  }

  // Only this window's work has to drain, but there is no cheap way to wait
  // for one window's submissions without also naming the shared resources its
  // command buffers reference, so this stays a device-wide idle. A resize is
  // rare and already janky; a second window blocking for a moment is not the
  // cost worth optimising here.
  vkDeviceWaitIdle(dev_.getDevice());

  // Render passes and pipelines survive — nothing about them is sized.
  destroySizedResources();
  cleanupSwapchain();

  extent_ = {static_cast<uint32_t>(fbW), static_cast<uint32_t>(fbH)};

  createSwapchain();
  createSizedResources();

  std::cout << "Framebuffer resized to " << extent_.width << "x"
            << extent_.height << '\n';
  return true;
}

// ─── Renderers ─────────────────────────────────────────────────────────────

void RenderWindow::initRenderers()
{
  if (renderersReady_) return;

  // Ordered 2D renderer: replays the draw list in index order across its quad
  // and line-strip pipelines, so paint order is emission order rather than the
  // old lines < geometry < text z-split.
  quads_.init();
  blur_.init();
  // Needs BlurPass's scene render pass, hence after its init rather than
  // inside quads_.init().
  quads_.createSceneTargetPipeline(blur_.sceneRenderPass());

  renderersReady_ = true;
}

void RenderWindow::setGlyphAtlas(VkImageView view, VkSampler sampler)
{
  quads_.setAtlas(view, sampler);
}

void RenderWindow::setViewTransform(float zoom, float panX, float panY)
{
  quads_.setViewTransform(zoom > 0.f ? zoom : 1.f, panX, panY);
}

void RenderWindow::pushBlurComposite(float x, float y, float w, float h,
                                     float viewW, float viewH, float radius)
{
  if (w <= 0.f || h <= 0.f || viewW <= 0.f || viewH <= 0.f) return;
  const vec2 uv = blur_.uvScaleFor(radius);
  quads_.pushBlurResultImage(
    {x, y}, {w, h},
    {x / viewW * uv.x, y / viewH * uv.y},
    {(x + w) / viewW * uv.x, (y + h) / viewH * uv.y}, 0xffffffffu);
}

void RenderWindow::replayDrawList(const canvas::DrawList &list, float viewW,
                                  float viewH,
                                  std::vector<Boundary> &outBoundaries)
{
  outBoundaries.clear();
  // Rect + radius of each open content-blur scope, so End knows what region
  // to composite. A stack even though the draw list forbids nesting today,
  // because an unbalanced End must not pop something that was never pushed.
  std::vector<canvas::DrawCommand> contentScopes;
  // Must match the slot waitForInFlightFrame() just freed / submit will use.
  quads_.begin({viewW, viewH}, currentFrameSlot());

  for (size_t cmdIndex = 0; cmdIndex < list.commandCount; ++cmdIndex) {
    const auto &cmd = list.commands[cmdIndex];
    switch (static_cast<canvas::DrawCommandKind>(cmd.kind)) {
    case canvas::DrawCommandKind::Rect:
      quads_.pushBox({cmd.x, cmd.y}, {cmd.w, cmd.h}, cmd.color, 0.f);
      break;
    case canvas::DrawCommandKind::RoundedRect:
      quads_.pushBox({cmd.x, cmd.y}, {cmd.w, cmd.h}, cmd.color, cmd.aux);
      break;
    case canvas::DrawCommandKind::Circle:
      quads_.pushCircle({cmd.x, cmd.y}, cmd.aux, cmd.color);
      break;
    case canvas::DrawCommandKind::Line:
      // x,y = p0 and w,h = p1 (see draw_command.hpp). aux carries stroke
      // width when the emitter sets it; 1.5px is the wire default.
      quads_.pushLine({cmd.x, cmd.y}, {cmd.w, cmd.h},
                      cmd.aux > 0.f ? cmd.aux : 1.5f, cmd.color);
      break;
    case canvas::DrawCommandKind::PushClip:
      quads_.pushScissor({cmd.x, cmd.y}, {cmd.w, cmd.h});
      break;
    case canvas::DrawCommandKind::PopClip:
      quads_.popScissor();
      break;
    case canvas::DrawCommandKind::Text: {
      // The producer shaped this run and positioned every glyph; all the
      // renderer does is resolve glyph ids to atlas rects. No shaping here
      // means a drawn run cannot drift from the run measured for layout.
      const uint32_t first = cmd.param;
      const uint32_t count = static_cast<uint32_t>(cmd.w);
      for (uint32_t g = 0; g < count; ++g) {
        const size_t idx = first + g;
        if (idx >= list.glyphCount) break;
        const auto &gi = list.glyphs[idx];
        TextRenderer::GlyphQuad q;
        if (!dev_.textRenderer().glyphQuad(gi.fontId, gi.glyphId, q)) continue;
        if (q.size.x <= 0.f || q.size.y <= 0.f) continue;  // e.g. space
        quads_.pushGlyph({gi.x + q.bearing.x, gi.y - q.bearing.y},
                         q.size, q.uv0, q.uv1, cmd.color);
      }
      break;
    }
    case canvas::DrawCommandKind::Mesh: {
      // The producer laid out every vertex (fan pivot, or inner/outer ring
      // pairs); the renderer only converts and triangulates.
      const uint32_t first = cmd.param;
      const uint32_t count = static_cast<uint32_t>(cmd.w);
      if (first + count > list.meshVertexCount) break;
      meshPointScratch_.clear();
      meshPointScratch_.reserve(count);
      for (uint32_t i = 0; i < count; ++i) {
        const auto &mv = list.meshVertices[first + i];
        meshPointScratch_.push_back({mv.x, mv.y});
      }
      quads_.pushMesh(meshPointScratch_.data(), count, cmd.color, cmd.aux > 0.f);
      break;
    }
    case canvas::DrawCommandKind::Polyline: {
      const uint32_t first = cmd.param;
      const uint32_t count = static_cast<uint32_t>(cmd.w);
      if (count < 2 || first + count > list.meshVertexCount) break;
      meshPointScratch_.clear();
      meshPointScratch_.reserve(count);
      for (uint32_t i = 0; i < count; ++i) {
        const auto &mv = list.meshVertices[first + i];
        meshPointScratch_.push_back({mv.x, mv.y});
      }
      quads_.pushPolyline(meshPointScratch_.data(), count, cmd.color);
      break;
    }
    case canvas::DrawCommandKind::SpatialTriangles: {
      const uint32_t first = cmd.param;
      const uint32_t count = static_cast<uint32_t>(cmd.w);
      if (count < 3 || first + count > list.spatialVertexCount) break;
      VkImageView texture = VK_NULL_HANDLE;
      vec2 uv0{0.f, 0.f}, uv1{1.f, 1.f};
      if (cmd.x >= 1.f) {
        auto &tm = TextureManager::getInstance();
        const auto id = static_cast<uint32_t>(cmd.x);
        texture = tm.getTextureView(id);
        tm.getTextureUV(id, uv0, uv1);
      }
      quads_.pushSpatialTriangles(list.spatialVertices + first, count, texture,
                                  uv0, uv1);
      break;
    }
    case canvas::DrawCommandKind::SpatialBegin:
      quads_.pushSpatialBegin({cmd.x, cmd.y}, {cmd.w, cmd.h});
      break;
    case canvas::DrawCommandKind::Image: {
      const uint32_t texId = cmd.param;
      auto &tm = TextureManager::getInstance();
      VkImageView view = tm.getTextureView(texId);
      if (view == VK_NULL_HANDLE) break;
      // UVs from the manager, not [0,1]: an atlased image is a cell inside a
      // shared page, and sampling the whole page would draw the neighbours.
      vec2 uv0, uv1;
      tm.getTextureUV(texId, uv0, uv1);
      quads_.pushImage({cmd.x, cmd.y}, {cmd.w, cmd.h}, uv0, uv1, cmd.color, view);
      break;
    }
    case canvas::DrawCommandKind::BeginBackdropBlur: {
      // Split so the GPU can end pass → blur → continue. The next segment
      // opens with a full-frame-UV composite of the glass rect.
      quads_.closeSegment();
      const float radius = cmd.aux > 0.f ? cmd.aux : 8.f;
      outBoundaries.push_back({Boundary::Kind::Backdrop, radius});
      pushBlurComposite(cmd.x, cmd.y, cmd.w, cmd.h, viewW, viewH, radius);
      break;
    }
    case canvas::DrawCommandKind::EndBackdropBlur:
      // Bookkeeping / future nesting — no GPU work.
      break;

    case canvas::DrawCommandKind::BeginContentBlur: {
      // The subtree lands in its own segment, drawn into the offscreen target
      // rather than the frame, so nothing is composited here.
      quads_.closeSegment();
      outBoundaries.push_back(
        {Boundary::Kind::ContentBegin, cmd.aux > 0.f ? cmd.aux : 8.f});
      contentScopes.push_back(cmd);
      break;
    }
    case canvas::DrawCommandKind::EndContentBlur: {
      if (contentScopes.empty()) break;
      const canvas::DrawCommand open = contentScopes.back();
      contentScopes.pop_back();
      quads_.closeSegment();
      const float radius = open.aux > 0.f ? open.aux : 8.f;
      outBoundaries.push_back({Boundary::Kind::ContentEnd, radius});

      // Grown by three sigma on every side: a blurred view's edge fades
      // *outward*, and clipping the composite to the layout rect would slice
      // that falloff off square, which is the one artefact that makes a blur
      // read as a bug rather than as softness.
      const float pad = std::ceil(radius * 3.f);
      const float x0 = std::max(0.f, open.x - pad);
      const float y0 = std::max(0.f, open.y - pad);
      const float x1 = std::min(viewW, open.x + open.w + pad);
      const float y1 = std::min(viewH, open.y + open.h + pad);
      pushBlurComposite(x0, y0, x1 - x0, y1 - y0, viewW, viewH, radius);
      break;
    }
    }
  }
  quads_.end();
}

void RenderWindow::render(const canvas::DrawList &list)
{
  // Wait for *this* frame slot only (2-in-flight). The other slot may still be
  // on the GPU while we fill host-visible buffers for this one.
  waitForInFlightFrame();

  // The atlas is shared across windows, so growing it is the device's call.
  dev_.syncGlyphAtlas();

  const auto ext = getExtent();
  const float viewW = static_cast<float>(ext.width);
  const float viewH = static_cast<float>(ext.height);

  // Each boundary is a point where the GPU has to stop drawing the frame and
  // do something else. Segment i is drawn, boundaries[i] runs, then segment
  // i+1 — whose first quad is usually the composite of whatever the boundary
  // produced. (Backdrop compositing must land in MSAA, not just the resolve,
  // or the next pass's resolve wipes it.)
  //
  // Sizing has to happen *before* replay, not after: replay bakes the
  // composite quads' UVs, and those depend on the allocation. Reallocating
  // also waits on every frame in flight, so it cannot happen mid-recording
  // either. Hence a cheap pre-scan for the radii.
  //
  // The *finest* radius drives the allocation, since that is the one needing
  // the most resolution; wider blurs then take a sub-region at their own
  // coarser grid rather than forcing the fine one down to theirs.
  float finestRadius = BlurPass::kMaxRadius;
  bool  anyBlur      = false;
  for (size_t cmdIndex = 0; cmdIndex < list.commandCount; ++cmdIndex) {
    const auto kind =
      static_cast<canvas::DrawCommandKind>(list.commands[cmdIndex].kind);
    if (kind != canvas::DrawCommandKind::BeginBackdropBlur &&
        kind != canvas::DrawCommandKind::BeginContentBlur) {
      continue;
    }
    anyBlur = true;
    const float aux = list.commands[cmdIndex].aux;
    finestRadius = std::min(finestRadius, aux > 0.f ? aux : 8.f);
  }
  if (anyBlur) {
    blur_.ensureSize(ext.width, ext.height, finestRadius);
  }

  std::vector<Boundary> boundaries;
  replayDrawList(list, viewW, viewH, boundaries);

  submitFrame(
    // Shadow pass kept only because submitFrame is the sole render entry
    // point; nothing 3D draws into it any more.
    [&](VkCommandBuffer) {},
    [&](VkCommandBuffer commandBuffer, u32 /*imageIndex*/) {
      const auto extent = getExtent();

      // Always open the clear pass so an empty first segment still clears the
      // framebuffer before a leading blur.
      beginMainRenderPass(commandBuffer, /*clear=*/true);
      quads_.drawSegment(commandBuffer, 0);

      uint32_t segment = 0;
      for (const auto &b : boundaries) {
        ++segment;
        if (!blur_.ready() || !blur_.sceneReady()) {
          // No blur resources: draw the segment unblurred rather than
          // half-executing a boundary and leaving passes unbalanced.
          quads_.drawSegment(commandBuffer, segment);
          continue;
        }

        switch (b.kind) {
        case Boundary::Kind::Backdrop:
          // The frame so far *is* the source, so it has to be resolved before
          // it can be read.
          endMainRenderPass(commandBuffer);
          blur_.captureAndBlur(commandBuffer, resolveImage(),
                               VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, b.radius);
          quads_.setBlurResultView(blur_.resultView(), blur_.sampler());
          beginMainRenderPass(commandBuffer, /*clear=*/false);
          quads_.drawSegment(commandBuffer, segment);
          break;

        case Boundary::Kind::ContentBegin:
          // The subtree is the source, so it is drawn on its own into a
          // cleared target rather than on top of the frame.
          endMainRenderPass(commandBuffer);
          blur_.beginSceneCapture(commandBuffer);
          quads_.drawSegment(commandBuffer, segment, /*intoSceneTarget=*/true);
          break;

        case Boundary::Kind::ContentEnd:
          blur_.endSceneCapture(commandBuffer);
          blur_.captureAndBlur(commandBuffer, blur_.sceneImage(),
                               VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, b.radius);
          quads_.setBlurResultView(blur_.resultView(), blur_.sampler());
          beginMainRenderPass(commandBuffer, /*clear=*/false);
          quads_.drawSegment(commandBuffer, segment);
          break;
        }
      }

      endMainRenderPass(commandBuffer);

      // Full-window scissor restored for anything that might follow (the
      // present blit does not need it, but keep the state consistent).
      VkRect2D fullScissor{.offset = {0, 0}, .extent = extent};
      vkCmdSetScissor(commandBuffer, 0, 1, &fullScissor);
    });
}
