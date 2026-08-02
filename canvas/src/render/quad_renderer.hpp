#pragma once

// Phase 3.5 — unified quad renderer.
//
// Replaces GeometryRenderer + LineRenderer + TextRenderer's draw path with a
// one ordered batch stream so the draw list replays in *index order*. The old renderers
// each accumulated a whole frame and flushed separately, which pinned paint
// order to lines < geometry < text regardless of emission order; a caret (a
// rect) could never cover its own glyphs, and a popup could never cover a
// label.
//
// Most primitives are four vertices of QuadVertex. Shapes use a rounded-box SDF
// (rect = radius 0, circle = square with radius w/2, stroked line = capsule in
// the segment's local frame); glyphs sample the R8 atlas. Solid shapes sample a
// reserved white texel from the same descriptor. Native polylines share the
// vertex buffer but switch to a dedicated LINE_STRIP pipeline; the batch stream
// preserves paint order across that switch.
//
// Frames-in-flight: host-visible VB/IB and descriptor sets are duplicated per
// frame slot (see Vulkan::kMaxFramesInFlight). begin()/end()/draw() use the
// slot passed to begin(); Application waits that slot before writing.

#include <cstdint>
#include <vector>

#include <vulkan/vulkan.h>
#include "vk_mem_alloc.h"

#include "render/vulkan_ptr.hpp"
#include "render/draw_command.hpp"
#include "util/types.hpp"

class Vulkan;

class QuadRenderer {
 public:
  enum class Kind : uint32_t { Sdf = 0, Glyph = 1, Image = 2, Mesh = 3 };

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
  // begin(slot) -> push*() in draw-list order -> end() -> draw().
  // `frameSlot` must match Vulkan::currentFrameSlot() for this submit.

  void begin(vec2 viewportSize, uint32_t frameSlot = 0);

  /// Axis-aligned box. radius 0 gives a hard rect; w/2 == h/2 == radius gives a
  /// circle. Coordinates are the box's top-left corner and size, in pixels.
  void pushBox(vec2 topLeft, vec2 size, uint32_t rgba, float radius = 0.0f);

  void pushCircle(vec2 center, float radius, uint32_t rgba);

  /// Stroked segment with round caps, emitted as a rotated capsule quad.
  void pushLine(vec2 p0, vec2 p1, float width, uint32_t rgba);

  /// Connected native 1px line strip. A dedicated pipeline is required
  /// because primitive topology is baked into a Vulkan graphics pipeline.
  void pushPolyline(const vec2 *points, uint32_t count, uint32_t rgba);

  /// Already projected window-space triangles with Vulkan depth in 0...1.
  /// Uses a dedicated depth-tested pipeline while remaining in batch order.
  void pushSpatialTriangles(const canvas::SpatialVertex *vertices, uint32_t count);
  void pushSpatialBegin(vec2 topLeft, vec2 size);

  /// One glyph quad. `uv0`/`uv1` are the atlas rect for this glyph.
  void pushGlyph(vec2 topLeft, vec2 size, vec2 uv0, vec2 uv1, uint32_t rgba);

  /// Full-color textured quad. `textureView` is sampled as RGBA; `uv0`/`uv1`
  /// are the source rect (usually (0,0)-(1,1)). Flushes the batch when the
  /// bound texture changes.
  void pushImage(vec2 topLeft, vec2 size, vec2 uv0, vec2 uv1, uint32_t rgba,
                 VkImageView textureView);

  /// Filled arbitrary polygon, flat-shaded (no SDF distance calc — the mesh
  /// boundary *is* the edge). `points` are absolute pixel positions.
  /// `isRing == false` fans the points around `points[0]`, correct for any
  /// solid star-convex shape (a pie wedge, a simple convex polygon). `isRing
  /// == true` reads `points` as alternating inner/outer pairs and
  /// triangulates a strip between them — an annulus sector (donut wedge),
  /// which has no single point the whole boundary can fan from.
  void pushMesh(const vec2 *points, uint32_t count, uint32_t rgba, bool isRing);

  /// Ends the current batch and records a scissor change. Rect is in pixels;
  /// a null rect (w or h <= 0) restores the full viewport.
  void pushScissor(vec2 topLeft, vec2 size);
  void popScissor();

  /// Marks the end of a draw segment for the blur multipass. Call wherever the
  /// draw list needs the GPU to interrupt the main pass, so a later
  /// `drawSegment` can stop before it. Vertices stay in one buffer; scissor
  /// state is preserved.
  void closeSegment();

  /// Full-color quad that samples the blur result (bound at draw time via
  /// `setBlurResultView`). `uv0`/`uv1` select the region of the full-frame blur
  /// texture. Serves both blur kinds: the backdrop composite is opaque because
  /// its source was, the content composite carries the subtree's own alpha.
  void pushBlurResultImage(vec2 topLeft, vec2 size, vec2 uv0, vec2 uv1,
                           uint32_t rgba = 0xffffffffu);

  void end();

  /// Camera transform applied at draw time (layout pixels → screen).
  /// Zoom is about the viewport center; pan is in layout pixels.
  void setViewTransform(float zoom, float panX, float panY);

  /// Bind the BlurPass result for batches created with pushBlurResultImage.
  /// Optional sampler (e.g. clamp-to-edge from BlurPass); null → default.
  void setBlurResultView(VkImageView view, VkSampler sampler = VK_NULL_HANDLE)
  {
    blurResultView_ = view;
    blurResultSampler_ = sampler;
  }

  /// Records every batch, in order, into `commandBuffer`.
  void draw(VkCommandBuffer commandBuffer);

  /// Number of segments closed via closeSegment() (+ final open tail after end).
  uint32_t segmentCount() const { return static_cast<uint32_t>(segmentEnds_.size()); }

  /// Build the pipeline variant targeting the content-blur scene pass. Separate
  /// from init() because BlurPass owns that render pass and is set up later.
  void createSceneTargetPipeline(VkRenderPass sceneRenderPass);

  /// Draw batches belonging to segment `segmentIndex` (0-based).
  /// Descriptor write cursor continues across calls within one begin/end frame.
  /// `intoSceneTarget` picks the pipeline built for the content-blur pass.
  void drawSegment(VkCommandBuffer commandBuffer, uint32_t segmentIndex,
                   bool intoSceneTarget = false);

  size_t quadCount() const { return vertices_.size() / 4; }
  size_t batchCount() const { return batches_.size(); }

 private:
  /// A contiguous run of quads sharing one scissor + one sampled texture.
  struct Batch {
    enum class Geometry : uint8_t { Quads, LineStrip, SpatialTriangles, SpatialBegin };
    Geometry geometry = Geometry::Quads;
    uint32_t firstIndex = 0;
    uint32_t indexCount = 0;
    uint32_t firstVertex = 0;
    uint32_t vertexCount = 0;
    VkRect2D scissor{};
    VkImageView textureView = VK_NULL_HANDLE;  // null → use glyphAtlasView_
    bool sampleBlurResult = false;             // bind blurResultView_ at draw
  };

  /// Per-frame-slot GPU resources (not shared across in-flight frames).
  struct FrameResources {
    VkBuffer      vertexBuffer = VK_NULL_HANDLE;
    VmaAllocation vertexAlloc  = VK_NULL_HANDLE;
    void         *vertexMapped = nullptr;
    VkBuffer      indexBuffer  = VK_NULL_HANDLE;
    VmaAllocation indexAlloc   = VK_NULL_HANDLE;
    void         *indexMapped  = nullptr;
    size_t        capacity     = 0;  // vertices
    std::vector<VkDescriptorSet> descriptorSets;
    uint32_t descriptorWriteIndex = 0;
  };

  void createPipelineLayout();
  void createPipeline(VkRenderPass renderPass, VkSampleCountFlagBits samples,
                      vk::Handle<VkPipeline> &out);
  void createLinePipeline(VkRenderPass renderPass, VkSampleCountFlagBits samples,
                          vk::Handle<VkPipeline> &out);
  void createSpatialPipeline(VkRenderPass renderPass, VkSampleCountFlagBits samples,
                             vk::Handle<VkPipeline> &out);
  void setupDescriptors();
  void createWhiteTexture();
  void ensureBufferCapacity(size_t vertexCount);
  void destroyFrameBuffers(FrameResources &fr);
  void flushBatch();
  /// Switch the texture used by subsequent quads (flushes if it changes).
  void ensureBatchTexture(VkImageView view);

  /// Appends 4 vertices + 6 indices. All four share the shape parameters; only
  /// `pos`/`local` differ per corner.
  void appendQuad(const vec2 corners[4], const vec2 locals[4], vec2 halfSize,
                  float radius, uint32_t rgba, Kind kind);

  FrameResources &activeFrame();

  Vulkan &vulkan_;

  vk::Handle<VkPipeline>            pipeline_;
  /// Same shaders and layout against the content-blur scene pass: one colour
  /// attachment, no depth, single sample. A pipeline is tied to a
  /// render-pass-compatible pass, so drawing the same geometry into a different
  /// target needs its own object rather than a state change.
  vk::Handle<VkPipeline>            pipelineScene_;
  vk::Handle<VkPipeline>            linePipeline_;
  vk::Handle<VkPipeline>            linePipelineScene_;
  vk::Handle<VkPipeline>            spatialPipeline_;
  vk::Handle<VkPipelineLayout>      pipelineLayout_;
  vk::Handle<VkDescriptorPool>      descriptorPool_;
  vk::Handle<VkDescriptorSetLayout> descriptorSetLayout_;

  /// Sets per texture bind within one frame slot (never rewritten while bound).
  static constexpr uint32_t kMaxDescriptorSetsPerFrame = 64;
  static constexpr uint32_t kMaxFramesInFlight = 2;
  FrameResources frames_[kMaxFramesInFlight]{};
  uint32_t activeFrameSlot_ = 0;

  // 1x1 opaque white, bound until setAtlas() supplies the glyph atlas.
  VkImage       whiteImage_      = VK_NULL_HANDLE;
  VmaAllocation whiteImageAlloc_ = VK_NULL_HANDLE;
  VkImageView   whiteImageView_  = VK_NULL_HANDLE;
  VkSampler      sampler_          = VK_NULL_HANDLE;
  VkImageView    glyphAtlasView_   = VK_NULL_HANDLE;
  VkSampler      glyphAtlasSampler_ = VK_NULL_HANDLE;
  VkImageView    currentBatchTexture_ = VK_NULL_HANDLE;

  // CPU-side build arena (copied into frames_[slot] on end()).
  std::vector<Vertex>   vertices_;
  std::vector<uint32_t> indices_;
  std::vector<Batch>    batches_;
  /// Exclusive batch-end indices for each closeSegment() (+ final in end()).
  std::vector<uint32_t> segmentEnds_;

  std::vector<VkRect2D> scissorStack_;
  VkRect2D              currentScissor_{};
  uint32_t              batchStartIndex_ = 0;

  VkImageView blurResultView_ = VK_NULL_HANDLE;
  VkSampler   blurResultSampler_ = VK_NULL_HANDLE;

  vec2 viewportSize_{800.0f, 600.0f};
  float viewZoom_ = 1.0f;
  float viewPanX_ = 0.0f;
  float viewPanY_ = 0.0f;

  void drawBatchRange(VkCommandBuffer commandBuffer, uint32_t firstBatch,
                      uint32_t batchCount, bool intoSceneTarget);
};
