#version 450

// See quad.vert. Coverage / sample paths:
//   kind 0 — rounded-box SDF (rect / round-rect / circle / stroked line).
//   kind 1 — glyph coverage from the R8 atlas (`.r` * tint).
//   kind 2 — full-color image (RGBA sample * tint). Descriptor is rebound
//            per batch to the image view; scissor + texture both break batches.
//
// Solid shapes still sample the bound texture (usually a white texel), so one
// descriptor set is enough.

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
  if (vKind == 2u) {
    // Image: vLocal holds UV; multiply by vertex color as tint.
    vec4 tex = texture(uAtlas, vLocal);
    outColor = tex * vColor;
    if (outColor.a <= 0.001) discard;
    return;
  }

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
