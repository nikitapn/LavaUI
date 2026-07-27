#pragma once

#include <string>
#include <memory>

#include <vulkan/vulkan.h>

#include "util/result.hpp"
#include "util/types.hpp"

// Not canvas::TextMetrics (render/font.hpp) — that one's float
// width/height/ascent/descent for Yoga; this is TextRenderer's own
// pre-existing int w/h public contract, kept as-is so callers (e.g.
// Application::uiCommit's label sizing) don't need to change. Both are
// computed from the same canvas::Font now, just rounded differently.
struct TextMetrics {
  int w, h;
};

enum class TextAlign { Left, Center, Right };

class Vulkan;

class TextRenderer {
  struct Impl;
  std::unique_ptr<Impl> impl_;
  
public:
  /// Does not load a font — call loadFont() after construction once the
  /// absolute path under assetsRoot is known (Application ctor runs before
  /// cwd/assetsRoot is set).
  explicit TextRenderer(Vulkan& vulkan);
  ~TextRenderer();
  
  // Non-copyable
  TextRenderer(const TextRenderer&) = delete;
  TextRenderer& operator=(const TextRenderer&) = delete;
  
  // Moveable
  TextRenderer(TextRenderer&& other) noexcept;
  TextRenderer& operator=(TextRenderer&& other) noexcept;

  // Main interface
  void init();
  /// Load FreeType face from an absolute (or process-cwd-relative) path.
  canvas::VoidResult loadFont(const std::string& fontPath, int fontSize);
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

