#ifndef LAVA_SRGB_GLSL
#define LAVA_SRGB_GLSL

// IEC 61966-2-1 EOTF. Vertex colours are authored as sRGB (a colour
// picker / `Color(r: 0.5)`); the swapchain is sRGB too, so writing the
// bytes straight through encoded them *again* and 0.5 arrived as ~0.73.
// Decode here, blend in linear, let the attachment encode on the way out.
// Alpha is not a colour and is left alone.

float srgbToLinear(float c) {
  return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4);
}

vec3 srgbToLinear(vec3 c) {
  return vec3(srgbToLinear(c.r), srgbToLinear(c.g), srgbToLinear(c.b));
}

vec4 srgbToLinear(vec4 c) {
  return vec4(srgbToLinear(c.rgb), c.a);
}

#endif
