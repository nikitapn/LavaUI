#version 450
#extension GL_EXT_nonuniform_qualifier : require

layout(location = 0) in vec2 vLocal;
layout(location = 1) in vec2 vHalfSize;
layout(location = 2) in float vRadius;
layout(location = 3) in vec4 vColor;
layout(location = 4) flat in uint vKind;
layout(location = 5) flat in float vAux;
layout(location = 6) in vec2 vUv;
layout(location = 7) flat in uint vTextureIndex;
layout(binding = 0) uniform sampler2D textures[];
layout(location = 0) out vec4 outColor;

float sdRoundBox(vec2 p, vec2 b, float r) {
  vec2 q = abs(p) - b + r;
  return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
}

void main() {
  if (vKind == 5u) {
    float d = sdRoundBox(vLocal, vHalfSize, vRadius);
    float fall = 1.0 - smoothstep(0.0, max(vAux, 1e-4), max(d, 0.0));
    float a = vColor.a * fall * fall;
    if (a <= 0.002) discard;
    outColor = vec4(vColor.rgb * a, a);
    return;
  }

  if (vKind == 4u) {
    float d = sdRoundBox(vLocal, vHalfSize, vRadius);
    float coverage = 1.0 - smoothstep(-max(fwidth(d), 1e-5),
                                     max(fwidth(d), 1e-5), d);
    if (coverage >= 0.999) discard;
    outColor = vec4(0.0, 0.0, 0.0, coverage);
    return;
  }

  if (vKind == 6u) {
    float d = sdRoundBox(vLocal, vHalfSize, vRadius);
    float aa = max(fwidth(d), 1e-5);
    float coverage = 1.0 - smoothstep(-aa, aa, d);
    vec4 sampled = texture(textures[nonuniformEXT(vTextureIndex)], vUv) * vColor;
    float a = sampled.a * coverage;
    if (a <= 0.001) discard;
    outColor = vec4(sampled.rgb * a, a);
    return;
  }

  if (vKind == 2u) {
    vec4 c = texture(textures[nonuniformEXT(vTextureIndex)], vUv) * vColor;
    if (c.a <= 0.001) discard;
    outColor = vec4(c.rgb * c.a, c.a);
    return;
  }

  float coverage;
  if (vKind == 1u) {
    coverage = texture(textures[nonuniformEXT(vTextureIndex)], vUv).r;
  } else {
    float d = sdRoundBox(vLocal, vHalfSize, vRadius);
    float aa = max(fwidth(d), 1e-5);
    coverage = 1.0 - smoothstep(-aa, aa, d);
  }
  if (coverage <= 0.0) discard;
  vec4 c = vec4(vColor.rgb, vColor.a * coverage);
  outColor = vec4(c.rgb * c.a, c.a);
}
