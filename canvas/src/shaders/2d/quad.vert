#version 450

// Unified quad pipeline (Phase 3.5). Every 2D primitive — rect, rounded rect,
// circle, stroked line, glyph — is four vertices of this format, so the whole
// draw list replays in index order through one pipeline instead of three
// renderers at fixed z-levels.
//
// Positions arrive in screen pixels; the only transform is pixels -> NDC, which
// keeps this a pass-through and avoids a UBO/descriptor for the projection.

layout(location = 0) in vec2  inPos;       // screen pixels, top-left origin
layout(location = 1) in vec2  inLocal;     // SDF-space coords, or atlas UV for glyphs
layout(location = 2) in vec2  inHalfSize;  // SDF half-extent
layout(location = 3) in float inRadius;    // SDF corner radius
layout(location = 4) in vec4  inColor;     // fetched from RGBA8 via R8G8B8A8_UNORM
layout(location = 5) in uint  inKind;      // 0 = sdf shape, 1 = glyph

layout(push_constant) uniform Push {
  vec2 viewport;  // framebuffer size in pixels
} pc;

layout(location = 0) out vec2       vLocal;
layout(location = 1) out vec2       vHalfSize;
layout(location = 2) out float      vRadius;
layout(location = 3) out vec4       vColor;
layout(location = 4) flat out uint  vKind;

void main() {
  vLocal    = inLocal;
  vHalfSize = inHalfSize;
  vRadius   = inRadius;
  vColor    = inColor;
  vKind     = inKind;

  // Pixels -> NDC. Y is not flipped: the swapchain already uses a top-left
  // origin here, matching TextRenderer's coordinate convention.
  vec2 ndc = vec2(
    inPos.x / pc.viewport.x * 2.0 - 1.0,
    inPos.y / pc.viewport.y * 2.0 - 1.0
  );
  gl_Position = vec4(ndc, 0.0, 1.0);
}
