#version 450
#include "srgb.glsl"

layout(location = 0) in vec2 inPos;
layout(location = 1) in vec2 inDepth;
layout(location = 2) in vec4 inColor;
layout(location = 3) in vec2 inAux;
layout(location = 4) in uint inTextureIndex;

layout(push_constant) uniform Push {
  vec2 viewport;
  vec2 pan;
  float zoom;
  float _pad;
} pc;

layout(location = 0) out vec4 vColor;
layout(location = 1) out vec2 vUV;
layout(location = 2) flat out float vTextured;
layout(location = 3) flat out uint vTextureIndex;

void main() {
  vColor = srgbToLinear(inColor);
  vUV = vec2(inDepth.y, inAux.y);
  vTextured = inAux.x;
  vTextureIndex = inTextureIndex;
  vec2 center = pc.viewport * 0.5;
  float z = pc.zoom > 0.0 ? pc.zoom : 1.0;
  vec2 screen = (inPos - center) * z + center + pc.pan;
  vec2 ndc = vec2(screen.x / pc.viewport.x * 2.0 - 1.0,
                  screen.y / pc.viewport.y * 2.0 - 1.0);
  gl_Position = vec4(ndc, clamp(inDepth.x, 0.0, 1.0), 1.0);
}
