#version 450

// Separable Gaussian blur. One pass is horizontal or vertical depending on
// push-constant direction. 9 taps, sigma ≈ 2 *texels*.
//
// `spacing` is expected to stay at or below 1. The kernel is a point-sampled
// Gaussian, so spacing above a texel does not widen the blur — it samples nine
// disjoint neighbourhoods and stamps nine offset copies of the source. Width
// comes from BlurPass instead: bigger texels (downscale) and one pass.
//
// The image is allocated for the *finest* radius in the frame, and each blur
// uses only the top-left `subScale` fraction of it, at whatever resolution its
// own radius wants. So a two-pixel blur and a sixteen-pixel blur in the same
// frame each get their own grid out of one allocation, instead of both being
// forced onto the coarser one. `subScale` is why every fetch is clamped: past
// that fraction lies the previous blur's data, not this one's.

layout(location = 0) in vec2 vUV;
layout(location = 0) out vec4 outColor;

layout(binding = 0) uniform sampler2D uSrc;

// std140: vec2@0, float@8, float@12, vec2@16, vec2@24 → 32 bytes
layout(push_constant) uniform Push {
  vec2  direction;  // one texel along the blur axis, in image UV
  float spacing;    // tap spacing in texels; 1 = one texel per tap
  float _pad;
  vec2  subScale;   // fraction of the image this blur occupies
  vec2  texel;      // (1/imageWidth, 1/imageHeight)
} pc;

void main() {
  // Precomputed Gaussian weights for offsets 0..4 (normalized).
  const float w0 = 0.2270270270;
  const float w1 = 0.1945945946;
  const float w2 = 0.1216216216;
  const float w3 = 0.0540540541;
  const float w4 = 0.0162162162;

  // Destination viewport and source sub-region are the same size, so the
  // interpolated UV maps onto the sub-region by a straight scale.
  vec2 uv = vUV * pc.subScale;
  vec2 lo = 0.5 * pc.texel;
  vec2 hi = pc.subScale - 0.5 * pc.texel;
  vec2 step = pc.direction * pc.spacing;

  vec4 c = texture(uSrc, clamp(uv, lo, hi)) * w0;
  c += texture(uSrc, clamp(uv + step * 1.0, lo, hi)) * w1;
  c += texture(uSrc, clamp(uv - step * 1.0, lo, hi)) * w1;
  c += texture(uSrc, clamp(uv + step * 2.0, lo, hi)) * w2;
  c += texture(uSrc, clamp(uv - step * 2.0, lo, hi)) * w2;
  c += texture(uSrc, clamp(uv + step * 3.0, lo, hi)) * w3;
  c += texture(uSrc, clamp(uv - step * 3.0, lo, hi)) * w3;
  c += texture(uSrc, clamp(uv + step * 4.0, lo, hi)) * w4;
  c += texture(uSrc, clamp(uv - step * 4.0, lo, hi)) * w4;

  // Alpha is blurred with the colour, not forced to 1. The source is
  // premultiplied, so this is the one form where averaging is correct, and
  // content blur depends on the faded alpha to get a soft edge. Backdrop blur
  // is unaffected: it reads the resolve, which is already opaque.
  outColor = c;
}
