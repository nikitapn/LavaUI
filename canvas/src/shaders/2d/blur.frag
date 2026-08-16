#version 450

// Dual Kawase (Filip Strugar / KWin / Hyprland). Downsample then upsample
// through a half-res pyramid. Far cheaper than a wide Gaussian, and it
// does not stamp a 9-tap grid — that is the dithering on a sky.

layout(location = 0) in vec2 vUV;
layout(location = 0) out vec4 outColor;

layout(binding = 0) uniform sampler2D uSrc;

// Tight: vec2 + two floats = 16 bytes.
layout(push_constant) uniform Push {
  vec2  halfpixel;  // 0.5 / dest size, in dest UV
  float offset;     // typically 1
  float upsample;   // 0 downsample, 1 upsample
} pc;

void main() {
  vec2 uv = vUV;
  vec2 o = pc.halfpixel * pc.offset;

  vec4 c;
  if (pc.upsample < 0.5) {
    c  = texture(uSrc, uv) * 4.0;
    c += texture(uSrc, uv - o);
    c += texture(uSrc, uv + o);
    c += texture(uSrc, uv + vec2( o.x, -o.y));
    c += texture(uSrc, uv + vec2(-o.x,  o.y));
    c *= 0.125;
  } else {
    c  = texture(uSrc, uv + vec2(-o.x * 2.0, 0.0));
    c += texture(uSrc, uv + vec2(-o.x,  o.y)) * 2.0;
    c += texture(uSrc, uv + vec2( 0.0,  o.y * 2.0));
    c += texture(uSrc, uv + vec2( o.x,  o.y)) * 2.0;
    c += texture(uSrc, uv + vec2( o.x * 2.0, 0.0));
    c += texture(uSrc, uv + vec2( o.x, -o.y)) * 2.0;
    c += texture(uSrc, uv + vec2( 0.0, -o.y * 2.0));
    c += texture(uSrc, uv + vec2(-o.x, -o.y)) * 2.0;
    c *= (1.0 / 12.0);
  }
  outColor = c;
}
