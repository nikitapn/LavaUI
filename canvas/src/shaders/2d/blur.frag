#version 450

// Separable Gaussian blur. One pass is horizontal or vertical depending on
// push-constant direction. 9 taps, sigma ≈ 2 *texels*.
//
// `spacing` is expected to stay at or below 1. The kernel is a point-sampled
// Gaussian, so spacing above a texel does not widen the blur — it samples nine
// disjoint neighbourhoods and stamps nine offset copies of the source. Width
// comes from BlurPass instead: bigger texels (downscale) and repeated passes.

layout(location = 0) in vec2 vUV;
layout(location = 0) out vec4 outColor;

layout(binding = 0) uniform sampler2D uSrc;

// std140: vec2@0, float@8, float@12 → 16 bytes
layout(push_constant) uniform Push {
  vec2  direction;  // (texelW, 0) or (0, texelH) in UV space
  float spacing;    // tap spacing in texels; 1 = one texel per tap
  float _pad;
} pc;

void main() {
  // Precomputed Gaussian weights for offsets 0..4 (normalized).
  const float w0 = 0.2270270270;
  const float w1 = 0.1945945946;
  const float w2 = 0.1216216216;
  const float w3 = 0.0540540541;
  const float w4 = 0.0162162162;

  vec2 step = pc.direction * pc.spacing;
  vec4 c = texture(uSrc, vUV) * w0;
  c += texture(uSrc, vUV + step * 1.0) * w1;
  c += texture(uSrc, vUV - step * 1.0) * w1;
  c += texture(uSrc, vUV + step * 2.0) * w2;
  c += texture(uSrc, vUV - step * 2.0) * w2;
  c += texture(uSrc, vUV + step * 3.0) * w3;
  c += texture(uSrc, vUV - step * 3.0) * w3;
  c += texture(uSrc, vUV + step * 4.0) * w4;
  c += texture(uSrc, vUV - step * 4.0) * w4;
  // Opaque result so compositing never discards on near-zero alpha.
  outColor = vec4(c.rgb, 1.0);
}
