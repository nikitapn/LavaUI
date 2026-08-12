#version 450
#extension GL_EXT_nonuniform_qualifier : require

layout(location = 0) in vec4 vColor;
layout(location = 1) in vec2 vUV;
layout(location = 2) flat in float vTextured;
layout(location = 3) flat in uint vTextureIndex;
layout(location = 0) out vec4 outColor;
layout(binding = 0) uniform sampler2D textures[];

void main() {
  vec4 texel = vTextured > 0.5
    ? texture(textures[nonuniformEXT(vTextureIndex)], vUV) : vec4(1.0);
  outColor = texel * vColor;
}
