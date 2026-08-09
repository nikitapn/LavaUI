#version 450

// Unified quad pipeline. Positions arrive in *layout* (window) pixels.
// Camera zoom/pan is applied here so Yoga/draw-list stay at zoom=1 and only
// the final pixel→NDC step pays for zoom (one mul/add per vertex).

layout(location = 0) in vec2  inPos;       // layout pixels, top-left origin
layout(location = 1) in vec2  inLocal;     // SDF-space coords, or atlas UV for glyphs
layout(location = 2) in vec2  inHalfSize;  // SDF half-extent
layout(location = 3) in float inRadius;    // SDF corner radius
layout(location = 4) in vec4  inColor;     // fetched from RGBA8 via R8G8B8A8_UNORM
layout(location = 5) in uint  inKind;      // 0 = sdf shape, 1 = glyph
layout(location = 6) in float inAux;       // kind-specific: shadow blur

// std140: vec2@0, vec2@8, float@16, float@20 → 24 bytes
layout(push_constant) uniform Push {
  vec2  viewport;  // framebuffer size in pixels
  vec2  pan;       // layout-space pan in pixels
  float zoom;      // 1 = identity
  float _pad;
} pc;

layout(location = 0) out vec2       vLocal;
layout(location = 1) out vec2       vHalfSize;
layout(location = 2) out float      vRadius;
layout(location = 3) out vec4       vColor;
layout(location = 4) flat out uint  vKind;
layout(location = 5) flat out float vAux;

void main() {
  vLocal    = inLocal;
  vHalfSize = inHalfSize;
  vRadius   = inRadius;
  vColor    = inColor;
  vKind     = inKind;
  vAux      = inAux;

  // Zoom about viewport center, then pan (layout → screen pixels).
  vec2 center = pc.viewport * 0.5;
  float z = pc.zoom > 0.0 ? pc.zoom : 1.0;
  vec2 screen = (inPos - center) * z + center + pc.pan;

  vec2 ndc = vec2(
    screen.x / pc.viewport.x * 2.0 - 1.0,
    screen.y / pc.viewport.y * 2.0 - 1.0
  );
  gl_Position = vec4(ndc, 0.0, 1.0);
}
