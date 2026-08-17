#pragma once

#include <iostream>
#include <stdexcept>
#include <memory>
#include <atomic>
#include <mutex>
#include <shared_mutex>
#include <vector>

#include <boost/stacktrace.hpp>

#include <vulkan/vulkan.h>
#include <vulkan/vulkan_core.h>

#include "vk_mem_alloc.h"

struct GLFWwindow;

#include "util/types.hpp"
#include "util/cout_ext.hpp"
#include "render/gpu_ledger.hpp"
#include "render/vulkan_ptr.hpp"

extern bool g_ValidationFromResult;

#define VR(x, message)                        \
  if (x != VK_SUCCESS) {                      \
    g_ValidationFromResult = true;            \
    std::cerr << clr::red                     \
      << "Vulkan Error: " << message << '\n'  \
      << "\tVkResult: " << x << '\n'          \
      << "\tStack trace:\n"                   \
      << boost::stacktrace::stacktrace()      \
      << clr::reset << std::endl;             \
    throw std::runtime_error(message);        \
  }

class Shaders;
class TextRenderer;

namespace vk {

/// GPU buffer owned through Vulkan/VMA. Prefer `RenderDevice::destroyBuffer` over
/// freeing memory by hand — VMA suballocates and raw `vkFreeMemory` is wrong.
struct Buffer {
  VkBuffer      buffer     = VK_NULL_HANDLE;
  VmaAllocation allocation = VK_NULL_HANDLE;
  u32           size       = 0;

  operator bool() const noexcept { return buffer != VK_NULL_HANDLE; }
};

};

class RenderWindow;

/// The GPU, and everything on it that outlives any one window.
///
/// Instance, physical and logical device, allocator, queue, command pool,
/// render passes, and the buffer/image helpers every renderer calls. Windows
/// attach to it (`RenderWindow`) and share all of it: the glyph atlas, the
/// texture manager and the pipeline set are created once no matter how many
/// surfaces are open. That sharing is the point — a second window should cost
/// its attachments, not a second copy of every font it draws.
///
/// The device is created before any window exists. Picking a physical device
/// needs a surface to test present support against, so `init(presentCapable)`
/// makes a throwaway hidden window, probes it, and destroys it. Without that,
/// device creation is chained to the first window's lifetime and the second
/// window has to hope the queue family it inherited happens to fit.
class RenderDevice
{
 public:
  /// How many samples the scene attachments may use at most.
  ///
  /// 4 rather than "whatever the device allows", which is what this used to
  /// take. The count multiplies both of the largest allocations a window makes
  /// — a multisampled colour attachment and a multisampled depth attachment —
  /// so on a device offering 8 it was 128 MiB per 1920×1080 surface, and a
  /// compositor holds one such surface per window plus one per title bar,
  /// shadow and frost. 4 halves that for a difference visible only on the
  /// diagonal edge of a rounded corner.
  ///
  /// Overridden per process by `LAVA_MSAA` (1, 2, 4, 8 …), which is how to
  /// compare them without a rebuild, and per session by `[render] msaa` in
  /// `lava.conf`, which the compositor passes to `setSampleCap`.
  static constexpr uint32_t kDefaultSampleCap = 4;

 private:
  bool enableValidationLayers_ = false;
  // Vulkan instance
  VkInstance instance_ = VK_NULL_HANDLE;
  // Debug handle
  VkDebugUtilsMessengerEXT debugMessenger_ = VK_NULL_HANDLE;
  // Used to enumerate physical devices
  VkPhysicalDevice physicalDevice_ = VK_NULL_HANDLE;
  // Cached device properties for the selected device
  VkPhysicalDeviceProperties physicalDeviceProperties_;
  // Logical device
  VkDevice device_ = VK_NULL_HANDLE;
  // Whether VK_KHR_present_mode_fifo_latest_ready was found and enabled at
  // device creation. The present mode it unlocks may only be requested when
  // this is true — see createSwapchain.
  bool fifoLatestReadyEnabled_ = false;
  /// Set when the physical device supports it *and* we asked for it on the
  /// logical device. Sampler creation must not enable anisotropy otherwise.
  bool samplerAnisotropy_ = false;
  // GPUOpen VMA — all createBuffer/createImage go through this.
  // Allocations live next to their VkBuffer/VkImage at each call site.
  VmaAllocator allocator_ = VK_NULL_HANDLE;
  // Graphics/present queues exposed by the selected family. A RenderWindow
  // leases one for its lifetime, allowing different windows to submit and
  // present concurrently without violating VkQueue external synchronization.
  u32     graphicsAndPresentationQueueFamilyIdx_ = -1;
  VkQueue graphicsQueue_ = VK_NULL_HANDLE;
  struct QueueSlot {
    VkQueue queue = VK_NULL_HANDLE;
    std::mutex mutex;
  };
  std::vector<std::unique_ptr<QueueSlot>> graphicsQueues_;
  std::atomic<uint32_t> nextQueue_{0};

  /// Whether the device was brought up able to present. Drives the instance
  /// and device extension sets, and whether a queue family has to prove it can
  /// present before being chosen.
  bool presentCapable_ = false;

  // ─── dmabuf export ───────────────────────────────────────────────────────
  //
  // Set by `exportToDrmDevice` before `init`, for the one caller whose images
  // are read by a driver that is not this one: the compositor, handing a
  // rendered surface to wlroots.

  /// DRM node the chosen GPU must be behind, or -1 when nothing outside this
  /// process will read our images.
  ///
  /// Not owned, and not a preference — a pin. A dmabuf can cross devices in
  /// principle and is miserable in practice, so "whichever GPU enumerates
  /// first" is the wrong rule as soon as a second process has to read the
  /// result. On a hybrid laptop it is also usually the wrong *device*.
  int exportDrmFd_ = -1;
  /// True when a semaphore signalled here can be handed out as a sync_file,
  /// which is what lets a consumer be told to wait instead of us blocking
  /// until the work is done. Queried, not assumed: having
  /// `VK_KHR_external_semaphore_fd` is not the same as supporting the handle
  /// type, and the fallback is correct, just slower.
  bool exportSyncFd_ = false;
  /// See `setExportFenceHonoured`. A property of the consumer, so it is set
  /// from outside and never inferred here.
  bool exportFenceHonoured_ = false;
  PFN_vkGetMemoryFdKHR getMemoryFd_ = nullptr;
  PFN_vkGetMemoryFdPropertiesKHR getMemoryFdProperties_ = nullptr;
  PFN_vkGetImageDrmFormatModifierPropertiesEXT getModifierProps_ = nullptr;
  PFN_vkGetSemaphoreFdKHR getSemaphoreFd_ = nullptr;

  /// Whether `device` is the GPU behind `exportDrmFd_`.
  bool matchesExportDrmDevice(VkPhysicalDevice device) const;
  /// Live only during `init`: the throwaway surface present support is tested
  /// against, since no real window exists yet. See `init`.
  VkSurfaceKHR probeSurface_ = VK_NULL_HANDLE;

  /// The glyph atlas and font faces, shared by every window. This is the
  /// cache multi-window exists to reuse: a second window drawing the same
  /// text rasterizes nothing new.
  std::unique_ptr<TextRenderer> text_;

  /// Every open window, so device-wide questions ("is anything still using
  /// this?", "wait for all GPU work") can be answered without a window having
  /// to volunteer itself. Windows register in their constructor.
  std::vector<RenderWindow *> windows_;

  /// Monotonically increasing, one per queue submission across all windows.
  /// This is the clock deferred destruction is measured on — a frame counter
  /// cannot be, because with two windows "three frames have passed" says
  /// nothing about whether the *other* window's frame has retired.
  std::atomic<uint64_t> nextSubmission_{1};
  mutable std::recursive_mutex sharedStateMutex_;

  /// Separates "a window drawing a frame" from "something the whole device
  /// shares changing underneath it".
  ///
  /// Shared by every `RenderWindow::render`: two windows drawing at once
  /// conflict over nothing, because their fences, command pools, descriptor
  /// sets and buffers are all their own. Exclusive for the operations that
  /// reach across windows — growing the glyph atlas, collecting garbage,
  /// resizing a swapchain. Those used to be safe because "no frame in flight"
  /// also meant "no frame being recorded"; with a worker per window it does
  /// not, and a fence read or an atlas free lands in the middle of someone
  /// else's recording.
  ///
  /// Never taken exclusively from inside a frame: `std::shared_mutex` does
  /// not upgrade, and the deadlock is immediate. That is why `syncGlyphAtlas`,
  /// `collectGarbage` and `resize` moved out of `render()` and into the
  /// prepare/retire steps either side of it.
  mutable std::shared_mutex frameMutex_;

  /// Serializes the whole `beginSingleTimeCommands`..`endSingleTimeCommands`
  /// span, not just its ends.
  ///
  /// `commandPool_` below is one object shared by every caller, and Vulkan
  /// requires external synchronization of a command pool for allocate, free
  /// *and* for recording into any buffer it owns. Locking only the allocate
  /// would still let two threads record concurrently. Every caller here is a
  /// rare, slow path that already blocks on `vkQueueWaitIdle`, so serializing
  /// them costs nothing worth reclaiming.
  ///
  /// Locked and unlocked by hand across that pair, with no lock object between
  /// them — see `beginSingleTimeCommands` for why a member `unique_lock` is
  /// actively wrong here.
  std::mutex singleTimeMutex_;

  /// GPU resources waiting for every submission that might reference them.
  struct PendingDestroy {
    VkImage       image      = VK_NULL_HANDLE;
    VmaAllocation allocation = VK_NULL_HANDLE;
    VkImageView   view       = VK_NULL_HANDLE;
    /// Submission index at the moment of the request. Anything submitted at
    /// or after this point was recorded after the handle was nulled, so it
    /// cannot name the resource.
    uint64_t      queuedAt   = 0;
  };
  std::vector<PendingDestroy> trash_;

  /// Format every window renders into. Fixed, and deliberately not the
  /// swapchain's: the swapchain is a blit destination, so surfaces disagreeing
  /// about their preferred format costs a blit, not a second render pass.
  VkFormat colorFormat_ = VK_FORMAT_R8G8B8A8_SRGB;

  VkPhysicalDeviceMemoryProperties deviceMemoryProperties_;
  VkRenderPass                     renderPass_ = VK_NULL_HANDLE;
  /// Same attachments as renderPass_ but LOAD (continue after backdrop blur).
  VkRenderPass                     renderPassContinue_ = VK_NULL_HANDLE;
  VkCommandPool                    commandPool_ = VK_NULL_HANDLE;

  /// Sample count every render pass and pipeline is built for. Device-wide,
  /// so every window's attachments must agree with it.
  VkSampleCountFlagBits msaaSamples_ = VK_SAMPLE_COUNT_1_BIT;

  /// The most `msaaSamples_` may be. See `setSampleCap`.
  uint32_t sampleCap_ = kDefaultSampleCap;

  /// Who asked for each allocation. Thread-safe on its own; allocations happen
  /// from window render workers as well as the main thread.
  canvas::GpuLedger gpuLedger_;


#ifdef INCLUDE_IMGUI
  // ImGui
  VkDescriptorPool imguiDescriptorPool_ = VK_NULL_HANDLE;
  bool             imguiInitialized_ = false;
#endif

  // Step 0: Enable validation layers
  static VKAPI_ATTR VkBool32 VKAPI_CALL
  debugCallback(VkDebugUtilsMessageSeverityFlagBitsEXT      messageSeverity,
                VkDebugUtilsMessageTypeFlagsEXT             messageType,
                const VkDebugUtilsMessengerCallbackDataEXT *pCallbackData,
                void                                       *pUserData);

  static bool checkValidationLayerSupport(
    const std::vector<const char *> &validationLayers);

  static VkResult createDebugUtilsMessengerEXT(
    VkInstance                                instance,
    const VkDebugUtilsMessengerCreateInfoEXT *pCreateInfo,
    const VkAllocationCallbacks              *pAllocator,
    VkDebugUtilsMessengerEXT                 *pDebugMessenger);

  static void destroyDebugUtilsMessengerEXT(
    VkInstance                   instance,
    VkDebugUtilsMessengerEXT     debugMessenger,
    const VkAllocationCallbacks *pAllocator);

  static VkDebugUtilsMessengerCreateInfoEXT createDebugMessengerInfo();

  void setupDebugMessenger();

  // Step 1: Create instance -> Enumerate physical devices -> Create Device
  void createVkInstance(const char *applicationName);
  bool checkExtensionsSupport(
    const std::vector<const char *> &requiredExtensions);
  VkSampleCountFlagBits getMaxUsableSampleCount();
  void                  selectSupportedGraphicsCard();

  // Step 2: Creates logical device and one graphics queue
  void createLogicalDevice();
  void createAllocator();
  void destroyAllocator();

  uint32_t findMemoryProperties(uint32_t              memoryTypeBitsRequirement,
                                VkMemoryPropertyFlags requiredProperties);

  vk::Buffer createImmutableBuffer(
    const void           *bufferData,
    VkDeviceSize          bufferSize,
    VkBufferUsageFlagBits usageFlagBits);

  VkFormat findSupportedFormat(const std::vector<VkFormat>& candidates, VkImageTiling tiling, VkFormatFeatureFlags features);
  bool hasStencilComponent(VkFormat format);


  // Step 3: Create render pass, command pool
  /// Clear pass (first UI segment) + continue pass (LOAD after blur).
  void createRenderPass();
  void createCommandPool();
  void createDescriptorPool();
  void createDescriptorSet();
#ifdef INCLUDE_IMGUI
  void initImGui();
#endif

 public:
  /// Creates instance, picks a GPU, and brings up the device and everything
  /// shared between windows.
  ///
  /// `presentCapable` enables the surface/swapchain extensions and picks a
  /// queue family that can present — checked against a throwaway hidden GLFW
  /// window, since present support is a property of a (device, family,
  /// surface) triple and there is no real surface yet. Pass false for headless
  /// use (smoke tests, offscreen render).
  void init(const char *applicationName, bool presentCapable);

  /// Pins device selection to the GPU behind `drmFd` and brings the device up
  /// able to export images as dmabufs. Call before `init`.
  ///
  /// Takes the descriptor rather than a device id because the caller has one
  /// and nothing else: wlroots hands out `wlr_renderer_get_drm_fd`, and which
  /// GPU that names is a question for `fstat`, not for the caller. The
  /// descriptor is only read during `init` and is not owned here.
  ///
  /// This is the whole of what "render for someone else" means to the device.
  /// It changes which GPU is chosen and which extensions are enabled; nothing
  /// downstream of it — render passes, pipelines, the atlas — knows or cares.
  void exportToDrmDevice(int drmFd) { exportDrmFd_ = drmFd; }

  /// True once `init` has brought up a device that can export dmabufs.
  bool canExportDmabuf() const { return getMemoryFd_ != nullptr; }
  /// True when this device can also *import* a dma-buf another driver wrote.
  /// Same extensions as export; the extra entry point is
  /// `vkGetMemoryFdPropertiesKHR`.
  bool canImportDmabuf() const { return getMemoryFdProperties_ != nullptr; }
  /// True when the handover can be fenced rather than waited on.
  bool canExportSyncFd() const { return exportSyncFd_; }

  /// Whether the consumer waits on the fence an exported frame publishes.
  ///
  /// Off by default, and that default is the expensive one: a frame ends by
  /// blocking until the GPU has finished it, because a consumer that never
  /// looks at the fence would otherwise read a surface still being written.
  /// Measured on NVIDIA, which has never honoured the fence hung off a buffer,
  /// that read the surface early about one run in five.
  ///
  /// Turning it on is a promise by whoever owns the buffers that they take the
  /// fence and wait on it themselves — for the compositor, that it hands the
  /// point to `wlr_scene_buffer`'s wait timeline. It is what lets a frame end
  /// when the work is *queued* instead of when it is done, and what keeps the
  /// event loop out of a GPU wait it has no business in.
  void setExportFenceHonoured(bool honoured) { exportFenceHonoured_ = honoured; }
  bool exportFenceHonoured() const { return exportFenceHonoured_; }

  // Extension entry points are not in the loader's static table, so they are
  // resolved once at `init` and handed out rather than looked up per call.
  PFN_vkGetMemoryFdKHR getMemoryFd() const { return getMemoryFd_; }
  PFN_vkGetMemoryFdPropertiesKHR getMemoryFdProperties() const
  {
    return getMemoryFdProperties_;
  }
  PFN_vkGetImageDrmFormatModifierPropertiesEXT getModifierProps() const
  {
    return getModifierProps_;
  }
  PFN_vkGetSemaphoreFdKHR getSemaphoreFd() const { return getSemaphoreFd_; }

  VkFormat colorFormat() const { return colorFormat_; }

  // ─── Windows ─────────────────────────────────────────────────────────────

  /// Called by `RenderWindow`'s constructor/destructor. Not for general use —
  /// the device only needs the list to answer questions that span windows.
  void registerWindow(RenderWindow *window);
  void unregisterWindow(RenderWindow *window);

  /// A copy of the window list, for a report that has to say what each window
  /// costs.
  ///
  /// Same contract as `registerWindow`: called on the thread that opens and
  /// closes windows, which is the one a compositor's control plane already runs
  /// on. Unlocked for that reason, like the two above it.
  std::vector<RenderWindow *> windowsSnapshot() const;

  /// Reserves the next submission index. Called by `RenderWindow::render`
  /// immediately before `vkQueueSubmit`.
  uint64_t nextSubmission() { return nextSubmission_.fetch_add(1); }

  /// The index the next submission *will* claim, without claiming it.
  ///
  /// Stamping a resource released right now with this mark says: every
  /// submission from here on was recorded after the last reference to it went
  /// away, so only submissions before the mark can still name it. Waiting for
  /// the retire clock to pass the mark is then equivalent to blocking on every
  /// fence, and costs nothing — which is what lets a caller that is *inside* a
  /// frame release something safely. See `collectGarbage`.
  uint64_t pendingSubmissionMark() const { return nextSubmission_.load(); }

  struct QueueLease {
    VkQueue queue = VK_NULL_HANDLE;
    std::mutex *mutex = nullptr;
  };
  /// Assigns queues round-robin. More windows than hardware queues safely
  /// share a slot; its mutex supplies Vulkan's required external sync.
  QueueLease leaseGraphicsQueue();

  using FrameLock = std::shared_lock<std::shared_mutex>;
  /// Held by a window for the whole of one frame. See `frameMutex_`.
  [[nodiscard]] FrameLock lockForFrame() { return FrameLock(frameMutex_); }

  /// Block until *every* window has finished every frame it has in flight.
  /// This is the one to call before destroying or replacing anything shared —
  /// growing the glyph atlas, recreating a buffer every window samples. A
  /// single window's `waitForAllFrames()` is not enough: the other window's
  /// command buffer names the same atlas.
  ///
  /// Reads fences belonging to windows other threads are driving, so it is
  /// only legal between frames, under the exclusive `frameMutex_`. Anything
  /// resizing a resource that is merely *per-window* — a quad buffer, a blur
  /// target — wants that window's own `waitForAllFrames()` instead, which is
  /// both correct here and a shorter wait.
  void waitForAllFramesInFlight();

  /// Destroys an image once no submission that might reference it is still
  /// running.
  ///
  /// The immediate `destroyImage` is only safe for something the GPU has
  /// provably finished with. Anything that was drawn recently — a texture the
  /// app just stopped using, an atlas page being retired — may still be
  /// referenced by a command buffer that has been submitted and not yet
  /// completed, and freeing it there is a use-after-free the validation layer
  /// reports as a crash somewhere else entirely.
  ///
  /// Queued here instead and released by `collectGarbage()`. Handles are
  /// nulled so the caller cannot use them again.
  void destroyImageDeferred(VkImage &image, VmaAllocation &allocation,
                            VkImageView &view);

  /// Releases anything queued by `destroyImageDeferred` whose submission has
  /// retired *in every window*.
  ///
  /// Called once per frame group, between frames — not at the end of a
  /// window's own frame. Asking whether a submission has retired means reading
  /// every window's fences, and a window that is submitting on another thread
  /// owns its fence exclusively while it does.
  ///
  /// Returns the retire mark it computed: the oldest submission still running
  /// anywhere, so anything stamped at or below it is provably unreferenced.
  /// Other caches that defer releases on the same clock — `TextureManager` and
  /// its atlas cells — drain against this, and must be called *after* this
  /// returns rather than from inside it, so their own locks are never taken
  /// underneath `sharedStateMutex_`.
  uint64_t collectGarbage();

  void cleanUp();

#ifdef INCLUDE_IMGUI
  bool imguiInitialized() const { return imguiInitialized_; }
#endif

  VkShaderModule createShaderModule(const std::vector<char> &code);

  vk::Buffer createImmutableVertexBuffer(
    const void *bufferData, VkDeviceSize bufferSize);

  vk::Buffer createImmutableIndexBuffer(
    const void *bufferData, VkDeviceSize bufferSize);

  vk::Buffer createImmutableUniformBuffer(
    const void *bufferData, VkDeviceSize bufferSize);

  VkSampler createTextureSampler();

  /// `tag` says who the memory is for; it is recorded in `gpuLedger()` and is
  /// the difference between a VRAM report that names an owner and one that
  /// says "1 GB of images". Defaulted so a caller allocating something too
  /// small to care about does not have to answer.
  void createBuffer(VkDeviceSize            size,
                    VkBufferUsageFlags      usage,
                    VkMemoryPropertyFlags   properties,
                    VkBuffer               &buffer,
                    VmaAllocation          &allocation,
                    const canvas::GpuTag   &tag = {});

  /// Destroy a buffer created with `createBuffer` (VMA-owned). Nulls both.
  void destroyBuffer(VkBuffer &buffer, VmaAllocation &allocation);

  /// Map/unmap host-visible buffers created with `createBuffer`.
  void *mapBuffer(VmaAllocation allocation);
  void  unmapBuffer(VmaAllocation allocation);

  void copyBuffer(VkBuffer srcBuffer, VkBuffer dstBuffer, VkDeviceSize size);

  std::tuple<VkBuffer, VmaAllocation> createUniformBuffer(
    VkDeviceSize bufferSize);

  VkCommandBuffer beginSingleTimeCommands();

  // It blocks until the command buffer finishes execution
  void endSingleTimeCommands(VkCommandBuffer commandBuffer);

  VkDevice                          getDevice() { return device_; }
  VkInstance                        instance() const { return instance_; }
  VkPhysicalDevice                  physicalDevice() const { return physicalDevice_; }
  // No `graphicsQueue()` accessor on purpose. Handing out a bare VkQueue is
  // how a submit ends up bypassing the lease's mutex, which is the bug this
  // class exists to make unrepresentable. Take a `leaseGraphicsQueue()`.
  uint32_t graphicsQueueFamily() const
  {
    return graphicsAndPresentationQueueFamilyIdx_;
  }
  bool fifoLatestReadyEnabled() const { return fifoLatestReadyEnabled_; }

  VmaAllocator                      getAllocator() { return allocator_; }
  VkCommandPool                     getCommandPool() { return commandPool_; }
  VkRenderPass                      getRenderPass() { return renderPass_; }
  VkRenderPass                      renderPassContinue() const { return renderPassContinue_; }
  const VkPhysicalDeviceProperties &getDeviceProperties()
  {
    return physicalDeviceProperties_;
  }

  auto     getMSAASamples() const noexcept { return msaaSamples_; }
  Shaders &getShaders();

  /// Caps the sample count — see `kDefaultSampleCap`.
  ///
  /// Must be called before `init` — the render passes and every pipeline are
  /// built against the count this settles, and changing it afterwards would
  /// mean rebuilding all of them.
  ///
  /// Clamped to a power of two in 1…64. 0 means "leave the default".
  void setSampleCap(uint32_t samples);

  /// Every allocation this device has made, and who asked for it.
  canvas::GpuLedger       &gpuLedger() { return gpuLedger_; }
  const canvas::GpuLedger &gpuLedger() const { return gpuLedger_; }

  /// What the driver and VMA say, as opposed to what the ledger accounts for.
  ///
  /// The two disagree by design and the difference is informative: VMA rounds
  /// allocations up into blocks and keeps empty ones for reuse, so
  /// `vmaBlockBytes - vmaAllocatedBytes` is slack this process could in
  /// principle give back, and `heapUsage - vmaBlockBytes` is everything the
  /// driver counts that VMA never allocated — swapchains, exported dma-bufs,
  /// and the driver's own working set.
  struct GpuMemoryTotals {
    std::string deviceName;
    /// Sum of live VMA allocations, i.e. what was asked for.
    uint64_t vmaAllocatedBytes = 0;
    /// Sum of the device-memory blocks VMA is holding to serve them.
    uint64_t vmaBlockBytes = 0;
    /// `VmaBudget` for the device-local heap: what the driver attributes to
    /// this process, and what it will let it have.
    uint64_t heapUsageBytes  = 0;
    uint64_t heapBudgetBytes = 0;
    uint64_t heapSizeBytes   = 0;
    uint32_t maxSamples      = 1;
    /// Sample count the render passes actually use — `getMaxUsableSampleCount`
    /// today, which is why it is worth reporting next to the attachments it
    /// multiplies.
    uint32_t samples = 1;
  };
  GpuMemoryTotals gpuMemoryTotals() const;

  /// Copies an image's mip 0 into host RGBA8. Blocking, and for debug tooling
  /// only — it waits for the device and allocates a staging buffer per call.
  ///
  /// `R8_UNORM` is expanded to grey RGBA so a glyph atlas can be looked at as a
  /// picture; RGBA8/BGRA8 come through as they are, with BGRA swizzled.
  /// `currentLayout` is restored before returning.
  bool readImagePixels(VkImage image, uint32_t width, uint32_t height,
                       VkFormat format, VkImageLayout currentLayout,
                       std::vector<uint8_t> &outRgba);

  /// Shared glyph atlas and font registry. Valid between `init` and `cleanUp`.
  TextRenderer &textRenderer();

  /// Grows the glyph atlas if the frame about to be recorded needs more room,
  /// and rebinds it in every window.
  ///
  /// Both halves have to be device-wide. Growing replaces the atlas image, so
  /// it must wait on every window's frames, not just the one about to draw —
  /// another window's submitted command buffer samples the same image. And the
  /// descriptor each window holds points at the old view, so every one of them
  /// needs rebinding or it samples freed memory.
  ///
  /// Both halves are also why this runs *between* frames rather than at the
  /// top of one. Growing frees the old atlas image immediately and rewrites
  /// every window's descriptor set; a window recording on another thread is
  /// naming that image and binding that set. Waiting on frames in flight does
  /// not cover it — the dangerous frame has not been submitted yet.
  void syncGlyphAtlas();

  /// Depth format the render passes were built with. Windows need it to make
  /// a matching attachment.
  VkFormat findDepthFormat();



  /// See `createBuffer` for `tag`.
  void createImage(uint32_t              width,
                   uint32_t              height,
                   uint32_t              mipLevels,
                   VkSampleCountFlagBits samples,
                   VkFormat              format,
                   VkImageTiling         tiling,
                   VkImageUsageFlags     usage,
                   VkMemoryPropertyFlags properties,
                   VkImage              &image,
                   VmaAllocation        &allocation,
                   const canvas::GpuTag &tag = {});

  /// Destroy an image created with `createImage` (VMA-owned). Nulls both.
  /// Does not destroy image views — caller frees views first.
  void destroyImage(VkImage &image, VmaAllocation &allocation);

  void transitionImageLayout(VkImage               image,
                             VkFormat              format,
                             VkImageLayout         oldLayout,
                             VkImageLayout         newLayout,
                             uint32_t              mipLevels = 1);

  void copyBufferToImage(VkBuffer buffer,
                         VkImage  image,
                         uint32_t width,
                         uint32_t height);

  /// True when `format` can be linearly blitted — the requirement for
  /// `generateMipmaps`. R8G8B8A8_SRGB does on every GPU we ship on.
  bool formatSupportsLinearBlit(VkFormat format) const;

  /// Blit mip 0 down the chain. Every level must already be TRANSFER_DST
  /// with level 0 filled; leaves the whole image SHADER_READ_ONLY.
  void generateMipmaps(VkImage image, int32_t width, int32_t height,
                       uint32_t mipLevels);

  /// Copies into a sub-rect, for packing many images into one atlas page.
  void copyBufferToImageRegion(VkBuffer buffer,
                               VkImage  image,
                               int32_t  dstX,
                               int32_t  dstY,
                               uint32_t width,
                               uint32_t height);

  /// Updates a sub-rect of a live sampled image in one submission. Recording
  /// both barriers and the copy together avoids idling the graphics queue once
  /// for each operation, which matters when a page receives many thumbnails.
  void updateSampledImageRegion(VkBuffer buffer,
                                VkImage  image,
                                int32_t  dstX,
                                int32_t  dstY,
                                uint32_t width,
                                uint32_t height);

  VkImageView createImageView(VkImage            image,
                              VkFormat           format,
                              VkImageAspectFlags aspectFlags,
                              uint32_t           mipLevels);

  // Compute shader support
  VkDescriptorSetLayout createComputeDescriptorSetLayout();
  VkPipelineLayout createComputePipelineLayout(VkDescriptorSetLayout descriptorSetLayout);
  VkPipeline createComputePipeline(VkPipelineLayout pipelineLayout, const std::string& shaderPath);
  VkDescriptorPool createComputeDescriptorPool(uint32_t maxSets);
  VkDescriptorSet allocateComputeDescriptorSet(VkDescriptorPool pool, VkDescriptorSetLayout layout);
  void dispatchCompute(VkCommandBuffer commandBuffer, VkPipeline pipeline, VkPipelineLayout layout, VkDescriptorSet descriptorSet, uint32_t groupCountX, uint32_t groupCountY = 1, uint32_t groupCountZ = 1);
};
