#version 450

layout(location = 0) in vec2 inPos;
layout(location = 1) in vec2 inDepth;
layout(location = 2) in vec4 inColor;

layout(push_constant) uniform Push {
  vec2 viewport;
  vec2 pan;
  float zoom;
  float _pad;
} pc;

layout(location = 0) out vec4 vColor;

void main() {
  vColor = inColor;
  vec2 center = pc.viewport * 0.5;
  float z = pc.zoom > 0.0 ? pc.zoom : 1.0;
  vec2 screen = (inPos - center) * z + center + pc.pan;
  vec2 ndc = vec2(screen.x / pc.viewport.x * 2.0 - 1.0,
                  screen.y / pc.viewport.y * 2.0 - 1.0);
  gl_Position = vec4(ndc, clamp(inDepth.x, 0.0, 1.0), 1.0);
}
