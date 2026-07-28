#pragma once

// Phase 3.5 — unified quad renderer.
//
// Replaces GeometryRenderer + LineRenderer + TextRenderer's draw path with a
// single pipeline so the draw list replays in *index order*. The old renderers
// each accumulated a whole frame and flushed separately, which pinned paint
// order to lines < geometry < text regardless of emission order; a caret (a
// rect) could never cover its own glyphs, and a popup could never cover a
// label.
//
// Every primitive is four vertices of QuadVertex. Shapes use a rounded-box SDF
// (rect = radius 0, circle = square with radius w/2, stroked line = capsule in
// the segment's local frame); glyphs sample the R8 atlas. Solid shapes sample a
// reserved white texel from the same descriptor, so scissor changes are the
// only thing that breaks a batch.

#include <cstdint>
#include <vector>

#include <vulkan/vulkan.h>

#include "render/vulkan_ptr.hpp"
#include "util/types.hpp"

class Vulkan;

class QuadRenderer {
 public:
  enum class Kind : uint32_t { Sdf = 0, Glyph = 1 };

  // Must match the vertex input layout in quad.vert.
  struct Vertex {
    vec2     pos;       // screen pixels, top-left origin
    vec2     local;     // SDF-space coords, or atlas UV for glyphs
    vec2     halfSize;  // SDF half-extent
    float    radius;    // SDF corner radius
    uint32_t color;     // RGBA8, R in the low byte
    uint32_t kind;
  };
  static_assert(sizeof(Vertex) == 36, "QuadVertex must stay tightly packed");

  explicit QuadRenderer(Vulkan &vulkan) : vulkan_{vulkan} {}

  QuadRenderer(const QuadRenderer &)            = delete;
  QuadRenderer &operator=(const QuadRenderer &) = delete;

  void init();
  void cleanUp();

  /// Rebinds the atlas the glyph path samples. Until called, an internal 1x1
  /// white texture is used, which is all the SDF path needs.
  void setAtlas(VkImageView view, VkSampler sampler);

  // ─── Frame recording ─────────────────────────────────────────────────────
  // begin() -> push*() in draw-list order -> end() -> draw().

  void begin(vec2 viewportSize);

  /// Axis-aligned box. radius 0 gives a hard rect; w/2 == h/2 == radius gives a
  /// circle. Coordinates are the box's top-left corner and size, in pixels.
  void pushBox(vec2 topLeft, vec2 size, uint32_t rgba, float radius = 0.0f);

  void pushCircle(vec2 center, float radius, uint32_t rgba);

  /// Stroked segment with round caps, emitted as a rotated capsule quad.
  void pushLine(vec2 p0, vec2 p1, float width, uint32_t rgba);

  /// One glyph quad. `uv0`/`uv1` are the atlas rect for this glyph.
  void pushGlyph(vec2 topLeft, vec2 size, vec2 uv0, vec2 uv1, uint32_t rgba);

  /// Ends the current batch and records a scissor change. Rect is in pixels;
  /// a null rect (w or h <= 0) restores the full viewport.
  void pushScissor(vec2 topLeft, vec2 size);
  void popScissor();

  void end();

  /// Records every batch, in order, into `commandBuffer`.
  void draw(VkCommandBuffer commandBuffer);

  size_t quadCount() const { return vertices_.size() / 4; }
  size_t batchCount() const { return batches_.size(); }

 private:
  /// A contiguous run of quads sharing one scissor rect.
  struct Batch {
    uint32_t firstIndex = 0;
    uint32_t indexCount = 0;
    VkRect2D scissor{};
  };

  void createPipeline();
  void setupDescriptors();
  void createWhiteTexture();
  void ensureBufferCapacity(size_t vertexCount);
  void flushBatch();

  /// Appends 4 vertices + 6 indices. All four share the shape parameters; only
  /// `pos`/`local` differ per corner.
  void appendQuad(const vec2 corners[4], const vec2 locals[4], vec2 halfSize,
                  float radius, uint32_t rgba, Kind kind);

  Vulkan &vulkan_;

  vk::Handle<VkPipeline>            pipeline_;
  vk::Handle<VkPipelineLayout>      pipelineLayout_;
  vk::Handle<VkDescriptorPool>      descriptorPool_;
  vk::Handle<VkDescriptorSetLayout> descriptorSetLayout_;
  VkDescriptorSet                   descriptorSet_ = VK_NULL_HANDLE;  // freed with pool

  // 1x1 opaque white, bound until setAtlas() supplies the glyph atlas. Solid
  // shapes never sample it (the SDF path ignores the texture), but the
  // descriptor must still point at something valid.
  VkImage        whiteImage_       = VK_NULL_HANDLE;
  VkDeviceMemory whiteImageMemory_ = VK_NULL_HANDLE;
  VkImageView    whiteImageView_   = VK_NULL_HANDLE;
  VkSampler      sampler_          = VK_NULL_HANDLE;

  // Host-visible and rewritten every frame. Safe as a single buffer because
  // Vulkan::drawFrame waits on inFlightFence_ before recording, so the previous
  // frame has completed by the time we write.
  VkBuffer       vertexBuffer_       = VK_NULL_HANDLE;
  VkDeviceMemory vertexBufferMemory_ = VK_NULL_HANDLE;
  void          *vertexMapped_       = nullptr;
  VkBuffer       indexBuffer_        = VK_NULL_HANDLE;
  VkDeviceMemory indexBufferMemory_  = VK_NULL_HANDLE;
  void          *indexMapped_        = nullptr;
  size_t         bufferCapacity_     = 0;  // in vertices

  std::vector<Vertex>   vertices_;
  std::vector<uint32_t> indices_;
  std::vector<Batch>    batches_;

  std::vector<VkRect2D> scissorStack_;
  VkRect2D              currentScissor_{};
  uint32_t              batchStartIndex_ = 0;

  vec2 viewportSize_{800.0f, 600.0f};
};
