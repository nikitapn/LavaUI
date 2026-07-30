#version 450

// See quad.vert. Coverage / sample paths:
//   kind 0 — rounded-box SDF (rect / round-rect / circle / stroked line).
//   kind 1 — glyph coverage from the R8 atlas (`.r` * tint).
//   kind 2 — full-color image (RGBA sample * tint). Descriptor is rebound
//            per batch to the image view; scissor + texture both break batches.
//
// Solid shapes still sample the bound texture (usually a white texel), so one
// descriptor set is enough.
//
// Output is **premultiplied** and the pipeline blends with ONE /
// ONE_MINUS_SRC_ALPHA. Over an opaque target that is identical to straight
// alpha with SRC_ALPHA / ONE_MINUS_SRC_ALPHA, so nothing about the normal path
// changes. It matters for content blur: that renders a subtree into a target
// cleared to transparent black and then runs a Gaussian over it, and a Gaussian
// may only be applied to premultiplied colour. Averaging straight alpha pulls
// the colour of fully transparent texels — black — into every edge, which shows
// up as a dark halo around everything blurred.
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
  vec4 c;

  if (vKind == 2u) {
    // Image: vLocal holds UV; multiply by vertex color as tint.
    c = texture(uAtlas, vLocal) * vColor;
    if (c.a <= 0.001) {
      discard;
    }
  } else {
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
    c = vec4(vColor.rgb, vColor.a * cov);
  }

  outColor = vec4(c.rgb * c.a, c.a);
}
