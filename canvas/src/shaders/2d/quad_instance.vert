#version 450

layout(location = 0) in vec2 inTopLeft;
layout(location = 1) in vec2 inSize;
layout(location = 2) in vec2 inHalfSize;
layout(location = 3) in float inRadius;
layout(location = 4) in float inAux;
layout(location = 5) in vec2 inUv0;
layout(location = 6) in vec2 inUv1;
layout(location = 7) in vec4 inColor;
layout(location = 8) in uint inKind;
layout(location = 9) in uint inTextureIndex;

layout(push_constant) uniform Push {
  vec2 viewport;
  vec2 pan;
  float zoom;
  float _pad;
} pc;

layout(location = 0) out vec2 vLocal;
layout(location = 1) out vec2 vHalfSize;
layout(location = 2) out float vRadius;
layout(location = 3) out vec4 vColor;
layout(location = 4) flat out uint vKind;
layout(location = 5) flat out float vAux;
layout(location = 6) out vec2 vUv;
layout(location = 7) flat out uint vTextureIndex;

void main() {
  const vec2 corners[6] = vec2[6](
    vec2(0.0, 0.0), vec2(1.0, 0.0), vec2(1.0, 1.0),
    vec2(0.0, 0.0), vec2(1.0, 1.0), vec2(0.0, 1.0));
  vec2 corner = corners[gl_VertexIndex];
  vec2 position = inTopLeft + corner * inSize;
  vec2 center = pc.viewport * 0.5;
  float z = pc.zoom > 0.0 ? pc.zoom : 1.0;
  vec2 screen = (position - center) * z + center + pc.pan;

  vLocal = mix(-inSize * 0.5, inSize * 0.5, corner);
  vHalfSize = inHalfSize;
  vRadius = inRadius;
  vColor = inColor;
  vKind = inKind;
  vAux = inAux;
  vUv = mix(inUv0, inUv1, corner);
  vTextureIndex = inTextureIndex;
  gl_Position = vec4(screen.x / pc.viewport.x * 2.0 - 1.0,
                     screen.y / pc.viewport.y * 2.0 - 1.0, 0.0, 1.0);
}
