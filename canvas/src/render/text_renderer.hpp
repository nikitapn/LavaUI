#pragma once

#include <string>
#include <memory>

#include <vulkan/vulkan.h>

#include "util/types.hpp"

struct TextMetrics {
  int w, h;
};

enum class TextAlign { Left, Center, Right };

class Vulkan;

class TextRenderer {
  struct Impl;
  std::unique_ptr<Impl> impl_;
  
public:
  TextRenderer(Vulkan& vulkan, const std::string& fontPath, int fontSize);
  ~TextRenderer();
  
  // Non-copyable
  TextRenderer(const TextRenderer&) = delete;
  TextRenderer& operator=(const TextRenderer&) = delete;
  
  // Moveable
  TextRenderer(TextRenderer&& other) noexcept;
  TextRenderer& operator=(TextRenderer&& other) noexcept;

  // Main interface
  void init();
  void beginTextRendering();
  void renderText(const std::string& text, vec2 position, vec3 color, TextAlign align = TextAlign::Left);
  void endTextRendering();
  void draw(VkCommandBuffer commandBuffer, vec2 viewportSize = {800, 600});
  void cleanUp();
  
  // Utilities
  TextMetrics getTextMetrics(const std::string& text);
  float getLineHeight() const;
  void bindDescriptorSet(VkCommandBuffer commandBuffer);
};

