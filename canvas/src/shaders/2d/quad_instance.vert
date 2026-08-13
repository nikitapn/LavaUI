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
// Two-stop linear ramp. `inGradAxis` is zero on everything that predates it,
// which makes `t` zero and the mix below exactly `inColor` — so this costs the
// solid path a dot product and nothing else. See QuadRenderer::Instance.
layout(location = 10) in vec4 inColor1;
layout(location = 11) in vec2 inGradAxis;
layout(location = 12) in float inGradBias;

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
/// 1 where this quad carries a gradient, 0 otherwise. Gates the dither in the
/// fragment shader, so text and images are never touched by it.
layout(location = 8) flat out float vDither;

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

  // Evaluated here rather than per fragment, and that is exact rather than a
  // saving: a two-stop ramp is an affine function of position, and affine is
  // precisely what the rasterizer's interpolation reproduces without error.
  // Multi-stop or radial would not survive this and would have to move into
  // the fragment shader.
  //
  // The clamp is what holds the end stops flat outside the ramp's own span,
  // which matters once a rounded corner or the antialias bleed pushes a
  // fragment past the corner the ramp was fitted to.
  float t = clamp(dot(corner, inGradAxis) + inGradBias, 0.0, 1.0);
  vColor = mix(inColor, inColor1, t);
  vDither = dot(inGradAxis, inGradAxis) > 0.0 ? 1.0 : 0.0;
  vKind = inKind;
  vAux = inAux;
  vUv = mix(inUv0, inUv1, corner);
  vTextureIndex = inTextureIndex;
  gl_Position = vec4(screen.x / pc.viewport.x * 2.0 - 1.0,
                     screen.y / pc.viewport.y * 2.0 - 1.0, 0.0, 1.0);
}
