// VMA single-header implementation unit.
// Keep this file free of other heavy includes so the amalgamation stays isolated.

#define VMA_IMPLEMENTATION
// Link against the Vulkan loader; no dynamic function table.
#define VMA_STATIC_VULKAN_FUNCTIONS 1
#define VMA_DYNAMIC_VULKAN_FUNCTIONS 0

#include <vulkan/vulkan.h>

// VMA's amalgamation is extremely noisy under clang nullability diagnostics.
#if defined(__clang__)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnullability-completeness"
#pragma clang diagnostic ignored "-Wunused-private-field"
#pragma clang diagnostic ignored "-Wunused-variable"
#endif

#include "vk_mem_alloc.h"

#if defined(__clang__)
#pragma clang diagnostic pop
#endif
