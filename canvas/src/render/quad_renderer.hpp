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
// frame slot (see RenderDevice::kMaxFramesInFlight). begin()/end()/draw() use the
// slot passed to begin(); Application waits that slot before writing.

#include <cstdint>
#include <unordered_map>
#include <vector>

#include <vulkan/vulkan.h>
#include "vk_mem_alloc.h"

#include "render/vulkan_ptr.hpp"
#include "render/draw_command.hpp"
#include "util/types.hpp"

class RenderDevice;
class RenderWindow;

/// The same RGBA8 with its alpha multiplied by `k`.
///
/// Scaling alpha rather than blending toward the background: a tint is an
/// overlay, so "half faded in" is the same colour at half the opacity, and
/// that stays true over whatever it happens to be sitting on.
///
/// Here rather than beside its callers because both of them are building
/// vertices — one composing a draw list, one filling the buffer — and a
/// second copy of this is a second place for the rounding to differ.
inline uint32_t withScaledAlpha(uint32_t rgba, float k)
{
  const uint32_t alpha = (rgba >> 24) & 0xffu;
  const float    scaled =
    static_cast<float>(alpha) * (k < 0.f ? 0.f : (k > 1.f ? 1.f : k)) + 0.5f;
  return (rgba & 0x00ffffffu) | (static_cast<uint32_t>(scaled) << 24);
}

class QuadRenderer {
 public:
  struct FrameStats {
    uint32_t drawCalls = 0;
    uint32_t textureBinds = 0;
    uint32_t descriptorWrites = 0;
    uint32_t uniqueTextureSamplers = 0;
    uint32_t descriptorPoolGrowths = 0;
    uint32_t bufferGrowths = 0;
    uint64_t vertexBytes = 0;
    uint64_t indexBytes = 0;
    uint64_t vertexCapacityBytes = 0;
    uint64_t indexCapacityBytes = 0;
    uint64_t replayCpuUs = 0;
    uint64_t uploadCpuUs = 0;
    uint32_t instanceCount = 0;
    uint64_t instanceBytes = 0;
    uint64_t instanceCapacityBytes = 0;
    /// Times this frame wanted a texture the bindless table had no room for
    /// and drew the white placeholder instead. See `textureSlot`.
    uint32_t textureSlotOverflows = 0;
  };

  enum class Kind : uint32_t {
    Sdf = 0, Glyph = 1, Image = 2, Mesh = 3,
    /// Coverage only, written as alpha and never discarded where a shape
    /// would be empty — the corners *are* the output. See `pushCornerMask`.
    Mask = 4,
    /// Rounded rect with an outward fade. `aux` carries the blur distance.
    Shadow = 5,
    /// Blur result sampled through a rounded-rect mask: `uv` selects the
    /// region of the blur texture, `local`/`halfSize`/`radius` describe the
    /// shape it is cut to. The one kind that needs both, which is what the
    /// separate `uv` attribute is for.
    BlurComposite = 6,
  };

  // Must match the vertex input layout in quad.vert.
  struct Vertex {
    vec2     pos;       // screen pixels, top-left origin
    vec2     local;     // SDF-space coords, or atlas UV for glyphs
    vec2     halfSize;  // SDF half-extent
    float    radius;    // SDF corner radius
    uint32_t color;     // RGBA8, R in the low byte
    uint32_t kind;
    /// One number whose meaning belongs to `kind`: the blur distance for a
    /// shadow, and unread by everything else.
    ///
    /// Four bytes on every vertex of every quad, for something one shape in a
    /// frame uses. Worth it against the alternatives: a push constant would
    /// have to be re-pushed per batch and would make the parameter a property
    /// of the *pipeline bind* rather than of the shape, and packing it into
    /// the spare bits of `kind` is the kind of cleverness that is discovered
    /// by whoever adds the next kind. A draw list of two thousand quads pays
    /// 32 KB for it.
    float    aux;
    /// Texture coords for a kind that needs `local` for something else.
    ///
    /// Only `BlurComposite` reads it: a shape that is both textured and
    /// rounded has two things to say and `local` can only carry one. Glyphs
    /// and images keep their UV in `local` rather than moving here, because
    /// they are the overwhelming majority of quads and the migration would buy
    /// them nothing.
    vec2     uv;
    /// Index into the frame slot's bindless combined-image-sampler table.
    uint32_t textureIndex;
  };
  static_assert(sizeof(Vertex) == 52, "QuadVertex must stay tightly packed");

  /// One axis-aligned quad. The instance vertex shader expands its six
  /// corners from gl_VertexIndex; rotated capsules and arbitrary meshes stay
  /// in Vertex because they cannot be described by this rectangle ABI.
  struct Instance {
    vec2 topLeft;
    vec2 size;
    vec2 halfSize;
    float radius;
    float aux;
    vec2 uv0;
    vec2 uv1;
    uint32_t color;
    uint32_t kind;
    uint32_t textureIndex;

    // ─── Gradient ──────────────────────────────────────────────────────────
    //
    // A second colour and a ramp across the quad, evaluated per vertex and
    // interpolated. Not a `Kind` of its own, deliberately: the ramp only
    // decides what `vColor` is, and every kind already uses `vColor` — as a
    // fill for shapes and as a tint for glyphs and images — so leaving it
    // orthogonal makes a gradient-tinted image fall out for free rather than
    // needing a seventh way to say "shape".
    //
    // Solid quads leave `gradAxis` zero, which makes the ramp position zero
    // everywhere and `mix(color, color1, 0)` exactly `color`. So there is no
    // branch in the shader and nothing to set on the paths that predate this.

    /// The far end of the ramp. Read only where `gradAxis` is non-zero.
    uint32_t color1 = 0;
    /// Ramp direction in the quad's own 0…1 corner space, pre-divided by the
    /// span so the shader is one dot product. Zero means "no gradient".
    ///
    /// Computed on the CPU (`pushBoxGradient`) rather than passing an angle,
    /// because turning an angle into this needs the quad's aspect ratio and a
    /// projection of four corners — per vertex, six times per quad, for a
    /// value that is constant across the whole instance.
    vec2 gradAxis{0.f, 0.f};
    /// Ramp offset, so `t = dot(corner, gradAxis) + gradBias` lands in 0…1
    /// across the quad whichever way the gradient points.
    float gradBias = 0.f;
  };
  static_assert(sizeof(Instance) == 76, "QuadInstance ABI changed");

  explicit QuadRenderer(RenderDevice &device) : device_{device} {}

  /// The window whose frame slots these buffers belong to. Set once, at
  /// construction of the owner. Growing a buffer has to wait for that
  /// window's frames — and only that window's, since no other one can name
  /// them.
  void setOwner(RenderWindow *owner) { owner_ = owner; }

  QuadRenderer(const QuadRenderer &)            = delete;
  QuadRenderer &operator=(const QuadRenderer &) = delete;

  void init();
  void cleanUp();

  /// Rebinds the atlas the glyph path samples. Until called, an internal 1x1
  /// white texture is used, which is all the SDF path needs.
  void setAtlas(VkImageView view, VkSampler sampler);

  // ─── Frame recording ─────────────────────────────────────────────────────
  // begin(slot) -> push*() in draw-list order -> end() -> draw().
  // `frameSlot` must match RenderDevice::currentFrameSlot() for this submit.

  void begin(vec2 viewportSize, uint32_t frameSlot = 0);

  /// Axis-aligned box. radius 0 gives a hard rect; w/2 == h/2 == radius gives a
  /// circle. Coordinates are the box's top-left corner and size, in pixels.
  void pushBox(vec2 topLeft, vec2 size, uint32_t rgba, float radius = 0.0f);

  /// The same box, filled with a two-stop linear ramp.
  ///
  /// `angle` is in radians, measured from +x towards +y — so 0 runs left to
  /// right and π/2 runs top to bottom, in screen terms. The ramp always spans
  /// the box exactly: `rgba0` sits on the first corner the direction reaches
  /// and `rgba1` on the last, whatever the angle and whatever the aspect
  /// ratio. Both ends may differ in alpha as well as colour.
  ///
  /// Exact rather than approximate, despite being interpolated between six
  /// vertices: a two-stop ramp is an affine function of position, and that is
  /// the one family barycentric interpolation reproduces perfectly. Multi-stop
  /// and radial are not, and would need the ramp evaluated per fragment.
  void pushBoxGradient(vec2 topLeft, vec2 size, uint32_t rgba0, uint32_t rgba1,
                       float angle, float radius = 0.0f);

  void pushCircle(vec2 center, float radius, uint32_t rgba);

  /// A rounded rectangle whose edge fades outwards over `blur` pixels.
  ///
  /// `topLeft`/`size` are the rect *casting* the shadow, not the area painted:
  /// the falloff reaches `blur` beyond it on every side, and the quad is grown
  /// to make room. Drawn with the ordinary blend — a shadow is painted, not
  /// masked — onto whatever is behind, which for a compositor is a surface of
  /// its own sitting under the window.
  void pushShadow(vec2 topLeft, vec2 size, float radius, float blur,
                  uint32_t rgba);

  /// Stroked segment with round caps, emitted as a rotated capsule quad.
  void pushLine(vec2 p0, vec2 p1, float width, uint32_t rgba);

  /// Connected native 1px line strip. A dedicated pipeline is required
  /// because primitive topology is baked into a Vulkan graphics pipeline.
  void pushPolyline(const vec2 *points, uint32_t count, uint32_t rgba);

  /// Already projected window-space triangles with Vulkan depth in 0...1.
  /// Uses a dedicated depth-tested pipeline while remaining in batch order.
  ///
  /// `offset` and `opacity` are the enclosing scene node's retained transform.
  /// They are applied here, in the copy this call already makes, for the same
  /// reason every other primitive applies them as its vertices are built: the
  /// producer's arrays are shared memory and must not be rewritten.
  void pushSpatialTriangles(const canvas::SpatialVertex *vertices, uint32_t count,
                            VkImageView textureView, vec2 uv0 = {0.f,0.f},
                            vec2 uv1 = {1.f,1.f}, vec2 offset = {0.f,0.f},
                            float opacity = 1.f);
  void pushSpatialBegin(vec2 topLeft, vec2 size);

  /// One glyph quad. `uv0`/`uv1` are the atlas rect for this glyph.
  void pushGlyph(vec2 topLeft, vec2 size, vec2 uv0, vec2 uv1, uint32_t rgba);

  /// Full-color textured quad. `textureView` is sampled as RGBA; `uv0`/`uv1`
  /// are the source rect (usually (0,0)-(1,1)). The view becomes a bindless
  /// table slot carried by the vertices, so changing it does not end a batch.
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

  /// Cuts everything outside a rounded rect out of what has already been
  /// drawn: `dst *= coverage`, so the corners become transparent and the edge
  /// antialiases the way every other rounded shape here does.
  ///
  /// Last thing in a frame, and only ever a window's own outline — this is how
  /// a window gets rounded corners without the client knowing it has them, and
  /// without the compositor re-rendering somebody else's buffer.
  ///
  /// The rect may fall outside the surface, which is how corners are rounded
  /// selectively: a mask an inch taller than the window rounds its top two
  /// corners and leaves the bottom two square, because the bottom curve
  /// happens past the last row of pixels. That is what a title bar above a
  /// window's content wants, and it needs no per-corner radii to express.
  void pushCornerMask(vec2 topLeft, vec2 size, float radius);

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
  ///
  /// `cornerRadius` rounds the composite to match the panel that will be drawn
  /// over it. It has to be stated here rather than left to the fill on top,
  /// because the frost is *behind* that fill: a square composite under a
  /// rounded panel shows four bright tabs the panel never covers. Zero keeps
  /// the plain rectangular quad, which is what a content blur wants — that one
  /// composites a subtree's own silhouette and has no panel to match.
  void pushBlurResultImage(vec2 topLeft, vec2 size, vec2 uv0, vec2 uv1,
                           float cornerRadius = 0.f,
                           uint32_t rgba = 0xffffffffu);

  void end();

  /// Camera transform applied at draw time (layout pixels → screen).
  /// Zoom is about the viewport center; pan is in layout pixels.
  void setViewTransform(float zoom, float panX, float panY);

  /// Bind the BlurPass result for batches created with pushBlurResultImage.
  /// Optional sampler (e.g. clamp-to-edge from BlurPass); null → default.
  void setBlurResultView(VkImageView view, VkSampler sampler = VK_NULL_HANDLE);

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

  size_t quadCount() const { return instances_.size() + vertices_.size() / 4; }
  size_t batchCount() const { return batches_.size(); }
  const FrameStats &frameStats() const { return frameStats_; }
  void setReplayCpuUs(uint64_t us) { frameStats_.replayCpuUs = us; }

 private:
  /// A contiguous run in one geometry stream sharing a scissor and pipeline.
  struct Batch {
    enum class Geometry : uint8_t {
      Instances, IndexedTriangles, LineStrip, SpatialTriangles, SpatialBegin
    };
    Geometry geometry = Geometry::IndexedTriangles;
    uint32_t firstIndex = 0;
    uint32_t indexCount = 0;
    uint32_t firstVertex = 0;
    uint32_t vertexCount = 0;
    uint32_t firstInstance = 0;
    uint32_t instanceCount = 0;
    VkRect2D scissor{};
    bool sampleBlurResult = false;             // bind blurResultView_ at draw
    /// Drawn with the mask pipeline: multiplies the target rather than
    /// painting over it. See `pushCornerMask`.
    bool mask = false;
  };

  /// Per-frame-slot GPU resources (not shared across in-flight frames).
  struct FrameResources {
    struct TextureSampler {
      VkImageView view = VK_NULL_HANDLE;
      VkSampler sampler = VK_NULL_HANDLE;

      bool operator==(const TextureSampler &) const = default;
    };

    struct TextureSamplerHash {
      size_t operator()(const TextureSampler &key) const {
        const size_t a = std::hash<VkImageView>{}(key.view);
        const size_t b = std::hash<VkSampler>{}(key.sampler);
        return a ^ (b + 0x9e3779b9u + (a << 6) + (a >> 2));
      }
    };

    VkBuffer      vertexBuffer = VK_NULL_HANDLE;
    VmaAllocation vertexAlloc  = VK_NULL_HANDLE;
    void         *vertexMapped = nullptr;
    VkBuffer      indexBuffer  = VK_NULL_HANDLE;
    VmaAllocation indexAlloc   = VK_NULL_HANDLE;
    void         *indexMapped  = nullptr;
    VkBuffer      instanceBuffer = VK_NULL_HANDLE;
    VmaAllocation instanceAlloc = VK_NULL_HANDLE;
    void         *instanceMapped = nullptr;
    size_t        capacity     = 0;  // vertices
    /// Indices, tracked separately rather than derived from `capacity`.
    /// A quad is 6 indices per 4 vertices, but a triangle fan is nearly 3 per
    /// 1 — so a frame with mesh content needs more than the quad ratio, and
    /// assuming otherwise overruns the buffer. See `ensureBufferCapacity`.
    size_t        indexCapacity = 0;
    size_t        instanceCapacity = 0;
    VkDescriptorSet descriptorSet = VK_NULL_HANDLE;
    uint32_t nextTextureIndex = 0;
    std::unordered_map<TextureSampler, uint32_t, TextureSamplerHash> textureSlots;
  };

  /// How a pipeline combines what it draws with what is already there.
  /// `Over` is premultiplied source-over, what everything paints with.
  /// `Mask` multiplies the target by the source's alpha and adds nothing.
  enum class Blend : uint8_t { Over, Mask };

  void createPipelineLayout();
  void createPipeline(VkRenderPass renderPass, VkSampleCountFlagBits samples,
                      vk::Handle<VkPipeline> &out, Blend blend = Blend::Over);
  void createInstancePipeline(VkRenderPass renderPass,
                              VkSampleCountFlagBits samples,
                              vk::Handle<VkPipeline> &out,
                              Blend blend = Blend::Over);
  void createLinePipeline(VkRenderPass renderPass, VkSampleCountFlagBits samples,
                          vk::Handle<VkPipeline> &out);
  void createSpatialPipeline(VkRenderPass renderPass, VkSampleCountFlagBits samples,
                             vk::Handle<VkPipeline> &out, bool depthEnabled);
  void setupDescriptors();
  uint32_t textureSlot(VkImageView view, VkSampler sampler = VK_NULL_HANDLE);
  void writeTextureSlot(uint32_t slot, VkImageView view, VkSampler sampler);
  void createWhiteTexture();
  void ensureBufferCapacity(size_t vertexCount, size_t indexCount,
                            size_t instanceCount);
  void destroyFrameBuffers(FrameResources &fr);
  void flushBatch();
  void flushIndexedBatch();
  void flushInstanceBatch();
  /// Switch the texture selected by subsequent vertices. Texture changes do
  /// not break a batch: the fragment shader indexes the descriptor table.
  void ensureBatchTexture(VkImageView view);

  /// Appends 4 vertices + 6 indices. All four share the shape parameters; only
  /// `pos`/`local`/`uv` differ per corner. `uvs` is null for every kind that
  /// keeps its texture coords in `local`.
  void appendQuad(const vec2 corners[4], const vec2 locals[4], vec2 halfSize,
                  float radius, uint32_t rgba, Kind kind, float aux = 0.f,
                  const vec2 *uvs = nullptr);
  void appendInstance(vec2 topLeft, vec2 size, vec2 halfSize, float radius,
                      uint32_t rgba, Kind kind, float aux = 0.f,
                      vec2 uv0 = {0.f, 0.f}, vec2 uv1 = {1.f, 1.f});

  FrameResources &activeFrame();

  RenderDevice &device_;
  RenderWindow *owner_ = nullptr;

  vk::Handle<VkPipeline>            pipeline_;
  vk::Handle<VkPipeline>            instancePipeline_;
  vk::Handle<VkPipeline>            instanceMaskPipeline_;
  /// Same shaders as `pipeline_` with the mask blend — see `pushCornerMask`.
  vk::Handle<VkPipeline>            maskPipeline_;
  /// Same shaders and layout against the content-blur scene pass: one colour
  /// attachment, no depth, single sample. A pipeline is tied to a
  /// render-pass-compatible pass, so drawing the same geometry into a different
  /// target needs its own object rather than a state change.
  vk::Handle<VkPipeline>            pipelineScene_;
  vk::Handle<VkPipeline>            instancePipelineScene_;
  /// Corner mask against the content-blur target, so a frost plate can punch
  /// its source *before* the Gaussian. Without this the square corner of the
  /// capture bleeds into the curve as a bright speck.
  vk::Handle<VkPipeline>            instanceMaskPipelineScene_;
  vk::Handle<VkPipeline>            linePipeline_;
  vk::Handle<VkPipeline>            linePipelineScene_;
  vk::Handle<VkPipeline>            spatialPipeline_;
  vk::Handle<VkPipeline>            spatialPipelineScene_;
  vk::Handle<VkPipelineLayout>      pipelineLayout_;
  vk::Handle<VkDescriptorPool>      descriptorPool_;
  vk::Handle<VkDescriptorSetLayout> descriptorSetLayout_;
  uint32_t maxBindlessTextures_ = 0;
  uint32_t blurTextureIndex_ = 0;
  /// Slot holding the 1x1 white placeholder, claimed first every frame so a
  /// frame that exhausts the table still has somewhere valid to point.
  uint32_t fallbackTextureIndex_ = 0;
  static constexpr uint32_t kDesiredBindlessTextures = 4096;
  static constexpr uint32_t kMaxFramesInFlight = 2;
  FrameResources frames_[kMaxFramesInFlight]{};
  uint32_t activeFrameSlot_ = 0;
  FrameStats frameStats_{};

  // 1x1 opaque white, bound until setAtlas() supplies the glyph atlas.
  VkImage       whiteImage_      = VK_NULL_HANDLE;
  VmaAllocation whiteImageAlloc_ = VK_NULL_HANDLE;
  VkImageView   whiteImageView_  = VK_NULL_HANDLE;
  VkSampler      sampler_          = VK_NULL_HANDLE;
  VkImageView    glyphAtlasView_   = VK_NULL_HANDLE;
  VkSampler      glyphAtlasSampler_ = VK_NULL_HANDLE;
  VkImageView    currentBatchTexture_ = VK_NULL_HANDLE;
  uint32_t       currentTextureIndex_ = 0;

  // CPU-side build arena (copied into frames_[slot] on end()).
  std::vector<Vertex>   vertices_;
  std::vector<uint32_t> indices_;
  std::vector<Instance> instances_;
  std::vector<Batch>    batches_;
  /// Exclusive batch-end indices for each closeSegment() (+ final in end()).
  std::vector<uint32_t> segmentEnds_;

  std::vector<VkRect2D> scissorStack_;
  VkRect2D              currentScissor_{};
  uint32_t              batchStartIndex_ = 0;
  uint32_t              instanceBatchStart_ = 0;

  VkImageView blurResultView_ = VK_NULL_HANDLE;
  VkSampler   blurResultSampler_ = VK_NULL_HANDLE;

  vec2 viewportSize_{800.0f, 600.0f};
  float viewZoom_ = 1.0f;
  float viewPanX_ = 0.0f;
  float viewPanY_ = 0.0f;

  void drawBatchRange(VkCommandBuffer commandBuffer, uint32_t firstBatch,
                      uint32_t batchCount, bool intoSceneTarget);
};
