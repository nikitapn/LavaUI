#version 450

// See quad.vert. Two coverage paths:
//   kind 0 — rounded-box SDF, which subsumes rect (r=0), rounded rect,
//            circle (halfSize = (r,r), radius = r) and stroked line
//            (a capsule is a rounded box in the segment's local frame).
//   kind 1 — glyph coverage sampled from the R8 atlas.
//
// Solid shapes still sample the atlas descriptor (a reserved white texel), so
// there is one descriptor set for everything and scissor is the only batch
// break.

layout(location = 0) in vec2      vLocal;
layout(location = 1) in vec2      vHalfSize;
layout(location = 2) in float     vRadius;
layout(location = 3) in vec4      vColor;
layout(location = 4) flat in uint vKind;

layout(binding = 0) uniform sampler2D uAtlas;

layout(location = 0) out vec4 outColor;

// Signed distance to a rounded box centred at the origin.
float sdRoundBox(vec2 p, vec2 b, float r) {
  vec2 q = abs(p) - b + r;
  return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
}

void main() {
  float cov;

  if (vKind == 1u) {
    cov = texture(uAtlas, vLocal).r;
  } else {
    float d = sdRoundBox(vLocal, vHalfSize, vRadius);
    // fwidth gives ~1px of screen-space falloff, so edges antialias without
    // MSAA. Clamped away from zero so degenerate (zero-area) quads don't NaN.
    float aa = max(fwidth(d), 1e-5);
    cov = 1.0 - smoothstep(-aa, aa, d);
  }

  if (cov <= 0.0) {
    discard;
  }
  outColor = vec4(vColor.rgb, vColor.a * cov);
}
